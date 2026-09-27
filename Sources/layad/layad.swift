import Foundation
import GRPC
import LayaCore
import LayaHTTP
import LayaGRPC
import Network
import NIOCore
import NIOPosix

/// layad — the warm decision daemon: ONE Engine (Core AI), the exact
/// Python HTTP wire (GET /health, GET /v1/models, POST /v1/laya +
/// /v1/systemone, laya_http bridge /decide + /guard), and the gRPC
/// surface (laya.v1.LayaDecision) for the Swift CLI. Binds 127.0.0.1 only.
///
/// Env contract: LAYA_ASSETS = the model root (HF download dir; the
/// sidecar dir is derived from it — LAYA_SOURCE remains a dev-only
/// override), LAYA_UNIT gpu|ne|cpu, LAYA_TOKEN (Bearer), LAYA_PORT
/// (HTTP 11270), LAYA_GRPC_PORT (gRPC 11271), LAYA_REQUEST_BUDGET_S.
///
/// Loads + shape-warms the Engine BEFORE binding (the Python daemon's
/// startup order: /health reports honest warm state).

@main
struct Layad {
    static func main() async {
        // LayaVersion is availability-ungated, so the version answer
        // works even on macOS < 27 (where the daemon itself refuses to
        // run) — one source of truth for all three binaries.
        LayaVersion.handleIfRequested(CommandLine.arguments)
        guard #available(macOS 27.0, *) else {
            FileHandle.standardError.write(Data("layad: macOS 27 required (CoreAI)\n".utf8))
            exit(1)
        }
        await run()
    }

    @available(macOS 27.0, *)
    static func run() async {
        // One root identifies the installation (HF layout): env ->
        // ~/.config/laya/daemon.json -> ~/.laya/model. The sidecar dir
        // (tokenizer + calibration) is DERIVED from it — no `source`
        // parameter. See LayaPaths.
        let (assets, source) = LayaPaths.resolve()
        let unit = Naming.envAlias("UNIT") ?? "gpu"
        let httpPort = UInt16(Naming.envAlias("PORT") ?? "11270") ?? 11270
        let grpcPort = UInt16(Naming.envAlias("GRPC_PORT") ?? "11271") ?? 11271

        let engine: Engine
        do {
            engine = try await Engine(Engine.Config(assetDir: assets,
                                                    sourceDir: source, unit: unit))
        } catch {
            FileHandle.standardError.write(Data("layad: engine load failed: \(error)\n".utf8))
            exit(3)
        }
        print("layad: engine warm (\(await engine.chainOrder.joined(separator: ",")))",
              terminator: "\n")

        // HTTP (exact Python wire)
        let router = HTTPRouter(engine: engine)
        let server: HTTPServer
        do {
            server = try HTTPServer(port: httpPort) { await router.handle($0) }
        } catch {
            FileHandle.standardError.write(Data("layad: http bind failed: \(error)\n".utf8))
            exit(3)
        }
        server.start()
        print("layad: http on http://127.0.0.1:\(httpPort)")

        // gRPC (Swift CLI ⇄ backend machine protocol)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let provider = LayaDecisionProvider(engine: engine)
        var grpcServer: Server?
        do {
            // (grpc-swift's server default max message size is 4 MB, which
            // matches the 1 MB wire cap with headroom.)
            let builder = Server.insecure(group: group)
                .withServiceProviders([provider])
            grpcServer = try await builder.bind(host: "127.0.0.1", port: Int(grpcPort))
                .get()
            print("layad: grpc on 127.0.0.1:\(grpcPort)")
        } catch {
            print("layad: grpc bind failed: \(error) (http only)")
        }

        // park forever (Python: serve_forever)
        while true {
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            catch { break }
        }
    }
}

