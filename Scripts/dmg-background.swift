import Cocoa

// Installer artwork only. This tool and bitmap are not copied into the app.
let size = NSSize(width: 660, height: 420)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 840,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ivory = NSColor(srgbRed: 0.906, green: 0.898, blue: 0.855, alpha: 1)
let ink = NSColor(srgbRed: 0.192, green: 0.204, blue: 0.180, alpha: 1)
let muted = NSColor(srgbRed: 0.48, green: 0.49, blue: 0.46, alpha: 1)
ivory.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
func text(_ string: String, y: CGFloat, size pointSize: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize, weight: weight), .foregroundColor: color]
    let label = string as NSString
    let measured = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: (size.width - measured.width) / 2, y: size.height - y - measured.height), withAttributes: attributes)
}
("Codex T3" as NSString).draw(at: NSPoint(x: 38, y: 344), withAttributes: [
    .font: NSFont.systemFont(ofSize: 31, weight: .semibold), .foregroundColor: ink
])
muted.withAlphaComponent(0.55).setFill()
for column in 0..<7 { for row in 0..<4 {
    NSBezierPath(ovalIn: NSRect(x: 572 + column * 7, y: 356 + row * 7, width: 2, height: 2)).fill()
} }
text("将 App 拖到「应用程序」", y: 98, size: 19, color: ink, weight: .medium)
text("Drag the app to Applications", y: 129, size: 14, color: muted)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 296, y: 200)); arrow.line(to: NSPoint(x: 364, y: 200))
arrow.move(to: NSPoint(x: 353, y: 208)); arrow.line(to: NSPoint(x: 364, y: 200)); arrow.line(to: NSPoint(x: 353, y: 192))
arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
muted.setStroke(); arrow.stroke()
text("复制完成后，从「应用程序」打开 Codex T3。", y: 351, size: 13, color: muted)
text("After copying, open Codex T3 from Applications.", y: 375, size: 12, color: muted)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
