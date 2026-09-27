// layacoreai-probe: live smoke test of the native CoreAI runtime against the
// shipped laya asset. Proves the Swift inference path end-to-end:
// specialize -> loadFunction -> run -> logits/act, and prints the shapes the
// engine port binds to.
//
// CoreAI is macOS 27+ with copy-ownership values (RawView/MutableView are
// ~Escapable, RawSpan construction is not available in this overlay): build
// inputs from NDArray.View(span: array.span, shape:) views.
import Foundation
import CoreAI

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("FATAL: " + msg + "\n").utf8))
    exit(1)
}

if #available(macOS 27.0, *) {
    await probeMain()
} else {
    die("macOS 27 required for CoreAI")
}

@available(macOS 27.0, *)
func probeMain() async {
    let assetPath = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
        ?? "/Users/andrei/Developer/ai/laya/models/coreai/laya-combined-f16.aimodel"
    let unitArg = CommandLine.arguments.first(where: { $0.hasPrefix("--unit=") })?
        .replacingOccurrences(of: "--unit=", with: "") ?? "gpu"

    print("asset:", assetPath)
    print("unit:", unitArg)
    print("available compute kinds:", ComputeUnitKind.availableKinds.map { String(describing: $0) }.joined(separator: ","))

    let t0 = Date()
    let opts: SpecializationOptions
    switch unitArg {
    case "cpu": opts = .cpuOnly
    case "gpu": opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
    case "ne":  opts = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    default:    opts = .default
    }

    let model: AIModel
    do {
        model = try await AIModel.specialize(contentsOf: URL(fileURLWithPath: assetPath), options: opts)
    } catch {
        die("specialize failed: \(error)")
    }
    print(String(format: "specialize+load: %.2f s", Date().timeIntervalSince(t0)))
    print("functionNames:", model.functionNames)

    guard let fname = model.functionNames.first else { die("asset has no functions") }
    let fn: InferenceFunction
    do {
        guard let f = try model.loadFunction(named: fname) else { die("loadFunction returned nil") }
        fn = f
    } catch { die("loadFunction: \(error)") }

    let desc = fn.descriptor
    print("function:", desc.name, "inputs:", desc.inputNames, "outputs:", desc.outputNames)
    for n in desc.inputNames {
        if case .ndArray(let nd)? = desc.inputDescriptor(of: n) {
            print("  in  \(n): \(nd.shape) \(nd.scalarType) dynamic=\(nd.hasDynamicShape)")
        }
    }
    for n in desc.outputNames {
        if case .ndArray(let nd)? = desc.outputDescriptor(of: n) {
            print("  out \(n): \(nd.shape) \(nd.scalarType)")
        }
    }

    // B is static (1); L and K are dynamic dims (L in [16,1024], K in [2,128])
    // per combined_provenance.json — the same source CombinedAgent reads.
    guard case .ndArray(let idsDesc)? = desc.inputDescriptor(of: "input_ids"),
          idsDesc.shape.count == 2 else { die("no 2-D input_ids descriptor") }
    let B = idsDesc.shape[0] >= 1 ? idsDesc.shape[0] : 1
    var L = 64, K = 128
    let provPath = ((assetPath as NSString).appendingPathComponent("..") as NSString)
        .appendingPathComponent("combined_provenance.json")
    if let data = FileManager.default.contents(atPath: provPath),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let shape = obj["shape"] as? [String: Any] {
        L = (shape["L_max"] as? Int) ?? L
        K = (shape["K_max"] as? Int) ?? K
    }
    print("resolved shape: B=\(B) L=\(L) K=\(K) (dynamic L/K)")

    do {
        try await runProbe(fn, unitArg + " cold", B: B, L: L, K: K)
        try await runProbe(fn, unitArg + " warm", B: B, L: L, K: K)
        try await runProbe(fn, unitArg + " warm2", B: B, L: L, K: K)
    } catch {
        die("run failed: \(error)")
    }
    print("PROBE OK")
}

// A valid padding batch: ids/qtype/marker_pos 0, attention 1, marker_mask true.
// View<Element>(span:shape:) borrows the Swift arrays; Inputs is
// lifetime-dependent on them, so build-and-run must share one frame.
@available(macOS 27.0, *)
func runProbe(_ fn: InferenceFunction, _ unit: String, B: Int, L: Int, K: Int) async throws {
    let ids = [Int32](repeating: 0, count: B * L)
    let att = [Int32](repeating: 1, count: B * L)
    let mpos = [Int32](repeating: 0, count: B * K)
    let mmask = [Bool](repeating: true, count: B * K)
    let qt = [Int32](repeating: 0, count: B)
    let headIdx = [Int32](repeating: 0, count: B)   // chain 0 = base

    var inputs = InferenceFunction.Inputs()
    inputs.insert(NDArray.View(span: ids.span, shape: [B, L]), for: "input_ids")
    inputs.insert(NDArray.View(span: att.span, shape: [B, L]), for: "attention_mask")
    inputs.insert(NDArray.View(span: mpos.span, shape: [B, K]), for: "marker_pos")
    inputs.insert(NDArray.View(span: mmask.span, shape: [B, K]), for: "marker_mask")
    inputs.insert(NDArray.View(span: qt.span, shape: [B]), for: "qtype")
    inputs.insert(NDArray.View(span: headIdx.span, shape: [B]), for: "head_idx")

    let tRun = Date()
    var outputs = try await fn.run(inputs: inputs)
    print(String(format: "run(%@): %.1f ms", unit, Date().timeIntervalSince(tRun) * 1000))
    for n in outputs.names {
        if let v = outputs.remove(n), let nd = v.ndArray {
            print("out \(n): shape \(nd.shape) \(nd.scalarType)")
        }
    }
}
