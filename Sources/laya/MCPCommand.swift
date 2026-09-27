import ArgumentParser
import Foundation
import LayaCore
import LayaHTTP

/// `laya mcp` — MCP stdio server, native Swift.
///
/// Speaks MCP over stdin/stdout (Content-Length framed, like LSP):
/// every MCP harness (Hermes `mcp add --command`, Claude Desktop,
/// opencode) registers it with zero dependencies — it IS the laya
/// binary. The daemon's `POST /mcp` mount serves the SAME three tools
/// through the SAME dispatch (MCP.swift); this transport only adds
/// framing.
///
/// Engine policy vs the legacy stdio server: legacy loaded the ~1 GB
/// asset at process start (fail fast). The Swift daemon already holds
/// a warm engine on :11270, so loading a SECOND one per harness session
/// here would double ANE/GPU pressure for no benefit. Therefore:
///   - `laya mcp` (default): tools proxy to the daemon's question API
///     over loopback (RemoteEngine path) — session start is instant,
///     the machine keeps ONE loaded model.
///   - `laya mcp --local`: legacy behavior — load CoreAI in-process
///     (for machines with no daemon).
/// Both answer through MCP.dispatch — identical envelopes.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP stdio server (laya_ask / laya_guard / laya_status).")

    @Flag(help: "load CoreAI in-process instead of proxying to the daemon")
    var local = false

    @Option(help: "daemon base url for the proxy (default env LAYA_DECISIOND_URL)")
    var url: String?

    func run() async throws {
        let bridge: any MCP.Bridge
        if #available(macOS 27.0, *) {
            if local {
                let (assets, source) = LayaCLI.Ask.resolvePaths()
                let engine = try await Engine(Engine.Config(
                    assetDir: assets, sourceDir: source,
                    unit: Naming.envAlias("UNIT") ?? "gpu"))
                bridge = MCPBridge(engine)
            } else {
                bridge = ProxyBridge(baseURL: url ?? Naming.envAlias("DECISIOND_URL")
                    ?? "http://127.0.0.1:11270")
            }
        } else {
            bridge = ProxyBridge(baseURL: url ?? Naming.envAlias("DECISIOND_URL")
                ?? "http://127.0.0.1:11270")
        }
        note("laya mcp: stdio server ready (" + (local ? "local engine" : "proxy → daemon") + ")")
        await StdioLoop(bridge: bridge).run()
    }
}

/// stdio transport: LSP-style `Content-Length: N\r\n\r\n{json}` frames
/// on stdin → stdout. stdout carries ONLY JSON-RPC (the `note()`
/// convention already keeps engine chatter on stderr).
///
/// POSIX read(2)/write(2) on fds 0/1 — NOT FileHandle.read(upToCount:):
/// inside a Task on the cooperative pool the Foundation API returns nil
/// on a blocking pipe instead of waiting (measured: zero frames, clean
/// exit). Blocking reads on a pool thread are exactly what the legacy
/// Python stdio server did; a stdio MCP server is ONE connection per
/// process, so no thread is wasted.
struct StdioLoop {
    let bridge: any MCP.Bridge

    func run() async {
        while let frame = Self.readFrame() {
            let response: JSONValue?
            if let msg = JSONValue.parse(frame) {
                switch await MCP.dispatch(msg, bridge: bridge) {
                case .none:
                    response = nil
                case .response(let envelope):
                    response = envelope
                }
            } else {
                // Parse error carries id "server-error" at the transport
                // level (HTTP mount answers 400; stdio has no status code —
                // the envelope alone is the signal, like the SDK's stdio
                // server).
                response = JSONValue.obj(
                    "jsonrpc", .string("2.0"),
                    "id", .string("server-error"),
                    "error", JSONValue.obj(
                        "code", .int(Int64(MCP.parseError)),
                        "message", .string("Parse error: invalid JSON")))
            }
            guard let response else { continue }
            Self.writeFrame(JSONValue.serialize(response,
                                                 separators: (",", ":")))
        }
    }

