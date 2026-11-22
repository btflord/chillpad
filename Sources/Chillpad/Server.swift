import CryptoKit
import Foundation
import Network

struct PhoneInfo: Equatable {
    var device: String
    var rtt: Int?
    var onTime: Double
}

/// HTTP + WebSocket on one port, straight on top of Network.framework with Nagle off.
final class Server {
    let queue = DispatchQueue(label: "chillpad.net", qos: .userInteractive)
    private let input = Input()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let pairing: Pairing
    let juno = JunoBridge()
    private var voiceState = ""   // latest ["vs", …] for phones that connect later

    /// Called on the main queue.
    var onPhones: (([PhoneInfo]) -> Void)?
    var onActivity: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    init(pairing: Pairing) { self.pairing = pairing }

    /// Juno's availability and state go to every phone. Call on the main queue.
    func startVoice() {
        juno.onUpdate = { [weak self] msg in
            guard let self else { return }
            self.queue.async {
                if msg.hasPrefix("[\"vs\"") { self.voiceState = msg }
                for c in self.connections.values where c.session != nil { c.wsText(msg) }
            }
        }
        juno.start()
        let first = juno.snapshot()
        queue.async { self.voiceState = first }
    }

    func start(port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo   // ask Wi‑Fi for low-latency queueing on replies
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let err) = state {
                    let busy = "\(err)".contains("48") || "\(err)".lowercased().contains("in use")
                    let msg = busy ? "Port \(port) is already in use. Is another copy of Chillpad running?" : "Couldn't start the server: \(err.localizedDescription)"
                    DispatchQueue.main.async { self?.onFailure?(msg) }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onFailure?("Couldn't start the server: \(error.localizedDescription)")
        }
    }

    private func accept(_ c: NWConnection) {
        let conn = Connection(c, server: self)
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }

    fileprivate func remove(_ c: Connection) {
        guard connections.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        if c.session != nil { publish() }
    }

    /// Drop every paired phone (after the pairing code is reset).
    func disconnectAll() {
        queue.async { for c in Array(self.connections.values) where c.session != nil { c.close() } }
    }

    private var publishPending = false
    fileprivate func publish(throttled: Bool = false) {
        let send = { [self] in
            publishPending = false
            let phones = connections.values.compactMap { c in
                c.session.map { PhoneInfo(device: $0.device, rtt: $0.rtt, onTime: $0.clock.onTime) }
            }
            DispatchQueue.main.async { self.onPhones?(phones) }
        }
        if !throttled { return send() }
        if publishPending { return }
        publishPending = true
        queue.asyncAfter(deadline: .now() + 1, execute: send)
    }

    private var lastActivity = ("", 0.0)
    fileprivate func activity(_ label: String) {
        let now = nowMs()
        if lastActivity.0 == label, now - lastActivity.1 < 200 { return }
        lastActivity = (label, now)
        DispatchQueue.main.async { self.onActivity?(label) }
    }

    // MARK: Routing

    fileprivate func respond(to req: HTTPRequest, on c: Connection) {
        let tokenOK = pairing.matches(req.query["k"])
        switch req.path {
        case "/pad":
            guard tokenOK else { return c.http(403, "text/html; charset=utf-8", Web.file("denied.html")) }
            var html = String(decoding: Web.file("pad.html"), as: UTF8.self)
            html = html.replacingOccurrences(of: "{{TOKEN}}", with: pairing.token)
            c.http(200, "text/html; charset=utf-8", Data(html.utf8))
        case "/manifest.webmanifest" where tokenOK:
            let m: [String: Any] = [
                "name": "Chillpad", "short_name": "Chillpad", "display": "standalone", "orientation": "any",
                "start_url": "/pad?k=\(pairing.token)", "scope": "/",
                "background_color": "#0a0a0c", "theme_color": "#0a0a0c",
                "icons": [["src": "/icon.png", "sizes": "512x512", "type": "image/png"]],
            ]
            c.http(200, "application/manifest+json", (try? JSONSerialization.data(withJSONObject: m)) ?? Data())
        case "/icon.png":
            c.http(200, "image/png", Web.file("icon.png"), cache: "max-age=86400")
        case "/ws":
            guard tokenOK, let key = req.headers["sec-websocket-key"] else { return c.http(401, "text/plain", Data("unauthorized".utf8)) }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            c.raw("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n")
            let s = PhoneSession(input: input, queue: queue) { [weak c] text in c?.wsText(text) }
            s.onActivity = { [weak self] label in self?.activity(label) }
            s.onInfo = { [weak self] in self?.publish(throttled: true) }
            s.onVoice = { [weak self] action in DispatchQueue.main.async { self?.juno.send(action) } }
            c.session = s
            c.wsText("[\"hi\",{\"name\":\(Web.jsonString(pairing.computerName))}]")
            if !voiceState.isEmpty { c.wsText(voiceState) }
            DispatchQueue.main.async { self.juno.refreshAndPush() }   // Juno may have been installed since
            publish()
        default:
            c.http(404, "text/plain", Data("not found".utf8))
        }
    }
}

