import Foundation
import Network
import CryptoKit
import Darwin
import CoreMedia

// Status frames are authenticated; transfer packets additionally use session-scoped AES-GCM.
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
    func hello() -> [String: Any] { ["type": "hello", "nonce": nonce, "role": role, "protocol": 2] }
    func acceptHello(_ frame: [String: Any]) -> Bool {
        guard peerNonce == nil, frame["type"] as? String == "hello", frame["protocol"] as? Int == 2,
              let n = frame["nonce"] as? String, UUID(uuidString: n) != nil,
              frame["role"] as? String == (role == "host" ? "camera" : "host") else { return false }
        peerNonce = n
        return true
    }
    private func bytes(sender: String, receiver: String, direction: String, sequence: Int, type: String, id: String, payload: String) -> Data {
        Data("cricket-p0-v2|\(sender)|\(receiver)|\(direction)|\(sequence)|\(type)|\(id)|\(payload)".utf8)
    }
    func signed(type: String, id: String, payload: String = "") -> [String: Any]? {
        guard let peerNonce else { return nil }
        sent += 1
        let mac = HMAC<SHA256>.authenticationCode(for: bytes(sender: nonce, receiver: peerNonce, direction: role, sequence: sent, type: type, id: id, payload: payload), using: key)
        return ["type": type, "id": id, "seq": sent, "mac": Data(mac).base64EncodedString(), "payload": payload]
    }
    func verify(_ frame: [String: Any]) -> Bool {
        guard let peerNonce, let seq = frame["seq"] as? Int, seq == received + 1,
              let type = frame["type"] as? String, ["auth", "ready", "ping", "pong", "status", "statusReply", "transfer"].contains(type),
              let id = frame["id"] as? String, UUID(uuidString: id) != nil,
              let encoded = frame["mac"] as? String, let mac = Data(base64Encoded: encoded), mac.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(mac,
                authenticating: bytes(sender: peerNonce, receiver: nonce, direction: role == "host" ? "camera" : "host", sequence: seq, type: type, id: id, payload: frame["payload"] as? String ?? ""), using: key) else { return false }
        received = seq
        return true
    }
    private func transferKey(direction: String) throws -> SymmetricKey {
        guard let peerNonce else { throw TransferError.invalid("No authenticated peer") }
        let host = role == "host" ? nonce : peerNonce, camera = role == "camera" ? nonce : peerNonce
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("\(host)|\(camera)".utf8),
            info: Data("cricket-p0-v2-aes-gcm-\(direction)".utf8), outputByteCount: 32)
    }
    func encrypt(_ packet: [String: Any], id: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: packet)
        let box = try AES.GCM.seal(data, using: transferKey(direction: role), authenticating: Data(id.utf8))
        guard let combined = box.combined else { throw TransferError.invalid("Encryption failed") }
        return combined.base64EncodedString()
    }
    func decrypt(_ payload: String, id: String) throws -> [String: Any] {
        guard payload.count <= 60000, let data = Data(base64Encoded: payload) else { throw TransferError.invalid("Invalid encrypted packet") }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: transferKey(direction: role == "host" ? "camera" : "host"), authenticating: Data(id.utf8))
        guard let packet = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw TransferError.invalid("Invalid transfer payload") }
        return packet
    }
}

