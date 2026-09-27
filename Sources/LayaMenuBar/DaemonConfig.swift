import Foundation

// Shared configuration model for the macOS native setup.
//
// ~/.config/laya/daemon.json is the single source of truth. The launchd
// plist (~/Library/LaunchAgents/com.laya.daemon.plist) is a GENERATED
// artifact — LayaMenuBar --render-plist rebuilds it from the JSON, so
// install.sh and the Settings window can never drift apart.
//
// Secrets policy: `token` is the loopback Bearer token; the config file
// is written 0600 and the token never appears in logs or the menu.

struct DaemonConfig: Codable, Equatable {
    /// The model root — the directory `hf download
    /// AndyInQtr/laya-decision-plugin` puts the bundle AND its
    /// sidecars (configs/tokenizer, rl_agent_config calibration,
    /// combined_provenance.json) into. There is deliberately NO
    /// `source` parameter: everything else is derived from this
    /// directory (see LayaPaths.probe).
    var assets: String
    var unit: String          // gpu | ne | cpu
    var port: Int
    var grpcPort: Int
    var token: String         // "" = no auth (loopback default)

    static let label = "com.laya.daemon"

    static var configDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/laya")
    }
    static var configFile: String {
        (configDir as NSString).appendingPathComponent("daemon.json")
    }
    static var plistFile: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var logDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/laya")
    }
    static var daemonBinary: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/layad")
    }

    static var defaults: DaemonConfig {
        // Derived from $HOME at runtime (repo rule: no personal paths in
        // tracked files or literals). ~/.laya/model is the documented
        // HF download location:
        //   hf download AndyInQtr/laya-decision-plugin --local-dir ~/.laya/model
        DaemonConfig(
            assets: (NSHomeDirectory() as NSString)
                .appendingPathComponent(".laya/model"),
            unit: "ne", port: 11270, grpcPort: 11271, token: "")
    }

    static func load() -> DaemonConfig {
        if let data = FileManager.default.contents(atPath: configFile),
           let cfg = try? JSONDecoder().decode(DaemonConfig.self, from: data) {
            return cfg
        }
        return .defaults
    }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.configDir,
                               withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        // 0600 before the write: the token must never be world-readable,
        // not even in the window between create and chmod.
        fm.createFile(atPath: Self.configFile, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        try data.write(to: URL(fileURLWithPath: Self.configFile))
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: Self.configFile)
    }

    /// launchd EnvironmentVariables for the daemon.
    var environment: [String: String] {
        // LAYA_ASSETS carries the model root; the daemon derives the
        // sidecar dir from it (LayaPaths). No LAYA_SOURCE.
        var env: [String: String] = [
            "LAYA_ASSETS": assets,
            "LAYA_UNIT": unit,
            "LAYA_PORT": String(port),
            "LAYA_GRPC_PORT": String(grpcPort),
        ]
        if !token.isEmpty { env["LAYA_TOKEN"] = token }
        return env
    }

    /// The launchd plist XML (XML property list, same layout the Python
    /// daemon's agent used: KeepAlive + RunAtLoad + ThrottleInterval).
    func renderedPlist() throws -> Data {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.logDir,
                                withIntermediateDirectories: true)
        let log = (Self.logDir as NSString).appendingPathComponent("daemon.log")
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [Self.daemonBinary],
            "WorkingDirectory": NSHomeDirectory(),
            "EnvironmentVariables": environment,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
    }
}
