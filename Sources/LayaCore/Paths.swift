import Foundation

/// Asset-path resolution shared by layad and the laya CLI.
///
/// ONE parameter identifies a complete installation: the model root —
/// the directory the HF model repo is downloaded into. The repo
/// (AndyInQtr/laya-decision-plugin) ships everything the engine needs:
///
///   <root>/laya-combined-f16.aimodel/   the weights (bundle)
///   <root>/combined_provenance.json     chain identity + L/K shapes
///   <root>/configs/tokenizer/           the 34 MB BPE vocab
///   <root>/configs/rl_agent_config.json + per-chain *.rl_agent_config.json
///                                       fitted calibration temperatures
///
/// so there is no separate `source` parameter anywhere (config file,
/// Settings window, env, docs): the sidecar directory is DERIVED from
/// the model folder. Resolution chain:
///
///   LAYA_MODEL_DIR env (canonical; JEV_* alias via Naming.envAlias)
///     → "modelDir" (or legacy "assets") in ~/.config/laya/daemon.json
///     → ~/.laya/model — the documented download location:
///        hf download AndyInQtr/laya-decision-plugin --local-dir ~/.laya/model
///
/// `probe` accepts any spelling that names a COMPLETE root: the root
/// itself, the .aimodel bundle inside it (parent is taken), or a legacy
/// dev layout whose sidecars live at <root>/../source. An incomplete
/// download is not silently patched over — resolve() hands back the
/// configured path and Engine's named-file LoadError is what the
/// operator sees.
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

    private static func has(_ dir: String, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: ((dir as NSString)
            .appendingPathComponent(rel) as NSString).standardizingPath)
    }

    /// Validate + decompose a candidate model root.
    /// Returns (bundlePath, sidecarDir) or nil when the installation is
    /// incomplete (bundle, provenance, and tokenizer must all resolve).
    public static func probe(_ candidate: String) -> (bundle: String, sidecar: String)? {
        let norm = (candidate as NSString).standardizingPath
        // Which root does this path name? The bundle itself -> its parent.
        let root: String
        if (norm as NSString).lastPathComponent == bundleName {
            root = ((norm as NSString).appendingPathComponent("..") as NSString)
                .standardizingPath
        } else if has(norm, bundleName) {
            root = norm                       // release/HF layout: root holds the bundle
        } else {
            return nil
        }
        // provenance: at the root (HF) — a bundle-sibling by definition.
        guard has(root, "combined_provenance.json") else { return nil }
        // sidecar candidates, HF layout first, legacy dev layouts after.
        let candidates = [
            (root as NSString).appendingPathComponent("configs"),   // HF release
            root,                                                    // tokenizer at root
            ((root as NSString).appendingPathComponent("../source") as NSString)
                .standardizingPath,                                  // dev layout
        ]
        for c in candidates where has(c, "tokenizer/tokenizer.json") {
            return ((root as NSString).appendingPathComponent(bundleName), c)
        }
        return nil
    }

    /// (bundle, sidecar) for this machine. Never guesses a personal
    /// path. When nothing probes complete, returns the configured
    /// spelling so Engine's LoadError names what the operator set up.
    public static func resolve() -> (bundle: String, sidecar: String) {
        let hf = (NSHomeDirectory() as NSString).appendingPathComponent(".laya/model")
        let configured = Naming.envAlias("MODEL_DIR")
            ?? Naming.envAlias("ASSETS")   // pre-0.2 spelling (same meaning:
            ?? configValue("modelDir")     //  root or bundle path)
            ?? configValue("assets")
            ?? hf
        if var ok = probe(configured) {
            if let src = Naming.envAlias("SOURCE") { ok.sidecar = src }  // dev escape hatch
            return ok
        }
        if configured != hf, var ok = probe(hf) {
            if let src = Naming.envAlias("SOURCE") { ok.sidecar = src }
            return ok
        }
        return ((hf as NSString).appendingPathComponent(bundleName),
                (hf as NSString).appendingPathComponent("configs"))
    }
}
