import Foundation
import AVFoundation

struct RecordingConfig {
    let retentionSeconds: Int
    let reviewSeconds: Int
    init(retentionSeconds: Int = 120, reviewSeconds: Int = 20) throws {
        guard (30...180).contains(retentionSeconds), (5...30).contains(reviewSeconds), reviewSeconds <= retentionSeconds - 10 else {
            throw RecordingError.invalid("Use retention 30–180 and review 5–30 whole seconds; review must be at least ten seconds shorter")
        }
        self.retentionSeconds = retentionSeconds; self.reviewSeconds = reviewSeconds
    }
}
enum RecordingError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
final class RecordingSegment {
    let url: URL
    let csv: URL
    let firstUs: Int64
    var lastUs: Int64
    var frames = 0
    var pins = 0
    var finalizing = true
    init(url: URL, firstUs: Int64) {
        self.url = url; self.csv = url.deletingPathExtension().appendingPathExtension("csv")
        self.firstUs = firstUs; self.lastUs = firstUs
    }
}
// Serial recording queue owns all mutation; extraction only reads pinned, completed files.
final class RecordingBuffer {
    let config: RecordingConfig
    var segments: [RecordingSegment] = []
    init(config: RecordingConfig) { self.config = config }
    func pin(endUs: Int64) throws -> [RecordingSegment] {
        let cutoff = endUs - Int64(config.reviewSeconds) * 1_000_000
        let selected = segments.filter { $0.lastUs >= cutoff && $0.firstUs <= endUs }
        guard let first = selected.first, first.firstUs <= cutoff, selected.allSatisfy({ !$0.finalizing }) else {
            throw RecordingError.invalid("Not enough finalized footage for this review window")
        }
        selected.forEach { $0.pins += 1 }; return selected
    }
    func release(_ selected: [RecordingSegment]) {
        selected.forEach { precondition($0.pins > 0); $0.pins -= 1 }
    }
    func evict(latestUs: Int64) throws {
        let cutoff = latestUs - Int64(config.retentionSeconds) * 1_000_000
        let expired = segments.filter { $0.lastUs < cutoff && $0.pins == 0 && !$0.finalizing }
        for segment in expired {
            for url in [segment.url, segment.csv] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        segments.removeAll { candidate in expired.contains { $0 === candidate } }
    }
}

enum RecordingMedia {
    static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }
    static func sync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }
    static func retime(_ sample: CMSampleBuffer, ptsUs: Int64) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else {
            throw RecordingError.invalid("Cannot preserve clip frame timing")
        }
        return copy
    }
}
