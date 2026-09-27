import Foundation

/// Port of core/laya_port/sequence.py (verbatim extract of the audited
/// laya==0.3.5 common.py): QTYPES, serialize_state, render_criterion,
/// render_options, build_sequence, confidence helpers.
///
/// Byte-parity with Python matters: the token sequence is what the model
/// scores, so the golden seq_cases in golden/tokenizer_golden.json must match
/// id-for-id.
public enum Sequence {
    public static let qtypes: [String: Int] = ["choice": 0, "score": 1, "noul": 2]
    public static let qtypeNames: [Int: String] = [0: "choice", 1: "score", 2: "noul"]

    /// Python `serialize_state`: strings pass through, structured values
    /// become compact JSON (separators (",", ":")).
    public static func serializeState(_ state: JSONValue) -> String {
        if case .string = state { return state.stringValue! }
        return JSONValue.serialize(state, sortKeys: false, separators: (",", ":"))
    }

    /// Python `render_criterion`: strings pass through; anything structured
    /// becomes JSON with separators (", ", ": ") so a rubric reads as JSON.
    public static func renderCriterion(_ value: JSONValue) -> String {
        if case .string = value { return value.stringValue! }
        return JSONValue.serialize(value, sortKeys: false, separators: (", ", ": "))
    }

    /// "no description" markers: only None and "" — 0 and False are
    /// legitimate criterion values.
    private static func isBlank(_ v: JSONValue?) -> Bool {
        v == nil || v == .null || v == .string("")
    }

    /// Option texts in label-index order. Noul is always [false, true].
    /// `q` uses the wire shorthand keys from the golden ("t", "crit") and the
    /// full API keys ("type", "criteria") — both accepted, like the Python.
    public static func renderOptions(_ q: JSONValue) -> [String] {
        let t = q["type"]?.stringValue ?? q["t"]?.stringValue ?? ""
        let crit = q["criteria"] ?? q["crit"]
        switch t {
        case "choice":
            let pairs = crit?.objectPairs ?? []
            return pairs.map { p in
                isBlank(p.value) ? p.key : "\(p.key): \(renderCriterion(p.value))"
            }
        case "score":
            // Python enumerates crit — a list of level descriptions (or a
            // string, which Python would enumerate char-wise; the API
            // validates score criteria as lists before we get here).
            return (crit?.arrayValue ?? []).enumerated().map { i, c in
                "level \(i): \(renderCriterion(c))"
            }
        default: // noul
            let falseCrit = crit?["false"]
            let trueCrit = crit?["true"]
            return [
                "false: " + (isBlank(falseCrit) ? "no, the statement does not hold"
                                                : renderCriterion(falseCrit!)),
                "true: " + (isBlank(trueCrit) ? "yes, the statement holds"
                                              : renderCriterion(trueCrit!)),
            ]
        }
    }

    public struct Built: Sendable {
        public let ids: [UInt32]
        public let markers: [Int]
    }

