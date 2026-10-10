import Foundation
import AVFoundation

// Real native encrypted loopback + generated H.264 decoding. Never physical phone evidence.
@main
struct ReviewFlowTests {
    static func require(_ condition: @autoclosure () -> Bool, _ detail: String) {
        if !condition() { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    static func snapshot(_ session: LocalSession) -> [String: Any] {
        let done = DispatchSemaphore(value: 0); var result: [String: Any] = [:]
        session.status { result = $0; done.signal() }
        require(done.wait(timeout: .now() + 3) == .success, "status callback"); return result
    }
    static func wait(_ detail: String, seconds: Double = 15, _ check: () -> Bool) {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if check() { return }; Thread.sleep(forTimeInterval: 0.02)
        }
        require(false, detail)
    }
    static func main() throws {
        let generated = DispatchSemaphore(value: 0); var fixture: Result<URL, Error>?
        SampleVideo.generate { fixture = $0; generated.signal() }
        require(generated.wait(timeout: .now() + 80) == .success, "silent fixture generation")
        let source = try fixture!.get(); defer { try? FileManager.default.removeItem(at: source) }
        let firstFrame = try RecordingClip.inspect(source, index: 0)
        let lastFrame = try RecordingClip.inspect(source, index: firstFrame.count - 1)
        let gapDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("review-gap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: gapDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gapDirectory) }
        let beforeGap = RecordingSegment(url: source, firstUs: 0); beforeGap.lastUs = lastFrame.timeUs; beforeGap.finalizing = false
        let afterGap = RecordingSegment(url: source, firstUs: 40_000_000); afterGap.lastUs = 40_000_000 + lastFrame.timeUs; afterGap.finalizing = false
        let gapOutput = gapDirectory.appendingPathComponent("gap.mp4")
        do { _ = try RecordingClip.extract(segments: [beforeGap, afterGap], endUs: 45_000_000, reviewSeconds: 30, output: gapOutput); require(false, "missing internal stretch accepted") }
        catch { require(!FileManager.default.fileExists(atPath: gapOutput.path), "gapped partial output removed") }
        let host = LocalSession(), camera = LocalSession(now: { LocalSession.nowUs() + 5_000_000 })
        host.validateReceivedReview = RecordingClip.validateReview
        let secret = LocalSession.newSecret(); let port = UInt16.random(in: 20000...40000)
        let started = DispatchSemaphore(value: 0)
        host.startHost(secret: secret, port: port) { require($0 == nil, "host start"); started.signal() }
        require(started.wait(timeout: .now() + 3) == .success, "start callback")
        defer { host.stop(); camera.stop() }
        wait("host listening") { snapshot(host)["state"] as? String == "listening" }
        camera.connect(address: "127.0.0.1", secret: secret, port: port)
        func connected() { wait("mutual authentication") { snapshot(host)["authenticated"] as? Bool == true && snapshot(camera)["authenticated"] as? Bool == true } }
        connected()
        var transferSource = source, transferFirst = firstFrame, transferLast = lastFrame
        var retention = 120, reviewSeconds = 20
        var endpoint: Int64 = 0; var unavailable = false; var corrupt = false; var wrongTap = false; var holdExport = false
        var heldExport: ((Result<(URL, [String: Any]), Error>) -> Void)?
        camera.onReview = { tap, done in
            endpoint = tap
            done(unavailable ? TransferError.invalid("Requested window is not available") : nil)
        }
        func export(_ done: (Result<(URL, [String: Any]), Error>) -> Void) {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-review-fixture-" + UUID().uuidString + ".mp4")
            try! FileManager.default.copyItem(at: transferSource, to: copy)
            if corrupt { try! Data([1, 2, 3]).write(to: copy) } // valid hash, invalid media
            let fixtureEndpoint = endpoint + (wrongTap ? 1_000_000 : 0)
            let origin = fixtureEndpoint - transferLast.timeUs - 33_333
            done(.success((copy, ["sourceFirstUs": origin, "sourceLastUs": origin + transferLast.timeUs,
                "requestedHostUs": fixtureEndpoint, "requestedSourceUs": fixtureEndpoint, "endpointErrorUs": -33_333,
                "frames": transferFirst.count, "retentionSeconds": retention, "reviewSeconds": reviewSeconds])))
        }
        camera.exportReview = { done in if holdExport { heldExport = done } else { export(done) } }
        func calibrate() {
            host.measureClock()
            wait("eight clock samples") { (snapshot(host)["clock"] as? [String: Any])?["samples"] as? Int == 8 }
        }
        func request(_ delay: Int = 0) {
            let queued = DispatchSemaphore(value: 0)
            host.requestReview(delayMs: delay) { require($0 == nil, "review queued"); queued.signal() }
            require(queued.wait(timeout: .now() + 3) == .success, "request callback")
        }
        func review() -> [String: Any] { snapshot(host)["review"] as? [String: Any] ?? [:] }
        for delay in [0, 2000, 5000] {
            calibrate(); request(delay)
            let requested = review()
            wait("verified host review") {
                if review()["state"] as? String == "failed" { print("Host:", snapshot(host)); print("Camera:", snapshot(camera)); require(false, "review failed") }
                return review()["state"] as? String == "ready"
            }
            require(abs(Double(endpoint) - (requested["peerTapUs"] as! Double)) <= 1, "tap anchored before delay")
            let state = snapshot(host)["transfer"] as! [String: Any]
            require(state["media"] as? String == "recording" && state["checksumVerified"] as? Bool == true, "recording only ready after verification")
            let info = state["recording"] as! [String: Any]
            require((info["sourceLastUs"] as! NSNumber).int64Value == endpoint - 20_000_000 + lastFrame.timeUs, "original source endpoint preserved")
            let acquired = DispatchSemaphore(value: 0)
            host.acquireReview { url, metadata in
                require(url != nil && metadata != nil, "verified recording URL")
                let frame = try! RecordingClip.inspect(url!, index: lastFrame.count - 1)
                require(frame.timeUs == lastFrame.timeUs && frame.count == lastFrame.count, "received real frame timestamps/count")
                acquired.signal()
            }
            require(acquired.wait(timeout: .now() + 5) == .success, "inspection callback")
            let blocked = DispatchSemaphore(value: 0)
            host.cleanupTransfer { require($0 != nil, "cleanup blocked during inspection/playback lease"); blocked.signal() }
            require(blocked.wait(timeout: .now() + 3) == .success, "lease cleanup callback")
            host.reviewPlaybackStarted() // event fixture, not actual AVPlayer/phone playback
            wait("native playback event timing") { review()["tapToPlayMs"] as? Double != nil }
            require((review()["tapToPlayMs"] as! Double) >= Double(delay), "elapsed includes injected delay")
            host.releaseMedia()
            wait("camera completion receipt") { (snapshot(camera)["transfer"] as? [String: Any])?["state"] as? String == "complete" }
        }
        // Native remux fixture plus a second valid configuration, still generated footage only.
        let short = gapDirectory.appendingPathComponent("review-short-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: short) }
        let segment = RecordingSegment(url: source, firstUs: 0); segment.lastUs = lastFrame.timeUs; segment.finalizing = false
        _ = try RecordingClip.extract(segments: [segment], endUs: lastFrame.timeUs, reviewSeconds: 10, output: short)
        transferSource = short; transferFirst = try RecordingClip.inspect(short, index: 0); transferLast = try RecordingClip.inspect(short, index: transferFirst.count - 1)
        retention = 60; reviewSeconds = 10
        calibrate(); request(); wait("second configuration verifies") { review()["state"] as? String == "ready" }
        let shortInfo = (snapshot(host)["transfer"] as! [String: Any])["recording"] as! [String: Any]
        require((shortInfo["retentionSeconds"] as! NSNumber).intValue == 60 && (shortInfo["reviewSeconds"] as! NSNumber).intValue == 10, "second configuration preserved")
        wait("second configuration receipt") { (snapshot(camera)["transfer"] as? [String: Any])?["state"] as? String == "complete" }
        transferSource = source; transferFirst = firstFrame; transferLast = lastFrame; retention = 120; reviewSeconds = 20
        unavailable = true; calibrate(); request()
        wait("missing window explicit failure") { review()["state"] as? String == "failed" }
        let unavailableDone = DispatchSemaphore(value: 0)
        host.acquireReview { url, _ in require(url == nil, "previous successful clip not offered as failed review"); unavailableDone.signal() }
        require(unavailableDone.wait(timeout: .now() + 3) == .success, "unavailable callback")
        unavailable = false
        // Interrupt between extraction and export. A late export must never be sent on a new session.
        holdExport = true; calibrate(); request()
        wait("export held") { heldExport != nil }
        camera.stop()
        wait("interrupted review explicit failure") { review()["state"] as? String == "failed" && snapshot(host)["authenticated"] as? Bool == false }
        let late = heldExport!; heldExport = nil; export(late); holdExport = false
        camera.connect(address: "127.0.0.1", secret: secret, port: port); connected()
        require(snapshot(host)["clock"] == nil, "reconnect invalidates clock")
        calibrate(); request()
        wait("fresh retry verifies") { review()["state"] as? String == "ready" }
        wait("retry receipt") { (snapshot(camera)["transfer"] as? [String: Any])?["state"] as? String == "complete" }
        wrongTap = true; calibrate(); request()
        wait("wrong mapped tap rejected") { review()["state"] as? String == "failed" && snapshot(host)["authenticated"] as? Bool == false }
        require((review()["detail"] as? String ?? "").contains("endpoint does not match"), "wrong tap error explicit")
        wrongTap = false; camera.connect(address: "127.0.0.1", secret: secret, port: port); connected()
        corrupt = true; calibrate(); request()
        wait("checksum-valid invalid MP4 rejected") { review()["state"] as? String == "failed" && snapshot(host)["authenticated"] as? Bool == false }
        let transfer = snapshot(host)["transfer"] as! [String: Any]
        require(transfer["checksumVerified"] as? Bool == false && transfer["state"] as? String == "failed", "decode failure never ready")
        let noPartial = DispatchSemaphore(value: 0)
        host.acquireReview { url, _ in require(url == nil, "invalid media cannot play"); noPartial.signal() }
        require(noPartial.wait(timeout: .now() + 3) == .success, "invalid media callback")
        let cleaned = DispatchSemaphore(value: 0)
        host.cleanupTransfer { require($0 == nil, "cleanup"); cleaned.signal() }
        require(cleaned.wait(timeout: .now() + 3) == .success, "cleanup callback")
        print("PASS: native remux/60-10 configuration and gap rejection, three encrypted H.264 review fixtures, 0/2/5-second tap anchoring, original timestamps and recorded frames, playback-event timing, media lease, unavailable footage, interruption/reconnect/retry, invalid-media rejection and cleanup (macOS loopback only)")
    }
}
