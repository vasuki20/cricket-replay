import Foundation

// Run the real Network/CryptoKit implementation on macOS loopback; not phone evidence.
@main
struct ConnectivityTests {
    static func require(_ condition: @autoclosure () -> Bool, _ description: String) {
        if !condition() { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }
    static func snapshot(_ session: LocalSession) -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var value: [String: Any] = [:]
        session.status { value = $0; sem.signal() }
        require(sem.wait(timeout: .now() + 2) == .success, "status responds")
        return value
    }
    static func wait(_ description: String, seconds: Double = 5, _ condition: () -> Bool) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        require(false, description)
    }
    static func main() {
        let secret = LocalSession.newSecret()
        let pairing = PairingCode(kind: "cricket-replay-pairing", version: 1, address: "192.168.1.10", port: 8765, secret: secret)
        let payload = String(data: try! JSONEncoder().encode(pairing), encoding: .utf8)!
        require(PairingCode.decode(payload)?.secret == secret, "QR payload round trip")
        require(PairingCode.decode("https://example.com") == nil, "reject unrelated QR")
        require(PairingCode.decode(payload.replacingOccurrences(of: "192.168.1.10", with: "8.8.8.8")) == nil, "reject public endpoint")
        require(PairingCode.decode(payload.replacingOccurrences(of: "8765", with: "70000")) == nil, "reject invalid port")
        require(PairingCode.decode(payload.replacingOccurrences(of: secret, with: "short")) == nil, "reject invalid secret")
        require(!PairingCode(kind: pairing.kind, version: 2, address: pairing.address, port: pairing.port, secret: secret).valid, "reject unknown QR version")
        require(!PairingCode.validAddress("192.168.1.10.extra"), "reject malformed IPv4")
        require(!PairingCode.validAddress("010.0.0.1"), "reject ambiguous leading-zero IPv4")
        require(LocalSession.validSecret(secret), "generated secret format")
        require(!LocalSession.validSecret("short"), "reject short secret")
        let hostAuth = SessionAuthentication(secret: secret, role: "host")
        let cameraAuth = SessionAuthentication(secret: secret, role: "camera")
        require(hostAuth.acceptHello(cameraAuth.hello()), "host hello")
        require(cameraAuth.acceptHello(hostAuth.hello()), "camera hello")
        require(!hostAuth.acceptHello(cameraAuth.hello()), "reject repeated hello")
        let proof = hostAuth.signed(type: "auth", id: UUID().uuidString)!
        require(cameraAuth.verify(proof), "valid proof")
        require(!cameraAuth.verify(proof), "reject replay")
        var tampered = hostAuth.signed(type: "ping", id: UUID().uuidString)!
        tampered["type"] = "status"
        require(!cameraAuth.verify(tampered), "reject altered type")
        let wrong = SessionAuthentication(secret: LocalSession.newSecret(), role: "camera")
        let wrongHost = SessionAuthentication(secret: secret, role: "host")
        require(wrong.acceptHello(wrongHost.hello()), "wrong key hello")
        require(wrongHost.acceptHello(wrong.hello()), "wrong key host hello")
        require(!wrongHost.verify(wrong.signed(type: "auth", id: UUID().uuidString)!), "reject wrong secret")
        let newCamera = SessionAuthentication(secret: secret, role: "camera")
        require(newCamera.acceptHello(hostAuth.hello()), "fresh connection hello")
        require(!newCamera.verify(proof), "reject proof replay on new connection")
        require(!hostAuth.verify(proof), "reject reflection")

        let host = LocalSession(), camera = LocalSession()
        let port = UInt16.random(in: 20000...40000)
        let started = DispatchSemaphore(value: 0)
        host.startHost(secret: secret, port: port) { error in
            require(error == nil, "host starts"); started.signal()
        }
        require(started.wait(timeout: .now() + 2) == .success, "start callback")
        wait("listener ready") { snapshot(host)["state"] as? String == "listening" }
        camera.connect(address: "127.0.0.1", secret: secret, port: port)
        wait("mutual authentication") { snapshot(host)["authenticated"] as? Bool == true && snapshot(camera)["authenticated"] as? Bool == true }
        host.ping(status: false) { require($0, "host ping sent") }
        camera.ping(status: true) { require($0, "camera status sent") }
        wait("bidirectional replies") { snapshot(host)["repliesReceived"] as? Int == 1 && snapshot(camera)["repliesReceived"] as? Int == 1 }
        require(snapshot(host)["lastRoundTripMs"] as? Double != nil, "round trip measured")
        camera.stop()
        wait("host allows reconnect") { snapshot(host)["state"] as? String == "listening" && snapshot(host)["authenticated"] as? Bool == false }
        camera.connect(address: "127.0.0.1", secret: secret, port: port)
        wait("same-secret reconnect") { snapshot(camera)["authenticated"] as? Bool == true }
        camera.stop()
        wait("host disconnected") { snapshot(host)["authenticated"] as? Bool == false }
        camera.connect(address: "127.0.0.1", secret: LocalSession.newSecret(), port: port)
        wait("wrong secret rejected on wire") { snapshot(camera)["state"] as? String == "failed" }
        require(snapshot(host)["authenticated"] as? Bool == false, "wrong secret never authenticates")
        host.stop(reason: "Background simulation")
        wait("stop clears listener and authentication") { snapshot(host)["state"] as? String == "stopped" && snapshot(host)["authenticated"] as? Bool == false }
        print("PASS: authentication, replay/tamper/reflection rejection, loopback bidirectional ping/status, reconnect, wrong-secret rejection and stop")
    }
}
