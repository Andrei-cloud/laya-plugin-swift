import Foundation
import LayaCore

/// The question-API router — byte-faithful port of laya_api_http.py.
/// Paths: POST /v1/systemone and POST /v1/laya (same handler), GET
/// /v1/models, GET /health (built by the daemon). Bearer auth via the
/// TOKEN alias, 60k state cap + 1 MB response cap enforced through
/// LayaAPI/LayaCore, refusal bodies carry codes only — never prompt
/// text, never secrets.
///
/// macOS 27: mounts the Core AI Engine (Engine is @available(macOS 27.0)).
@available(macOS 27.0, *)
public enum QuestionAPI {
    public static let paths = ["/v1/systemone", "/v1/laya"]
    public static let modelsPath = "/v1/models"
    public static let defaultRequestBudgetS = 90.0

    public static func requestBudgetS() -> Double {
        if let s = Naming.envAlias("REQUEST_BUDGET_S"), let v = Double(s) { return v }
        return defaultRequestBudgetS
    }

    /// GET /health document (the daemon's warm state — `warm` reports the
    /// engine's honest state, not a hardcoded true).
    public static func healthPayload(chains: [String], calls: Int,
                                     totalMs: Double, warm: Bool) -> JSONValue {
        JSONValue.obj(
            "ok", .bool(true),
            "warm", .bool(warm),
            "chains", .array(chains.map { .string($0) }),
            "calls", .int(Int64(calls)),
            "mean_latency_ms", .double((totalMs / Double(max(1, calls)) * 100).rounded() / 100))
    }

    /// Validate → answer every question → validate our own answers →
    /// build the response envelope. Raises LayaAPI.ApiError on refusals;
    /// `deadline` is checked BETWEEN questions (T1.5 batching) so an
    /// over-budget batch aborts retryable BEFORE half-answering.
    public static func answerRequest(_ payload: JSONValue, engine: Engine,
                                     deadline: Date? = nil) async throws -> JSONValue {
        let req = try LayaAPI.validateRequest(payload)
        var answers: [(key: String, value: JSONValue)] = []
        for qp in req.questions {
            if let deadline, Date() > deadline {
                throw LayaAPI.ApiError(
                    code: "overloaded",
                    detail: "request budget exceeded after \(answers.count)"
                        + " of \(req.questions.count) questions")
            }
            // Engine.question runs the chain rule AND the laya_ops answerer
            // (the Python engine.question + _ANSWERERS[qtype] pair folded
            // into one call — the probe-verified path).
            let wa = try await engine.question(name: qp.name, q: qp.q, state: req.state)
            answers.append((key: qp.name, value: wa.answer))
        }
        // We validate our OWN answers with the consumer's validators before
        // sending — an invariant break never leaves the process.
        let answersObj = JSONValue.object(answers)
        try LayaAPI.validateAnswers(questions: req.questions, answers: answersObj)
        let body = JSONValue.obj(
            "answers", answersObj,
            "model", .string(req.model),
            "usage", JSONValue.obj(
                "requests", .int(1),
                "chars_in", .int(Int64(req.stateChars)),
                "chars_out", .int(Int64(JSONValue.jsonCharLen(answersObj)))))
        _ = try LayaAPI.checkResponseSize(body)   // ≤ 1 MB
        return body
    }

    /// Route one request. Returns nil when no route matches (caller 404s).
    public static func handle(_ req: HTTPRequest, engine: Engine) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        if path == modelsPath && method == "GET" {
            let mid = Naming.modelId(nil)
            let chains = await engine.chainOrder
            return HTTPResponse.json(200, JSONValue.obj(
                "object", .string("list"),
                "data", .array([JSONValue.obj(
                    "id", .string(mid), "object", .string("model"),
                    "owned_by", .string("laya"),
                    "chains", .array(chains.map { .string($0) }))])))
        }
        guard paths.contains(path) else { return nil }
        if method != "POST" {
            return HTTPResponse.json(405, JSONValue.obj(
                "status", .string("invalid_request"), "error", .string("POST only")))
        }

        let requestID = req.header("x-request-id")
            ?? String(UUID().uuid4Hex().prefix(16))
        let reqHdr: [(String, String)] = [("x-request-id", requestID)]
        do {
            try LayaAPI.checkAuth(authorization: req.header("authorization"))
            let cap = LayaAPI.maxStateChars + 65_536
            guard req.body.count <= cap else {
                throw LayaAPI.ApiError(code: "state_too_large",
                                       detail: "request body over \(cap) bytes")
            }
            guard let payload = JSONValue.parse(req.body) else {
                throw LayaAPI.ApiError(code: "malformed", detail: "body is not JSON")
            }
            let deadline = Date().addingTimeInterval(requestBudgetS())
            let body = try await answerRequest(payload, engine: engine, deadline: deadline)
            return HTTPResponse.json(200, body, extraHeaders: reqHdr)
        } catch let e as LayaAPI.ApiError {
            return HTTPResponse.json(e.httpStatus, e.toResponse(), extraHeaders: reqHdr)
        } catch let e as LayaOps.OpsError {
            // laya_ops refusing to serialize an invariant-breaking answer
            // (Python ValueError lane → internal): code-only body.
            _ = e
            return HTTPResponse.json(500, JSONValue.obj(
                "status", .string("invalid_request"), "error", .string("internal")),
                extraHeaders: reqHdr)
        } catch {
            // Engine worker error (ANE failure, timeout): RETRYABLE
            // overloaded semantics — the client retries once, else fails
            // open. No internals in the body.
            return HTTPResponse.json(529, JSONValue.obj(
                "status", .string("invalid_request"), "error", .string("overloaded")),
                extraHeaders: reqHdr)
        }
    }
}

extension UUID {
    /// 32 hex chars without dashes (Python uuid4().hex).
    func uuid4Hex() -> String {
        withUnsafeBytes(of: uuid) { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }
}
