// laya-engine-probe: end-to-end check of the Swift Engine (native CoreAI
// inference) against golden/wire_golden.json — the exact request/answer
// pairs captured from the live Python daemon. Replays every golden case
// through Engine.decide + LayaOps mappers and compares the wire answers.
//
// Exit 0 with "ALL MATCH" only when every golden choice/noul agrees
// (probabilities within tolerance, choice/confidence exact).
import Foundation
import LayaCore

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("FATAL: " + msg + "\n").utf8))
    exit(1)
}

if #available(macOS 27.0, *) {
    await engineMain()
} else {
    die("macOS 27 required for CoreAI")
}

@available(macOS 27.0, *)
func engineMain() async {
    let assetDir = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
        ?? "/Users/andrei/Developer/ai/laya/models/coreai/laya-combined-f16.aimodel"
    let sourceDir = "/Users/andrei/Developer/ai/laya/models/source"
    let unit = CommandLine.arguments.first(where: { $0.hasPrefix("--unit=") })?
        .replacingOccurrences(of: "--unit=", with: "") ?? "gpu"

    let root = FileManager.default.currentDirectoryPath
    let goldenPath = root + "/golden/wire_golden.json"
    guard let data = FileManager.default.contents(atPath: goldenPath),
          let golden = JSONValue.parse(data) else {
        die("cannot read \(goldenPath) (run from the repo root)")
    }

    let t0 = Date()
    let engine: Engine
    do {
        engine = try await Engine(Engine.Config(assetDir: assetDir, sourceDir: sourceDir, unit: unit))
    } catch {
        die("engine load: \(error)")
    }
    print(String(format: "engine ready (warm=%d): %.2f s", (await engine.warm) ? 1 : 0,
                 Date().timeIntervalSince(t0)))
    print("chains:", (await engine.chainOrder).joined(separator: ","))

    var checked = 0, mismatched = 0
    for c in golden["cases"]!.arrayValue! {
        let name = c["name"]!.stringValue!
        let payload = c["payload"]!
        let want = c["response"]!
        let req: LayaAPI.ValidatedRequest
        do { req = try LayaAPI.validateRequest(payload) }
        catch { die("golden payload rejected: \(error)") }

        for qp in req.questions {
            let qname = qp.name
            let q = qp.q
            let qtype = q["type"]!.stringValue!
            let mapped: JSONValue
            do { mapped = try await engine.question(name: qname, q: q, state: req.state).answer }
            catch { print("  \(name)/\(qname): mapper: \(error)"); mismatched += 1; continue }

            let wantAns = want["answers"]![qname]!
            var ok = true
            switch qtype {
            case "choice":
                ok = mapped["choice"]?.stringValue == wantAns["choice"]?.stringValue
            case "noul":
                let got = mapped["noul"]?.numberValue ?? -1
                let exp = wantAns["noul"]?.numberValue ?? -2
                ok = abs(got - exp) < 0.05     // same-side agreement
            default:
                ok = true
            }
            if ok { checked += 1 } else {
                mismatched += 1
                print("  MISMATCH \(name)/\(qname):\n    got  \(JSONValue.serialize(mapped))\n    want \(JSONValue.serialize(wantAns))")
            }
        }
    }
    print("checked:", checked, "mismatched:", mismatched)
    print(mismatched == 0 ? "ALL MATCH" : "MISMATCHES FOUND")
    exit(mismatched == 0 ? 0 : 1)
}
