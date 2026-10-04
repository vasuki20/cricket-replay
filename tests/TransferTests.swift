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
        print("PASS: checksum gating, corrupted/out-of-order/oversized rejection, partial cleanup, generated playable 20-second silent MP4")
    }
}
