import Foundation

/// Port of server/laya_ops.py — wire ⇄ engine mapping. Invariants held BY
/// CONSTRUCTION (spec-v2 §1): probability keys == criteria keys exactly,
/// Σp = 1 ± MASS_SLACK, choice == argmax (ties → criteria insertion order),
/// confidence == p[choice].
enum LayaOps {
    // Consumer tolerances (spec §1), stated once.
    static let epsMass = 0.01 + 1e-12
    static let argmaxTolerance = 1e-9
    static let scoreDotTolerance = 0.02 + 1e-12
    static let scoreBandLo = -0.5
    static let scoreBandHi = -0.5   // upper = L + this

    // Our emission rules (tighter than the consumer's).
    static let roundDecimals = 10
    static let massSlack = 1e-12
    static let residualMax = 1e-9

    /// Python round(v, 10): CPython rounds on the shortest decimal repr, so
    /// values that are already ≤10-decimal clean (engine.decide emits 4dp)
    /// pass through bit-exactly. The same holds for our clamp/min/max use:
    /// we only ever round values produced by round(_, 4) upstream, hence a
    /// plain binary nearest rounding at 1e10 scale is exact for them.
    static func roundPy(_ v: Double) -> Double {
        let scale = 1e10
        let s = v * scale
        // Guard overflow beyond exact integer range.
        if !s.isFinite || abs(s) > 9.2e18 { return v }
        return s.rounded(.toNearestOrEven) / scale
    }