final class LocalSession {
    private let clock: () -> Double
    private let transferDirectory: URL?
    init(now: @escaping () -> Double = { LocalSession.nowUs() }, directory: URL? = nil) { clock = now; transferDirectory = directory }
    private let queue = DispatchQueue(label: "cricket.local-session")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var authentication: SessionAuthentication?
    private var buffer = Data()
    private var timeout: DispatchWorkItem?
    private var pending: [String: (Double, DispatchWorkItem)] = [:]
    private var clockSamples = 0
    private var bestClock: (Double, Double, Double)? // peer minus local, half network RTT, local measurement time
    var onReview: ((Int64, @escaping (Error?) -> Void) -> Void)?
    var onReviewCancelled: (() -> Void)?
    var exportReview: ((@escaping (Result<(URL, [String: Any]), Error>) -> Void) -> Void)?
    var validateReceivedReview: ((URL, [String: Any]) throws -> Void)?
    private var preparingReview = false
    private var mediaInUse = false
    private var outgoingReview: URL?
    private var authenticated = false
    private var role = "host"
    private var secret = ""
    private var generation = UUID()
    private var handshake = "hello"
    private var snapshot: [String: Any] = ["state": "stopped", "detail": "No session", "role": "host", "addresses": [], "pingsReceived": 0, "repliesReceived": 0]
    var onChange: (([String: Any]) -> Void)?
    private lazy var transfer: SampleTransfer = {
        let engine = SampleTransfer(queue: queue, directory: transferDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("cricket-transfer-" + UUID().uuidString))
        engine.onSend = { [weak self] id, packet in
            guard let self, self.authenticated, let auth = self.authentication else { return }
            do {
                let payload = try auth.encrypt(packet, id: id)
                if let frame = auth.signed(type: "transfer", id: id, payload: payload) { self.send(frame) }
            } catch { self.failPeer(error.localizedDescription) }
        }
        engine.acceptOffer = { [weak self] media, id in
            guard let self, !self.mediaInUse else { throw TransferError.invalid("Close host playback/inspection before sending") }
            let review = self.snapshot["review"] as? [String: Any]
            if media == "recording" {
                guard review?["requestId"] as? String == id, ["requesting", "transferring"].contains(review?["state"] as? String ?? "") else { throw TransferError.invalid("Unexpected or stale recording review") }
            } else if ["requesting", "transferring"].contains(review?["state"] as? String ?? "") { throw TransferError.invalid("A recorded review is pending") }
        }
        engine.validateRecording = { [weak self] url, info in
            guard let self, let review = self.snapshot["review"] as? [String: Any],
                  let mapped = review["peerTapUs"] as? NSNumber, let endpoint = info["requestedHostUs"] as? NSNumber,
                  abs(mapped.doubleValue - endpoint.doubleValue) <= 1 else { throw TransferError.invalid("Recording endpoint does not match the requested tap") }
            guard let validate = self.validateReceivedReview else { throw TransferError.invalid("Host recording decoder unavailable") }
            try validate(url, info)
        }
        engine.onChange = { [weak self] state in
            guard let self else { return }
            self.snapshot["transfer"] = state
            if state["media"] as? String == "recording", state["state"] as? String == "ready",
               var review = self.snapshot["review"] as? [String: Any], review["requestId"] as? String == state["reviewId"] as? String {
                review["state"] = "ready"; review["detail"] = "Recording verified and decoded on host; ready to play"
                review["verifiedElapsedMs"] = (self.clock() - (review["tapUs"] as? Double ?? self.clock())) / 1000
                self.snapshot["review"] = review
                if let id = review["requestId"] as? String { self.pending.removeValue(forKey: id)?.1.cancel() }
            }
            if state["state"] as? String == "complete", let url = self.outgoingReview {
                try? FileManager.default.removeItem(at: url); self.outgoingReview = nil
            }
        }
        engine.onFailure = { [weak self] detail in self?.failPeer(detail) }
        return engine
    }()
    func sendSample(_ url: URL, slow: Bool, completion: @escaping (Error?) -> Void) {
        queue.async {
            guard self.role == "camera", self.authenticated, !self.preparingReview else { completion(TransferError.invalid("Connect camera to host first")); return }
            do { try self.transfer.begin(url, slow: slow); completion(nil) } catch { completion(error) }
        }
    }
    func completedSample(_ completion: @escaping (URL?) -> Void) { queue.async { completion(self.transfer.state["media"] as? String == "sample" && self.transfer.state["state"] as? String == "ready" ? self.transfer.completed : nil) } }
    func acquireSample(_ completion: @escaping (URL?) -> Void) { queue.async {
        guard !self.mediaInUse, !["requesting", "transferring"].contains((self.snapshot["review"] as? [String: Any])?["state"] as? String ?? ""),
              self.transfer.state["media"] as? String == "sample", self.transfer.state["state"] as? String == "ready", let url = self.transfer.completed else { completion(nil); return }
        self.mediaInUse = true; completion(url)
    } }
    func acquireReview(_ completion: @escaping (URL?, [String: Any]?) -> Void) { queue.async {
        guard !self.mediaInUse, self.snapshot["review"] as? [String: Any] != nil,
              (self.snapshot["review"] as? [String: Any])?["state"] as? String == "ready",
              self.transfer.state["state"] as? String == "ready",
              self.transfer.state["reviewId"] as? String == (self.snapshot["review"] as? [String: Any])?["requestId"] as? String, let url = self.transfer.completed, let info = self.transfer.recording else { completion(nil, nil); return }
        self.mediaInUse = true; completion(url, info)
    } }
    func releaseMedia() { queue.async { self.mediaInUse = false } }
    func reviewPlaybackStarted() { queue.async {
        guard var review = self.snapshot["review"] as? [String: Any], review["state"] as? String == "ready" else { return }
        if review["tapToPlayMs"] == nil { review["tapToPlayMs"] = (self.clock() - (review["tapUs"] as? Double ?? self.clock())) / 1000 }
        self.snapshot["review"] = review
    } }
    func cleanupTransfer(_ completion: @escaping (Error?) -> Void) {
        queue.async { do {
            guard !self.mediaInUse, !self.preparingReview, !["requesting", "transferring"].contains((self.snapshot["review"] as? [String: Any])?["state"] as? String ?? "") else { throw TransferError.invalid("Close playback/inspection and stop or finish the pending review first") }
            try self.transfer.cleanup(); self.snapshot.removeValue(forKey: "review"); completion(nil)
        } catch { completion(error) } }
    }

