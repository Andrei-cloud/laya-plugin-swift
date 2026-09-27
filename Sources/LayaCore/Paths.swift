import Foundation

/// Asset-path resolution shared by layad and the laya CLI — no
/// machine-specific defaults live in source. Chain:
///
///   1. LAYA_ASSETS env (canonical; JEV_* alias via Naming.envAlias)
///   2. "assets" in ~/.config/laya/daemon.json (the macOS setup's
///      single source of truth)
///   3. ~/.laya/model/laya-combined-f16.aimodel (the documented HF
///      download location: `hf download AndyInQtr/laya-decision-plugin
///      --local-dir ~/.laya/model`)
///
/// Same for "source" (the directory holding tokenizer/tokenizer.json):
/// LAYA_SOURCE → daemon.json → ~/.laya/model/configs.
public enum LayaPaths {
    public static let bundleName = "laya-combined-f16.aimodel"

    private static var configDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/laya")
    }

    private static func configValue(_ key: String) -> String? {
        let p = (configDir as NSString).appendingPathComponent("daemon.json")
        guard let data = FileManager.default.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj[key] as? String, !s.isEmpty
        else { return nil }
        return (s as NSString).expandingTildeInPath
    }

    private static func firstExistingDir(_ candidates: [String]) -> String {
        for c in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue {
                return c
            }
        }
        return candidates.first ?? ""
    }

    /// (assets, source) — assets may name the .aimodel bundle itself or
    /// a release directory containing it; callers keep distinguishing
    /// that by leaf name (a bundle IS a directory).
    public static func resolve() -> (assets: String, source: String) {
        let hfAssets = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".laya/model/\(bundleName)")
        let hfRelease = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".laya/model")
        let assets = Naming.envAlias("ASSETS")
            ?? configValue("assets")
            ?? (FileManager.default.fileExists(atPath: hfAssets, isDirectory: nil)
                ? hfAssets : hfRelease)
        let source = Naming.envAlias("SOURCE")
            ?? configValue("source")
            ?? firstExistingDir([
                (assets as NSString).appendingPathComponent("configs"),
                (hfRelease as NSString).appendingPathComponent("configs"),
            ])
        return (assets, source)
    }
}
