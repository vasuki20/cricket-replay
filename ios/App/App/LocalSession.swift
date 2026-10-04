import Foundation
import Network
import CryptoKit
import Darwin

// Status-only feasibility transport. Authenticated, NOT encrypted; never send video here.
final class SessionAuthentication {
    let nonce: String
    private let key: SymmetricKey
    private(set) var peerNonce: String?
    private var sent = 0
    private var received = 0
    private let role: String

    init(secret: String, role: String) {
        self.role = role
        key = SymmetricKey(data: Data(secret.utf8))
        nonce = UUID().uuidString.lowercased()
    }
    func hello() -> [String: Any] { ["type": "hello", "nonce": nonce, "role": role] }
    func acceptHello(_ frame: [String: Any]) -> Bool {
        guard peerNonce == nil, frame["type"] as? String == "hello",
              let n = frame["nonce"] as? String, UUID(uuidString: n) != nil,
              frame["role"] as? String == (role == "host" ? "camera" : "host") else { return false }
        peerNonce = n
        return true
    }
    private func bytes(sender: String, receiver: String, direction: String, sequence: Int, type: String, id: String) -> Data {
        Data("cricket-p0-v1|\(sender)|\(receiver)|\(direction)|\(sequence)|\(type)|\(id)".utf8)
    }
    func signed(type: String, id: String) -> [String: Any]? {
        guard let peerNonce else { return nil }
        sent += 1
        let mac = HMAC<SHA256>.authenticationCode(for: bytes(sender: nonce, receiver: peerNonce, direction: role, sequence: sent, type: type, id: id), using: key)
        return ["type": type, "id": id, "seq": sent, "mac": Data(mac).base64EncodedString()]
    }
    func verify(_ frame: [String: Any]) -> Bool {
        guard let peerNonce, let seq = frame["seq"] as? Int, seq == received + 1,
              let type = frame["type"] as? String, ["auth", "ready", "ping", "pong", "status", "statusReply"].contains(type),
              let id = frame["id"] as? String, UUID(uuidString: id) != nil,
              let encoded = frame["mac"] as? String, let mac = Data(base64Encoded: encoded), mac.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(mac,
                authenticating: bytes(sender: peerNonce, receiver: nonce, direction: role == "host" ? "camera" : "host", sequence: seq, type: type, id: id), using: key) else { return false }
        received = seq
        return true
    }
}

final class LocalSession {
    private let queue = DispatchQueue(label: "cricket.local-session")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var authentication: SessionAuthentication?
    private var buffer = Data()
    private var timeout: DispatchWorkItem?
    private var pending: [String: (Double, DispatchWorkItem)] = [:]
    private var authenticated = false
    private var role = "host"
    private var secret = ""
    private var generation = UUID()
    private var handshake = "hello"
    private var snapshot: [String: Any] = ["state": "stopped", "detail": "No session", "role": "host", "addresses": [], "pingsReceived": 0, "repliesReceived": 0]
    var onChange: (([String: Any]) -> Void)?

