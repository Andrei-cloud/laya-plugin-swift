import Foundation

/// Port of server/laya_api_sec.py — the Jev-compatible question-API wire
/// contract: error vocabulary, Bearer auth, request-envelope validation,
/// answer-invariant validation, response size cap.
///
/// Wire names are NOT ours to rename (spec-v2 §8): question types and
/// envelope/answer fields stay exactly Jev-compat.
public enum LayaAPI {
    static let questionTypes: Set<String> = ["choice", "score", "noul"]

    static let maxStateChars = 60_000
    static let maxResponseBytes = 1_000_000

    // Tolerances the caller's validators enforce — satisfied by construction.
    static let sigmaTol = 0.01 + 1e-12
    static let argmaxTol = 1e-9
    static let scoreMatchTol = 0.02 + 1e-12

    static let retryable: Set<String> = [
        "rate_limited", "overloaded", "network",
        "http_500", "http_502", "http_503", "http_504",
    ]

    static let httpStatusMap: [String: Int] = [
        "no_key": 401, "auth_failed": 401, "credits_exhausted": 402,
        "rate_limited": 429, "overloaded": 529, "state_too_large": 400,
        "invalid_response": 400, "response_too_large": 500,
        "malformed": 400, "timeout": 504,
    ]

    public static func isRetryable(_ code: String) -> Bool { retryable.contains(code) }

    public static func httpStatus(_ code: String) -> Int {
        if let s = httpStatusMap[code] { return s }
        if code.hasPrefix("http_"), let n = Int(code.dropFirst(5)) { return n }
        return 400
    }

    public struct ApiError: Error, CustomStringConvertible {
        public let code: String
        public var detail: String? = nil
        public var invariant: String? = nil
        public var description: String {
            invariant == nil ? code : "\(code): \(invariant!)"
        }
        public var httpStatus: Int { LayaAPI.httpStatus(code) }

        /// {"status":"invalid_request","error":code[,invariant]} — never a
        /// secret, never prompt text.
        public func toResponse() -> JSONValue {
            var pairs: [(key: String, value: JSONValue)] = [
                (key: "status", value: .string("invalid_request")),
                (key: "error", value: .string(code)),
            ]
            if let inv = invariant { pairs.append((key: "invariant", value: .string(inv))) }
            return .object(pairs)
        }
    }

    // MARK: - auth

    /// Bearer check against the TOKEN alias (constant-time compare, no
    /// secret material in code/detail/body). No token configured → loopback
    /// trust (pass).
    public static func checkAuth(authorization: String?) throws {
        let expected = Naming.envAlias("TOKEN")
        guard let expected, !expected.isEmpty else { return }
        guard let authorization else {
            throw ApiError(code: "auth_failed", detail: "missing Authorization header")
        }
        let parts = authorization.split(separator: " ", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            throw ApiError(code: "auth_failed", detail: "Authorization header must be Bearer")
        }
        let supplied = parts[1].trimmingCharacters(in: .whitespaces)
        guard constantTimeEquals(supplied, expected) else {
            throw ApiError(code: "auth_failed", detail: "bearer token mismatch")
        }
    }

    /// hmac.compare_digest equivalent.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        // Length equality is not secret here (token lengths are fixed-width
        // hex); still, compare every byte of the shorter side.
        var diff: UInt8 = UInt8(truncatingIfNeeded: ab.count &- bb.count)
        for i in 0..<min(ab.count, bb.count) {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0 && ab.count == bb.count
    }

    // MARK: - request validation

    public struct ValidatedRequest {
        public var state: JSONValue
        public var stateChars: Int
        public var model: String
        public var questions: [(name: String, q: JSONValue)]   // insertion order kept
    }

