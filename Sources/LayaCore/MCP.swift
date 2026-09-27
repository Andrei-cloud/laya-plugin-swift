import Foundation

/// MCP (Model Context Protocol) core — native Swift, transport-agnostic.
///
/// One dispatch implementation serves BOTH surfaces, so the stdio CLI
/// server (`laya mcp`) and the daemon's streamable-HTTP mount
/// (POST /mcp on layad) can never drift from each other or from the
/// question API — every tool call lands on the SAME validate→answer→
/// validate path as HTTP /v1/laya (mirrors the legacy
/// server/laya_mcp.py + laya_http_mcp.py pair, which shared one
/// `Server("laya-decision")` app across stdio and HTTP).
///
/// Wire behavior was captured byte-for-byte from the legacy
/// mcp SDK 1.30.0 StreamableHTTPSessionManager (stateless=True) —
/// see golden/mcp_wire.json + Tests. Deviations from the Python SDK
/// are deliberate and documented at each site (pydantic validation
/// dumps cannot be cloned; the JSON-RPC CODES are preserved).
public enum MCP {
    public static let serverName = "laya-decision"
    /// Newest protocol revision we answer for (legacy SDK's LATEST —
    /// clients that offer something unknown get this value back).
    public static let latestProtocolVersion = "2025-11-25"
    /// Revisions we fully implement (echoed back verbatim).
    public static let knownProtocolVersions: Set<String> = [
        "2024-10-07", "2025-03-26", "2025-06-18", "2025-11-25",
    ]

    /// JSON-RPC error codes (spec-fixed).
    public static let parseError = -32700
    public static let invalidParams = -32602
    public static let invalidRequest = -32600

    // MARK: - bridge (engine side)

    /// The tool-execution side. Implementations must NOT throw:
    /// fail-open semantics — a decision failure returns
    /// `{"error": code, "fallback": "proceed with normal judgement"}`
    /// as TEXT (isError stays false), exactly like legacy
    /// laya_mcp.call_tool's `except` arm: the harness must never crash
    /// over a decision.
    public protocol Bridge: Sendable {
        func callTool(name: String, args: JSONValue) async -> MCP.ToolText
    }

    public struct ToolText: Sendable {
        public var text: String
        public var isError: Bool
        public init(text: String, isError: Bool = false) {
            self.text = text; self.isError = isError
        }
        public static func text(_ t: String, isError: Bool = false) -> ToolText {
            ToolText(text: t, isError: isError)
        }
    }

    // MARK: - tool specs (verbatim from legacy laya_mcp.py)

    public static func toolsSpec() -> JSONValue {
        let askSchema = JSONValue.obj(
            "type", .string("object"),
            "properties", JSONValue.obj(
                "state", .string(
                    "Agent state: last action/command + short context. "
                    + "Plain text or JSON; <=60 000 chars."),
                "questions", .string(
                    "Named wire questions, one per key: {name: "
                    + "{type:'noul'|'choice'|'score', instructions:str, "
                    + "criteria?: {opt:meaning} | [levels lowest-first]}}. "
                    + "noul carries no criteria; choice needs >=2 options; "
                    + "score needs >=2 rubric levels."),
                "model", .string("Optional id; echoed back verbatim.")),
            "required", .array([.string("state"), .string("questions")]))
        let guardSchema = JSONValue.obj(
            "type", .string("object"),
            "properties", JSONValue.obj(
                "command", .string("The exact command or action about to run.")),
            "required", .array([.string("command")]))
        return .array([
            JSONValue.obj(
                "name", .string("laya_ask"),
                "description", .string(
                    "Ask the Laya decision model named wire questions in "
                    + "one call: types noul (yes/no probability), choice "
                    + "(closed-set pick + calibrated probabilities), score "
                    + "(rubric levels, lowest first). Answers satisfy the "
                    + "wire invariants (Σp=1, choice=argmax, score matches "
                    + "its distribution); confidence<0.6 means escalate to "
                    + "the LLM / human. Escape hatch for any harness."),
                "inputSchema", askSchema),
            JSONValue.obj(
                "name", .string("laya_guard"),
                "description", .string(
                    "Safety-gate one proposed command/action before running "
                    + "it. Returns allow/ask/block + confidence. block/ask "
                    + "=> do not run without explicit user confirmation."),
                "inputSchema", guardSchema),
            JSONValue.obj(
                "name", .string("laya_status"),
                "description", .string(
                    "Plugin health: asset loaded, chains, mean latency, "
                    + "call count."),
                "inputSchema", JSONValue.obj("type", .string("object"),
                                             "properties", .object([]))),
        ])
    }