    /// Format: [CLS] <type> instructions [SEP] [MASK] opt0 [MASK] opt1 ...
    /// [SEP] state [SEP]. Mirrors build_sequence() argument-for-argument
    /// (tok(...) == tokenizer.encode, add_special_tokens=False).
    public static func buildSequence(tok: LayaTokenizer,
                              state: JSONValue,
                              q: JSONValue,
                              maxLength: Int = 512,
                              headMaxLength: Int = 192,
                              optionOrder: [Int]? = nil,
                              truncateLeft: Bool = false) -> Built {
        let maskTok = tok.maskTok
        let opts = renderOptions(q)
        let order = optionOrder ?? Array(opts.indices)
        let t = q["type"]?.stringValue ?? q["t"]?.stringValue ?? ""
        let insRaw = q["instructions"]?.stringValue ?? q["ins"]?.stringValue ?? ""
        let ins = maskFree(insRaw, maskTok)
        var headIds = tok.encode("\(t) question: \(ins)")

        var optIds: [[UInt32]] = []
        optIds.reserveCapacity(order.count)
        for i in order {
            var o: [UInt32] = [tok.maskId]
            o.append(contentsOf: tok.encode(" " + maskFree(opts[i], maskTok)).prefix(48))
            optIds.append(o)
        }
        var optBudget = headMaxLength - optIds.reduce(0) { $0 + $1.count }
        if optBudget < 16 {
            let per = max(4, (headMaxLength - 16) / max(1, optIds.count))
            optIds = optIds.map { Array($0.prefix(per)) }
            optBudget = headMaxLength - optIds.reduce(0) { $0 + $1.count }
        }
        headIds = Array(headIds.prefix(max(8, optBudget)))

        var ids: [UInt32] = [UInt32(tok.clsId)]
        ids.append(contentsOf: headIds)
        ids.append(UInt32(tok.sepId))
        var markers: [Int] = []
        for o in optIds {
            markers.append(ids.count)
            ids.append(contentsOf: o)
        }
        ids.append(UInt32(tok.sepId))

        let room = max(0, maxLength - ids.count - 1)
        let stateText = maskFree(serializeState(state), maskTok)
        var st = tok.encode(stateText)
        // S1: skip the slice entirely when nothing truncates (common case)
        if st.count > room {
            st = truncateLeft ? Array(st.suffix(room)) : Array(st.prefix(room))
        }
        ids.append(contentsOf: st)
        ids.append(UInt32(tok.sepId))
        return Built(ids: Array(ids.prefix(maxLength)),
                     markers: markers.filter { $0 < maxLength })
    }

    // MARK: - confidence / calibration (verbatim ports)

    /// S2: replacingOccurrences is NSString-backed (bridges + allocates even
    /// when the needle is absent — the common case). Guard on contains().
    static func maskFree(_ s: String, _ maskTok: String) -> String {
        s.contains(maskTok) ? s.replacingOccurrences(of: maskTok, with: " ") : s
    }

    /// Normalized Shannon entropy confidence: 1 - H(p) / log(k).
    public static func confidenceFromProbs(_ p: [Double], k: Int) -> Double {
        if k < 2 { return 1.0 }
        let ent = -p.prefix(k).reduce(0.0) { $0 + $1 * log(max($1, 1e-12)) }
        return min(1.0, max(0.0, 1.0 - ent / log(Double(k))))
    }

    /// Expected Calibration Error across `bins` equal-width confidence bins.
    public static func eceScore(conf: [Double], correct: [Double], bins: Int = 15) -> Double {
        if conf.isEmpty { return .nan }
        var e = 0.0
        for b in 0..<bins {
            let lo = Double(b) / Double(bins)
            let hi = Double(b + 1) / Double(bins)
            var sel: [Int] = []
            for (i, c) in conf.enumerated() where c > lo && c <= hi { sel.append(i) }
            if !sel.isEmpty {
                let cm = sel.reduce(0.0) { $0 + conf[$1] } / Double(sel.count)
                let am = sel.reduce(0.0) { $0 + correct[$1] } / Double(sel.count)
                e += Double(sel.count) / Double(conf.count) * abs(cm - am)
            }
        }
        return e
    }

    public static let tempMin = 0.5
    public static let tempMax = 5.0

    /// A fitted temperature below 1 sharpens logits (~10x at the shipped
    /// choice:11+ bucket 0.1006 — a 0.24 top probability publishes as 0.99).
    /// Confine to [lo, hi]; non-numeric falls back to 1.0.
    public static func clampTemperature(_ t: Double?, lo: Double = tempMin, hi: Double = tempMax) -> Double {
        guard let t, t.isFinite else { return 1.0 }
        return min(hi, max(lo, t))
    }

    /// "choice:3-5" style bucket key from qtype index and k.
    public static func tempBucket(qtype: Int, k: Int) -> String {
        let size = k <= 2 ? "2" : k <= 5 ? "3-5" : k <= 10 ? "6-10" : "11+"
        return "\(qtypeNames[qtype] ?? "?"):\(size)"
    }
}
