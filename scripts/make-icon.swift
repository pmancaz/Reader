import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets", isDirectory: true)
let iconset = root.appendingPathComponent("Reader.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func render(_ pixels: Int, _ filename: String) throws {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let scale = CGFloat(pixels) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208).fill()
    NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1).setFill()
    let left = NSBezierPath()
    left.move(to: NSPoint(x: 232, y: 270)); left.line(to: NSPoint(x: 232, y: 747))
    left.curve(to: NSPoint(x: 496, y: 698), controlPoint1: NSPoint(x: 346, y: 767), controlPoint2: NSPoint(x: 436, y: 733))
    left.line(to: NSPoint(x: 496, y: 233))
    left.curve(to: NSPoint(x: 232, y: 270), controlPoint1: NSPoint(x: 416, y: 278), controlPoint2: NSPoint(x: 334, y: 289)); left.close(); left.fill()
    let right = NSBezierPath()
    right.move(to: NSPoint(x: 792, y: 270)); right.line(to: NSPoint(x: 792, y: 747))
    right.curve(to: NSPoint(x: 528, y: 698), controlPoint1: NSPoint(x: 678, y: 767), controlPoint2: NSPoint(x: 588, y: 733))
    right.line(to: NSPoint(x: 528, y: 233))
    right.curve(to: NSPoint(x: 792, y: 270), controlPoint1: NSPoint(x: 608, y: 278), controlPoint2: NSPoint(x: 690, y: 289)); right.close(); right.fill()
    NSColor(srgbRed: 0.57, green: 0.62, blue: 0.64, alpha: 1).setStroke()
    for y in [620, 544, 468] {
        let line = NSBezierPath(); line.lineWidth = 16; line.lineCapStyle = .round
        line.move(to: NSPoint(x: 286, y: y)); line.line(to: NSPoint(x: 435, y: y - 10)); line.stroke()
        let line2 = NSBezierPath(); line2.lineWidth = 16; line2.lineCapStyle = .round
        line2.move(to: NSPoint(x: 589, y: y - 10)); line2.line(to: NSPoint(x: 738, y: y)); line2.stroke()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, "icon_\(size)x\(size).png")
    try render(size * 2, "icon_\(size)x\(size)@2x.png")
}