    private func publish(_ state: String, _ detail: String) {
        snapshot["state"] = state; snapshot["detail"] = detail; snapshot["role"] = role
        snapshot["authenticated"] = authenticated
        onChange?(snapshot)
    }
    func status(_ completion: @escaping ([String: Any]) -> Void) { queue.async { self.snapshot["transfer"] = self.transfer.state; completion(self.snapshot) } }
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
    private func signed(_ type: String, _ id: String = UUID().uuidString.lowercased(), payload: String = "") {
        if let frame = authentication?.signed(type: type, id: id, payload: payload) { send(frame) }
    }
    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, self.connection === conn else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline)
                guard line.count <= 65536, let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      line.count <= 2048 || (self.authenticated && frame["type"] as? String == "transfer") else {
                    self.failPeer("Invalid or oversized message"); return
                }
                self.buffer.removeSubrange(...newline)
                self.handle(frame)
                if self.connection !== conn { return }
            }
            if self.buffer.count > (self.authenticated ? 65536 : 2048) { self.failPeer("Oversized message"); return }
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
        case "transfer":
            do {
                guard let payload = frame["payload"] as? String else { throw TransferError.invalid("Missing encrypted payload") }
                transfer.receive(id: id, packet: try auth.decrypt(payload, id: id), isHost: role == "host")
            } catch { failPeer(error.localizedDescription) }
        case "ping", "status":
            snapshot["pingsReceived"] = (snapshot["pingsReceived"] as? Int ?? 0) + 1
            let receivedUs = self.clock()
            let data = (frame["payload"] as? String ?? "").data(using: .utf8) ?? Data()
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if type == "status", body?["kind"] as? String == "review" {
                guard role == "camera", let endpoint = body?["peerTapUs"] as? NSNumber, let onReview else { failPeer("Review receiver unavailable"); return }
                guard !preparingReview, !transfer.active else {
                    signed("statusReply", id, payload: Self.json(["kind": "review", "ok": false, "detail": "A review/transfer is already active"])); return
                }
                preparingReview = true
                let token = auth
                onReview(endpoint.int64Value) { error in self.queue.async {
                    guard self.authentication === token else { return }
                    func reply(_ error: Error?) {
                        self.preparingReview = false
                        self.signed("statusReply", id, payload: Self.json(["kind": "review", "ok": error == nil, "detail": error?.localizedDescription ?? "Extracted; encrypted recording transfer in progress", "peerTapUs": endpoint]))
                    }
                    if let error { reply(error); return }
                    guard let export = self.exportReview else { reply(TransferError.invalid("Recording export unavailable")); return }
                    export { result in self.queue.async {
                        switch result {
                        case .failure(let error): if self.authentication === token { reply(error) }
                        case .success(let (url, info)):
                            guard self.authentication === token else { try? FileManager.default.removeItem(at: url); return }
                            do { try self.transfer.begin(url, recording: info, reviewId: id); self.outgoingReview = url; reply(nil) }
                            catch { try? FileManager.default.removeItem(at: url); reply(error) }
                        }
                    } }
                } }
            } else if type == "status", body?["kind"] as? String == "clock" {
                signed("statusReply", id, payload: Self.json(["kind": "clock", "t2": receivedUs, "t3": self.clock()]))
            } else { signed(type == "ping" ? "pong" : "statusReply", id) }
            publish("connected", "Received authenticated \(type); replied")
        case "pong", "statusReply":
            guard let request = pending[id] else { failPeer("Unexpected response"); return }
            let t4 = self.clock()
            if let data = (frame["payload"] as? String)?.data(using: .utf8),
               let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if body["kind"] as? String == "clock", let t2 = body["t2"] as? NSNumber, let t3 = body["t3"] as? NSNumber {
                    let t1 = request.0 * 1_000_000
                    let network = t4 - t1 - (t3.doubleValue - t2.doubleValue)
                    guard network >= 0, t3.doubleValue >= t2.doubleValue else { failPeer("Invalid clock exchange"); return }
                    let offset = ((t2.doubleValue - t1) + (t3.doubleValue - t4)) / 2
                    clockSamples += 1
                    if bestClock == nil || network / 2 < bestClock!.1 { bestClock = (offset, network / 2, t4) }
                    if let bestClock { snapshot["clock"] = ["samples": clockSamples, "offsetUs": bestClock.0, "uncertaintyUs": bestClock.1, "measuredAtUs": bestClock.2] }
                } else if body["kind"] as? String == "review" {
                    var review = snapshot["review"] as? [String: Any] ?? [:]
                    for (key, value) in body { review[key] = value }
                    if review["state"] as? String != "ready" { review["state"] = body["ok"] as? Bool == true ? "transferring" : "failed" }
                    review["replyElapsedMs"] = (t4 - request.0 * 1_000_000) / 1000
                    snapshot["review"] = review
                }
            }
            if (snapshot["review"] as? [String: Any])?["requestId"] as? String != id ||
                (snapshot["review"] as? [String: Any])?["state"] as? String == "failed" {
                pending.removeValue(forKey: id)?.1.cancel()
            }
            snapshot["lastRoundTripMs"] = (self.clock() / 1_000_000 - request.0) * 1000
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
            self.pending[id] = (self.clock() / 1_000_000, timeout)
            self.queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            self.signed(status ? "status" : "ping", id, payload: status ? Self.json(["kind": "clock"]) : ""); completion(true)
        }
    }
    static func nowUs() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000 }
    private static func json(_ value: [String: Any]) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), encoding: .utf8) ?? "" }
    func measureClock() { queue.async {
        self.clockSamples = 0; self.bestClock = nil; self.snapshot.removeValue(forKey: "clock")
        let token = self.authentication
        for index in 0..<8 { self.queue.asyncAfter(deadline: .now() + Double(index) * 0.4) {
            guard self.authenticated, self.authentication === token else { return }
            self.ping(status: true) { _ in }
        } }
    } }
    func requestReview(delayMs: Int, done: @escaping (Error?) -> Void) {
        let tap = self.clock()
        queue.async {
            guard self.role == "host", self.authenticated, self.clockSamples >= 4, let best = self.bestClock,
                  tap - best.2 < 30_000_000, (0...5000).contains(delayMs), self.pending.isEmpty, !self.transfer.active, !self.mediaInUse else {
                done(TransferError.invalid("Measure clocks first; wait for replies, then review within 30 seconds")); return
            }
            let id = UUID().uuidString.lowercased(); let token = self.authentication
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.authentication === token, self.pending[id] != nil else { return }
                self.failPeer("Timed review expired; reconnect")
            }
            self.pending[id] = (tap / 1_000_000, timeout)
            self.queue.asyncAfter(deadline: .now() + 45, execute: timeout)
            self.snapshot["review"] = ["kind": "review", "requestId": id, "state": "requesting", "tapUs": tap, "peerTapUs": tap + best.0, "uncertaintyUs": best.1, "injectedDelayMs": delayMs]
            self.queue.asyncAfter(deadline: .now() + Double(delayMs) / 1000) {
                guard self.authentication === token, self.authenticated else { return }
                self.signed("status", id, payload: Self.json(["kind": "review", "peerTapUs": Int64((tap + best.0).rounded())]))
            }
            done(nil)
        }
    }
    private func failPeer(_ detail: String) {
        bestClock = nil; clockSamples = 0; snapshot.removeValue(forKey: "clock")
        if preparingReview { onReviewCancelled?() }; preparingReview = false
        if var review = snapshot["review"] as? [String: Any], ["requesting", "transferring"].contains(review["state"] as? String ?? "") {
            review["state"] = "failed"; review["detail"] = detail; snapshot["review"] = review
        }
        transfer.cancel(detail)
        if let outgoingReview { try? FileManager.default.removeItem(at: outgoingReview) }; outgoingReview = nil
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
