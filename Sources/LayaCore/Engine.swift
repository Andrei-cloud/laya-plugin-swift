import Foundation
import CoreAI

/// Port of the inference half of server/engine.py +
/// core/laya_port/combined_agent.py: one AIModel asset, N head-chains
/// selected by `head_idx`, laya-exact semantics (build_sequence
/// tokenization, per-chain temperature_by_options calibration, entropy
/// confidence, act probabilities).
///
/// The actor IS the serialized engine worker (Python: one worker thread plus
/// one event loop): concurrent requests queue here, so the persistent padded
/// buffers need no locks.
///
/// Verified traps (carried from the Python agent):
///  * ONE specialization per compute unit; an ANE load failure is a hard
///    trap, not an exception — specialize once at startup, never per call.
///  * Core AI re-specializes ~3-5 s per distinct input SHAPE: pad every call
///    to L_max and pay the warmup once at startup.
///  * Padded positions stay mask=0: semantics identical (attention-masked).
@available(macOS 27.0, *)
public actor Engine {
    public struct Config {
        public var assetDir: String
        public var sourceDir: String      // tokenizer + rl_agent_config.json live here
        public var unit: String           // "gpu" | "ne" | "cpu" | "all"
        public init(assetDir: String, sourceDir: String, unit: String = "gpu") {
            self.assetDir = assetDir; self.sourceDir = sourceDir; self.unit = unit
        }
    }

    public struct EngineResult: Sendable {
        public var task: String
        public var chain: String
        public var choice: String
        public var confidence: Double
        public var acted: Bool
        public var actP: Double
        public var probs: [Prob]
        public var latencyMs: Double
    }

    /// One (name, probability) pair. A struct rather than a labeled tuple so
    /// it can cross the actor boundary and feed LayaOps.
    public struct Prob: Sendable, Equatable {
        public var key: String
        public var value: Double
    }

    public static let defaultRoute: [String: Int] = [
        "triage": 0, "lang_route": 1, "guardrail": 2, "act_escalate": 2,
        "tool_route": 3, "skill_route": 4,
    ]

    public private(set) var chainOrder: [String] = []
    public private(set) var route: [String: Int] = [:]
    public private(set) var Lmax = 1024
    public private(set) var Kmax = 128
    public let headMaxLen: Int
    public let tokenizer: LayaTokenizer
    private let padId: UInt32
    private let temps: [ChainTemps]
    private let fn: InferenceFunction

    public struct ChainTemps {
        public var temperature: [Double]              // per qtype index
        public var temperatureByOptions: [String: Double]
    }

    /// Persistent input buffers (padded to L_max every call): reuse avoids
    /// per-call allocation churn; each pass borrows them zero-copy through
    /// NDArray.View(span:).
    private var idsBuf: [Int32]
    private var attBuf: [Int32]
    private var mposBuf: [Int32]
    private var mmaskBuf: [Bool]

    public enum LoadError: Error, CustomStringConvertible {
        case missingProvenance(String), noFunction, loadFailed(String)
        public var description: String {
            switch self {
            case .missingProvenance(let p): return "combined_provenance.json not found at \(p)"
            case .noFunction: return "asset has no usable function"
            case .loadFailed(let m): return "CoreAI load failed: \(m)"
            }
        }
    }

    /// Loads provenance + tokenizer + config, specializes the asset on the
    /// pinned unit, and warms it with one padded probe pass (the ~5 s cold
    /// cost is paid here, not on the first user request).
    public init(_ cfg: Config) async throws {
        let provPath = ((cfg.assetDir as NSString).appendingPathComponent("..") as NSString)
            .appendingPathComponent("combined_provenance.json")
        guard let data = FileManager.default.contents(atPath: provPath),
              let prov = JSONValue.parse(data) else {
            throw LoadError.missingProvenance(provPath)
        }
        let shape = prov["shape"]!
        Lmax = (shape["L_max"]?.intValue) ?? 1024
        Kmax = (shape["K_max"]?.intValue) ?? 128
        chainOrder = prov["heads"]?.keys ?? []
        route = Self.defaultRoute
        route["base"] = 0
        // Provenance-carried routing overrides the static table: the builder
        // writes heads[chain].tasks, so a rebuilt asset with new chains
        // re-routes the wire without a code change here.
        if let heads = prov["heads"]?.objectPairs {
            for (i, h) in heads.enumerated() {
                for t in (h.value["tasks"]?.arrayValue ?? []) {
                    if let ts = t.stringValue { route[ts] = i }
                }
            }
        }

        // per-chain temperatures, from each head's own rl_agent_config.json
        var temps: [ChainTemps] = []
        for (i, h) in chainOrder.enumerated() {
            let hp = ((cfg.sourceDir as NSString).appendingPathComponent("..") as NSString)
                .appendingPathComponent("\(h)/rl_agent_config.json")
            let alt = (cfg.sourceDir as NSString).appendingPathComponent("\(h).rl_agent_config.json")
            var t: JSONValue = .object([])
            if i != 0 {   // chain 0 (base) keeps T=1.0 unless an alt config exists
                if FileManager.default.fileExists(atPath: hp),
                   let d = FileManager.default.contents(atPath: hp) {
                    t = JSONValue.parse(d) ?? t
                } else if FileManager.default.fileExists(atPath: alt),
                          let d = FileManager.default.contents(atPath: alt) {
                    t = JSONValue.parse(d) ?? t
                }
            }
            var ct = ChainTemps(temperature: [1.0, 1.0, 1.0], temperatureByOptions: [:])
            if let arr = t["temperature"]?.arrayValue, arr.count == 3 {
                ct.temperature = arr.map { Sequence.clampTemperature($0.numberValue) }
            }
            if let byo = t["temperature_by_options"]?.objectPairs {
                var m: [String: Double] = [:]
                for p in byo { m[p.key] = Sequence.clampTemperature(p.value.numberValue) }
                ct.temperatureByOptions = m
            }
            temps.append(ct)
        }
        self.temps = temps

        let cfgPath = (cfg.sourceDir as NSString).appendingPathComponent("rl_agent_config.json")
        if let d = FileManager.default.contents(atPath: cfgPath),
           let c = JSONValue.parse(d) {
            headMaxLen = (c["head_max_len"]?.intValue) ?? 256
        } else {
            headMaxLen = 256
        }
        tokenizer = try LayaTokenizer.load(fromFile: (cfg.sourceDir as NSString)
            .appendingPathComponent("tokenizer/tokenizer.json"))
        padId = tokenizer.padId

        let opts: SpecializationOptions
        switch cfg.unit {
        case "cpu": opts = .cpuOnly
        case "gpu": opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
        case "ne":  opts = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        default:    opts = .default
        }
        let url = URL(fileURLWithPath: (cfg.assetDir as NSString).standardizingPath)
        let model: AIModel
        do {
            model = try await AIModel.specialize(contentsOf: url, options: opts)
        } catch { throw LoadError.loadFailed("\(error)") }
        guard let fname = model.functionNames.first,
              let f = try model.loadFunction(named: fname) else {
            throw LoadError.noFunction
        }
        fn = f

        idsBuf = [Int32](repeating: Int32(padId), count: Lmax)
        attBuf = [Int32](repeating: 0, count: Lmax)
        mposBuf = [Int32](repeating: 0, count: Kmax)
        mmaskBuf = [Bool](repeating: false, count: Kmax)

        // warmup probe at full pad (pays graph warmup; flips `warm`)
        _ = try await decide(task: "base", state: .string("warmup"),
                             question: JSONValue.obj("warm", JSONValue.obj(
                                "type", .string("noul"),
                                "instructions", .string("is the engine warm?"))))
    }

    public private(set) var calls = 0
    public private(set) var totalMs = 0.0
    public var warm: Bool { calls > 0 }
    public var meanLatencyMs: Double { totalMs / Double(max(1, calls)) }

    // MARK: - encoding (combined_agent._encode semantics)

    public struct BuiltItem: Sendable {
        public var chain: Int
        public var q: JSONValue          // internal question dict {t, ins, crit}
        public var qtype: Int
        public var ids: [UInt32]
        public var markers: [Int]
    }

    public func encodeItem(task: String, state: JSONValue, question: JSONValue) throws -> BuiltItem {
        let chain = route[task] ?? 0
        let q = question.objectPairs!.first!.value
        let crit = q["criteria"]
        let critPairs = crit?.objectPairs
        let hasCriteria = !(crit == nil || crit == .null || (critPairs?.isEmpty ?? true))

        var qb: JSONValue
        var qt: Int
        if hasCriteria, let pairs = critPairs, !pairs.isEmpty {
            // choice rendering: str(v)[:120] per criterion
            qb = JSONValue.obj("t", .string("choice"),
                               "ins", q["instructions"] ?? .string(""),
                               "crit", .object(pairs.map { p in
                                    let text = p.value.stringValue
                                        ?? JSONValue.serialize(p.value, sortKeys: false,
                                                               separators: (",", ":"))
                                    return (key: p.key, value: .string(String(text.prefix(120))))
                               }))
            qt = 0
        } else {
            qb = JSONValue.obj("t", .string("noul"),
                               "ins", q["instructions"] ?? .string(""),
                               "crit", JSONValue.obj("yes", .string("yes"),
                                                     "no", .string("no")))
            qt = 2
        }
        // state: string passthrough; structured -> sorted-keys JSON, [:900]
        let stateText: String
        if let s = state.stringValue {
            stateText = s
        } else {
            stateText = String(JSONValue.serializeSorted(state).prefix(900))
        }
        let built = Sequence.buildSequence(tok: tokenizer,
                                           state: .string(stateText), q: qb,
                                           maxLength: min(1024, Lmax),
                                           headMaxLength: 256)
        guard built.markers.count <= Kmax else {
            throw LayaOps.OpsError(message: "\(built.markers.count) options > asset K=\(Kmax)")
        }
        return BuiltItem(chain: chain, q: qb, qtype: qt, ids: built.ids, markers: built.markers)
    }

    // MARK: - wire question → engine task (engine.question() port)

    /// Families whose BINARY questions were trained as choice {no,yes}.
    public static let choiceBinaryTasks: Set<String> = ["supervise", "rerank"]
    /// Static supported set (chain-0 pseudo-task included); hints outside it
    /// are still valid when the loaded asset reports the route key.
    public static let supportedTasks: Set<String> = [
        "guardrail", "act_escalate", "triage", "lang_route",
        "tool_route", "skill_route", "base",
    ]

    /// Heuristic slate→head matcher for choice questions whose task the
    /// caller did not pin. Exact-set match; foreign slates → "base".
    public func matchSlate(_ criteria: JSONValue) -> String {
        let names = Set(criteria.keys ?? [])
        // guardrail/triage/lang use fixed vocabularies
        if names == ["allow", "ask_user", "block"] { return "guardrail" }
        if names == ["reply", "act"] { return "triage" }
        // ft_lang was trained on exactly this 7-ISO-code slate
        if names == ["ar", "en", "es", "hi", "ja", "ru", "zh"] { return "lang_route" }
        return "base"
    }

    public struct WireAnswer: Sendable {
        public var name: String
        public var answer: JSONValue
    }

    /// Run ONE wire question through the chain rule and map the engine
    /// result to the wire answer (engine.question + laya_ops in one call).
    public func question(name qname: String, q: JSONValue, state: JSONValue) async throws -> WireAnswer {
        let qtype = q["type"]?.stringValue ?? ""
        let hint = q["route_task"]?.stringValue
        let supported = hint != nil && route[hint!] != nil
        var qb: JSONValue
        var task: String

        switch qtype {
        case "noul":
            // r36 DIALECT FIX: binary questions trained in TWO dialects —
            // choice {no,yes} for supervise/rerank, native noul (criteria
            // ABSENT) for triage/mail/guardrail/skill/base. The qtype
            // embedding is a trained input: wrong dialect flips poles.
            if let h = hint, Self.choiceBinaryTasks.contains(h), supported {
                qb = JSONValue.obj("type", .string("choice"),
                                   "instructions", q["instructions"] ?? .string(""),
                                   "criteria", JSONValue.obj("no", .string("no"), "yes", .string("yes")))
            } else {
                qb = JSONValue.obj("type", .string("noul"),
                                   "instructions", q["instructions"] ?? .string(""))
            }
            task = supported ? hint! : "base"
        case "score":
            let levels = q["criteria"]?.arrayValue ?? []
            let L = levels.count
            qb = JSONValue.obj("type", .string("choice"),
                               "instructions", q["instructions"] ?? .string(""),
                               "criteria", .object(levels.enumerated().map { i, lv in
                                    (key: String(i),
                                     value: .string("\(lv.stringValue ?? "") (level \(i) of \(L - 1))"))
                               }))
            task = supported ? hint! : "base"
        case "choice":
            let pairs = q["criteria"]?.objectPairs ?? []
            qb = JSONValue.obj("type", .string("choice"),
                               "instructions", q["instructions"] ?? .string(""),
                               "criteria", .object(pairs.map { p in
                                    let v = p.value.stringValue ?? ""
                                    return (key: p.key, value: .string(v.isEmpty ? "option \(p.key)" : v))
                               }))
            var t = hint ?? matchSlate(qb["criteria"]!)
            if !Self.supportedTasks.contains(t) && !supported {
                t = matchSlate(qb["criteria"]!)
            }
            task = t
        default:
            throw LayaOps.OpsError(message: "unknown question type \(qtype)")
        }

        let out = try await decide(task: task, state: state,
                                   question: JSONValue.obj(.string(qname), qb))
        let eo = LayaOps.EngineOut(task: out.task, chain: out.chain,
                                   probs: out.probs.map { ($0.key, $0.value) },
                                   confidence: out.confidence, actP: out.actP)
        let answer = try LayaOps.answerer(qtype)(qname, q, eo)
        return WireAnswer(name: qname, answer: answer)
    }

    // MARK: - decide (one model pass, pad-to-L_max)

    public func decide(task: String, state: JSONValue, question: JSONValue) async throws -> EngineResult {
        let t0 = Date()
        let item = try encodeItem(task: task, state: state, question: question)
        let n = item.ids.count
        guard n <= Lmax else {
            throw LayaOps.OpsError(message: "prompt \(n) > asset L=\(Lmax) (raise, never truncate)")
        }

        // Fill persistent buffers; pad beyond content with mask=0.
        for i in 0..<n { idsBuf[i] = Int32(bitPattern: item.ids[i]); attBuf[i] = 1 }
        if n < Lmax {
            for i in n..<Lmax { idsBuf[i] = Int32(padId); attBuf[i] = 0 }
        }
        let k = item.markers.count
        for i in 0..<k { mposBuf[i] = Int32(item.markers[i]); mmaskBuf[i] = true }
        if k < Kmax { for i in k..<Kmax { mposBuf[i] = 0; mmaskBuf[i] = false } }
        let (logits, act) = try await runPass(qt: Int32(item.qtype), hi: Int32(item.chain))

        // temperature-calibrated softmax over the k real markers
        let tp = temps[item.chain]
        let tScale = tp.temperatureByOptions[Sequence.tempBucket(qtype: item.qtype, k: k)]
            ?? tp.temperature[min(item.qtype, 2)]
        var z = [Double](repeating: 0, count: k)
        for i in 0..<k { z[i] = logits[i] / max(tScale, 1e-6) }
        let p = Engine.softmax(z)

        // names: choice -> criteria keys; noul -> ["no","yes"]
        let names: [String] = item.q["t"]?.stringValue == "choice"
            ? (item.q["crit"]?.keys ?? [])
            : ["no", "yes"]
        var best = 0
        for i in 1..<p.count where p[i] > p[best] { best = i }
        let conf = Sequence.confidenceFromProbs(p, k: k)
        // act head [1,2] -> P(index 1) is the act probability
        let actP = Engine.softmax([act[0], act[1]])[1]

        let ms = Date().timeIntervalSince(t0) * 1000
        calls += 1
        totalMs += ms
        var probs = [Prob]()
        probs.reserveCapacity(min(names.count, p.count))
        for i in 0..<min(names.count, p.count) {
            probs.append(Prob(key: names[i], value: Engine.round4(p[i])))
        }
        return EngineResult(task: task, chain: chainOrder[item.chain],
                            choice: names[best], confidence: Engine.round4(conf),
                            acted: conf >= 0.7, actP: Engine.round4(actP),
                            probs: probs,
                            latencyMs: (ms * 100).rounded() / 100)
    }

    /// Builds the padded batch views over the persistent buffers and runs one
    /// pass. The views BORROW the buffers: refcount-cheap let copies pin the
    /// shared buffers in this async frame across the await (the pattern the
    /// probe verified); the actor guarantees no other writer until we return.
    private func runPass(qt: Int32, hi: Int32) async throws -> ([Double], [Double]) {
        let ids = idsBuf
        let att = attBuf
        let mpos = mposBuf
        let mmask = mmaskBuf
        let qtArr = [qt]
        let hiArr = [hi]

        var inputs = InferenceFunction.Inputs()
        inputs.insert(NDArray.View(span: ids.span, shape: [1, Lmax]), for: "input_ids")
        inputs.insert(NDArray.View(span: att.span, shape: [1, Lmax]), for: "attention_mask")
        inputs.insert(NDArray.View(span: mpos.span, shape: [1, Kmax]), for: "marker_pos")
        inputs.insert(NDArray.View(span: mmask.span, shape: [1, Kmax]), for: "marker_mask")
        inputs.insert(NDArray.View(span: qtArr.span, shape: [1]), for: "qtype")
        inputs.insert(NDArray.View(span: hiArr.span, shape: [1]), for: "head_idx")

        var logits = [Double](repeating: 0, count: Kmax)
        var act = [Double](repeating: 0, count: 2)
        var outputs = try await fn.run(inputs: inputs)
        if let v = outputs.remove("logits"), let nd = v.ndArray {
            let arr = nd.toFloat64Array()
            if arr.count >= Kmax { logits = Array(arr.prefix(Kmax)) }
        }
        if let v = outputs.remove("act"), let nd = v.ndArray {
            let arr = nd.toFloat64Array()
            if arr.count >= 2 { act = [arr[0], arr[1]] }
        }
        return (logits, act)
    }

    public static func softmax(_ xs: [Double]) -> [Double] {
        guard let m = xs.max() else { return [] }
        var e = [Double](repeating: 0, count: xs.count)
        var s = 0.0
        for i in 0..<xs.count { let v = Foundation.exp(xs[i] - m); e[i] = v; s += v }
        guard s > 0 else { return e }
        for i in 0..<e.count { e[i] /= s }
        return e
    }

    public static func round4(_ v: Double) -> Double {
        (v * 1e4).rounded(.toNearestOrEven) / 1e4
    }
}

@available(macOS 27.0, *)
extension NDArray {
    /// Contiguous float32/float16 -> [Double] through the runtime's own
    /// withUnsafeBytes (no intermediate copies).
    func toFloat64Array() -> [Double] {
        var out: [Double] = []
        var count = 1
        for d in shape { count *= d }
        guard count > 0 else { return out }
        switch scalarType {
        case .float32:
            out = [Double](repeating: 0, count: count)
            _ = view(as: Float.self).withUnsafePointer { p, _, _ in
                for i in 0..<count { out[i] = Double(p[i]) }
            }
        case .float16:
            out = [Double](repeating: 0, count: count)
            _ = view(as: UInt16.self).withUnsafePointer { p, _, _ in
                for i in 0..<count {
                    out[i] = Double(Float16(bitPattern: p[i]))
                }
            }
        default:
            break
        }
        return out
    }
}
