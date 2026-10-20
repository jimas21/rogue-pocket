import Foundation
import Network

/// The Rogue Dex's server, on the phone: http://127.0.0.1:8091. It serves the Dex page from DexStore and answers the
/// live endpoints from the running game, so the page works exactly as it does against the NAS (it calls
/// "http://<its own host>:8091/battle" and so on) with no network at all. Loopback only.
final class LocalDexServer {
    static let port: UInt16 = 8091
    static var pageURL: URL { URL(string: "http://127.0.0.1:\(port)/index.html")! }

    private let store: DexStore
    private let bridge: () -> LiveBridge?
    private let onStateChanged: () -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rogue-pocket.dex-server")

    init(store: DexStore, bridge: @escaping () -> LiveBridge?, onStateChanged: @escaping () -> Void) {
        self.store = store
        self.bridge = bridge
        self.onStateChanged = onStateChanged
    }

    /// Starts listening (again, after the app comes back from the background). Safe to call repeatedly. Main thread.
    func start() {
        if let listener {
            switch listener.state {
            case .ready, .setup, .waiting: return
            default: break
            }
        }
        listener?.cancel()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.listener = nil
                    self?.start()
                }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return conn.cancel() }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = Request(buf) {
                self.respond(conn, request)
            } else if done || error != nil || buf.count > 512 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data

        /// nil until the whole request (headers and Content-Length body) has arrived.
        init?(_ raw: Data) {
            guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: raw[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return nil }
            var length = 0
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].lowercased() == "content-length" {
                    length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = end.upperBound
            guard raw.count - bodyStart >= length else { return nil }
            method = String(parts[0])
            let target = URLComponents(string: String(parts[1]))
            path = target?.path ?? "/"
            var q: [String: String] = [:]
            for item in target?.queryItems ?? [] { q[item.name] = item.value ?? "" }
            query = q
            body = raw.subdata(in: bodyStart..<(bodyStart + length))
        }
    }

    private func respond(_ conn: NWConnection, _ req: Request) {
        switch (req.method, req.path) {
        case ("OPTIONS", _):
            send(conn, 204, Data(), type: nil)
        case ("GET", "/health"):
            send(conn, 200, Data(#"{"ok":true}"#.utf8))
        case ("GET", "/state"):
            send(conn, 200, store.stateData())
        case ("PUT", "/state"):
            let (code, body) = store.putState(req.body)
            send(conn, code, body)
            if code == 200 { DispatchQueue.main.async { self.onStateChanged() } }
        case ("GET", "/party"), ("GET", "/battle"), ("GET", "/run"), ("GET", "/bag"):
            DispatchQueue.main.async {
                let (code, body) = self.bridge()?.answer(path: req.path, query: req.query)
                    ?? (503, Data(#"{"error":"the live reader is not available"}"#.utf8))
                self.queue.async { self.send(conn, code, body) }
            }
        case ("GET", _):
            let path = req.path == "/" ? "index.html" : String(req.path.dropFirst())
            if let data = store.file(at: path) {
                send(conn, 200, data, type: Self.contentType(path), cache: true)
            } else {
                send(conn, 404, Data("not found".utf8), type: "text/plain")
            }
        default:
            send(conn, 404, Data(#"{"error":"unknown path"}"#.utf8))
        }
    }

    private func send(_ conn: NWConnection, _ code: Int, _ body: Data, type: String? = "application/json",
                      cache: Bool = false) {
        var head = "HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, PUT, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += cache ? "Cache-Control: no-cache\r\n" : "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
