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

import ReinforcementLearning

fileprivate struct CartPoleActor: Network {
  @noDerivative public var state: None = None()

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

fileprivate struct CartPoleActorCritic: Network {
  @noDerivative public var state: None = None()

  public var dense1Action: Dense<Float> = Dense<Float>(inputSize: 4, outputSize: 100)
  public var dense2Action: Dense<Float> = Dense<Float>(inputSize: 100, outputSize: 2)
  public var dense1Value: Dense<Float> = Dense<Float>(inputSize: 4, outputSize: 100)
  public var dense2Value: Dense<Float> = Dense<Float>(inputSize: 100, outputSize: 1)

  @differentiable
  public func callAsFunction(
    _ input: CartPoleEnvironment.Observation
  ) -> ActorCriticOutput<Categorical<Int32>> {
    let stackedInput = Tensor<Float>(
      stacking: [
        input.position, input.positionDerivative,
        input.angle, input.angleDerivative],
      alongAxis: input.position.rank)
    let outerDimCount = stackedInput.rank - 1
    let outerDims = [Int](stackedInput.shape.dimensions[0..<outerDimCount])
    let flattenedBatchStackedInput = stackedInput.flattenedBatch(outerDimCount: outerDimCount)
    let actionLogits = dense2Action(leakyRelu(dense1Action(flattenedBatchStackedInput)))
    let flattenedValue = dense2Value(leakyRelu(dense1Value(flattenedBatchStackedInput)))
    let flattenedActionDistribution = Categorical<Int32>(logits: actionLogits)
    return ActorCriticOutput(
      actionDistribution: flattenedActionDistribution.unflattenedBatch(outerDims: outerDims),
      value: flattenedValue.unflattenedBatch(outerDims: outerDims).squeezingShape(at: -1))
  }
}

public func runCartPole(
  using agentType: AgentType,
  batchSize: Int = 32,
  maxEpisodes: Int = 32,
  maxReplayedSequenceLength: Int = 1000,
  discountFactor: Float = 0.9,
  entropyRegularizationWeight: Float = 0.0
) {
  // Environment:
  var environment = CartPoleEnvironment(batchSize: batchSize)
  var renderer = CartPoleRenderer()

  // Metrics:
  var averageEpisodeLength = AverageEpisodeLength<
    CartPoleEnvironment.Observation,
    Tensor<Int32>,
    Tensor<Float>,
    None
  >(batchSize: batchSize, bufferSize: 10)
  
  // Training Loop:
  func train<A: Agent>(
    agent: inout A
  ) where A.Environment == CartPoleEnvironment, A.State == None {
    for step in 0..<10000 {
      let loss = agent.update(
        using: &environment,
        maxSteps: maxReplayedSequenceLength * batchSize,
        maxEpisodes: maxEpisodes,
        stepCallbacks: [{ trajectory in
          averageEpisodeLength.update(using: trajectory)
          if step > 100 {
            try! renderer.render(trajectory.observation)
          }
        }])
      if step % 1 == 0 {
        print("Step \(step) | Loss: \(loss) | Average Episode Length: \(averageEpisodeLength.value())")
      }
    }
  }

  // Agent Type:
  switch agentType {
    case .reinforce:
      let network = CartPoleActor()
      var agent = ReinforceAgent(
        for: environment,
        network: network,
        optimizer: AMSGrad(for: network, learningRate: 1e-3),
        maxReplayedSequenceLength: maxReplayedSequenceLength,
        discountFactor: discountFactor,
        returnsNormalizer: { standardNormalize($0, alongAxes: 0, 1) },
        entropyRegularizationWeight: entropyRegularizationWeight)
      train(agent: &agent)
    case .advantageActorCritic:
      let network = CartPoleActorCritic()
      var agent = AdvantageActorCriticAgent(
        for: environment,
        network: network,
        optimizer: AMSGrad(for: network, learningRate: 1e-3),
        maxReplayedSequenceLength: maxReplayedSequenceLength,
        advantageFunction: GeneralizedAdvantageEstimation(discountFactor: discountFactor),
        advantagesNormalizer: { standardNormalize($0, alongAxes: 0, 1) },
        entropyRegularizationWeight: entropyRegularizationWeight)
      train(agent: &agent)
  }
}