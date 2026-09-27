import Foundation

/// The ONE env/config alias resolver (decision D6) — Swift port of
/// server/naming.py. Every read of the Laya external surface goes through
/// `envAlias`: canonical `LAYA_<NAME>` first, then `JEV_<NAME>`, then the
/// explicitly-listed third alias (`TYPESAFE_*`, `DASHBOARD_TOKEN`). When two
/// namespaces are BOTH set with DIFFERENT values, the canonical `LAYA_*`
/// wins, the divergence is recorded ONCE per name — never raised. Empty
/// env values count as unset.
///
/// SECURITY RULE (binding, mirrors the Python module): secret values
/// (SECRET_KEYS) are NEVER logged, warned, or reported — presence/source/
/// length only.
public enum Naming {
    static let aliasTable: [String: [String]] = [
        "ROUTING_CONFIG": ["LAYA_ROUTING_CONFIG", "JEV_ROUTING_CONFIG"],
        "LADDER_STATE": ["LAYA_LADDER_STATE", "JEV_LADDER_STATE"],
        "MEMO": ["LAYA_MEMO", "JEV_MEMO"],
        "MIN_CONFIDENCE": ["LAYA_MIN_CONFIDENCE", "JEV_MIN_CONFIDENCE"],
        "MODEL": ["LAYA_MODEL", "JEV_MODEL", "TYPESAFE_MODEL"],
        "API_KEY": ["LAYA_API_KEY", "JEV_API_KEY", "TYPESAFE_API_KEY"],
        "PROBE_ALLOWLIST": ["LAYA_PROBE_ALLOWLIST", "JEV_PROBE_ALLOWLIST"],
        "PLAN_MODEL": ["LAYA_PLAN_MODEL", "JEV_PLAN_MODEL"],
        "HANDOFF_JEV": ["LAYA_HANDOFF_JEV", "JEV_HANDOFF_JEV"],
        "TOKEN": ["LAYA_TOKEN", "JEV_TOKEN", "DASHBOARD_TOKEN"],
    ]

    static let secretKeys: Set<String> = ["API_KEY", "TOKEN"]

    /// Echoed when a client sends no model; strict clients compare the echo.
    public static let defaultModel = "laya-r15"

    // MARK: module state (tests reset via resetState())

    private static let lock = NSLock()
    // Lock-guarded module state; Swift 6 needs the explicit nonisolated marker.
    nonisolated(unsafe) private static var _divergences: [JSONValue] = []
    nonisolated(unsafe) private static var _resolved: [String: (source: String, value: String?)] = [:]
    nonisolated(unsafe) private static var _warned: Set<String> = []
    nonisolated(unsafe) private static var _permWarned: Set<String> = []