    struct OpsError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func checkQuestion(_ qtype: String, _ qname: String, _ q: JSONValue) throws {
        guard q["type"]?.stringValue == qtype else {
            throw OpsError(message: "question \(qname): type \(q["type"]?.stringValue ?? "nil") not accepted by the \(qtype) mapper")
        }
        guard let ins = q["instructions"]?.stringValue,
              !ins.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw OpsError(message: "question \(qname): instructions must be non-empty")
        }
        guard ins != qname else {
            throw OpsError(message: "question \(qname): instructions must differ from the question name")
        }
    }

    private static func probsOf(_ qname: String, _ engineOut: JSONValue) throws -> [(key: String, value: Double)] {
        guard let probs = engineOut["probs"]?.objectPairs, !probs.isEmpty else {
            throw OpsError(message: "question \(qname): engine_out missing probs")
        }
        return probs.map { ($0.key, $0.value.numberValue ?? .nan) }   // Double.nan sentinel
    }

    /// {key: f64} with keys == criteria keys exactly, Σ == 1 ± MASS_SLACK.
    /// Round to wire precision, divide by actual mass (order-preserving),
    /// spread the residual evenly over keys with headroom (each move
    /// ≤ RESIDUAL_MAX so argmax cannot flip), pin the leftover on the top key.
    static func renormalize(_ qname: String, _ keys: [String], _ raw: [(key: String, value: Double)]) throws -> [(key: String, value: Double)] {
        var rawMap: [String: Double] = [:]
        for p in raw { rawMap[p.key] = p.value }
        var vals: [String: Double] = [:]
        for k in keys {
            guard let v0 = rawMap[k], !v0.isNaN else {
                throw OpsError(message: "question \(qname): engine_out probs missing numeric entries for the question's keys")
            }
            vals[k] = roundPy(min(1.0, max(0.0, v0)))
        }
        var mass = vals.values.reduce(0, +)
        guard mass > 0 else {
            throw OpsError(message: "question \(qname): engine_out probs have no mass to renormalize")
        }
        if abs(mass - 1.0) > massSlack {
            for k in keys { vals[k] = roundPy(vals[k]! / mass) }
        }
        var converged = false
        for _ in 0..<8 {
            let err = 1.0 - vals.values.reduce(0, +)
            if abs(err) <= massSlack { converged = true; break }
            let movable = keys.filter { err > 0 ? vals[$0]! < 1.0 : vals[$0]! > 0.0 }
            guard !movable.isEmpty else {
                throw OpsError(message: "question \(qname): probabilities cannot be renormalized to sum 1")
            }
            let step = err / Double(movable.count)
            guard abs(step) <= residualMax else {
                throw OpsError(message: "question \(qname): engine_out mass too far from 1 to fix without moving argmax (residual \(err))")
            }
            for k in movable { vals[k]! += step }
        }
        guard converged else {
            throw OpsError(message: "question \(qname): probabilities cannot be renormalized to sum 1 within \(massSlack)")
        }
        let leftover = 1.0 - vals.values.reduce(0, +)
        guard abs(leftover) <= massSlack else {
            throw OpsError(message: "question \(qname): probabilities cannot be renormalized to sum 1 within \(massSlack)")
        }
        for k in keys where vals[k]! < 0.0 || vals[k]! > 1.0 {
            throw OpsError(message: "question \(qname): renormalization left probs outside [0,1]")
        }
        if leftover != 0.0 {   // exact pin on the top key (first max, insertion order)
            vals[argmax(keys, vals)]! += leftover
        }
        return keys.map { (key: $0, value: vals[$0]!) }
    }

    /// First key with the max value — ties broken by criteria insertion order
    /// (same rule as the engine's argmax).
    static func argmax(_ keys: [String], _ vals: [String: Double]) -> String {
        var best = keys[0]
        for k in keys.dropFirst() where vals[k]! > vals[best]! { best = k }
        return best
    }

    /// Engine result {task, chain, choice, confidence, acted, act_p, probs,
    /// latency_ms} as the Swift side produces it.
    struct EngineOut {
        var task: String
        var chain: String
        var probs: [(key: String, value: Double)]
        var confidence: Double
        var actP: Double
    }

    // MARK: - mappers (wire answer shapes)

    static func answerFromNoul(qname: String, q: JSONValue, out: EngineOut) throws -> JSONValue {
        try checkQuestion("noul", qname, q)
        guard q["criteria"] == nil || q["criteria"] == .null || q["criteria"] == .object([]) else {
            throw OpsError(message: "question \(qname): noul questions must have no criteria")
        }
        guard let pYes = out.probs.first(where: { $0.key == "yes" })?.value else {
            throw OpsError(message: "question \(qname): engine_out probs missing 'yes'")
        }
        return .object([
            (key: "type", value: .string("noul")),
            (key: "noul", value: .double(min(1.0, max(0.0, pYes)))),
        ])
    }

    static func answerFromChoice(qname: String, q: JSONValue, out: EngineOut) throws -> JSONValue {
        try checkQuestion("choice", qname, q)
        guard let crit = q["criteria"]?.objectPairs, crit.count >= 2 else {
            throw OpsError(message: "question \(qname): choice questions need a criteria mapping with ≥ 2 options")
        }
        let keys = crit.map(\.key)   // insertion order == consumer option order
        let probs = try renormalize(qname, keys, out.probs)
        var map: [String: Double] = [:]
        for p in probs { map[p.key] = p.value }
        let top = argmax(keys, map)
        var pairs: [(key: String, value: JSONValue)] = [
            (key: "type", value: .string("choice")),
            (key: "choice", value: .string(top)),
            (key: "probabilities", value: .object(probs.map { (key: $0.key, value: .double($0.value)) })),
            (key: "confidence", value: .double(map[top]!)),
        ]
        _ = pairs   // keep mutable for future optional fields
        return .object(pairs)
    }

    static func answerFromScore(qname: String, q: JSONValue, out: EngineOut) throws -> JSONValue {
        try checkQuestion("score", qname, q)
        guard let crit = q["criteria"]?.arrayValue, crit.count >= 2 else {
            throw OpsError(message: "question \(qname): score questions need a criteria rubric list with ≥ 2 levels")
        }
        let L = crit.count
        let keys = (0..<L).map(String.init)
        let probs = try renormalize(qname, keys, out.probs)
        var map: [String: Double] = [:]
        for p in probs { map[p.key] = p.value }
        let top = argmax(keys, map)
        let score = probs.reduce(0.0) { $0 + Double($1.key)! * $1.value }
        guard scoreBandLo <= score && score <= Double(L) + scoreBandHi else {
            throw OpsError(message: "question \(qname): score \(score) outside the consumer band [\(scoreBandLo), \(Double(L) + scoreBandHi)]")
        }
        var pairs: [(key: String, value: JSONValue)] = [
            (key: "type", value: .string("score")),
            (key: "score", value: .double(score)),
            (key: "probabilities", value: .object(probs.map { (key: $0.key, value: .double($0.value)) })),
            (key: "spread_reported", value: .bool(true)),
            (key: "confidence", value: .double(map[top]!)),
        ]
        // legend is optional on the wire (spec §1)
        if let legend = q["legend"], legend != .null,
           case .object = legend {
            pairs.append((key: "legend",
                          value: .object(zip(keys, crit).compactMap { k, lv in
                              lv.stringValue.map { (key: k, value: .string($0)) }
                          })))
        }
        return .object(pairs)
    }

    static func answerer(_ qtype: String) -> (String, JSONValue, EngineOut) throws -> JSONValue {
        switch qtype {
        case "noul": return answerFromNoul
        case "score": return answerFromScore
        default: return answerFromChoice
        }
    }
}
