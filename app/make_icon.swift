// Renders the GlucoseBar app icon: swift make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centred in 1024 canvas
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// background gradient
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [
    NSColor(red: 0.07, green: 0.10, blue: 0.20, alpha: 1).cgColor,
    NSColor(red: 0.10, green: 0.22, blue: 0.33, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])

// target band
let band = CGRect(x: rect.minX, y: 400, width: rect.width, height: 210)
ctx.setFillColor(NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.16).cgColor)
ctx.fill(band)
ctx.setStrokeColor(NSColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 0.35).cgColor)
ctx.setLineWidth(4); ctx.setLineDash(phase: 0, lengths: [18, 14])
ctx.stroke(CGRect(x: band.minX - 10, y: band.minY, width: band.width + 20, height: band.height))
ctx.setLineDash(phase: 0, lengths: [])

// glucose curve
let pts: [CGPoint] = [(150, 470), (250, 560), (350, 690), (450, 640), (540, 440), (630, 360), (720, 450), (800, 520)]
    .map { CGPoint(x: $0.0, y: $0.1) }
let curve = CGMutablePath()
curve.move(to: pts[0])
for i in 1..<pts.count {
    let p0 = pts[max(i - 2, 0)], p1 = pts[i - 1], p2 = pts[i], p3 = pts[min(i + 1, pts.count - 1)]
    let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
    let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
    curve.addCurve(to: p2, control1: c1, control2: c2)
}
ctx.saveGState()
ctx.addPath(curve)
ctx.setLineWidth(46); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
let line = CGGradient(colorsSpace: nil, colors: [
    NSColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1).cgColor,
    NSColor.white.cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(line, start: CGPoint(x: 150, y: 0), end: CGPoint(x: 800, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// current reading dot with glow
let last = pts.last!
for (r, a) in [(95.0, 0.10), (70.0, 0.20)] {
    ctx.setFillColor(NSColor(red: 0.30, green: 0.90, blue: 0.55, alpha: a).cgColor)
    ctx.fillEllipse(in: CGRect(x: last.x - r, y: last.y - r, width: 2 * r, height: 2 * r))
}
ctx.setFillColor(NSColor(red: 0.30, green: 0.90, blue: 0.55, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: last.x - 50, y: last.y - 50, width: 100, height: 100))
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: last.x - 22, y: last.y - 22, width: 44, height: 44))

// top gloss
let gloss = CGGradient(colorsSpace: nil, colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
ctx.restoreGState()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
