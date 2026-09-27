import Foundation
import LayaCore

/// Engine-backed MCP bridge + the daemon's streamable-HTTP `/mcp`
/// mount — native Swift, zero-dependency.
///
/// Legacy parity: laya_http_mcp.py co-hosted
/// StreamableHTTPSessionManager(app=laya_mcp.app, stateless=True) on
/// the SAME port and Engine as the question API. `stateless=True`
/// means: every POST is a self-contained request/response — no session
/// map, no GET stream, no DELETE sessions. All wire shapes below were
/// golden-captured from the legacy mcp SDK 1.30.0 behavior on this
/// machine (golden/mcp_wire.json).
@available(macOS 27.0, *)
public final class MCPBridge: MCP.Bridge, @unchecked Sendable {
    public let engine: Engine
    public init(_ engine: Engine) { self.engine = engine }

    /// Fail-open tool execution: a decision failure NEVER throws — the
    /// harness gets `{"error": code, "fallback": "proceed with normal
    /// judgement"}` as text with isError=false (legacy call_tool's
    /// except arm; structured refusals keep their CODE).
    public func callTool(name: String, args: JSONValue) async -> MCP.ToolText {
        do {
            switch name {
            case "laya_ask":
                // SAME validate→answer→validate path as HTTP /v1/laya.
                let body = try await QuestionAPI.answerRequest(args, engine: engine)
                return .text(JSONValue.serialize(body))
            case "laya_guard":
                let cmd = args["command"]?.stringValue ?? ""
                // engine.ask_guardrail: one guardrail question over the
                // raw engine path (chain rule picks the trained chain),
                // then the verdict rail. State cap 900 chars, Python's.
                let out = try await engine.decideLegacy(
                    task: "guardrail",
                    state: .string(String(("About to run: " + cmd).prefix(900))),
                    options: nil, toolSlate: .object([]), skillSlate: .object([]))
                let choice = out["choice"]?.stringValue ?? "ask_user"
                let conf = out["confidence"]?.numberValue ?? 0.0
                let doc = JSONValue.obj(
                    "choice", .string(choice),
                    "confidence", .double(conf),
                    "verdict", .string(guardrailVerdict(choice: choice, confidence: conf)),
                    "latency_ms", out["latency_ms"] ?? .double(0),
                    "chain", .string(out["chain"]?.stringValue ?? ""))
                return .text(JSONValue.serialize(doc))
            case "laya_status":
                let stats = await (engine.chainOrder, engine.calls, engine.totalMs)
                let mean = (stats.2 / Double(max(1, stats.1)) * 100).rounded() / 100
                let doc = JSONValue.obj(
                    "ok", .bool(true),
                    "unit", .string(Naming.envAlias("UNIT") ?? "gpu"),
                    "chains", .array(stats.0.map { .string($0) }),
                    "calls", .int(Int64(stats.1)),
                    "mean_latency_ms", .double(mean))
                return .text(JSONValue.serialize(doc))
            default:
                return .text(Self.failOpen("ValueError: unknown tool \(name)"))
            }
        } catch let e as LayaAPI.ApiError {
            return .text(Self.failOpen(e.code))
        } catch let e as LayaOps.OpsError {
            return .text(Self.failOpen("ValueError: \(e.message)"))
        } catch {
            return .text(Self.failOpen("RuntimeError: "
                + String(String(describing: error).prefix(200))))
        }
    }

    static func failOpen(_ code: String) -> String {
        JSONValue.serialize(JSONValue.obj(
            "error", .string(code),
            "fallback", .string("proceed with normal judgement")))
    }
}

/// The streamable-HTTP transport (stateless) as a router handler.
/// Returns nil for non-/mcp paths. Check order mirrors the legacy SDK
/// exactly (golden-verified): accept → parse → dispatch.
@available(macOS 27.0, *)
public enum MCPHTTP {
    public static let pathPrefix = "/mcp"

