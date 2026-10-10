import Foundation
import CoreVideo

@main
struct RecordingOrientationTests {
    static func require(_ condition: @autoclosure () -> Bool, _ detail: String) {
        if !condition() { fputs("FAIL: \(detail)\n", stderr); exit(1) }
    }
    static func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (address[offset + 2], address[offset + 1], address[offset])
    }
    static func main() throws {
        var source: CVPixelBuffer?
        require(CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &source) == kCVReturnSuccess, "source buffer")
        let input = source!
        CVPixelBufferLockBaseAddress(input, [])
        let bytes = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<90 { for x in 0..<160 {
            let offset = y * CVPixelBufferGetBytesPerRow(input) + x * 4
            let red = x < 80 && y < 45
            bytes[offset] = red ? 0 : 255; bytes[offset + 1] = 0; bytes[offset + 2] = red ? 255 : 0; bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(input, [])
        let normalizer = RecordingFrameNormalizer()
        // The same live recording changes from portrait to both landscape directions and back.
        for orientation: Int32 in [6, 1, 3, 8, 1] {
            let output = try normalizer.render(input, orientation: orientation)
            require(CVPixelBufferGetWidth(output) == 160 && CVPixelBufferGetHeight(output) == 90, "rotation keeps encoder dimensions stable")
            if orientation == 1 {
                require(pixel(output, 20, 20).0 > 240, "landscape retains top-left red marker")
                require(pixel(output, 140, 70).2 > 240, "landscape retains bottom-right blue marker")
            } else if orientation == 3 {
                require(pixel(output, 140, 70).0 > 240, "opposite landscape turns marker upright")
            } else {
                if orientation == 6 { require(pixel(output, 90, 20).0 > 240, "portrait quarter-turn puts marker top-right") }
                if orientation == 8 { require(pixel(output, 70, 70).0 > 240, "upside-down portrait puts marker bottom-left") }
                let side = pixel(output, 5, 45)
                require(side.0 < 5 && side.1 < 5 && side.2 < 5, "portrait fits without cropping into a landscape canvas")
                let center = pixel(output, 80, 30)
                require(center.0 > 240 || center.2 > 240, "portrait content remains visible")
            }
        }
        print("PASS: portrait-to-landscape capture transitions preserve frame dimensions, landscape marker orientation and uncropped portrait content")
    }
}
