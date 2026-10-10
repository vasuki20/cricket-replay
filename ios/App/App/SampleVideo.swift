import Foundation
import AVFoundation
import CoreGraphics

// Synthetic footage only: 600 moving frames, 20 seconds, H.264 MP4, no audio.
enum SampleVideo {
    static func generate(completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue(label: "cricket.sample-generator").async {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cricket-sample-" + UUID().uuidString + ".mp4")
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: 30]])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
                guard writer.canAdd(input) else { throw TransferError.invalid("Video encoder unavailable") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? TransferError.invalid("Cannot start encoder") }
                writer.startSession(atSourceTime: .zero)
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                for frame in 0..<600 {
                    while !input.isReadyForMoreMediaData {
                        guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                            writer.cancelWriting(); throw writer.error ?? TransferError.invalid("Sample generation timed out")
                        }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    try autoreleasepool {
                        var optional: CVPixelBuffer?
                        guard let pool = adaptor.pixelBufferPool,
                              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else {
                            throw TransferError.invalid("Cannot allocate video frame")
                        }
                        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw TransferError.invalid("Cannot draw video frame") }
                        context.setFillColor(CGColor(red: 0.05, green: 0.18, blue: 0.12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
                        context.fillEllipse(in: CGRect(x: (frame * 4) % 600, y: 140, width: 40, height: 40))
                        // One second tick per bar makes ordering and full duration visible.
                        for tick in 0...frame / 30 { context.fill(CGRect(x: 15 + tick * 30, y: 30, width: 20, height: 20)) }
                        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                            throw writer.error ?? TransferError.invalid("Cannot encode video frame")
                        }
                    }
                }
                input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 20, timescale: 1))
                let done = DispatchSemaphore(value: 0)
                writer.finishWriting { done.signal() }
                guard done.wait(timeout: .now() + 15) == .success, writer.status == .completed else {
                    writer.cancelWriting(); throw writer.error ?? TransferError.invalid("Cannot finish sample")
                }
                completion(.success(url))
            } catch { try? FileManager.default.removeItem(at: url); completion(.failure(error)) }
        }
    }
}
