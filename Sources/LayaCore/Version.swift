import Foundation

/// Single source of truth for the shipped version. Bump HERE only —
/// layad, the laya CLI (--version), and laya-menubar (--version) all
/// report this value, and install scripts / release tags must match it
/// (`laya --version` is what an agent validates against before deciding
/// whether to reinstall).
public enum LayaVersion {
    /// Semantic version of the Swift port (layad + laya + laya-menubar).
    /// 0.2.0: the `source` parameter is GONE — the model root derives
    /// everything (HF layout). Old configs load unchanged (unknown keys
    /// ignored, legacy "assets" honored). Agents that pinned 0.1.0 must
    /// upgrade to get derivation; the agent installer's version rule
    /// only rebuilds on a bump, so schema-visible changes ALWAYS bump.
    public static let string = "0.3.1"

    /// One-line identity printed by --version everywhere:
    ///   layad 0.1.0 (swift; coreai; macos-27)
    public static var banner: String {
        "laya \(string) (swift; coreai; macOS \(ProcessInfo.processInfo.operatingSystemVersionString))"
    }

    /// `--version` / `-v` handling for binaries without ArgumentParser
    /// (layad, laya-menubar). Prints and exits 0.
    public static func handleIfRequested(_ argv: [String]) {
        if argv.contains("--version") || argv.contains("-v") {
            print(banner)
            exit(0)
        }
    }
}