/// The daemon's full route table (laya_http_mcp._asgi + laya_http bridge).
@available(macOS 27.0, *)
struct HTTPRouter: Sendable {
    let engine: Engine

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        if req.path == "/health" && req.method == "GET" {
            let stats = await (engine.chainOrder, engine.calls, engine.totalMs, engine.warm)
            return HTTPResponse.json(200, QuestionAPI.healthPayload(
                chains: stats.0, calls: stats.1, totalMs: stats.2, warm: stats.3))
        }
        if let resp = await QuestionAPI.handle(req, engine: engine) {
            return resp
        }
        // laya_http bridge surface (opencode-style harnesses)
        if req.method == "POST", req.path == "/decide" || req.path == "/guard" {
            return await bridge(req)
        }
        return HTTPResponse.json(404, JSONValue.obj("error", .string("not found")))
    }

    private func bridge(_ req: HTTPRequest) async -> HTTPResponse {
        guard let payload = JSONValue.parse(req.body) else {
            // Python: json.loads failure → 500 {"error": "JSONDecodeError: …"}
            return HTTPResponse.json(500, JSONValue.obj(
                "error", .string("JSONDecodeError: Expecting value")))
        }
        do {
            if req.path == "/decide" {
                guard let task = payload["task"]?.stringValue else {
                    return HTTPResponse.json(500, JSONValue.obj(
                        "error", .string("KeyError: 'task'")))
                }
                let out = try await engine.decideLegacy(
                    task: task, state: payload["state"] ?? .string(""),
                    options: payload["options"],
                    toolSlate: Self.toolSlate, skillSlate: Self.skillSlate)
                return HTTPResponse.json(200, out)
            } else {
                guard let cmd = payload["command"]?.stringValue else {
                    return HTTPResponse.json(500, JSONValue.obj(
                        "error", .string("KeyError: 'command'")))
            }
                // e.decide("guardrail", f"About to run: {cmd[:800]}") — then
                // the verdict rail over the raw engine document.
                let stateText = String("About to run: "
                    + cmd.prefix(800).replacingOccurrences(of: "\u{0}", with: ""))
                let out = try await engine.decideLegacy(
                    task: "guardrail", state: .string(stateText),
                    options: nil, toolSlate: Self.toolSlate, skillSlate: Self.skillSlate)
                let choice = out["choice"]?.stringValue ?? ""
                let acted = out["acted"]?.boolValue ?? false
                let verdict = choice == "block" ? "deny"
                    : (choice == "ask_user" || !acted) ? "confirm" : "allow"
                if case .object(var pairs) = out {
                    pairs.append((key: "verdict", value: .string(verdict)))
                    return HTTPResponse.json(200, .object(pairs))
                }
                return HTTPResponse.json(200, out)
            }
        } catch let e as LayaOps.OpsError {
            // Python: ValueError from question_for → 500 {"error": "ValueError: …"}
            return HTTPResponse.json(500, JSONValue.obj(
                "error", .string("ValueError: \(e.message)")))
        } catch {
            return HTTPResponse.json(500, JSONValue.obj(
                "error", .string("RuntimeError: \(String(describing: error).prefix(200))")))
        }
    }

    /// laya_http slates: LAYA_TOOL_SLATE / LAYA_SKILL_SLATE (JSON, default []).
    static let toolSlate: JSONValue = slateFromEnv("TOOL_SLATE")
    static let skillSlate: JSONValue = slateFromEnv("SKILL_SLATE")
    private static func slateFromEnv(_ key: String) -> JSONValue {
        guard let s = Naming.envAlias(key), let v = JSONValue.parse(Data(s.utf8)) else {
            return .array([])
        }
        return v
    }
}

/// gRPC provider: the same wire documents as HTTP, bytes round-trip
/// exactly (JSONValue.parse/serialize), refusals mirror the HTTP status.
@available(macOS 27.0, *)
final class LayaDecisionProvider: Laya_V1_LayaDecisionAsyncProvider, @unchecked Sendable {
    let engine: Engine
    init(engine: Engine) { self.engine = engine }

