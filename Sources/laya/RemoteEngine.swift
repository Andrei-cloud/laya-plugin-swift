import Foundation
import LayaCore

/// RemoteEngine — Swift twin of server/laya_remote.py's RemoteEngine:
/// the Engine duck over HTTP for the degraded use-case rows. POSTs one
/// question to /v1/laya and reshapes the wire answer back into the raw
/// engine result contract LayaOps answerers consume. Raises on any
/// daemon failure — exactly what the use-case fail-open rails catch.
///
/// Chain label: /health `chains` (GET, cached, never an error); r15
/// head order maps base/ft_lang/ft_gr14/ft_tool5v2/ft_skill4, foreign
/// tasks → chain 0, no table → "chain?". Display/audit only — nothing
/// in the rails reads it.
@available(macOS 27.0, *)
public actor RemoteEngine: Questioning {
    public let baseURL: String
    public let timeoutS: Double
    private var chains: [String]?
    public private(set) var calls = 0
    public private(set) var totalMS = 0.0

    static let defaultURL = "http://127.0.0.1:11270"
    static let defaultTimeoutS = 60.0

    /// guardrail / triage vocab sets for the task hint (primitive's own).
    static let guardVocab: Set<String> = ["allow", "ask_user", "block"]
    static let triageVocab: Set<String> = ["now", "today", "queue", "ignore"]

    public init(baseURL: String? = nil, timeoutS: Double? = nil) {
        var u = baseURL ?? Naming.envAlias("DECISIOND_URL") ?? Self.defaultURL
        if u.hasSuffix("/") { u = String(u.dropLast()) }
        self.baseURL = u
        if let t = timeoutS { self.timeoutS = t }
        else if let e = Naming.envAlias("DECISION_TIMEOUT_S"), let v = Double(e) {
            self.timeoutS = v
        } else { self.timeoutS = Self.defaultTimeoutS }
    }

    // MARK: transport (codes only in errors: never secret, never prompt)

    private struct DaemonError: Error { let message: String }

    private func post(_ path: String, _ payload: JSONValue) async throws -> JSONValue {
        guard let url = URL(string: baseURL + path) else {
            throw DaemonError(message: "daemon unreachable (bad url)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token = Naming.envAlias("TOKEN"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = Data(JSONValue.serialize(payload).utf8)
        request.timeoutInterval = timeoutS
        let data: Data
        do {
            let (d, r) = try await URLSession.shared.data(for: request)
            guard let http = r as? HTTPURLResponse else {
                throw DaemonError(message: "daemon unreachable (non-http)")
            }
            guard http.statusCode == 200 else {
                // structured refusal body is {status, error} (codes only).
                var detail = ""
                if let body = JSONValue.parse(d) {
                    detail = (body["error"]?.stringValue
                              ?? body["status"]?.stringValue ?? "").prefix(120).description
                }
                throw DaemonError(message: "daemon http_\(http.statusCode)"
                                  + (detail.isEmpty ? "" : " " + detail))
            }
            data = d
        } catch let e as DaemonError {
            throw e
        } catch let e as URLError {
            throw DaemonError(message: "daemon unreachable (\(e.code.rawValue))")
        } catch {
            throw DaemonError(message: "daemon unreachable (\(type(of: error)))")
        }
        guard let parsed = JSONValue.parse(data) else {
            throw DaemonError(message: "daemon malformed (non-JSON response)")
        }
        return parsed
    }

    private func get(_ path: String) async -> JSONValue? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(3.0, timeoutS)
        guard let (d, r) = try? await URLSession.shared.data(for: request),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return JSONValue.parse(d)
    }

    // MARK: Engine duck

    public func question(name: String, q: JSONValue, state: JSONValue) async throws
        -> Engine.WireAnswer
    {
        let qtype = q["type"]?.stringValue ?? ""
        guard qtype == "noul" || qtype == "choice" || qtype == "score" else {
            throw LayaOps.OpsError(message: "unknown question type \(qtype)")
        }
        let model = Naming.envAlias("MODEL") ?? "laya-r15"
        let payload = JSONValue.obj("model", .string(model),
                                    "state", state,
                                    "questions", .object([(key: name, value: q)]))
        // U12: ONE clock read for the whole ms metric (the old code
        // called t0.duration(to: .now) twice — two clock reads, and the
        // seconds and attoseconds came from different instants).
        let t0 = ContinuousClock.now
        let body = try await post("/v1/laya", payload)
        let elapsed = t0.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        guard let ans = body["answers"]?[name], ans.objectPairs != nil else {
            throw DaemonError(message: "daemon answer missing for '\(name)'")
        }

        var probs: [(key: String, value: Double)] = []
        if qtype == "noul" {
            let pYes = ans["noul"]?.numberValue ?? 0
            probs = [("no", (1 - pYes).rounded(toPlaces: 4)),
                     ("yes", pYes.rounded(toPlaces: 4))]
        } else {
            probs = (ans["probabilities"]?.objectPairs ?? []).map {
                ($0.key, $0.value.numberValue ?? 0)
            }
        }
        guard !probs.isEmpty else {
            throw DaemonError(message: "daemon answer for '\(name)' carries no probabilities")
        }
        var top = probs[0]
        for p in probs where p.value > top.value { top = p }
        let conf = ans["confidence"]?.numberValue ?? top.value
        // (Python's `choice` local was dead here too — the answer comes
        // from the LayaOps answerer, not from this value.)

        let task = Self.taskHint(q)
        calls += 1
        totalMS += ms
        let confR = conf.rounded(toPlaces: 4)
        let eo = LayaOps.EngineOut(
            task: task, chain: await chainFor(task),
            probs: probs.map { ($0.key, $0.value.rounded(toPlaces: 4)) },
            confidence: confR, actP: confR)
        let answer = try LayaOps.answerer(qtype)(name, q, eo)
        return Engine.WireAnswer(name: name, answer: answer)
    }

    static func taskHint(_ q: JSONValue) -> String {
        // U8: criteria are ≤7 keys — count-guarded membership beats
        // allocating a Set + map array + SipHashing every key per
        // question just to compare against two static Sets.
        let keys = q["criteria"]?.objectPairs ?? []
        if keys.count == guardVocab.count && keys.allSatisfy({ guardVocab.contains($0.key) }) {
            return "guardrail"
        }
        if keys.count == triageVocab.count && keys.allSatisfy({ triageVocab.contains($0.key) }) {
            return "triage"
        }
        return "base"
    }

    func chainFor(_ task: String) async -> String {
        if chains == nil {
            let h = await get("/health")
            if let ch = h?["chains"]?.arrayValue, !ch.isEmpty {
                chains = ch.map { $0.stringValue ?? "" }
            } else { chains = [] }
        }
        // r15 head order (deploy-proven): base, ft_lang, ft_gr14,
        // ft_tool5v2, ft_skill4; foreign tasks → chain 0; no table → "chain?".
        // U9: the table is a process-lifetime static (was a fresh
        // [String: Int] literal per question — 5-7 per supervise run).
        guard let c = chains, !c.isEmpty else { return "chain?" }
        let idx = Self.chainIndex[task] ?? 0
        return c.indices.contains(idx) ? c[idx] : c[0]
    }

    static let chainIndex: [String: Int] = [
        "base": 0, "ft_lang": 1, "ft_gr14": 2, "ft_tool5v2": 3, "ft_skill4": 4]
}

extension Double {
    /// Python round(x, 4) at these magnitudes (nearest-even ties are
    /// unreachable for probabilities here). U10: the 10^places scale is
    /// looked up, not recomputed via pow() per call (7-9 calls per
    /// supervise round through this one helper).
    func rounded(toPlaces places: Int) -> Double {
        let f: Double
        switch places {
        case 0: f = 1
        case 1: f = 10
        case 2: f = 100
        case 3: f = 1_000
        case 4: f = 10_000
        case 5: f = 100_000
        case 6: f = 1_000_000
        default: f = pow(10.0, Double(places))
        }
        return (self * f).rounded() / f
    }
}
