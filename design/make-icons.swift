// Draws the Remote Keeper icon (a reconnect loop around a dot) at the sizes the web app needs.
// Usage: swift design/make-icons.swift <output dir>
import AppKit

func icon(size: CGFloat, inset: CGFloat, mac: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    if mac {
        // macOS icon grid: an 824/1024 rounded square with a soft shadow.
        let side = size * 824 / 1024, origin = (size - side) / 2
        let shape = CGPath(roundedRect: CGRect(x: origin, y: origin, width: side, height: side), cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(shape); ctx.clip()
    }
    let colors = [NSColor(srgbRed: 0.42, green: 0.33, blue: 0.98, alpha: 1).cgColor, NSColor(srgbRed: 0.23, green: 0.20, blue: 0.78, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    let c = CGPoint(x: size / 2, y: size / 2)
    let unit = size * (1 - 2 * inset)
    let radius = unit * 0.27
    let line = unit * 0.085
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    // A loop that is almost closed, with an arrowhead at its end: "reconnect".
    let start = CGFloat.pi * 0.62, end = CGFloat.pi * 0.62 + CGFloat.pi * 1.62
    ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
    let tip = CGPoint(x: c.x + radius * cos(end), y: c.y + radius * sin(end))
    let along = CGPoint(x: -sin(end), y: cos(end))   // direction of travel at the end
    let out = CGPoint(x: cos(end), y: sin(end))
    let head = unit * 0.13
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.move(to: CGPoint(x: tip.x + along.x * head, y: tip.y + along.y * head))
    ctx.addLine(to: CGPoint(x: tip.x + out.x * head * 0.75 - along.x * head * 0.2, y: tip.y + out.y * head * 0.75 - along.y * head * 0.2))
    ctx.addLine(to: CGPoint(x: tip.x - out.x * head * 0.75 - along.x * head * 0.2, y: tip.y - out.y * head * 0.75 - along.y * head * 0.2))
    ctx.closePath()
    ctx.fillPath()
    let dot = unit * 0.075
    ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "--mac" {
    // An .iconset for iconutil.
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try! icon(size: CGFloat(size * scale), inset: 0.19, mac: true).write(to: out.appendingPathComponent(name))
        }
    }
    exit(0)
}
for (name, size, inset) in [("apple-touch-icon", 180.0, 0.0), ("icon-192", 192, 0.0), ("icon-512", 512, 0.0), ("icon-maskable-512", 512, 0.1), ("icon-1024", 1024, 0.0)] {
    try! icon(size: CGFloat(size), inset: CGFloat(inset)).write(to: out.appendingPathComponent("\(name).png"))
}
