import AppKit
import Foundation

// Keep the flat T3 artwork, but provide complete macOS raster icon variants.
// Widget galleries can then load the icon without an Icon Composer renderer.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artwork = root.appendingPathComponent("Source/IconArtwork.png")
let catalog = root.appendingPathComponent("Source/Assets.xcassets", isDirectory: true)
let iconset = catalog.appendingPathComponent("AppIconT3.appiconset", isDirectory: true)
guard let original = NSImage(contentsOf: artwork) else { fatalError("Missing T3 artwork") }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        NSColor(srgbRed: 0.91, green: 0.90, blue: 0.86, alpha: 1).setFill()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        rect.fill()
        original.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        try png.write(to: iconset.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appendingPathComponent("Contents.json"))
print("Generated all 10 macOS flat T3 icon variants.")
