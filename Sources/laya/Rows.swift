import ArgumentParser
import Foundation
import LayaCore

/// The §2 use-case rows — triage / mail / supervise. Python contract
/// (laya_cli.py cmd_triage/cmd_mail/cmd_supervise): stdin ONE JSON
/// object, the primitive answers through the engine duck, _emit the
/// body, exit 0. An engine that CANNOT build degrades to the daemon
/// (RemoteEngine twin = laya_remote.py: its errors land on the
/// use-cases' fail-open rails, exit 0 — unreachable ≠ failure). `ask`
/// keeps its own strict engine build (exit 3); these rows never exit 3
/// on a missing asset. (macOS < 27 has no CoreAI AND no RemoteEngine
/// type — there the rows emit engine_unavailable and exit 2.)
enum RowSupport {

    /// Box for the availability-gated Holder (an `Any` static would trip
    /// strict concurrency; the value is written exactly once at init).
    struct Opaque: @unchecked Sendable { let value: Any? }

    /// The Python _engine() singleton, lazy per process.
    @available(macOS 27.0, *)
    actor Holder {
        var engine: Engine?
        var failed = false

        /// nil ⇒ the local engine could not build; rows answer degraded
        /// through the RemoteEngine duck instead.
        func local() async -> (any Questioning)? {
            if let engine { return engine }
            guard !failed else { return nil }
            let (assets, source) = LayaCLI.Ask.resolvePaths()
            do {
                let e = try await Engine(Engine.Config(
                    assetDir: assets, sourceDir: source,
                    unit: Naming.envAlias("UNIT") ?? "gpu"))
                engine = e
                return e
            } catch {
                failed = true
                note("engine unavailable, answering degraded: "
                     + String(String(describing: error).prefix(200)))
                return nil
            }
        }
    }

    static let holder = Opaque(value: {
        if #available(macOS 27.0, *) { return Holder() }
        return nil
    }())

    /// The row body: run the primitive on whichever engine duck answers
    /// (local first; daemon RemoteEngine when the local build failed),
    /// emit, exit 0.
    @available(macOS 27.0, *)
    static func runRow(
        _ primitive: @escaping @Sendable (any Questioning) async -> JSONValue
    ) async -> Int32 {
        let engine: any Questioning
        if let holder = holder.value as? Holder, let local = await holder.local() {
            engine = local
        } else {
            engine = RemoteEngine()
        }
        emit(await primitive(engine))
        return 0
    }

    /// _read_stdin_json: ONE JSON object, empty stdin → {}, else exit 2.
    static func readStdinJSON() throws -> JSONValue {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        // U13: byte-level ASCII-whitespace trim, then ONE decode. The
        // old String(...).trimmingCharacters(in:) made a second full
        // copy of the buffer even when nothing needed trimming.
        // (JSON input is ASCII-framed by the parser; byte trim of
        // space/tabs/CR/LF ≡ str.strip() for the payloads in contract.)
        var lo = 0
        var hi = data.count
        let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        while lo < hi, ws.contains(data[data.startIndex + lo]) { lo += 1 }
        while hi > lo, ws.contains(data[data.startIndex + hi - 1]) { hi -= 1 }
        // String(data:encoding:) keeps the old strict semantics:
        // invalid UTF-8 -> nil -> "" -> {} (String(decoding:) would
        // silently U+FFFD-substitute and change the empty-stdin contract).
        let trimmed = lo < hi
            ? data.subdata(in: data.startIndex + lo..<data.startIndex + hi)
            : Data()
        let raw = String(data: trimmed, encoding: .utf8) ?? ""
        if raw.isEmpty { return .object([]) }
        guard let parsed = JSONValue.parse(raw) else {
            note("stdin is not JSON")
            emit(.obj("error", .string("malformed"),
                      "detail", .string("stdin is not JSON: cannot parse")))
            throw ExitCode(2)
        }
        guard parsed.objectPairs != nil else {
            note("stdin must be ONE JSON object")
            emit(.obj("error", .string("malformed"),
                      "detail", .string("stdin must be ONE JSON object")))
            throw ExitCode(2)
        }
        return parsed
    }

    /// _message_from: `message` (string or object) or the
    /// from/subject/body triple; neither → exit 2 invalid_request.
    static func messageFrom(_ obj: JSONValue) throws -> JSONValue {
        if let m = obj["message"] { return m }
        if ["from", "subject", "body"].contains(where: { obj[$0] != nil }) {
            return JSONValue.obj(
                "from", obj["from"] ?? .string(""),
                "subject", obj["subject"] ?? .string(""),
                "body", obj["body"] ?? .string(""))
        }
        note("missing required key")
        emit(.obj("error", .string("invalid_request"),
                  "detail", .string("missing required key: message|from|subject|body")))
        throw ExitCode(2)
    }

    /// Availability gate shared by the three rows: below macOS 27 there
    /// is no engine and no daemon duck — emit the §2 degraded body.
    static func availabilityGate() throws {
        guard #available(macOS 27.0, *) else {
            emit(.obj("error", .string("engine_unavailable"),
                      "detail", .string("macOS 27 required for CoreAI")))
            throw ExitCode(2)
        }
    }
}

struct TriageRow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "triage")
    func run() async throws {
        guard #available(macOS 27.0, *) else {
            emit(.obj("error", .string("engine_unavailable"),
                      "detail", .string("macOS 27 required for CoreAI")))
            throw ExitCode(2)
        }
        let msg = try RowSupport.messageFrom(RowSupport.readStdinJSON())
        let code = await rowRun(msg)
        if code != 0 { throw ExitCode(code) }
    }

    @available(macOS 27.0, *)
    private func rowRun(_ msg: JSONValue) async -> Int32 {
        await RowSupport.runRow { engine in
            await UseCases.triage(engine: engine, message: msg)
        }
    }
}

struct MailRow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mail")
    func run() async throws {
        guard #available(macOS 27.0, *) else {
            emit(.obj("error", .string("engine_unavailable"),
                      "detail", .string("macOS 27 required for CoreAI")))
            throw ExitCode(2)
        }
        let msg = try RowSupport.messageFrom(RowSupport.readStdinJSON())
        let code = await rowRun(msg)
        if code != 0 { throw ExitCode(code) }
    }

    @available(macOS 27.0, *)
    private func rowRun(_ msg: JSONValue) async -> Int32 {
        await RowSupport.runRow { engine in
            await UseCases.mail(engine: engine, message: msg)
        }
    }
}

struct SuperviseRow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "supervise")
    func run() async throws {
        guard #available(macOS 27.0, *) else {
            emit(.obj("error", .string("engine_unavailable"),
                      "detail", .string("macOS 27 required for CoreAI")))
            throw ExitCode(2)
        }
        let obj = try RowSupport.readStdinJSON()
        // facts dict, §2 supervise row keys — pre-filtered to the known
        // keys in SUPERVISE_FACT_KEYS order (Python dict literal
        // {k: obj[k] for k in KEYS if k in obj}).
        let factKeys = K.superviseFactKeys
        var pairs: [(key: String, value: JSONValue)] = []
        for k in factKeys {
            if let v = obj[k] { pairs.append((key: k, value: v)) }
        }
        let code = await rowRun(JSONValue.object(pairs))
        if code != 0 { throw ExitCode(code) }
    }

    @available(macOS 27.0, *)
    private func rowRun(_ facts: JSONValue) async -> Int32 {
        await RowSupport.runRow { engine in
            await UseCases.supervise(engine: engine, facts: facts)
        }
    }
}
