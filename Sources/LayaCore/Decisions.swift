import Foundation

/// Decision log — the local bookkeeping trail (spec-v2 §4). Swift port of
/// server/laya_decisions.py.
///
/// Rules (binding): DECISIONS ONLY, never prompt text — every record passes
/// redaction. DUAL-WRITE (D6): every line is appended BYTE-IDENTICALLY to
/// the Laya path and the Jev alias path. Files are 0600; a failing log NEVER
/// breaks a decision path (fail open, counted in logFailures for doctor).
enum Decisions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failures: [(path: String, error: String)] = []

    static var logKinds: Set<String> { K.logKinds }

    /// Redact emails/phones/tokens/keyvals/hex BEFORE anything is stored
    /// (spec §4 privacy-before-send; we redact even local writes).
    static func redact(_ text: String) -> String {
        var out = text
        for (_, regex) in K.redactPatterns {
            // ns MUST be recomputed per pattern: every replacement shrinks
            // `out`, and searching with the pre-shrink length raises
            // NSRangeException (out of bounds) the moment one pattern hits
            // and a later one searches — dormant until the triage/mail
            // rows started feeding email-bearing messages (2026-09-27).
            let ns = out as NSString
            let matches = regex.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var rebuilt = ""
            var last = 0
            for m in matches {
                rebuilt += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                rebuilt += "[redacted]"
                last = m.range.location + m.range.length
            }
            rebuilt += ns.substring(with: NSRange(location: last, length: ns.length - last))
            out = rebuilt
        }
        return out
    }

    static func redact(_ v: JSONValue) -> JSONValue {
        if case .string(let s) = v { return .string(redact(s)) }
        return .string(JSONValue.serializeSorted(v))   // Python: json.dumps sort_keys for non-str
    }

    /// <profile>/logs via the ONE resolver (D6): LAYA_LOG_DIR alias, then
    /// hermesRoot()/logs, then ~/.hermes/logs. HERMES_HOME reads the env
    /// DIRECTLY (host-addressing seam, never through envAlias).
    static func logDir() -> URL {
        if let v = Naming.envAlias("LOG_DIR") {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Naming.hermesRoot().appendingPathComponent("logs", isDirectory: true)
    }

    private static func targets() -> (URL, URL) {
        let d = logDir()
        return (d.appendingPathComponent("laya-decisions.jsonl"),
                d.appendingPathComponent("jev-decisions.jsonl"))
    }

    private static func writeLine(_ path: URL, _ line: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: path)
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        chmod(path.path, 0o600)   // umask-proof 0600 (Python: fchmod after open)
        fh.write(Data(line.utf8))
    }

    /// Append one decision record (ordered object) byte-identically under
    /// BOTH names. Returns true on full success; never throws (robustness
    /// default). `kind` must be one of logKinds (the dashboard filters on it).
    @discardableResult
    static func logDecision(_ kind: String, _ record: [(key: String, value: JSONValue)]) -> Bool {
        guard logKinds.contains(kind) else { return false }
        var rec: [(key: String, value: JSONValue)] = [
            (key: "ts", value: .double((Date().timeIntervalSince1970 * 1000).rounded() / 1000)),
            (key: "kind", value: .string(kind)),
        ]
        for p in record {
            rec.append((key: p.key, value: redact(p.value)))
        }
        let line = JSONValue.serialize(.object(rec), sortKeys: true) + "\n"
        var ok = true
        lock.lock()
        for path in [targets().0, targets().1] {
            do { try writeLine(path, line) }
            catch {
                failures.append((path: path.path, error: "\(type(of: error)): \(error)"))
                ok = false
            }
        }
        lock.unlock()
        return ok
    }

    /// Last n records from the canonical file; [] when missing/unreadable.
    static func tail(_ n: Int = 20) -> [JSONValue] {
        let path = targets().0
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).compactMap { l in
            l.trimmingCharacters(in: .whitespaces).isEmpty ? nil : JSONValue.parse(String(l))
        }
    }

    /// Safe-to-print health of the logging surface. Never the contents.
    static func doctor() -> JSONValue {
        let (canon, alias) = targets()
        func stat(_ p: URL) -> JSONValue {
            if let st = try? FileManager.default.attributesOfItem(atPath: p.path) {
                let mode = ((st[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777
                return .object([
                    (key: "path", value: .string(p.path)),
                    (key: "exists", value: .bool(true)),
                    (key: "bytes", value: .int(Int64((st[.size] as? NSNumber)?.int64Value ?? 0))),
                    (key: "mode", value: .string(String(format: "0%o", mode))),
                ])
            }
            return .object([(key: "path", value: .string(p.path)), (key: "exists", value: .bool(false))])
        }
        let c = stat(canon), a = stat(alias)
        var identical: JSONValue = .null
        if let d1 = try? Data(contentsOf: canon), let d2 = try? Data(contentsOf: alias) {
            identical = .bool(d1 == d2)
        }
        lock.lock()
        let lastFailure = failures.last
        let count = failures.count
        lock.unlock()
        return .object([
            (key: "canonical", value: c), (key: "alias", value: a),
            (key: "byte_identical", value: identical),
            (key: "write_failures", value: .int(Int64(count))),
            (key: "last_failure", value: lastFailure.map {
                .array([.string($0.path), .string($0.error)])
            } ?? .null),
        ])
    }
}


