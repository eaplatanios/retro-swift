// Copyright 2019, Emmanouil Antonios Platanios. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

import Logging
import ReinforcementLearning
import TensorFlow

fileprivate struct CartPoleActor: Layer {
  public var dense1: Dense<Float> = Dense<Float>(inputSize: 4, outputSize: 100)
  public var dense2: Dense<Float> = Dense<Float>(inputSize: 100, outputSize: 2)

  @differentiable
  public func callAsFunction(_ input: CartPoleEnvironment.Observation) -> Categorical<Int32> {
    let stackedInput = Tensor<Float>(
      stacking: [
        input.position, input.positionDerivative,
        input.angle, input.angleDerivative],
      alongAxis: input.position.rank)
    let outerDimCount = stackedInput.rank - 1
    let outerDims = [Int](stackedInput.shape.dimensions[0..<outerDimCount])
    let flattenedBatchStackedInput = stackedInput.flattenedBatch(outerDimCount: outerDimCount)
    let hidden = leakyRelu(dense1(flattenedBatchStackedInput))
    let actionLogits = dense2(hidden)
    let flattenedActionDistribution = Categorical<Int32>(logits: actionLogits)
    return flattenedActionDistribution.unflattenedBatch(outerDims: outerDims)
  }
}

fileprivate struct CartPoleActorCritic: Layer {
  public var dense1Action: Dense<Float> = Dense<Float>(inputSize: 4, outputSize: 100)
  public var dense2Action: Dense<Float> = Dense<Float>(inputSize: 100, outputSize: 2)
  public var dense1Value: Dense<Float> = Dense<Float>(inputSize: 4, outputSize: 100)
  public var dense2Value: Dense<Float> = Dense<Float>(inputSize: 100, outputSize: 1)

  @differentiable
  public func callAsFunction(
    _ input: CartPoleEnvironment.Observation
  ) -> StatelessActorCriticOutput<Categorical<Int32>> {
    let stackedInput = Tensor<Float>(
      stacking: [
        input.position, input.positionDerivative,
        input.angle, input.angleDerivative],
      alongAxis: -1)
    let outerDimCount = stackedInput.rank - 1
    let outerDims = [Int](stackedInput.shape.dimensions[0..<outerDimCount])
    let flattenedBatchStackedInput = stackedInput.flattenedBatch(outerDimCount: outerDimCount)
    let actionLogits = dense2Action(leakyRelu(dense1Action(flattenedBatchStackedInput)))
    let flattenedValue = dense2Value(leakyRelu(dense1Value(flattenedBatchStackedInput)))
    let flattenedActionDistribution = Categorical<Int32>(logits: actionLogits)
    return StatelessActorCriticOutput(
      actionDistribution: flattenedActionDistribution.unflattenedBatch(outerDims: outerDims),
      value: flattenedValue.unflattenedBatch(outerDims: outerDims).squeezingShape(at: -1))
  }
}

fileprivate struct CartPoleQNetwork: Layer & Copyable {
  public var dense1: Dense<Float> = Dense<Float>(inputSize: 4, outputSize: 100)
  public var dense2: Dense<Float> = Dense<Float>(inputSize: 100, outputSize: 2)

  @differentiable
  public func callAsFunction(_ input: CartPoleEnvironment.Observation) -> Tensor<Float> {
    let stackedInput = Tensor<Float>(
      stacking: [
        input.position, input.positionDerivative,
        input.angle, input.angleDerivative],
      alongAxis: input.position.rank)
    let outerDimCount = stackedInput.rank - 1
    let outerDims = [Int](stackedInput.shape.dimensions[0..<outerDimCount])
    let flattenedBatchStackedInput = stackedInput.flattenedBatch(outerDimCount: outerDimCount)
    let hidden = leakyRelu(dense1(flattenedBatchStackedInput))
    let flattenedQValues = dense2(hidden)
    return flattenedQValues.unflattenedBatch(outerDims: outerDims)
  }

  public func copy() -> CartPoleQNetwork { self }
}

public func runCartPole(
  using agentType: AgentType,
  batchSize: Int = 32,
  maxEpisodes: Int = 32,
  maxReplayedSequenceLength: Int = 1000,
  discountFactor: Float = 0.9,
  entropyRegularizationWeight: Float = 0.01
) throws {
  let logger = Logger(label: "Cart-Pole Experiment")
  var environment = CartPoleEnvironment(batchSize: batchSize)
  var averageEpisodeLength = AverageEpisodeLength<CartPoleEnvironment, Empty>(
    for: environment,
    bufferSize: 10)
  var agent: AnyAgent<CartPoleEnvironment, Empty> = {
    switch agentType {
    case .reinforce:
      return AnyAgent(ReinforceAgent(
        for: environment,
        network: CartPoleActor(),
        optimizer: { AMSGrad(for: $0, learningRate: 1e-3) },
        discountFactor: discountFactor,
        entropyRegularizationWeight: entropyRegularizationWeight))
    case .advantageActorCritic:
      return AnyAgent(A2CAgent(
        for: environment,
        network: CartPoleActorCritic(),
        optimizer: { AMSGrad(for: $0, learningRate: 1e-3) },
        advantageFunction: GeneralizedAdvantageEstimation(discountFactor: discountFactor),
        entropyRegularizationWeight: entropyRegularizationWeight))
    case .ppo:
      return AnyAgent(PPOAgent(
        for: environment,
        network: CartPoleActorCritic(),
        optimizer: { AMSGrad(for: $0) },
        learningRate: LinearlyDecayedLearningRate(
          baseLearningRate: FixedLearningRate(Float(1e-3)),
          slope: -1e-3 / 100.0,
          lowerBound: 1e-6),
        advantageFunction: GeneralizedAdvantageEstimation(
          discountFactor: 0.99,
          discountWeight: 0.95)))
    case .dqn:
      return AnyAgent(DQNAgent(
        for: environment,
        qNetwork: CartPoleQNetwork(),
        optimizer: { AMSGrad(for: $0, learningRate: 1e-3) },
        trainSequenceLength: 1,
        maxReplayedSequenceLength: maxReplayedSequenceLength,
        epsilonGreedy: 0.1,
        targetUpdateForgetFactor: 0.95,
        targetUpdatePeriod: 5,
        discountFactor: 0.99,
        trainStepsPerIteration: 1))
    }
  }()

  for step in 0..<10000 {
    let loss = try agent.update(
      using: &environment,
      maxSteps: maxReplayedSequenceLength * batchSize,
      maxEpisodes: maxEpisodes,
      callbacks: [{ (environment, trajectory) in
        averageEpisodeLength.update(using: trajectory)
        if step > 0 { environment.render() }
      }])
    if step % 1 == 0 {
      logger.info("Step \(step) | Loss: \(loss) | Average Episode Length: \(averageEpisodeLength.value())")
    }
  }
}
