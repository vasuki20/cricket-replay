import Foundation
import AVFoundation

@main
struct TransferTests {
    static func require(_ condition: @autoclosure () -> Bool, _ detail: String) {
        if !condition() { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    static func main() async throws {
        let queue = DispatchQueue(label: "transfer.test")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-engine-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiver = SampleTransfer(queue: queue, directory: directory)
        queue.sync {
            let id = UUID().uuidString.lowercased()
            receiver.receive(id: id, packet: ["kind": "offer", "bytes": 3, "sha256": String(repeating: "0", count: 64)], isHost: true)
            receiver.receive(id: id, packet: ["kind": "chunk", "offset": 0, "data": Data([1, 2, 3]).base64EncodedString()], isHost: true)
            require(receiver.state["bytes"] as? Int == 3, "all bytes received")
            require(receiver.completed == nil && receiver.state["checksumVerified"] as? Bool == false, "100 percent is not ready before checksum")
            receiver.receive(id: id, packet: ["kind": "end"], isHost: true)
            require(receiver.state["state"] as? String == "failed" && receiver.completed == nil, "bad checksum rejected")
            require((try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 0, "bad checksum removes partial")
            receiver.receive(id: id, packet: ["kind": "offer", "bytes": 3, "sha256": String(repeating: "0", count: 64)], isHost: true)
            receiver.receive(id: id, packet: ["kind": "chunk", "offset": 1, "data": Data([1]).base64EncodedString()], isHost: true)
            require(receiver.state["state"] as? String == "failed", "out-of-order rejected")
            require((try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 0, "invalid chunk removes partial")
            receiver.receive(id: id, packet: ["kind": "offer", "bytes": SampleTransfer.maxBytes + 1, "sha256": String(repeating: "0", count: 64)], isHost: true)
            require(receiver.state["state"] as? String == "failed", "oversized offer rejected")
        }
        let lowDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-low-storage-" + UUID().uuidString)
        let low = SampleTransfer(queue: queue, directory: lowDirectory, availableBytes: { _ in 0 })
        queue.sync {
            low.receive(id: UUID().uuidString, packet: ["kind": "offer", "bytes": 3, "sha256": String(repeating: "0", count: 64)], isHost: true)
            require(low.state["state"] as? String == "failed" && low.completed == nil, "low storage cannot become ready")
            require((try? FileManager.default.contentsOfDirectory(atPath: lowDirectory.path).count) == 0, "low storage discards partial")
            try! low.cleanup()
            let info: [String: Any] = ["sourceFirstUs": 1_000_000, "sourceLastUs": 20_966_667, "requestedHostUs": 21_000_000,
                "requestedSourceUs": 21_000_000, "endpointErrorUs": -33_333, "frames": 600, "retentionSeconds": 120, "reviewSeconds": 20]
            require((try? SampleTransfer.recordingMetadata(info)) != nil, "valid original timing metadata")
            for (key, value) in [("endpointErrorUs", -500_000), ("frames", 0), ("reviewSeconds", 31), ("sourceLastUs", 2_000_000), ("requestedSourceUs", 21_000_000.5)] as [(String, Any)] {
                var invalid = info; invalid[key] = value
                require((try? SampleTransfer.recordingMetadata(invalid)) == nil, "invalid/partial timing rejected: \(key)")
            }
            let expected = UUID().uuidString
            low.validateRecording = { _, _ in }
            low.acceptOffer = { _, id in if id != expected { throw TransferError.invalid("Unexpected or stale recording review") } }
            low.receive(id: UUID().uuidString, packet: ["kind": "offer", "bytes": 3, "sha256": String(repeating: "0", count: 64), "media": "recording", "reviewId": UUID().uuidString, "recording": info], isHost: true)
            require(low.state["state"] as? String == "failed" && low.completed == nil, "stale review rejected before reception")
            try! low.cleanup()
            // Startup discards killed-process media instead of restoring ready state.
            try! FileManager.default.createDirectory(at: lowDirectory, withIntermediateDirectories: true)
            try! Data([1]).write(to: lowDirectory.appendingPathComponent("stale.part"))
            let fresh = SampleTransfer(queue: queue, directory: lowDirectory)
            require(fresh.completed == nil && fresh.state["state"] as? String == "idle" && !FileManager.default.fileExists(atPath: lowDirectory.path), "process restart clears stale partial")
        }
        let done = DispatchSemaphore(value: 0)
        var generated: Result<URL, Error>?
        SampleVideo.generate { generated = $0; done.signal() }
        require(done.wait(timeout: .now() + 80) == .success, "generation completes")
        let url = try generated!.get(); defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let playable = try await asset.load(.isPlayable)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        require(abs(CMTimeGetSeconds(duration) - 20) < 0.05, "sample duration 20 seconds")
        require(playable, "generated MP4 playable")
        require(video.count == 1 && audio.isEmpty, "one video track without audio")
        require(size < SampleTransfer.maxBytes, "sample within transfer limit")
        print("PASS: checksum gating, corrupted/out-of-order/oversized rejection, low storage, partial/stale timing metadata, process-restart cleanup, generated playable 20-second silent MP4")
    }
}