    static var divergences: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return _divergences
    }

    static func resetState() {
        lock.lock(); defer { lock.unlock() }
        _divergences = []
        _resolved = [:]
        _warned = []
        _permWarned = []
    }

    private static func env(_ name: String) -> String? {
        let v = ProcessInfo.processInfo.environment[name]
        return (v != nil && v != "") ? v : nil
    }

    private static func chain(_ name: String) -> [String] {
        aliasTable[name] ?? ["LAYA_\(name)", "JEV_\(name)", "TYPESAFE_\(name)"]
    }

    private static func recordDivergence(name: String, winner: String, diverged: [String]) {
        lock.lock()
        let first = !_warned.contains(name)
        _warned.insert(name)
        if first {
            _divergences.append(.object([
                (key: "name", value: .string(name)),
                (key: "source", value: .string(winner)),
                (key: "diverged_sources", value: .array(diverged.map { .string($0) })),
            ]))
        }
        lock.unlock()
        if first {
            FileHandle.standardError.write(
                Data("laya.naming: \(name) set in \(winner) and \(diverged.joined(separator: ", ")) with different values; canonical \(winner) wins (divergence recorded once, doctor reports it)\n".utf8))
        }
    }

    /// First-hit resolution: (value, sourceEnv) or (nil, nil).
    static func resolve(_ name: String) -> (value: String?, source: String?) {
        let ch = chain(name)
        var found: [(env: String, value: String)] = []
        for e in ch {
            if let v = env(e) { found.append((e, v)) }
        }
        guard let winner = found.first else { return (nil, nil) }
        let diverged = found.dropFirst().filter { $0.value != winner.value }.map(\.env)
        if !diverged.isEmpty {
            recordDivergence(name: name, winner: winner.env, diverged: diverged)
        }
        lock.lock()
        // secrets: presence only, value never memoized
        _resolved[name] = (source: winner.env, value: secretKeys.contains(name) ? nil : winner.value)
        lock.unlock()
        return (winner.value, winner.env)
    }

    /// THE env read for the Laya surface.
    public static func envAlias(_ name: String, default def: String? = nil) -> String? {
        let (value, _) = resolve(name)
        return value ?? def
    }

    // MARK: model id (echo rule)

    /// Echo non-empty strings VERBATIM; canonical default when nil/empty is
    /// env alias MODEL else `laya-r15`.
    public static func modelId(_ requested: String?) -> String {
        if let r = requested, !r.isEmpty { return r }
        return envAlias("MODEL") ?? defaultModel
    }

    // MARK: layered config dirs (Laya first, Jev fallback)

    private static func xdgBase(_ kind: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if kind == "cache" {
            if let e = env("XDG_CACHE_HOME") { return URL(fileURLWithPath: e, isDirectory: true) }
            return home.appendingPathComponent(".cache", isDirectory: true)
        }
        if let e = env("XDG_CONFIG_HOME") { return URL(fileURLWithPath: e, isDirectory: true) }
        return home.appendingPathComponent(".config", isDirectory: true)
    }

    /// Ordered candidate FILE paths for `subpath`: <xdg>/laya/ then <xdg>/jev/.
    static func configDirChain(_ subpath: String, kind: String = "config") -> [URL] {
        let base = xdgBase(kind)
        return ["laya", "jev"].map { base.appendingPathComponent($0, isDirectory: true).appendingPathComponent(subpath) }
    }

    /// <hermes_root> = env HERMES_HOME or ~/.hermes. NOTE: reads os.environ
    /// DIRECTLY (host-addressing seam, not a Laya-surface alias).
    static func hermesRoot() -> URL {
        if let h = ProcessInfo.processInfo.environment["HERMES_HOME"] {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes", isDirectory: true)
    }

    /// THE routing.json candidate chain (D6): <hermes>/laya, <hermes>/jev,
    /// <xdg_config>/laya, <xdg_config>/jev; first EXISTING file wins.
    static func routingConfigChain(_ subpath: String = "routing.json") -> [URL] {
        let root = hermesRoot()
        var out = ["laya", "jev"].map { root.appendingPathComponent($0, isDirectory: true).appendingPathComponent(subpath) }
        out += ["laya", "jev"].map { xdgBase("config").appendingPathComponent($0, isDirectory: true).appendingPathComponent(subpath) }
        return out
    }

    /// The single shared ladder state path (D6 symlink rule).
    static func ladderStatePath() -> URL {
        if let v = resolve("LADDER_STATE").value {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        }
        return hermesRoot().appendingPathComponent("laya", isDirectory: true)
            .appendingPathComponent("ladder.json")
    }

    // MARK: key resolution — env (3) → keystore (2) → files (2)

    private static let keystoreChain: [(service: String, account: String)] = [
        ("Hermes Laya API", "LAYA_API_KEY"),
        ("Hermes TypeSafe API", "TYPESAFE_API_KEY"),
    ]

    /// macOS keystore read via `security find-generic-password -w`, bounded
    /// 5 s; nil on ANY failure. Value never logged.
    static func keychainSecret(service: String, account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // bounded 5 s wait (Python: subprocess timeout=5)
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let v = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? nil : v
    }

    /// Read one credentials file (expected mode 0600). Accepts bare key,
    /// NAME=value lines, or a JSON object; loose mode warns once.
    static func readCredentialsFile(_ path: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue,
              let text = try? String(contentsOf: path, encoding: .utf8)
        else { return nil }
        if let st = try? fm.attributesOfItem(atPath: path.path),
           let mode = (st[.posixPermissions] as? NSNumber)?.uint16Value,
           mode & 0o077 != 0 {
            lock.lock()
            let first = !_permWarned.contains(path.path)
            _permWarned.insert(path.path)
            lock.unlock()
            if first {
                FileHandle.standardError.write(
                    Data("laya.naming: credentials file \(path.path) is group/world-readable (expected 0600)\n".utf8))
            }
        }
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return nil }
        let keyNames: Set<String> = ["LAYA_API_KEY", "JEV_API_KEY", "TYPESAFE_API_KEY", "API_KEY"]
        if stripped.hasPrefix("{") {
            guard let root = JSONValue.parse(stripped),
                  case .object(let pairs) = root
            else { return nil }
            for k in ["LAYA_API_KEY", "JEV_API_KEY", "TYPESAFE_API_KEY", "API_KEY"] {
                for p in pairs.reversed() where p.key == k {
                    if case .string(let s) = p.value, !s.isEmpty { return s }
                }
            }
            return nil
        }
        for rawLine in stripped.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let eq = line.firstIndex(of: "=") {
                let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                if keyNames.contains(k) {
                    let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    return v.isEmpty ? nil : v
                }
                continue
            }
            return line
        }
        return nil
    }

    /// Full key resolution chain. First hit wins; value never logged.
    static func resolveApiKey() -> String? {
        if let v = resolve("API_KEY").value, !v.isEmpty { return v }
        for hop in keystoreChain {
            if let v = keychainSecret(service: hop.service, account: hop.account) { return v }
        }
        for path in configDirChain("credentials") {
            if let v = readCredentialsFile(path) { return v }
        }
        return nil
    }

    /// Where resolveApiKey() would find the key, WITHOUT returning it.
    private static func keySource() -> String? {
        for e in chain("API_KEY") where env(e) != nil { return e }
        for hop in keystoreChain {
            if keychainSecret(service: hop.service, account: hop.account) != nil {
                return "keystore:\(hop.service)"
            }
        }
        for path in configDirChain("credentials") {
            if readCredentialsFile(path) != nil { return path.path }
        }
        return nil
    }

    /// {present, provider, source, length} — length only, NEVER the key.
    static func describeApiKey() -> JSONValue {
        guard let src = keySource() else {
            return .object([
                (key: "present", value: .bool(false)), (key: "provider", value: .null),
                (key: "source", value: .null), (key: "length", value: .int(0)),
            ])
        }
        let key = resolveApiKey() ?? ""
        let provider = (src.contains("TYPESAFE") || src.contains("TypeSafe")) ? "typesafe" : "laya"
        return .object([
            (key: "present", value: .bool(true)), (key: "provider", value: .string(provider)),
            (key: "source", value: .string(src)), (key: "length", value: .int(Int64(key.count))),
        ])
    }

    /// {divergences, resolved} for every D6-table name (+ anything else ever
    /// resolved). SECRET_KEYS never carry a value.
    static func doctorAliasReport() -> JSONValue {
        var resolvedPairs: [(key: String, value: JSONValue)] = []
        var names = Array(aliasTable.keys)
        lock.lock()
        names += _resolved.keys.filter { !aliasTable.keys.contains($0) }
        let resolvedSnapshot = _resolved
        lock.unlock()
        for name in names.sorted() {
            if name == "API_KEY" {
                resolvedPairs.append((key: name, value: describeApiKey()))
                continue
            }
            if secretKeys.contains(name) {
                let (v, src) = resolve(name)
                resolvedPairs.append((key: name, value: .object([
                    (key: "present", value: .bool(v != nil)),
                    (key: "source", src.map { .string($0) } ?? .null),
                ])))
                continue
            }
            let (v, src) = resolve(name)
            resolvedPairs.append((key: name, value: .object([
                (key: "source", src.map { .string($0) } ?? .null),
                (key: "value", v.map { .string($0) } ?? .null),
            ])))
            _ = resolvedSnapshot
        }
        return .object([
            (key: "divergences", value: .array(divergences)),
            (key: "resolved", value: .object(resolvedPairs)),
        ])
    }
}