    /// Blocking read of exactly `count` bytes (EOF/short → nil).
    private static func readExact(_ count: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }        // EOF or error
            got += n
        }
        return Data(buf)
    }

    private static func readLineBlocking() -> String? {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = withUnsafeMutableBytes(of: &byte) { read(0, $0.baseAddress!, 1) }
            if n <= 0 {
                // EOF (n == 0) or a real error: end of stream either way.
                return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
            }
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
            if line.count > 1_000_000 { return String(decoding: line, as: UTF8.self) }
        }
    }

    private static func readFrame() -> Data? {
        // Header block: lines until the empty line. Only Content-Length
        // is honoured; unknown headers are ignored (spec).
        var length = -1
        while true {
            guard var line = readLineBlocking() else { return nil }   // EOF
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { break }                                   // end of headers
            let parts = line.split(separator: ":", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].lowercased() == "content-length",
               let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                length = n
            }
        }
        guard length >= 0 else { return nil }
        return readExact(length)
    }

    /// One framed message out, full-write loop (stdout is a pipe).
    private static func writeFrame(_ payload: String) {
        let bytes = Array(payload.utf8)
        var head = Array("Content-Length: \(bytes.count)\r\n\r\n".utf8)
        head.append(contentsOf: bytes)
        var sent = 0
        head.withUnsafeBytes { raw in
            while sent < head.count {
                let n = write(1, raw.baseAddress! + sent, head.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

/// Bridge that answers through the daemon over loopback HTTP — the
/// same RemoteEngine rails the use-case rows use, wrapped as MCP tool
/// calls. Fail-open: a daemon that can't be reached returns
/// {"error":"network","fallback":…} as text, never throws.
final class ProxyBridge: MCP.Bridge, @unchecked Sendable {
    let baseURL: String
    init(baseURL: String) {
        var b = baseURL
        if b.hasSuffix("/") { b = String(b.dropLast()) }
        self.baseURL = b
    }

    func callTool(name: String, args: JSONValue) async -> MCP.ToolText {
        switch name {
        case "laya_ask":
            return await post("/v1/laya", args)
        case "laya_guard":
            // The daemon's /guard rail builds "About to run: …" itself —
            // send the raw command verbatim (no double prefix), then
            // reshape its engine document to the legacy laya_guard
            // fields (choice/confidence/verdict/latency_ms/chain).
            let raw = await post("/guard", JSONValue.obj(
                "command", args["command"] ?? .string("")))
            if let doc = JSONValue.parse(raw.text), doc["verdict"] != nil {
                let keep = ["choice", "confidence", "verdict", "latency_ms", "chain"]
                let pairs = keep.compactMap { k -> (String, JSONValue)? in
                    doc[k].map { (k, $0) }
                }
                return .text(JSONValue.serialize(.object(pairs),
                                                 separators: (",", ":")))
            }
            return raw
        case "laya_status":
            return await get("/health")
        default:
            return .text(MCPHTTPBridgeFail.open("ValueError: unknown tool \(name)"))
        }
    }

    private func post(_ path: String, _ payload: JSONValue) async -> MCP.ToolText {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token = Naming.envAlias("TOKEN"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = Data(JSONValue.serialize(payload,
                                                    separators: (",", ":")).utf8)
        request.timeoutInterval = 120
        do {
            let (d, _) = try await URLSession.shared.data(for: request)
            // The daemon's body (200 or refusal) is the tool result
            // document verbatim — codes preserved.
            return .text(String(decoding: d, as: UTF8.self))
        } catch {
            return .text(MCPHTTPBridgeFail.open("network"))
        }
    }

    private func get(_ path: String) async -> MCP.ToolText {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "GET"
        if let token = Naming.envAlias("TOKEN"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        request.timeoutInterval = 30
        do {
            let (d, _) = try await URLSession.shared.data(for: request)
            return .text(String(decoding: d, as: UTF8.self))
        } catch {
            return .text(MCPHTTPBridgeFail.open("network"))
        }
    }
}

enum MCPHTTPBridgeFail {
    static func open(_ code: String) -> String {
        JSONValue.serialize(JSONValue.obj(
            "error", .string(code),
            "fallback", .string("proceed with normal judgement")),
            separators: (",", ":"))
    }
}
