import Foundation
import AVFoundation

enum RecordingClip {
    static func inspect(_ url: URL, index: Int) throws -> (image: CGImage, timeUs: Int64, count: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw RecordingError.invalid("No video track") }
        let (reader, source) = try reader(asset, track); defer { reader.cancelReading() }
        var times: [Int64] = []
        while let sample = source.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            let time = RecordingMedia.microseconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard times.count < 10000, times.last == nil || time > times.last! else { throw RecordingError.invalid("Frame order or count unsupported") }
            times.append(time)
        }
        guard reader.status != .failed, times.indices.contains(index) else { throw RecordingError.invalid("Frame index outside recorded clip or reader failed") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var actual = CMTime.invalid
        let image = try generator.copyCGImage(at: CMTime(value: times[index], timescale: 1_000_000), actualTime: &actual)
        guard abs(RecordingMedia.microseconds(actual) - times[index]) <= 1 else { throw RecordingError.invalid("Decoder returned a different frame") }
        return (image, times[index], times.count)
    }
    // Passthrough remuxing with original PTS intervals; preceding sync sample supplies decoder lead-in.
    static func extract(segments: [RecordingSegment], endUs: Int64, reviewSeconds: Int, output: URL) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let cutoff = endUs - Int64(reviewSeconds) * 1_000_000
        let csv = output.deletingLastPathComponent().appendingPathComponent("clip-frames.csv")
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var success = false; var base: Int64 = -1; var last: Int64 = -1
        var frames = 0; var maxDelta: Int64 = 0; var gaps = 0; var width: Int32 = 0; var height: Int32 = 0
        var frameTimes: [Int64] = []
        FileManager.default.createFile(atPath: csv.path, contents: nil)
        let log = try FileHandle(forWritingTo: csv); defer { try? log.close() }
        try log.write(contentsOf: Data("frame,sourcePtsUs,clipPtsUs,deltaUs,segment\n".utf8))
        defer {
            if !success {
                if let writer, writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: csv)
            }
        }
        for (index, segment) in segments.enumerated() {
            let asset = AVURLAsset(url: segment.url)
            guard asset.tracks(withMediaType: .audio).isEmpty, let track = asset.tracks(withMediaType: .video).first else {
                throw RecordingError.invalid("Missing silent video input")
            }
            let descriptions = track.formatDescriptions as! [CMFormatDescription]
            guard let description = descriptions.first, CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264 else {
                throw RecordingError.invalid("Expected H.264 segment")
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            var firstToCopy = segment.firstUs
            if index == 0 {
                let (reader, source) = try reader(asset, track)
                defer { reader.cancelReading() }
                var preceding: Int64?
                while let sample = source.copyNextSampleBuffer() {
                    // AVAssetReader can return a zero-sample end marker; it is not a video frame.
                    if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                    let pts = segment.firstUs + RecordingMedia.microseconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    if pts > cutoff { break }
                    if RecordingMedia.sync(sample) { preceding = pts }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingError.invalid("Clip seek timed out") }
                }
                guard let preceding else { throw RecordingError.invalid("No preceding keyframe for the review window") }
                firstToCopy = preceding
            }
            if writer == nil {
                width = dimensions.width; height = dimensions.height
                let newWriter = try AVAssetWriter(outputURL: output, fileType: .mp4); writer = newWriter
                let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
                input = newInput; newInput.expectsMediaDataInRealTime = false; newInput.mediaTimeScale = 1_000_000
                guard newWriter.canAdd(newInput) else { throw RecordingError.invalid("Clip format unavailable") }
                newWriter.add(newInput)
                guard newWriter.startWriting() else { throw newWriter.error ?? RecordingError.invalid("Cannot start clip writer") }
                newWriter.startSession(atSourceTime: .zero)
            }
            guard dimensions.width == width && dimensions.height == height else { throw RecordingError.invalid("Segment resolution changed") }
            let (reader, source) = try reader(asset, track); defer { reader.cancelReading() }
            while let sample = source.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                let pts = segment.firstUs + RecordingMedia.microseconds(CMSampleBufferGetPresentationTimeStamp(sample))
                if pts < firstToCopy { continue }; if pts > endUs { break }
                if base < 0 {
                    guard RecordingMedia.sync(sample) else { throw RecordingError.invalid("Clip does not start with a keyframe") }; base = pts
                }
                guard last < 0 || pts > last else { throw RecordingError.invalid("Non-monotonic source timestamps: \(pts) after \(last), file \(segment.url.lastPathComponent), origin \(segment.firstUs)") }
                guard let writer, let input else { throw RecordingError.invalid("No clip writer") }
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw writer.error ?? RecordingError.invalid("Clip writer timed out")
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingError.invalid("Clip extraction exceeded 30 seconds") }
                let copy = try RecordingMedia.retime(sample, ptsUs: pts - base)
                guard input.append(copy) else { throw writer.error ?? RecordingError.invalid("Cannot append clip frame") }
                let delta = last < 0 ? 0 : pts - last
                maxDelta = max(maxDelta, delta); if delta > 50_000 { gaps += 1 }
                try log.write(contentsOf: Data("\(frames),\(pts),\(pts - base),\(delta),\(segment.url.lastPathComponent)\n".utf8))
                frameTimes.append(pts - base); frames += 1; last = pts
            }
            if reader.status == .failed { throw reader.error ?? RecordingError.invalid("Cannot read segment") }
        }
        guard frames > 1, last >= cutoff, base <= cutoff, cutoff - base <= 5_000_000, let writer, let input else {
            throw RecordingError.invalid("Incomplete clip or keyframe lead-in exceeds five seconds")
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0); writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 15) == .success, writer.status == .completed else {
            throw writer.error ?? RecordingError.invalid("Clip finalization timed out")
        }
        // Decode actual beginning/middle/end frames as smoke evidence, not a visual continuity verdict.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for time in [frameTimes[0], frameTimes[frameTimes.count / 2], frameTimes[frameTimes.count - 1]] {
            _ = try generator.copyCGImage(at: CMTime(value: time, timescale: 1_000_000), actualTime: nil)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingError.invalid("Clip inspection exceeded 30 seconds") }
        success = true
        return ["ready": true, "bytes": try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "frames": frames, "width": width, "height": height, "durationSeconds": Double(last - base) / 1_000_000,
            "effectiveFps": Double(frames - 1) * 1_000_000 / Double(last - base), "sourceFirstUs": base, "sourceLastUs": last,
            "leadInSeconds": Double(cutoff - base) / 1_000_000, "segments": segments.count,
            "maxFrameDeltaMs": Double(maxDelta) / 1000, "intervalsOver50ms": gaps, "decodedFrames": 3]
    }
    private static func reader(_ asset: AVAsset, _ track: AVAssetTrack) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil); source.alwaysCopiesSampleData = false
        guard reader.canAdd(source) else { throw RecordingError.invalid("Cannot read compressed segment") }
        reader.add(source)
        guard reader.startReading() else { throw reader.error ?? RecordingError.invalid("Cannot start segment reader") }
        return (reader, source)
    }
}
