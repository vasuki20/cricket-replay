import AppKit
import ImageIO

// Package the supplied artwork into native icon/splash sizes; source PNGs stay unchanged.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
func image(_ path: String) throws -> NSImage {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else { throw NSError(domain: "BrandAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(path)"]) }
    return image
}
let icon = try image("src/assets/brand/app-icon.png")
let logo = try image("src/assets/brand/logo.png")
let cream = NSColor(srgbRed: 0.98, green: 0.965, blue: 0.925, alpha: 1)
func export(_ artwork: NSImage, width: Int, height: Int, path: String, splash: Bool = false, round: Bool = false) throws {
    let alpha = round ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue) else { throw NSError(domain: "BrandAssets", code: 2) }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    if round { NSBezierPath(ovalIn: bounds).addClip() }
    cream.setFill(); bounds.fill()
    let drawing: NSRect
    if splash {
        let w = min(CGFloat(width) * 0.62, CGFloat(height) * 1.4, 1100)
        let h = w / (logo.size.width / logo.size.height)
        drawing = NSRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h)
    } else { drawing = bounds }
    artwork.draw(in: drawing, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    let destination = root.appendingPathComponent(path)
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let output = canvas.makeImage(), let destinationImage = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "BrandAssets", code: 3) }
    CGImageDestinationAddImage(destinationImage, output, nil)
    guard CGImageDestinationFinalize(destinationImage) else { throw NSError(domain: "BrandAssets", code: 4) }
}
try export(icon, width: 1024, height: 1024, path: "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png")
for (density, size, foreground) in [("mdpi", 48, 108), ("hdpi", 72, 162), ("xhdpi", 96, 216), ("xxhdpi", 144, 324), ("xxxhdpi", 192, 432)] {
    let folder = "android/app/src/main/res/mipmap-\(density)"
    try export(icon, width: size, height: size, path: "\(folder)/ic_launcher.png")
    try export(icon, width: size, height: size, path: "\(folder)/ic_launcher_round.png", round: true)
    try export(icon, width: foreground, height: foreground, path: "\(folder)/ic_launcher_foreground.png")
}
let resources = root.appendingPathComponent("android/app/src/main/res")
for folder in try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) where folder.lastPathComponent.hasPrefix("drawable") {
    let splash = folder.appendingPathComponent("splash.png")
    if let data = try? Data(contentsOf: splash), let bitmap = NSBitmapImageRep(data: data) {
        try export(logo, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, path: "android/app/src/main/res/\(folder.lastPathComponent)/splash.png", splash: true)
    }
}
for name in ["splash-2732x2732.png", "splash-2732x2732-1.png", "splash-2732x2732-2.png"] {
    try export(logo, width: 2732, height: 2732, path: "ios/App/App/Assets.xcassets/Splash.imageset/\(name)", splash: true)
}
print("Generated native icons and splash artwork from src/assets/brand")
