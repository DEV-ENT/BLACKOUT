// Renders Blackout's 1024x1024 app icon: amber radar on black, green blips for linked phones.
// Usage: swiftc -O -o /tmp/make-icon tools/make-icon.swift && /tmp/make-icon ios/Blackout/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
let size = 1024.0, c = CGPoint(x: 512, y: 512)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func amber(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 0.65, blue: 0.1, alpha: a) }
let green = CGColor(srgbRed: 0.3, green: 0.88, blue: 0.5, alpha: 1)
ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
// Sweep: a wedge fading from amber to clear, drawn as thin slices.
let start = CGFloat.pi * 0.25, span = CGFloat.pi * 0.62, r = 400.0
ctx.setShouldAntialias(false) // no seams between slices; the outer ring covers the rim
for i in 0..<120 {
    let t = CGFloat(i) / 120, a0 = start + span * t, a1 = start + span * (t + 1.0 / 120) + 0.002
    ctx.setFillColor(amber(0.42 * t * t))
    ctx.move(to: c); ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false); ctx.closePath(); ctx.fillPath()
}
ctx.setShouldAntialias(true)
// Leading edge of the sweep.
ctx.setStrokeColor(amber(1)); ctx.setLineWidth(10); ctx.setLineCap(.round)
ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + cos(start + span) * r, y: c.y + sin(start + span) * r)); ctx.strokePath()
// Rings and crosshair.
for (i, rr) in [133.0, 266.0, 400.0].enumerated() {
    ctx.setStrokeColor(amber(0.35 + 0.2 * CGFloat(i))); ctx.setLineWidth(i == 2 ? 14 : 9)
    ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
}
ctx.setStrokeColor(amber(0.25)); ctx.setLineWidth(6)
ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y)); ctx.strokePath()
// Blips with glow, and you in the center.
for (x, y, s) in [(700.0, 690.0, 34.0), (330.0, 640.0, 28.0), (610.0, 300.0, 30.0)] {
    ctx.setShadow(offset: .zero, blur: 40, color: green); ctx.setFillColor(green)
    ctx.fillEllipse(in: CGRect(x: x - s, y: y - s, width: 2 * s, height: 2 * s))
}
ctx.setShadow(offset: .zero, blur: 30, color: amber(1)); ctx.setFillColor(amber(1))
ctx.fillEllipse(in: CGRect(x: c.x - 30, y: c.y - 30, width: 60, height: 60))
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
