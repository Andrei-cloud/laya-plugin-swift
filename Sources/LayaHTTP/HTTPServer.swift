import Foundation
import LayaCore
import Network

/// Minimal HTTP/1.1 server on Network.framework, loopback-only — the Swift
/// mount of the exact Python wire contract (laya_api_http.py). No external
/// dependencies; responses carry the same headers the Python ASGI sends
/// (content-type, content-length, x-request-id). `connection: close` is a
/// transport behavior, not part of the documented contract.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [(String, String)]      // names lowercased
    public var body: Data

    public func header(_ name: String) -> String? {
        let want = name.lowercased()
        for h in headers where h.0 == want { return h.1 }
        return nil
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data
    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    /// Body bytes exactly as Python's `json.dumps(obj).encode("utf-8")`
    /// produces (default separators ", " / ": ", insertion key order) — the
    /// content-length the Python daemon would send must match byte-for-byte
    /// for strict-client parity tests.
    public static func json(_ status: Int, _ obj: JSONValue,
                            extraHeaders: [(String, String)] = []) -> HTTPResponse {
        let body = Data(JSONValue.serialize(obj).utf8)
        var headers: [(String, String)] = [
            ("content-type", "application/json"),
            ("content-length", String(body.count)),
        ]
        headers += extraHeaders
        return HTTPResponse(status: status, headers: headers, body: body)
    }
}

/// Client disconnected mid-request — abandon without response (LayaStopped).
public struct ClientDisconnected: Error {}

public enum HTTPServerError: Error {
    case invalidPort(UInt16)
}

public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "laya.http", attributes: .concurrent)
    private let handler: Handler

    public init(port: UInt16, handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        // Loopback-only bind (the daemon's job per the Python module docs).
        // The port lives INSIDE requiredLocalEndpoint — passing it again via
        // `on:` conflicts (NWListener throws EINVAL).
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw HTTPServerError.invalidPort(port)
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: p)
        listener = try NWListener(using: params)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.serve(conn)
        }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        Task {
            defer { conn.cancel() }
            do {
                let req = try await Self.readRequest(conn)
                let resp = await handler(req)
                try await Self.write(conn, resp)
            } catch {
                // ClientDisconnected or a read error: no response possible.
            }
        }
    }

    // MARK: - NWConnection async plumbing

    private static func receive(_ conn: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, isComplete, error in
                if error != nil { cont.resume(throwing: ClientDisconnected()); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: ClientDisconnected()); return }
                cont.resume(returning: Data())
            }
        }
    }

    private static func readRequest(_ conn: NWConnection) async throws -> HTTPRequest {
        var buf = Data()
        var sepRange: Range<Int>?
        // 1. head
        while sepRange == nil {
            let chunk = try await receive(conn, min: 1, max: 65536)
            if buf.isEmpty { buf = chunk } else { buf.append(chunk) }
            if sepRange == nil {
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    sepRange = r.startIndex - buf.startIndex ..< r.endIndex - buf.startIndex
                }
            }
            if buf.count > 8 << 20 { throw ClientDisconnected() }
        }
        let sep = sepRange!
        guard let head = String(data: buf.subdata(in: buf.startIndex..<(buf.startIndex + sep.lowerBound)),
                                encoding: .utf8) else {
            throw ClientDisconnected()
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        guard parts.count >= 2 else { throw ClientDisconnected() }
        var contentLength = 0
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<idx]).lowercased()
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }
        // 2. body
        var have = buf.count - (sep.upperBound)
        var body = Data()
        if have > 0 {
            body = Data(buf.suffix(from: buf.startIndex + sep.upperBound))
        }
        while body.count < contentLength {
            let chunk = try await receive(conn, min: 1, max: 65536)
            body.append(chunk)
            if body.count > (60_000 + 65_536) * 4 && contentLength > body.count {
                // far past any sane cap; the handler's cap check would fire
                // anyway — stop reading rather than buffer unbounded.
                throw ClientDisconnected()
            }
        }
        if body.count > contentLength { body = body.prefix(contentLength) }
        return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    private static func write(_ conn: NWConnection, _ resp: HTTPResponse) async throws {
        var head = "HTTP/1.1 \(resp.status) \(reason(resp.status))\r\n"
        for h in resp.headers { head += "\(h.0): \(h.1)\r\n" }
        head += "connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: out, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 402: return "Payment Required"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 504: return "Gateway Timeout"
        case 529: return "Too Many Requests"   // overload status (no IANA reason)
        default: return "Status"
        }
    }
}
