import CoreAI
import Foundation

/// laya-aot-probe — the AOT cache truth-probe for the ship flow:
/// does AIModelCache answer when the source .aimodel is gone?
///
///   laya-aot-probe <asset.aimodel dir> [--compile]
///
/// --compile: specialize+persist with NO purge conditions first (the
/// first-launch AOT step), then report. Without it: only ask the cache
/// (the later-launch step). Run it with the asset hidden to answer the
/// deletion question empirically.

if #available(macOS 27.0, *) {
    aotMain()
} else {
    FileHandle.standardError.write(Data("macOS 27 required\n".utf8))
    exit(1)
}

@available(macOS 27.0, *)
func aotMain() {
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
    let flags = Set(CommandLine.arguments.filter { $0.hasPrefix("--") })
    guard let path = args.first else {
        FileHandle.standardError.write(Data("usage: laya-aot-probe <asset.aimodel> [--compile]\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
    let opts = SpecializationOptions(preferredComputeUnitKind: .gpu)

    func report(_ m: AIModel?, _ label: String) {
        guard let m else { print("\(label): CACHE MISS (nil)"); return }
        print("\(label): CACHE HIT functions=\(m.functionNames)")
        do {
            if let f = try m.loadFunction(named: m.functionNames.first ?? "") {
                print("\(label): loadFunction OK")
            }
        } catch {
            print("\(label): loadFunction failed: \(error)")
        }
    }

    if flags.contains("--compile") {
        let t0 = Date()
        Task {
            do {
                // Ship-flow first launch: no purge conditions — the compiled
                // delegate is not a discardable cache entry.
                let m = try await AIModel.specialize(
                    contentsOf: url, options: opts, cache: .default,
                    cachePolicy: AIModelCache.Policy(purgeConditions: []))
                print(String(format: "compiled in %.2f s", Date().timeIntervalSince(t0)))
                report(m, "post-compile")
                exit(0)
            } catch {
                print("compile failed: \(error)")
                exit(1)
            }
        }
        // park the main thread while the Task runs
        RunLoop.main.run()
    } else {
        do {
            report(try AIModelCache.default.model(for: url, options: opts), "cache ask")
        } catch {
            print("cache ask threw: \(error)")
            exit(1)
        }
    }
}
