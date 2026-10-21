// Renders the Smooth Cursor app icon: a cursor gliding along a smooth trail and clicking.
// Usage: swift Assets/Logo/render-logo.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "logo.png")
let size = args.count > 2 ? Int(args[2])! : 1024
let s = CGFloat(size) / 1024

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
// Draw in a top-left origin space, like the design.
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// macOS icon grid: 824 pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x000000, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0x141417))
ctx.fillPath()
ctx.restoreGState()

// Body: deep graphite with a warm glow where the cursor lands.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(gradient([color(0x26262C), color(0x0E0E11)], [0, 1]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.drawRadialGradient(gradient([color(0xFF6A1F, 0.42), color(0xFF6A1F, 0)], [0, 1]),
                       startCenter: CGPoint(x: 590, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: 590, y: 430), endRadius: 470, options: [])

// Subtle canvas frame, like a recording on a background.
let frame = CGPath(roundedRect: CGRect(x: 196, y: 238, width: 632, height: 470), cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.addPath(frame)
ctx.setStrokeColor(color(0xFFFFFF, 0.07))
ctx.setLineWidth(6)
ctx.strokePath()

// Motion trail: a cubic curve drawn as overlapping dots that grow and brighten toward the cursor.
let p0 = CGPoint(x: 230, y: 790), c1 = CGPoint(x: 300, y: 520), c2 = CGPoint(x: 420, y: 700), p3 = CGPoint(x: 560, y: 410)
func bezier(_ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x
    let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y
    return CGPoint(x: x, y: y)
}
let steps = 400
for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps)
    let p = bezier(t)
    let r = 4 + 22 * pow(t, 1.4)
    let a = 0.06 + 0.94 * pow(t, 1.8)
    // Orange to pink-red along the trail.
    let mix = t
    let red: CGFloat = 1, green = (0x3D + (0x6A - 0x3D) * mix) / 255, blue = (0x6E + (0x1F - 0x6E) * mix) / 255
    ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: a))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

// Click ripples around the cursor tip.
let tip = CGPoint(x: 572, y: 392)
for (radius, alpha, width) in [(CGFloat(78), CGFloat(0.55), CGFloat(10)), (128, 0.28, 8), (182, 0.12, 6)] {
    ctx.setStrokeColor(color(0xFF8A3D, alpha))
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: 2 * radius, height: 2 * radius))
}
ctx.restoreGState()

// The cursor: classic arrow, white with a dark outline, slightly tilted with motion.
let arrow: [CGPoint] = [
    CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1.0), CGPoint(x: 0.235, y: 0.79), CGPoint(x: 0.385, y: 1.13),
    CGPoint(x: 0.525, y: 1.07), CGPoint(x: 0.375, y: 0.735), CGPoint(x: 0.68, y: 0.735),
]
let scale: CGFloat = 330
var transform = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: -0.12).scaledBy(x: scale, y: scale)
let cursor = CGMutablePath()
cursor.addLines(between: arrow, transform: transform)
cursor.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: color(0x000000, 0.55))
ctx.addPath(cursor)
ctx.setFillColor(color(0x101012))
ctx.setLineJoin(.round)
ctx.setLineWidth(34)
ctx.setStrokeColor(color(0x101012))
ctx.drawPath(using: .fillStroke)
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cursor)
ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xE9E9EE)], [0, 1]),
                       start: tip, end: CGPoint(x: tip.x + 150, y: tip.y + 360), options: [])
ctx.restoreGState()

// Top highlight on the body edge.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote", out.path)
