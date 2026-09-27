import ArgumentParser
import Foundation
import GRPC
import LayaCore
import LayaGRPC
import LayaHTTP
import NIOCore
import NIOPosix

/// laya — dual-named decision CLI (`laya` / `jev` via symlink), the
/// laya_cli.py contract: stdin is ONE JSON object (empty stdin = {}),
/// stdout is EXACTLY ONE JSON document, exit codes:
///   0 answered · 2 invalid input / refusal / engine error (ask row has
///   NO fail-open) · 3 engine could not build (missing asset).
///
/// Backends (--backend):
///   local — in-process Core AI Engine (this binary IS the inference)
///   http  — POST /v1/laya on the warm daemon (Python-identical wire,
///           RemoteEngine twin)
///   grpc  — laya.v1.LayaDecision/Ask on the daemon (Swift machine
///           protocol; envelope bytes identical)
@main
struct LayaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "laya",
        version: LayaVersion.string,
        subcommands: [Ask.self, Health.self, Models.self,
                      TriageRow.self, MailRow.self, SuperviseRow.self,
                      MCPCommand.self])
}

// MARK: ask

extension LayaCLI {
    struct Ask: AsyncParsableCommand {
        @Option(help: "local | http | grpc") var backend: String = "local"
        @Option(help: "http base url (default env LAYA_DECISIOND_URL or http://127.0.0.1:11270)") var url: String?
        @Option(help: "grpc host:port (default env LAYA_GRPC_ADDR or 127.0.0.1:11271)") var grpcAddr: String?

        func run() async throws {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let payload: JSONValue
            if data.isEmpty || String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                payload = .object([])
            } else if let p = JSONValue.parse(data) {
                payload = p
            } else {
                emit(.obj("error", .string("malformed"),
                          "detail", .string("stdin is not JSON")))
                note("stdin is not JSON")
                throw ExitCode(2)
            }
            guard #available(macOS 27.0, *) else {
                emit(.obj("error", .string("engine_unavailable"),
                          "detail", .string("macOS 27 required for CoreAI")))
                throw ExitCode(3)
            }
            let code: Int32
            switch backend {
            case "local": code = await runLocal(payload)
            case "http": code = await runHTTP(payload)
            case "grpc": code = await runGRPC(payload)
            default:
                emit(.obj("error", .string("invalid_request"),
                          "detail", .string("unknown backend \(backend)")))
                throw ExitCode(2)
            }
            if code != 0 { throw ExitCode(code) }
        }

        /// engine.py default: sidecars derive from the model root; LAYA_SOURCE
        /// layout keeps the tokenizer at <models>/source — try configs first.
        ///
        /// LAYA_ASSETS convention (engine.py:7): a DIRECTORY containing
        /// laya-combined-f16.aimodel/ + combined_provenance.json. Accept
        /// BOTH spellings — a directory expands to the bundle inside it
        /// (Engine then reads provenance at <dir>/combined_provenance.json
        /// via its ../ resolution); a direct bundle path works as before.
        /// Getting this wrong silently degrades the local engine to the
        /// RemoteEngine rail — every row then answers daemon-sourced and
        /// looks healthy while the in-process inference never loaded
        /// (found by the rows differential, 2026-09-27).
        static func resolvePaths() -> (assets: String, source: String) {
            // One root identifies the installation; the sidecar dir is
            // derived from it (LayaPaths: env -> daemon.json ->
            // ~/.laya/model, HF layout). Kept as (assets, source) for
            // Engine.Config's naming.
            let r = LayaPaths.resolve()
            return (r.bundle, r.sidecar)
        }

        // MARK: local (in-process Core AI)

        @available(macOS 27.0, *)
        func runLocal(_ payload: JSONValue) async -> Int32 {
            let (assets, source) = Self.resolvePaths()
            let engine: Engine
            do {
                engine = try await Engine(Engine.Config(
                    assetDir: assets, sourceDir: source,
                    unit: Naming.envAlias("UNIT") ?? "gpu"))
            } catch {
                emit(.obj("error", .string("engine_unavailable"),
                          "detail", .string(String(String(describing: error).prefix(300)))))
                note("engine build failed")
                return 3
            }
            do {
                let body = try await QuestionAPI.answerRequest(payload, engine: engine)
                emit(body)
                return 0
            } catch let e as LayaAPI.ApiError {
                emit(.obj("error", .string(e.code),
                          "detail", .string(String((e.detail ?? "").prefix(300)))))
                note("refused: \(e.code)")
                return 2
            } catch let e as LayaOps.OpsError {
                emit(.obj("error", .string("invalid_response"),
                          "detail", .string(String(e.message.prefix(300)))))
                note("ops: \(e.message)")
                return 2
            } catch {
                emit(.obj("error", .string("overloaded"),
                          "detail", .string(String(String(describing: error).prefix(300)))))
                note("engine error")
                return 2
            }
        }

        // MARK: http backend (RemoteEngine twin — exact Python wire)

        func runHTTP(_ payload: JSONValue) async -> Int32 {
            var base = url ?? Naming.envAlias("DECISIOND_URL")
                ?? "http://127.0.0.1:11270"
            if base.hasSuffix("/") { base = String(base.dropLast()) }
            var request = URLRequest(url: URL(string: base + "/v1/laya")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if let token = Naming.envAlias("TOKEN"), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            }
            request.httpBody = Data(JSONValue.serialize(payload).utf8)
            request.timeoutInterval = 60
            do {
                let (d, r) = try await URLSession.shared.data(for: request)
                guard let http = r as? HTTPURLResponse else {
                    emit(.obj("error", .string("network"),
                              "detail", .string("non-HTTP response")))
                    return 2
                }
                guard let body = JSONValue.parse(d) else {
                    emit(.obj("error", .string("malformed"), .string("daemon non-JSON")))
                    note("daemon returned non-JSON")
                    return 2
                }
                if http.statusCode == 200 { emit(body); return 0 }
                // refusal body is {status, error} — surface the code verbatim
                let code = body["error"]?.stringValue ?? "http_\(http.statusCode)"
                emit(.obj("error", .string(code)))
                note("daemon refused: \(code) (http \(http.statusCode))")
                return 2
            } catch {
                emit(.obj("error", .string("network"),
                          "detail", .string(String(error.localizedDescription.prefix(300)))))
                note("daemon unreachable")
                return 2
            }
        }

        // MARK: grpc backend

        func runGRPC(_ payload: JSONValue) async -> Int32 {
            let target = grpcAddr ?? Naming.envAlias("GRPC_ADDR") ?? "127.0.0.1:11271"
            let parts = target.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]) else {
                emit(.obj("error", .string("invalid_request"),
                          "detail", .string("bad --grpc-addr target")))
                return 2
            }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { Task { try? await group.shutdownGracefully() } }
            do {
                let channel = try GRPCChannelPool.with(
                    target: .host(String(parts[0]), port: port),
                    transportSecurity: .plaintext,
                    eventLoopGroup: group)
                let client = Laya_V1_LayaDecisionAsyncClient(channel: channel)
                var opts = CallOptions()
                opts.timeLimit = .timeout(.seconds(60))
                let call = client.makeAskCall(Laya_V1_AskRequest.with {
                    $0.json = Data(JSONValue.serialize(payload).utf8)
                }, callOptions: opts)
                let reply = try await call.response
                guard let body = JSONValue.parse(Data(reply.json)) else {
                    emit(.obj("error", .string("malformed"), .string("daemon non-JSON")))
                    return 2
                }
                if reply.httpStatus == 200 { emit(body); return 0 }
                let code = body["error"]?.stringValue ?? "http_\(reply.httpStatus)"
                emit(.obj("error", .string(code)))
                note("daemon refused: \(code) (grpc \(reply.httpStatus))")
                return 2
            } catch {
                emit(.obj("error", .string("network"),
                          "detail", .string("daemon unreachable (grpc)")))
                note("grpc call failed")
                return 2
            }
        }
    }
}

