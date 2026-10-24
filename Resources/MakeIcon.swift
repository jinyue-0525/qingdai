import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let outline = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
    NSColor(calibratedRed: 237 / 255, green: 243 / 255, blue: 1, alpha: 1).setFill()
    outline.fill()

    let panel = NSBezierPath(roundedRect: NSRect(x: 230, y: 226, width: 564, height: 572), xRadius: 108, yRadius: 108)
    NSColor(calibratedRed: 77 / 255, green: 107 / 255, blue: 254 / 255, alpha: 1).setFill()
    panel.fill()

    let header = NSBezierPath(roundedRect: NSRect(x: 314, y: 685, width: 198, height: 30), xRadius: 15, yRadius: 15)
    NSColor.white.withAlphaComponent(0.48).setFill()
    header.fill()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: 354, y: 485))
    check.line(to: NSPoint(x: 465, y: 376))
    check.line(to: NSPoint(x: 677, y: 586))
    check.lineWidth = 62
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let name = "icon_\(size)x\(size)\(multiplier == 2 ? "@2x" : "").png"
        try drawIcon(size: size * multiplier).write(to: destination.appendingPathComponent(name))
    }
}