    private func publish(_ state: String, _ detail: String) {
        snapshot["state"] = state; snapshot["detail"] = detail; snapshot["role"] = role
        snapshot["authenticated"] = authenticated
        onChange?(snapshot)
    }
    func status(_ completion: @escaping ([String: Any]) -> Void) { queue.async { completion(self.snapshot) } }
    static func newSecret() -> String {
        let key = SymmetricKey(size: .bits128)
        return key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }
    static func validSecret(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    func startHost(secret: String, port: UInt16, completion: @escaping (Error?) -> Void) {
        queue.async {
            self.reset(); self.role = "host"; self.secret = secret
            self.snapshot["addresses"] = Self.addresses(); self.snapshot["port"] = Int(port)
            do {
                let params = NWParameters.tcp
                params.prohibitedInterfaceTypes = [.cellular]
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.publish("listening", "Waiting for camera; keep this app foreground")
                    case .failed(let error): self.reset(); self.publish("failed", error.localizedDescription)
                    case .waiting(let error): self.publish("waiting", error.localizedDescription)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.connection == nil else { connection.cancel(); return }
                    self.attach(connection)
                }
                listener.start(queue: self.queue)
                self.publish("starting", "Starting listener"); completion(nil)
            } catch { self.publish("failed", error.localizedDescription); completion(error) }
        }
    }
    func connect(address: String, secret: String, port: UInt16) {
        queue.async {
            self.reset(); self.role = "camera"; self.secret = secret
            self.snapshot["port"] = Int(port)
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = [.cellular]
            self.attach(NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: params))
        }
    }
    private func attach(_ conn: NWConnection) {
        connection = conn; buffer.removeAll(); authenticated = false; handshake = "hello"
        authentication = SessionAuthentication(secret: secret, role: role)
        let token = generation
        let timer = DispatchWorkItem { [weak self, weak conn] in
            guard let self, let conn, self.connection === conn else { return }
            self.failPeer("Connection/authentication timed out; check address, network permission and secret")
        }
        timeout = timer; queue.asyncAfter(deadline: .now() + 20, execute: timer)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, self.connection === conn, self.generation == token else { return }
            switch state {
            case .ready:
                self.publish("authenticating", "Checking session secret")
                self.send(self.authentication!.hello()); self.receive(conn)
            case .waiting(let error): self.publish("waiting", "\(error.localizedDescription); check Local Network access in Settings")
            case .failed(let error): self.failPeer(error.localizedDescription)
            default: break
            }
        }
        publish("connecting", "Connecting over local network")
        conn.start(queue: queue)
    }
    private func send(_ frame: [String: Any]) {
        guard let conn = connection, let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        conn.send(content: data + Data([10]), completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, let conn, self.connection === conn else { return }
            if let error { self.failPeer(error.localizedDescription) }
        })
    }
    private func signed(_ type: String, _ id: String = UUID().uuidString.lowercased()) {
        if let frame = authentication?.signed(type: type, id: id) { send(frame) }
    }
    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, self.connection === conn else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline)
                guard line.count <= 2048, let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    self.failPeer("Invalid or oversized message"); return
                }
                self.buffer.removeSubrange(...newline)
                self.handle(frame)
                if self.connection !== conn { return }
            }
            if self.buffer.count > 2048 { self.failPeer("Oversized message"); return }
            if complete || error != nil { self.failPeer(error?.localizedDescription ?? "Peer disconnected"); return }
            self.receive(conn)
        }
    }
    private func handle(_ frame: [String: Any]) {
        guard let auth = authentication else { return }
        if handshake == "hello" {
            guard auth.acceptHello(frame) else { failPeer("Invalid handshake"); return }
            handshake = "auth"; signed("auth"); return
        }
        guard auth.verify(frame), let type = frame["type"] as? String, let id = frame["id"] as? String else {
            failPeer("Authentication rejected: wrong secret, replay or altered message"); return
        }
        if handshake == "auth" {
            guard type == "auth" else { failPeer("Expected authentication proof"); return }
            handshake = "ready"; signed("ready"); return
        }
        if handshake == "ready" {
            guard type == "ready" else { failPeer("Expected ready confirmation"); return }
            handshake = "complete"; authenticated = true; timeout?.cancel(); timeout = nil
            if role == "camera" { secret = "" }
            publish("connected", "Authenticated peer; status messages are unencrypted"); return
        }
        guard authenticated else { failPeer("Peer not authenticated"); return }
        switch type {
        case "ping", "status":
            snapshot["pingsReceived"] = (snapshot["pingsReceived"] as? Int ?? 0) + 1
            signed(type == "ping" ? "pong" : "statusReply", id)
            publish("connected", "Received authenticated \(type); replied")
        case "pong", "statusReply":
            guard let request = pending.removeValue(forKey: id) else { failPeer("Unexpected response"); return }
            request.1.cancel()
            snapshot["lastRoundTripMs"] = (ProcessInfo.processInfo.systemUptime - request.0) * 1000
            snapshot["repliesReceived"] = (snapshot["repliesReceived"] as? Int ?? 0) + 1
            publish("connected", "Received authenticated \(type)")
        default: failPeer("Unexpected handshake message")
        }
    }
    func ping(status: Bool, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.authenticated, self.pending.count < 4 else { completion(false); return }
            let id = UUID().uuidString.lowercased()
            let token = self.generation
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token, self.pending[id] != nil else { return }
                self.failPeer("Peer response timed out; reconnect")
            }
            self.pending[id] = (ProcessInfo.processInfo.systemUptime, timeout)
            self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            self.signed(status ? "status" : "ping", id); completion(true)
        }
    }
    private func failPeer(_ detail: String) {
        timeout?.cancel(); timeout = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        authentication = nil; authenticated = false; buffer.removeAll()
        pending.values.forEach { $0.1.cancel() }; pending.removeAll()
        // Host keeps its listener/secret for another attempt; stop clears everything.
        publish(listener == nil ? "failed" : "listening", detail)
    }
    private func reset() {
        generation = UUID(); listener?.cancel(); listener = nil
        failPeer("Stopped"); secret = ""
        snapshot = ["state": "stopped", "detail": "No session", "role": role, "authenticated": false, "addresses": [], "pingsReceived": 0, "repliesReceived": 0]
    }
    func stop(reason: String = "Stopped") { queue.async { self.reset(); self.publish("stopped", reason) } }
    static func addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var results: [String] = []
        var pointer = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                results.append("\(name): \(String(cString: host))")
            }
        }
        return results.sorted()
    }
}
