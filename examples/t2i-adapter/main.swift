import Foundation
import NNC
import NNCPythonConversion
import PythonKit

let ldm_modules_encoders_adapter = Python.import("ldm.modules.encoders.adapter")
let torch = Python.import("torch")
let random = Python.import("random")
let numpy = Python.import("numpy")

func ResnetBlock(outChannels: Int, inConv: Bool) -> (
  Model?, Model, Model, Model
) {
  let x = Input()
  let outX: Model.IO
  var skipModel: Model? = nil
  if inConv {
    let skip = Convolution(
      groups: 1, filters: outChannels, filterSize: [1, 1],
      hint: Hint(stride: [1, 1]))
    outX = skip(x)
    skipModel = skip
  } else {
    outX = x
  }
  let inLayerConv2d = Convolution(
    groups: 1, filters: outChannels, filterSize: [3, 3],
    hint: Hint(stride: [1, 1], border: Hint.Border(begin: [1, 1], end: [1, 1])))
  var out = inLayerConv2d(outX)
  out = ReLU()(out)
  // Dropout if needed in the future (for training).
  let outLayerConv2d = Convolution(
    groups: 1, filters: outChannels, filterSize: [1, 1],
    hint: Hint(stride: [1, 1]))
  out = outLayerConv2d(out) + outX
  return (
    skipModel, inLayerConv2d, outLayerConv2d, Model([x], [out])
  )
}

func Adapter(
  channels: [Int], numRepeat: Int
) -> ((PythonObject) -> Void, Model) {
  let x = Input()
  let convIn = Convolution(
    groups: 1, filters: channels[0], filterSize: [3, 3],
    hint: Hint(stride: [1, 1], border: Hint.Border(begin: [1, 1], end: [1, 1])))
  var out = convIn(x)
  var readers = [(PythonObject) -> Void]()
  var previousChannel = channels[0]
  var outs = [Model.IO]()
  for (i, channel) in channels.enumerated() {
    for j in 0..<numRepeat {
      let (skipModel, inLayerConv2d, outLayerConv2d, resnetBlock) = ResnetBlock(outChannels: channel, inConv: previousChannel != channel)
      previousChannel = channel
      out = resnetBlock(out)
      let reader: (PythonObject) -> Void = { state_dict in
        let block1_weight = state_dict["body.\(i * numRepeat + j).block1.weight"].numpy()
        let block1_bias = state_dict["body.\(i * numRepeat + j).block1.bias"].numpy()
        inLayerConv2d.parameters(for: .weight).copy(from: try! Tensor<Float>(numpy: block1_weight))
        inLayerConv2d.parameters(for: .bias).copy(from: try! Tensor<Float>(numpy: block1_bias))
        let block2_weight = state_dict["body.\(i * numRepeat + j).block2.weight"].numpy()
        let block2_bias = state_dict["body.\(i * numRepeat + j).block2.bias"].numpy()
        outLayerConv2d.parameters(for: .weight).copy(from: try! Tensor<Float>(numpy: block2_weight))
        outLayerConv2d.parameters(for: .bias).copy(from: try! Tensor<Float>(numpy: block2_bias))
        if let skipModel = skipModel {
          let in_conv_weight = state_dict["body.\(i * numRepeat + j).in_conv.weight"].numpy()
          let in_conv_bias = state_dict["body.\(i * numRepeat + j).in_conv.bias"].numpy()
          skipModel.parameters(for: .weight).copy(from: try! Tensor<Float>(numpy: in_conv_weight))
          skipModel.parameters(for: .bias).copy(from: try! Tensor<Float>(numpy: in_conv_bias))
        }
      }
      readers.append(reader)
    }
    outs.append(out)
    if i != channels.count - 1 {
      let downsample = AveragePool(filterSize: [2, 2], hint: Hint(stride: [2, 2]))
      out = downsample(out)
    }
  }
  let reader: (PythonObject) -> Void = { state_dict in
    let conv_in_weight = state_dict["conv_in.weight"].numpy()
    let conv_in_bias = state_dict["conv_in.bias"].numpy()
    convIn.parameters(for: .weight).copy(from: try! Tensor<Float>(numpy: conv_in_weight))
    convIn.parameters(for: .bias).copy(from: try! Tensor<Float>(numpy: conv_in_bias))
    for reader in readers {
      reader(state_dict)
    }
  }
  return (reader, Model([x], outs))
}

random.seed(42)
numpy.random.seed(42)
torch.manual_seed(42)
torch.cuda.manual_seed_all(42)

let hint = torch.randn([2, 1, 512, 512])

let adapter = ldm_modules_encoders_adapter.Adapter(cin: 64, channels: [320, 640, 1280, 1280], nums_rb: 2, ksize: 1, sk: true, use_conv: false).to(torch.device("cpu"))
adapter.load_state_dict(torch.load("/home/liu/workspace/T2I-Adapter/models/t2iadapter_canny_sd14v1.pth"))
let state_dict = adapter.state_dict()
let ret = adapter(hint)
print(ret[0])

let graph = DynamicGraph()
let hintTensor = graph.variable(try! Tensor<Float>(numpy: hint.numpy())).toGPU(0)
let (reader, adapternet) = Adapter(channels: [320, 640, 1280, 1280], numRepeat: 2)
graph.workspaceSize = 1_024 * 1_024 * 1_024
graph.withNoGrad {
  let hintIn = hintTensor.reshaped(format: .NCHW, shape: [2, 1, 64, 8, 64, 8]).permuted(0, 1, 3, 5, 2, 4).copied().reshaped(.NCHW(2, 64, 64, 64))
  var controls = adapternet(inputs: hintIn).map { $0.as(of: Float.self) }
  reader(state_dict)
  controls = adapternet(inputs: hintIn).map { $0.as(of: Float.self) }
  debugPrint(controls[0])
  /*
  graph.openStore("/home/liu/workspace/swift-diffusion/adapter.ckpt") {
    $0.write("adapter", model: adapter)
  }
  */
}