    public static func validateQuestion(name: String, q: JSONValue) throws {
        guard !name.isEmpty else {
            throw ApiError(code: "invalid_question_name",
                           detail: "question name must be a non-empty string")
        }
        guard case .object = q else {
            throw ApiError(code: "question_not_object", detail: "question \(name) must be an object")
        }
        if q["kind"] != nil || q["text"] != nil {
            throw ApiError(code: "cli_alias_on_http",
                           detail: "question \(name): kind/text aliases are CLI-only, the wire requires type/instructions")
        }
        let qtype = q["type"]?.stringValue ?? ""
        guard questionTypes.contains(qtype) else {
            throw ApiError(code: "unknown_question_type",
                           detail: "question \(name): type '\(qtype)' not in \(questionTypes.sorted())")
        }
        guard let ins = q["instructions"]?.stringValue, !ins.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ApiError(code: "instructions_required",
                           detail: "question \(name): instructions must be a non-empty string")
        }
        guard ins != name else {
            throw ApiError(code: "instructions_equals_name",
                           detail: "question \(name): instructions must differ from its name")
        }
        let criteria = q["criteria"]
        switch qtype {
        case "noul":
            let empty: Bool = criteria == nil || criteria == .null
                || criteria == .object([]) || criteria == .array([])
            guard empty else {
                throw ApiError(code: "noul_criteria_forbidden",
                               detail: "question \(name): noul must not carry criteria")
            }
        case "choice":
            guard let pairs = criteria?.objectPairs, pairs.count >= 2 else {
                throw ApiError(code: "choice_needs_two_options",
                               detail: "question \(name): choice needs a criteria mapping with >=2 options")
            }
            guard pairs.allSatisfy({ !$0.key.isEmpty }) else {
                throw ApiError(code: "choice_option_names_invalid",
                               detail: "question \(name): choice option names must be non-empty strings")
            }
        case "score":
            guard let levels = criteria?.arrayValue, levels.count >= 2,
                  levels.allSatisfy({ ($0.stringValue ?? "").isEmpty == false })
            else {
                throw ApiError(code: "score_levels_invalid",
                               detail: "question \(name): score levels must be non-empty strings")
            }
        default: break
        }
    }

    public static func validateRequest(_ payload: JSONValue) throws -> ValidatedRequest {
        guard case .object = payload else {
            throw ApiError(code: "envelope_not_object", detail: "request body must be a JSON object")
        }
        guard let state = payload["state"] else {
            throw ApiError(code: "state_required", detail: "state is required")
        }
        switch state {
        case .string, .object, .array: break
        default:
            throw ApiError(code: "state_type", detail: "state must be a string, object, or array")
        }
        let stateChars = JSONValue.serialize(state, sortKeys: false).unicodeScalars.count
        guard stateChars <= maxStateChars else {
            throw ApiError(code: "state_too_large",
                           detail: "state is \(stateChars) JSON chars (cap \(maxStateChars))")
        }
        if let m = payload["model"], m != .null, m.stringValue == nil {
            throw ApiError(code: "model_type", detail: "model must be a string when present")
        }
        let model = Naming.modelId(payload["model"]?.stringValue)
        guard let qs = payload["questions"]?.objectPairs, !qs.isEmpty else {
            throw ApiError(code: "questions_required",
                           detail: "questions must be a mapping with at least one entry")
        }
        for p in qs {
            try validateQuestion(name: p.key, q: p.value)
        }
        return ValidatedRequest(state: state, stateChars: stateChars, model: model,
                                questions: qs.map { (name: $0.key, q: $0.value) })
    }

    // MARK: - answer validation (invariants the caller refuses to act on)

    private static func isNumber(_ v: JSONValue?) -> Bool {
        if case .int = v { return true }
        if case .double = v { return true }
        return false
    }

    private static func requireNumber(_ answer: JSONValue, _ key: String, _ invariant: String) throws -> Double {
        let v = answer[key]
        guard isNumber(v) else {
            throw ApiError(code: "invalid_response", detail: "\(key) must be a number", invariant: invariant)
        }
        return v!.numberValue!
    }

    public static func validateAnswer(name: String, question: JSONValue, answer: JSONValue) throws {
        guard case .object = answer else {
            throw ApiError(code: "invalid_response", detail: "answer \(name) must be an object",
                           invariant: "answer_shape")
        }
        let qtype = question["type"]?.stringValue ?? ""
        guard answer["type"]?.stringValue == qtype else {
            throw ApiError(code: "invalid_response",
                           detail: "answer \(name): type \(answer["type"]?.stringValue ?? "nil") != question type \(qtype)",
                           invariant: "answer_type_mismatch")
        }
        switch qtype {
        case "noul":
            let p = try requireNumber(answer, "noul", "noul_range")
            guard (0.0...1.0).contains(p) else {
                throw ApiError(code: "invalid_response", detail: "answer \(name): noul \(p) outside [0,1]",
                               invariant: "noul_range")
            }
        case "choice":
            guard let critPairs = question["criteria"]?.objectPairs else {
                throw ApiError(code: "invalid_response", detail: "question criteria missing",
                               invariant: "probability_keys")
            }
            let options = Set(critPairs.map(\.key))
            guard let probs = answer["probabilities"]?.objectPairs,
                  Set(probs.map(\.key)) == options else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): probability keys must equal the options exactly",
                               invariant: "probability_keys")
            }
            guard probs.allSatisfy({ isNumber($0.value) }) else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): probabilities must all be numbers",
                               invariant: "probability_numbers")
            }
            let total = probs.reduce(0.0) { $0 + $1.value.numberValue! }
            guard abs(total - 1.0) <= sigmaTol else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): Σp=\(total) != 1 ± \(sigmaTol)",
                               invariant: "probability_mass")
            }
            guard let chosen = answer["choice"]?.stringValue, options.contains(chosen) else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): choice is not an option",
                               invariant: "argmax")
            }
            let best = probs.map { $0.value.numberValue! }.max() ?? 0
            let chosenP = probs.first { $0.key == chosen }!.value.numberValue!
            guard chosenP >= best - argmaxTol else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): choice \(chosen) is not the argmax",
                               invariant: "argmax")
            }
            _ = try requireNumber(answer, "confidence", "confidence_number")
        case "score":
            guard let levels = question["criteria"]?.arrayValue else {
                throw ApiError(code: "invalid_response", detail: "score levels missing",
                               invariant: "probability_keys")
            }
            let L = levels.count
            let score = try requireNumber(answer, "score", "score_band")
            guard -0.5...Double(L) - 0.5 ~= score else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): score \(score) outside [-0.5, \(Double(L) - 0.5)]",
                               invariant: "score_band")
            }
            guard let probs = answer["probabilities"]?.objectPairs,
                  Set(probs.map(\.key)) == Set((0..<L).map(String.init)) else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): probability keys must be \"0\"..\"\(L - 1)\"",
                               invariant: "probability_keys")
            }
            guard probs.allSatisfy({ isNumber($0.value) }) else {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): probabilities must all be numbers",
                               invariant: "probability_numbers")
            }
            if answer["spread_reported"] == .bool(true) {
                let total = probs.reduce(0.0) { $0 + $1.value.numberValue! }
                guard abs(total - 1.0) <= sigmaTol else {
                    throw ApiError(code: "invalid_response",
                                   detail: "answer \(name): Σp=\(total) != 1 ± \(sigmaTol)",
                                   invariant: "probability_mass")
                }
                let expectation = probs.reduce(0.0) { $0 + Double($1.key)! * $1.value.numberValue! }
                guard abs(expectation - score) <= scoreMatchTol else {
                    throw ApiError(code: "invalid_response",
                                   detail: "answer \(name): Σ(level·p)=\(expectation) != score \(score) ± \(scoreMatchTol)",
                                   invariant: "score_matches_its_distribution")
                }
            }
            if let conf = answer["confidence"], !isNumber(conf) {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): confidence must be a number",
                               invariant: "confidence_number")
            }
            if let legend = answer["legend"], case .object(let lp) = legend {
                let ok = lp.allSatisfy {
                    $0.value.stringValue != nil && !$0.key.isEmpty
                }
                guard ok else {
                    throw ApiError(code: "invalid_response",
                                   detail: "answer \(name): legend must be an idx->str mapping",
                                   invariant: "legend_shape")
                }
            } else if answer["legend"] != nil && answer["legend"] != .null {
                throw ApiError(code: "invalid_response",
                               detail: "answer \(name): legend must be an idx->str mapping",
                               invariant: "legend_shape")
            }
        default: break
        }
    }

    public static func validateAnswers(questions: [(name: String, q: JSONValue)],
                                answers: JSONValue) throws {
        guard case .object = answers else {
            throw ApiError(code: "invalid_response", detail: "answers must be a mapping",
                           invariant: "answers_shape")
        }
        let qNames = Set(questions.map(\.name))
        let aNames = Set(answers.objectPairs?.map(\.key) ?? [])
        let missing = qNames.subtracting(aNames)
        let extra = aNames.subtracting(qNames)
        if !missing.isEmpty {
            throw ApiError(code: "invalid_response",
                           detail: "missing answers for \(missing.sorted())",
                           invariant: "missing_answer")
        }
        if !extra.isEmpty {
            throw ApiError(code: "invalid_response",
                           detail: "answers for unknown questions \(extra.sorted())",
                           invariant: "unexpected_answer")
        }
        for q in questions {
            try validateAnswer(name: q.name, question: q.q, answer: answers[q.name]!)
        }
    }

    // MARK: - response size cap

    @discardableResult
    public static func checkResponseSize(_ payload: JSONValue) throws -> Int {
        let n = JSONValue.serialize(payload).utf8.count
        guard n <= maxResponseBytes else {
            throw ApiError(code: "response_too_large",
                           detail: "response is \(n) bytes (cap \(maxResponseBytes))")
        }
        return n
    }
}
