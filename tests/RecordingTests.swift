import Foundation
import AVFoundation
import CoreGraphics

// macOS development checks: synthetic pixel buffers only; no camera, personal footage or network.
@main
struct RecordingTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw RecordingError.invalid("TEST: \(message)") }
    }
    static func status(_ engine: RollingRecording) throws -> [String: Any] {
        let done = DispatchSemaphore(value: 0); var result: [String: Any]?
        engine.status { result = $0; done.signal() }
        try require(done.wait(timeout: .now() + 5) == .success, "status timeout"); return result!
    }
    static func main() throws {
        for (retention, review) in [(29, 20), (181, 20), (120, 4), (120, 31), (30, 25)] {
            var rejected = false
            do { _ = try RecordingConfig(retentionSeconds: retention, reviewSeconds: review) } catch { rejected = true }
            try require(rejected, "invalid configuration accepted")
        }
        try protection()
        try failureCleanup()
        try syntheticCapture()
        print("PASS: configuration, pin/finalization eviction protection, failure cleanup, continuous synthetic VideoToolbox encoding, cross-file remux, decoded joins, eviction, stop and cleanup")
    }
    static func protection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-pin-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ring = RecordingBuffer(config: try RecordingConfig(retentionSeconds: 30, reviewSeconds: 20))
        for index in 0..<8 {
            let segment = RecordingSegment(url: root.appendingPathComponent("\(index).mp4"), firstUs: Int64(index) * 5_000_000)
            segment.lastUs = segment.firstUs + 4_966_667; segment.finalizing = false
            try Data([1]).write(to: segment.url); try Data([2]).write(to: segment.csv); ring.segments.append(segment)
        }
        let pins = try ring.pin(endUs: 29_966_667)
        try ring.evict(latestUs: 90_000_000)
        try require(ring.segments.count == pins.count && pins.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "pinned inputs evicted")
        ring.release(pins); try ring.evict(latestUs: 90_000_000)
        try require(ring.segments.isEmpty, "pins not released")
        let sealing = RecordingSegment(url: root.appendingPathComponent("sealing.mp4"), firstUs: 0)
        try Data([3]).write(to: sealing.url); ring.segments.append(sealing); try ring.evict(latestUs: 90_000_000)
        try require(ring.segments.count == 1 && FileManager.default.fileExists(atPath: sealing.url.path), "finalizing input evicted")
    }
    static func failureCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-failure-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("clip.mp4")
        let segment = RecordingSegment(url: root.appendingPathComponent("missing.mp4"), firstUs: 0); segment.lastUs = 25_000_000
        var rejected = false
        do { _ = try RecordingClip.extract(segments: [segment], endUs: 25_000_000, reviewSeconds: 20, output: output) } catch { rejected = true }
        try require(rejected && !FileManager.default.fileExists(atPath: output.path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("clip-frames.csv").path), "invalid inputs published a partial clip")
    }
    static func syntheticCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-recording-test-\(UUID())")
        let engine = RollingRecording(directory: root)
        defer {
            let stopped = DispatchSemaphore(value: 0); engine.stop { stopped.signal() }; _ = stopped.wait(timeout: .now() + 15)
            let cleaned = DispatchSemaphore(value: 0); engine.cleanup { _ in cleaned.signal() }; _ = cleaned.wait(timeout: .now() + 5)
        }
        try engine.beginFixture(config: RecordingConfig(retentionSeconds: 30, reviewSeconds: 20))
        let extracted = DispatchSemaphore(value: 0); var extractionError: Error?; var requested = false; var inspected = false
        let origin: Int64 = 1_000_000_000_000
        for frame in 0..<1260 {
            // Give the concurrent remux worker wall-clock time while capture still feeds frames.
            if requested { Thread.sleep(forTimeInterval: 0.01) }
            try autoreleasepool {
                engine.appendRawFixture(try pixelSample(frame: frame, origin: origin))
                var result = try status(engine)
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while (result["encodedFrames"] as? Int ?? 0) < frame - 3 && result["state"] as? String != "failed" && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.001); result = try status(engine)
                }
                try require(result["state"] as? String != "failed", result["detail"] as? String ?? "recording failed")
                try require(ProcessInfo.processInfo.systemUptime < deadline, "encoder did not drain bounded input")
                if frame == 670 {
                    requested = true; engine.extract { extractionError = $0; extracted.signal() }
                }
                if requested && !inspected && (result["extraction"] as? [String: Any])?["ready"] as? Bool == true {
                    try require(extracted.wait(timeout: .now() + 1) == .success, "extract completion missing")
                    if let extractionError { throw extractionError }
                    let info = result["extraction"] as! [String: Any]
                    try require(result["state"] as? String == "recording", "extraction stopped encoding")
                    try require(info["segments"] as? Int ?? 0 >= 4 && info["decodedFrames"] as? Int == 3, "cross-file decode smoke check")
                    try inspectJoins(root)
                    inspected = true
                }
            }
        }
        try require(inspected, "extraction did not finish while synthetic input continued: \(try status(engine))")
        let stopped = DispatchSemaphore(value: 0); engine.stop { stopped.signal() }
        try require(stopped.wait(timeout: .now() + 15) == .success, "stop did not complete")
        let result = try status(engine)
        try require(result["state"] as? String == "stopped", result["detail"] as? String ?? "stop failed")
        try require(result["encodedFrames"] as? Int == 1260, "frames lost in pipeline")
        try require(abs((result["effectiveFps"] as? Double ?? 0) - 30) < 0.01, "effective synthetic fps changed")
        try require(result["intervalsOver50ms"] as? Int == 0, "synthetic timestamp gap")
        try require((result["bufferedSeconds"] as? Double ?? 0) < 40, "whole-segment retention not bounded")
        try require(result["pinnedSegments"] as? Int == 0, "extraction pins leaked")
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("report.json"))) as! [String: Any]
        try require((report["segments"] as? [[String: Any]] ?? []).count >= 8, "segment evidence missing")
    }
    static func pixelSample(frame: Int, origin: Int64) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pixel) == kCVReturnSuccess, let pixel else { throw RecordingError.invalid("Cannot create fixture pixel") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        memset(y, 35, row * 360)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * 180)
        let x = 20 + frame * 4 % 600
        for iy in 160..<200 { for ix in max(0, x - 20)..<min(640, x + 20) {
            if (ix - x) * (ix - x) + (iy - 180) * (iy - 180) < 400 { y[iy * row + ix] = 220 }
        } }
        for bit in 0..<16 { for iy in 20..<36 { for ix in bit * 20 + 10..<bit * 20 + 22 { y[iy * row + ix] = frame & (1 << bit) == 0 ? 35 : 180 } } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr else { throw RecordingError.invalid("Cannot describe fixture pixel") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTimeAdd(CMTime(value: origin, timescale: 1_000_000), CMTime(value: Int64(frame), timescale: 30)), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw RecordingError.invalid("Cannot create fixture sample") }
        return sample
    }
    static func inspectJoins(_ root: URL) throws {
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("report.json"))) as! [String: Any]
        let segments = report["segments"] as! [[String: Any]]
        let rows = try String(contentsOf: root.appendingPathComponent("clip-frames.csv"), encoding: .utf8).split(separator: "\n").dropFirst().map { $0.split(separator: ",").map(String.init) }
        let clip = AVAssetImageGenerator(asset: AVURLAsset(url: root.appendingPathComponent("latest-clip.mp4")))
        clip.requestedTimeToleranceBefore = .zero; clip.requestedTimeToleranceAfter = .zero
        var joins = 0
        for index in 1..<rows.count {
            let delta = Int64(rows[index][1])! - Int64(rows[index - 1][1])!
            try require((33_332...33_334).contains(delta), "original frame intervals changed across file boundary")
            if rows[index][4] == rows[index - 1][4] { continue }
            for frame in [index - 1, index, index + 1] where frame < rows.count {
                let row = rows[frame]
                let metadata = segments.first { $0["file"] as? String == row[4] }!
                let first = (metadata["firstPtsUs"] as! NSNumber).int64Value
                let source = AVAssetImageGenerator(asset: AVURLAsset(url: root.appendingPathComponent(row[4])))
                source.requestedTimeToleranceBefore = .zero; source.requestedTimeToleranceAfter = .zero
                let a = try source.copyCGImage(at: CMTime(value: Int64(row[1])! - first, timescale: 1_000_000), actualTime: nil)
                let b = try clip.copyCGImage(at: CMTime(value: Int64(row[2])!, timescale: 1_000_000), actualTime: nil)
                try require(a.width == b.width && a.height == b.height && a.dataProvider!.data! as Data == b.dataProvider!.data! as Data, "decoded synthetic boundary frame changed")
            }
            joins += 1
        }
        try require(joins >= 3, "too few decoded file joins")
    }
}
