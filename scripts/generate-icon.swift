import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(pixels)
        NSColor(calibratedRed: 0.055, green: 0.085, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88), xRadius: side * 0.19, yRadius: side * 0.19).fill()
        NSColor(calibratedRed: 0.40, green: 0.88, blue: 0.72, alpha: 1).setStroke()
        for offset in [0.0, 0.16, 0.32] {
            let y = side * (0.32 + offset)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: side * 0.25, y: y + side * 0.09))
            path.line(to: NSPoint(x: side * 0.50, y: y - side * 0.04))
            path.line(to: NSPoint(x: side * 0.75, y: y + side * 0.09))
            path.lineWidth = max(1, side * 0.035); path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