// MARK: health / models

extension LayaCLI {
    struct Health: AsyncParsableCommand {
        @Flag var grpc = false
        @Option var url: String?

        func run() async throws {
            if grpc {
                let target = url ?? Naming.envAlias("GRPC_ADDR") ?? "127.0.0.1:11271"
                let parts = target.split(separator: ":")
                guard parts.count == 2, let port = Int(parts[1]) else { return }
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                defer { Task { try? await group.shutdownGracefully() } }
                let channel = try GRPCChannelPool.with(
                    target: .host(String(parts[0]), port: port),
                    transportSecurity: .plaintext, eventLoopGroup: group)
                let client = Laya_V1_LayaDecisionAsyncClient(channel: channel)
                let call = client.makeHealthCall(Laya_V1_Empty(), callOptions: nil)
                if let reply = try? await call.response,
                   let body = JSONValue.parse(Data(reply.json)) {
                    emit(body)
                }
                return
            }
            let base = url ?? Naming.envAlias("DECISIOND_URL") ?? "http://127.0.0.1:11270"
            var request = URLRequest(url: URL(string: base + "/health")!)
            request.httpMethod = "GET"
            if let (d, _) = try? await URLSession.shared.data(for: request),
               let body = JSONValue.parse(d) {
                emit(body)
            }
        }
    }

    struct Models: AsyncParsableCommand {
        @Option var url: String?

        func run() async throws {
            let base = url ?? Naming.envAlias("DECISIOND_URL") ?? "http://127.0.0.1:11270"
            var request = URLRequest(url: URL(string: base + "/v1/models")!)
            request.httpMethod = "GET"
            if let token = Naming.envAlias("TOKEN"), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            }
            if let (d, _) = try? await URLSession.shared.data(for: request),
               let body = JSONValue.parse(d) {
                emit(body)
            }
        }
    }
}

/// stdout: EXACTLY ONE JSON document (json.dumps equivalent).
func emit(_ v: JSONValue) {
    FileHandle.standardOutput.write(Data((JSONValue.serialize(v) + "\n").utf8))
}

/// failure notes go to stderr, never stdout.
func note(_ s: String) {
    FileHandle.standardError.write(Data("laya: \(s)\n".utf8))
}