    static func jsonRPCError(_ id: String, _ code: Int, _ message: String) -> JSONValue {
        JSONValue.obj(
            "jsonrpc", .string("2.0"),
            "id", .string(id),
            "error", JSONValue.obj(
                "code", .int(Int64(code)),
                "message", .string(message)))
    }

    /// Accept gate — the legacy SDK's literal substring tests
    /// (`"application/json" in accept and "text/event-stream" in
    /// accept`), no */* shortcut. Verified: a json-only accept gets 406
    /// from the legacy daemon too.
    static func acceptProblem(_ accept: String?) -> String? {
        let a = accept ?? ""
        if !(a.contains("application/json") && a.contains("text/event-stream")) {
            return "Not Acceptable: Client must accept both application/json and text/event-stream"
        }
        return nil
    }

    public static func handle(_ req: HTTPRequest, bridge: MCPBridge) async -> HTTPResponse? {
        guard req.path == pathPrefix || req.path.hasPrefix(pathPrefix + "/") else {
            return nil
        }
        switch req.method {
        case "POST":
            break
        case "GET":
            // Stateless mount: we never push server-initiated messages,
            // so we decline the standby stream instead of holding a
            // socket that can never fire (the legacy SDK opened the SSE
            // GET stream and hung it until disconnect — observable
            // behavior identical to a conformant client: zero messages
            // ever arrive).
            return HTTPResponse.json(405, jsonRPCError(
                "server-error", MCP.invalidRequest,
                "Method Not Allowed: Session termination not supported"))
        case "DELETE":
            return HTTPResponse.json(405, jsonRPCError(
                "server-error", MCP.invalidRequest,
                "Method Not Allowed: Session termination not supported"))
        default:
            return HTTPResponse.json(405, jsonRPCError(
                "server-error", MCP.invalidRequest, "Method Not Allowed"))
        }

        // Accept gate BEFORE parsing (legacy order — 406 even on garbage body).
        if let problem = acceptProblem(req.header("accept")) {
            return HTTPResponse.json(406, jsonRPCError(
                "server-error", MCP.invalidRequest, problem))
        }

        // Bearer auth (our addition around the legacy surface: the
        // daemon's other routes enforce LAYA_TOKEN; /mcp must not be
        // the hole that bypasses it).
        if let token = Naming.envAlias("TOKEN"), !token.isEmpty {
            let auth = (req.header("authorization") ?? "").lowercased()
            let supplied = auth.hasPrefix("bearer ")
                ? (req.header("authorization")!.dropFirst(7)
                    .trimmingCharacters(in: .whitespaces))
                : ""
            if supplied != Naming.envAlias("TOKEN") {
                return HTTPResponse.json(401, jsonRPCError(
                    "server-error", MCP.invalidRequest, "Unauthorized"))
            }
        }

        guard let msg = JSONValue.parse(req.body) else {
            // 400 + parse error, id "server-error" (golden).
            return HTTPResponse.json(400, jsonRPCError(
                "server-error", MCP.parseError, "Parse error: invalid JSON"))
        }

        switch await MCP.dispatch(msg, bridge: bridge) {
        case .none:
            // notification: 202 Accepted, empty body (golden)
            return HTTPResponse(status: 202, headers: [("content-length", "0")])
        case .response(let envelope):
            if !MCP.looksLikeRPC(msg) {
                // not a JSON-RPC message: 400 + validation error with
                // id "server-error" (the legacy pydantic dump is not
                // reproducible; the CODE and status are).
                return HTTPResponse.json(400, jsonRPCError(
                    "server-error", MCP.invalidParams,
                    "Validation error: not a valid JSON-RPC message"))
            }
            // Successful/failed request: one SSE frame, CRLF endings,
            // blank-line terminator (golden byte layout).
            let frame = "event: message\r\ndata: "
                + JSONValue.serialize(envelope, separators: (",", ":")) + "\r\n\r\n"
            return HTTPResponse(status: 200, headers: [
                ("content-type", "text/event-stream"),
                ("cache-control", "no-cache, no-transform"),
                ("x-accel-buffering", "no"),
            ], body: Data(frame.utf8))
        }
    }
}