    // MARK: - dispatch (shared by stdio + HTTP transports)

    public enum Outcome: Sendable {
        /// Nothing to write (a notification was consumed).
        case none
        /// One JSON-RPC response envelope to write back.
        case response(JSONValue)
    }

    static func error(id: JSONValue?, code: Int, message: String,
                      data: String? = nil) -> JSONValue {
        var err: [(key: String, value: JSONValue)] = [
            (key: "code", value: .int(Int64(code))),
            (key: "message", value: .string(message)),
        ]
        if let data { err.append((key: "data", value: .string(data))) }
        return .object([
            (key: "jsonrpc", value: .string("2.0")),
            (key: "id", value: id ?? .null),
            (key: "error", value: .object(err)),
        ])
    }

    static func result(id: JSONValue?, _ result: JSONValue) -> JSONValue {
        .object([
            (key: "jsonrpc", value: .string("2.0")),
            (key: "id", value: id ?? .null),
            (key: "result", value: result),
        ])
    }

    /// Shape check mirroring the SDK's pydantic discrimination: a
    /// request/notification needs jsonrpc == "2.0" and a string method.
    public static func looksLikeRPC(_ msg: JSONValue) -> Bool {
        msg["jsonrpc"]?.stringValue == "2.0" && msg["method"]?.stringValue != nil
    }

    /// One parsed JSON-RPC message → one response (or none).
    /// Unknown methods answer -32602 "Invalid request parameters" —
    /// the legacy SDK's observed behavior (NOT -32601; golden-captured:
    /// mcp SDK routes unknown methods through its request-validation
    /// arm). A message without an id is a notification → .none.
    public static func dispatch(_ msg: JSONValue, bridge: Bridge) async -> Outcome {
        guard looksLikeRPC(msg) else {
            // stdio lane: the SDK would reply with a validation error;
            // HTTP maps the same shape to 400 before dispatch.
            return .response(error(id: msg["id"], code: invalidParams,
                                   message: "Validation error: not a valid JSON-RPC message"))
        }
        let method = msg["method"]!.stringValue!
        let id = msg["id"]

        if method.hasPrefix("notifications/") || id == nil {
            _ = await bridge   // consumed silently (initialized etc.)
            return .none
        }

        switch method {
        case "initialize":
            let params = msg["params"] ?? .null
            guard let pv = params["protocolVersion"]?.stringValue else {
                return .response(error(id: id, code: invalidParams,
                                       message: "Invalid request parameters", data: ""))
            }
            let negotiated = knownProtocolVersions.contains(pv) ? pv : latestProtocolVersion
            return .response(result(id: id, .object([
                (key: "protocolVersion", value: .string(negotiated)),
                (key: "capabilities", value: .object([
                    (key: "experimental", value: .object([])),
                    (key: "tools", value: .object([
                        (key: "listChanged", value: .bool(false))])),
                ])),
                (key: "serverInfo", value: .object([
                    (key: "name", value: .string(serverName)),
                    (key: "version", value: .string(LayaVersion.string))])),
            ])))
        case "ping":
            return .response(result(id: id, .object([])))
        case "tools/list":
            return .response(result(id: id, .object([
                (key: "tools", value: toolsSpec())])))
        case "tools/call":
            let params = msg["params"] ?? .null
            guard let name = params["name"]?.stringValue else {
                return .response(error(id: id, code: invalidParams,
                                       message: "Invalid request parameters", data: ""))
            }
            let args = params["arguments"] ?? .object([])
            let out = await bridge.callTool(name: name, args: args)
            return .response(result(id: id, .object([
                (key: "content", value: .array([.object([
                    (key: "type", value: .string("text")),
                    (key: "text", value: .string(out.text)),
                ])])),
                (key: "isError", value: .bool(out.isError)),
            ])))
        default:
            return .response(error(id: id, code: invalidParams,
                                   message: "Invalid request parameters", data: ""))
        }
    }
}
