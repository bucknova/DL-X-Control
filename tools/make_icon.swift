import AppKit
// Draws the app icon: a glass tile with a load trace and a bolt.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let tile = NSBezierPath(roundedRect: NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s), xRadius: 185*s, yRadius: 185*s)
    NSGradient(colors: [NSColor(red: 0.18, green: 0.44, blue: 0.53, alpha: 1), NSColor(red: 0.08, green: 0.1, blue: 0.16, alpha: 1), NSColor(red: 0.54, green: 0.29, blue: 0.14, alpha: 1)])!.draw(in: tile, angle: -55)
    NSColor(white: 1, alpha: 0.28).setStroke(); tile.lineWidth = 8*s; tile.stroke()
    let trace = NSBezierPath()
    trace.move(to: NSPoint(x: 190*s, y: 620*s))
    trace.curve(to: NSPoint(x: 430*s, y: 520*s), controlPoint1: NSPoint(x: 240*s, y: 540*s), controlPoint2: NSPoint(x: 320*s, y: 530*s))
    trace.line(to: NSPoint(x: 700*s, y: 500*s))
    trace.curve(to: NSPoint(x: 835*s, y: 250*s), controlPoint1: NSPoint(x: 780*s, y: 495*s), controlPoint2: NSPoint(x: 810*s, y: 420*s))
    NSColor(red: 0.42, green: 0.7, blue: 1, alpha: 1).setStroke(); trace.lineWidth = 34*s; trace.lineCapStyle = .round; trace.stroke()
    let bolt = NSBezierPath()
    for (i, p) in [(560, 850), (340, 500), (490, 500), (440, 240), (690, 610), (535, 610)].enumerated() {
        let pt = NSPoint(x: CGFloat(p.0)*s, y: CGFloat(p.1)*s)
        if i == 0 { bolt.move(to: pt) } else { bolt.line(to: pt) }
    }
    bolt.close(); NSColor(red: 1, green: 0.7, blue: 0.25, alpha: 1).setFill(); bolt.fill()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: dir.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: dir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
