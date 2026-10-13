import Foundation
import Network

/// One open request from the hook script. Answered once; reports when the other side hangs up.
final class HookConnection {
    private let conn: NWConnection
    private let lock = NSLock()
    private var finished = false
    var onClose: (@MainActor () -> Void)?

    init(_ c: NWConnection) { conn = c }

    func reply(_ text: String) { send("200 OK", text) }
    func reject(_ status: String) { send(status, "") }

    private func send(_ status: String, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let out = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + out, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    /// Detects the caller hanging up (the user answered in the terminal, or Claude stopped).
    func watchForClose() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, err in
            guard let self else { return }
            self.lock.lock(); let already = self.finished; self.lock.unlock()
            if already { return }
            if done || err != nil {
                self.lock.lock(); self.finished = true; self.lock.unlock()
                let cb = self.onClose
                Task { @MainActor in cb?() }
            } else {
                self.watchForClose()
            }
        }
    }
}

/// Listens on 127.0.0.1 only. Accepts POST /permission with the secret token.
final class HookServer {
    private let token: String
    private var listener: NWListener?
    var onRequest: (@MainActor ([String: Any], HookConnection) -> Void)?
    var onEvent: (@MainActor ([String: Any]) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    init(token: String) { self.token = token }

    func start(port: UInt16 = NotchConfig.port) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                let cb = self?.onFailure
                Task { @MainActor in cb?("Notch+ could not listen for Claude Code: \(e)") }
            }
        }
        l.start(queue: .global())
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: .global())
        let hc = HookConnection(c)
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buf.append(data) }
                if buf.count > 4 << 20 { hc.reject("413 Payload Too Large"); return }
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                    let lines = head.components(separatedBy: "\r\n")
                    let len = lines.first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                    let body = buf[r.upperBound...]
                    if body.count >= len {
                        self.dispatch(lines: lines, body: Data(body.prefix(len)), hc)
                        return
                    }
                }
                if done || err != nil { c.cancel(); return }
                read()
            }
        }
        read()
    }

    private func dispatch(lines: [String], body: Data, _ hc: HookConnection) {
        let isPermission = lines.first?.hasPrefix("POST /permission") == true
        let isEvent = lines.first?.hasPrefix("POST /event") == true
        guard isPermission || isEvent else { hc.reject("404 Not Found"); return }
        let auth = lines.first { $0.lowercased().hasPrefix("authorization:") }?
            .dropFirst(14).trimmingCharacters(in: .whitespaces) ?? ""
        guard Self.constantTimeEqual(auth, "Bearer " + token) else { hc.reject("401 Unauthorized"); return }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            hc.reject("400 Bad Request"); return
        }
        if isEvent {
            // Status events are answered at once; Claude Code never waits on them.
            hc.reply("{}")
            let cb = onEvent
            Task { @MainActor in cb?(json) }
            return
        }
        hc.watchForClose()
        let cb = onRequest
        Task { @MainActor in cb?(json, hc) }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
