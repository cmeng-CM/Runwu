// Editable monochrome adaptation of the approved Runwu v2 wind-swept raindrop.
// Run: swift Scripts/make-menubar-icon.swift (also works from another directory).
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = root.appendingPathComponent("Resources/Assets.xcassets/MenuBarIcon.imageset")

func windDropPath(in size: CGFloat) -> NSBezierPath {
    // A broad rounded drop, a curved windward tip, and an internal flowing cut.
    // Coordinates use a 64-unit, y-up canvas; optical margins remain at 16pt.
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 32, y: 61))
    path.curve(to: NSPoint(x: 58, y: 25), controlPoint1: NSPoint(x: 44, y: 56), controlPoint2: NSPoint(x: 57, y: 39))
    path.curve(to: NSPoint(x: 33, y: 3), controlPoint1: NSPoint(x: 61, y: 11), controlPoint2: NSPoint(x: 48, y: 3))
    path.curve(to: NSPoint(x: 8, y: 25), controlPoint1: NSPoint(x: 18, y: 3), controlPoint2: NSPoint(x: 6, y: 12))
    path.curve(to: NSPoint(x: 25, y: 45), controlPoint1: NSPoint(x: 8, y: 36), controlPoint2: NSPoint(x: 23, y: 38))
    path.curve(to: NSPoint(x: 32, y: 61), controlPoint1: NSPoint(x: 31, y: 51), controlPoint2: NSPoint(x: 31, y: 58))
    path.close()

    // Keep the negative space broad enough for 1x; no text or extra symbols.
    let wind = NSBezierPath()
    wind.move(to: NSPoint(x: 16, y: 29))
    wind.curve(to: NSPoint(x: 35, y: 51), controlPoint1: NSPoint(x: 29, y: 35), controlPoint2: NSPoint(x: 38, y: 44))
    wind.curve(to: NSPoint(x: 31, y: 34), controlPoint1: NSPoint(x: 42, y: 43), controlPoint2: NSPoint(x: 39, y: 36))
    wind.curve(to: NSPoint(x: 45, y: 27), controlPoint1: NSPoint(x: 34, y: 28), controlPoint2: NSPoint(x: 42, y: 30))
    wind.curve(to: NSPoint(x: 30, y: 28), controlPoint1: NSPoint(x: 40, y: 21), controlPoint2: NSPoint(x: 36, y: 27))
    wind.curve(to: NSPoint(x: 16, y: 29), controlPoint1: NSPoint(x: 23, y: 32), controlPoint2: NSPoint(x: 18, y: 31))
    wind.close()
    path.append(wind)
    path.windingRule = .evenOdd
    var transform = AffineTransform()
    transform.translate(x: size * 0.5, y: size * 0.5)
    transform.scale(size / 64 * 0.9)
    transform.translate(x: -32, y: -32)
    path.transform(using: transform)
    return path
}

func export(_ pixels: Int) throws {
    // Explicit pixels avoid Retina lockFocus doubling; every rep is 16pt.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSColor.black.setFill()
    windDropPath(in: CGFloat(pixels)).fill()
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: 16, height: 16)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
    try png.write(to: destination.appendingPathComponent("MenuBarIcon-\(pixels).png"))
    print("Generated MenuBarIcon-\(pixels).png (\(pixels)x\(pixels), 16pt, black + alpha)")
}

try [16, 32, 48].forEach(export)
let legacy = destination.appendingPathComponent("MenuBarIcon-64.png")
if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