    private func authOK(_ context: GRPCAsyncServerCallContext) -> Bool {
        let expected = Naming.envAlias("TOKEN")
        guard let expected, !expected.isEmpty else { return true }
        for header in context.request.headers where header.name.lowercased() == "authorization" {
            let v = header.value
            if v.lowercased().hasPrefix("bearer ") {
                return v.dropFirst(7).trimmingCharacters(in: .whitespaces) == expected
            }
        }
        return false
    }

    func health(request: Laya_V1_Empty,
                context: GRPCAsyncServerCallContext) async throws -> Laya_V1_HealthReply {
        let stats = await (engine.chainOrder, engine.calls, engine.totalMs, engine.warm)
        let doc = QuestionAPI.healthPayload(chains: stats.0, calls: stats.1,
                                            totalMs: stats.2, warm: stats.3)
        return Laya_V1_HealthReply.with { $0.json = Data(JSONValue.serialize(doc).utf8) }
    }

    func models(request: Laya_V1_Empty,
                context: GRPCAsyncServerCallContext) async throws -> Laya_V1_ModelsReply {
        let chains = await engine.chainOrder
        let doc = JSONValue.obj(
            "object", .string("list"),
            "data", .array([JSONValue.obj(
                "id", .string(Naming.modelId(nil)), "object", .string("model"),
                "owned_by", .string("laya"),
                "chains", .array(chains.map { .string($0) }))]))
        return Laya_V1_ModelsReply.with { $0.json = Data(JSONValue.serialize(doc).utf8) }
    }

    func ask(request: Laya_V1_AskRequest,
             context: GRPCAsyncServerCallContext) async throws -> Laya_V1_AskReply {
        var reply = Laya_V1_AskReply()
        guard authOK(context) else {
            let body = JSONValue.obj("status", .string("invalid_request"),
                                     "error", .string("auth_failed"))
            reply.json = Data(JSONValue.serialize(body).utf8)
            reply.httpStatus = 401
            return reply
        }
        guard let payload = JSONValue.parse(Data(request.json)) else {
            let body = JSONValue.obj("status", .string("invalid_request"),
                                     "error", .string("malformed"))
            reply.json = Data(JSONValue.serialize(body).utf8)
            reply.httpStatus = 400
            return reply
        }
        do {
            let deadline = Date().addingTimeInterval(QuestionAPI.requestBudgetS())
            let body = try await QuestionAPI.answerRequest(payload, engine: engine,
                                                           deadline: deadline)
            reply.json = Data(JSONValue.serialize(body).utf8)
            reply.httpStatus = 200
        } catch let e as LayaAPI.ApiError {
            reply.json = Data(JSONValue.serialize(e.toResponse()).utf8)
            reply.httpStatus = Int32(e.httpStatus)
        } catch {
            let body = JSONValue.obj("status", .string("invalid_request"),
                                     "error", .string("overloaded"))
            reply.json = Data(JSONValue.serialize(body).utf8)
            reply.httpStatus = 529
        }
        return reply
    }

    func question(request: Laya_V1_EngineQuestion,
                  context: GRPCAsyncServerCallContext) async throws -> Laya_V1_EngineResultReply {
        var reply = Laya_V1_EngineResultReply()
        guard authOK(context) else {
            reply.json = Data(#"{"error":"auth_failed"}"#.utf8)
            return reply
        }
        guard let q = JSONValue.parse(Data(request.questionJson)),
              let state = JSONValue.parse(Data(request.stateJson)) else {
            reply.json = Data(#"{"error":"malformed"}"#.utf8)
            return reply
        }
        do {
            let wa = try await engine.question(name: request.name, q: q, state: state)
            reply.json = Data(JSONValue.serialize(wa.answer).utf8)
        } catch {
            reply.json = Data(#"{"error":"overloaded"}"#.utf8)
        }
        return reply
    }
}
