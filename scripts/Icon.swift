import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.05, y: p * 0.05, width: p * 0.9, height: p * 0.9), xRadius: p * 0.20, yRadius: p * 0.20).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p * 0.50, y: p * 0.80))
        path.curve(to: NSPoint(x: p * 0.80, y: p * 0.50), controlPoint1: NSPoint(x: p * 0.54, y: p * 0.58), controlPoint2: NSPoint(x: p * 0.59, y: p * 0.54))
        path.curve(to: NSPoint(x: p * 0.50, y: p * 0.20), controlPoint1: NSPoint(x: p * 0.59, y: p * 0.46), controlPoint2: NSPoint(x: p * 0.54, y: p * 0.41))
        path.curve(to: NSPoint(x: p * 0.20, y: p * 0.50), controlPoint1: NSPoint(x: p * 0.46, y: p * 0.41), controlPoint2: NSPoint(x: p * 0.41, y: p * 0.46))
        path.curve(to: NSPoint(x: p * 0.50, y: p * 0.80), controlPoint1: NSPoint(x: p * 0.41, y: p * 0.54), controlPoint2: NSPoint(x: p * 0.46, y: p * 0.59))
        NSColor(calibratedRed: 0.76, green: 0.89, blue: 0.79, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// PNG-backed ICNS entries also work in headless builds where iconutil rejects
// an otherwise valid iconset. Keep the existing bitmap artwork.
if CommandLine.arguments.count > 2 {
    func word(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    var entries = Data()
    for (type, name) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
                         ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
                         ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
                         ("ic10", "icon_512x512@2x.png")] {
        let png = try Data(contentsOf: directory.appendingPathComponent(name))
        entries.append(Data(type.utf8)); entries.append(word(UInt32(png.count + 8))); entries.append(png)
    }
    var icon = Data("icns".utf8); icon.append(word(UInt32(entries.count + 8))); icon.append(entries)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
