// Generates classic macOS icons from the approved Runwu v2 PNG, without drawing.
// Run from any working directory: swift /path/to/Runwu/Scripts/make-icon.swift
import Foundation
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/Icons/Runwu-AppIcon-v2.png")
let destination = root.appendingPathComponent("Resources/AppIcon.icns")
let manager = FileManager.default

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
    image.width == image.height, image.width > 0,
    [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo) else {
    fatalError("Approved source must be a square PNG with alpha: \(source.path)")
}

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw NSError(domain: "Runwu.IconGeneration", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Icon conversion failed: \(tool)"])
    }
}

let iconset = manager.temporaryDirectory.appendingPathComponent("Runwu-\(UUID().uuidString).iconset")
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: iconset) }

// Logical macOS sizes with both scale factors; every representation is resized
// directly from the approved original, retaining its alpha and orientation.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", source.path, "--out", file.path])
    }
}
try run("/usr/bin/iconutil", ["--convert", "icns", "--output", destination.path, iconset.path])
print("Generated \(destination.path) from approved \(source.lastPathComponent)")