struct HTTPRequest {
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
}

enum Web {
    static let dir: URL = {
        if let d = Env.all["CHILL_WEB"] { return URL(fileURLWithPath: d) }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("web")
    }()
    static func file(_ name: String) -> Data { (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data() }
    static func jsonString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
}

/// One TCP connection: an HTTP request, optionally upgraded to a WebSocket.
final class Connection {
    private let conn: NWConnection
    private unowned let server: Server
    private var buf = [UInt8]()
    private var closed = false
    var session: PhoneSession?

    init(_ c: NWConnection, server: Server) { conn = c; self.server = server }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: server.queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                if self.session != nil { self.frames() } else { self.request() }
            }
            if done || error != nil { return self.close() }
            self.receive()
        }
    }

    func close() { conn.cancel(); finish() }

    private func finish() {
        guard !closed else { return }
        closed = true
        session?.close()
        server.remove(self)
    }

    // MARK: HTTP

    private func request() {
        guard let end = headerEnd() else {
            if buf.count > 16384 { close() }
            return
        }
        let head = String(decoding: buf[..<end], as: UTF8.self)
        buf.removeFirst(end + 4)
        var req = HTTPRequest()
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://x" + parts[1]) else {
            return http(400, "text/plain", Data("bad request".utf8))
        }
        req.path = comps.path
        for q in comps.queryItems ?? [] { req.query[q.name] = q.value ?? "" }
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            req.headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        server.respond(to: req, on: self)
        if session != nil, !buf.isEmpty { frames() }
    }

    private func headerEnd() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) where buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 { return i }
        return nil
    }

    func http(_ code: Int, _ type: String, _ body: Data, cache: String = "no-store") {
        let status = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found"][code] ?? "OK"
        var out = Data("HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: \(cache)\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func raw(_ s: String) { conn.send(content: Data(s.utf8), completion: .contentProcessed { _ in }) }

    // MARK: WebSocket (RFC 6455)

    private func frames() {
        var pos = 0
        while buf.count - pos >= 2 {
            let op = buf[pos] & 0x0f
            let masked = buf[pos + 1] & 0x80 != 0
            var len = Int(buf[pos + 1] & 0x7f)
            var off = pos + 2
            if len == 126 {
                guard buf.count - pos >= 4 else { break }
                len = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3]); off = pos + 4
            } else if len == 127 {
                guard buf.count - pos >= 10 else { break }
                len = 0
                for i in 2..<10 { len = len << 8 | Int(buf[pos + i]) }
                off = pos + 10
            }
            if len < 0 || len > 1 << 20 { return close() }
            let start = off + (masked ? 4 : 0)
            guard buf.count >= start + len else { break }
            if masked {
                for i in 0..<len { buf[start + i] ^= buf[off + (i & 3)] }
            }
            let payload = buf[start..<(start + len)]
            pos = start + len
            switch op {
            case 0x1: session?.text(String(decoding: payload, as: UTF8.self))
            case 0x2: session?.binary(payload)
            case 0x8: session?.flush(); return close()
            case 0x9: wsFrame(0x8a, Array(payload))
            default: break
            }
        }
        if pos > 0 { buf.removeFirst(pos) }
        session?.flush()
    }

    private func wsFrame(_ first: UInt8, _ payload: [UInt8]) {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 10)
        out.append(first)
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 255))
        } else {
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8((payload.count >> (8 * i)) & 255)) }
        }
        out.append(contentsOf: payload)
        conn.send(content: Data(out), completion: .contentProcessed { _ in })
    }

    func wsText(_ s: String) { if !closed { wsFrame(0x81, Array(s.utf8)) } }
}
