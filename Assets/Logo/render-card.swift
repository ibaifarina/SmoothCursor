// Composes a README feature card: title, subtitle and a framed render.
// Usage: swift Assets/Logo/render-card.swift <image.png> <out.png> <title> <subtitle>
import AppKit

let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let out = URL(fileURLWithPath: args[2])
let title = args[3], subtitle = args[4]

let W = 1600, H = 1100
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Card body (CoreGraphics origin is bottom-left).
let card = CGRect(x: 0, y: 0, width: W, height: H)
let cardPath = CGPath(roundedRect: card, cornerWidth: 48, cornerHeight: 48, transform: nil)
ctx.addPath(cardPath)
ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [color(0x1C1C21), color(0x0E0E11)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 0, y: 0), options: [])
ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [color(0xFF6A1F, 0.16), color(0xFF6A1F, 0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: CGFloat(W) * 0.85, y: CGFloat(H)), startRadius: 0,
                       endCenter: CGPoint(x: CGFloat(W) * 0.85, y: CGFloat(H)), endRadius: 900, options: [])

// Text.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.white, .kern: -0.5]
let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .regular), .foregroundColor: NSColor(white: 1, alpha: 0.55)]
NSAttributedString(string: title, attributes: titleAttrs).draw(at: CGPoint(x: 80, y: CGFloat(H) - 140))
NSAttributedString(string: subtitle, attributes: subAttrs).draw(at: CGPoint(x: 80, y: CGFloat(H) - 196))

// Framed image, running off the bottom edge.
let imageWidth = CGFloat(W) - 160
let imageHeight = imageWidth * CGFloat(source.height) / CGFloat(source.width)
let frame = CGRect(x: 80, y: CGFloat(H) - 250 - imageHeight, width: imageWidth, height: imageHeight)
let framePath = CGPath(roundedRect: frame, cornerWidth: 24, cornerHeight: 24, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: color(0x000000, 0.6))
ctx.addPath(framePath)
ctx.setFillColor(color(0x000000))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(framePath)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(source, in: frame)
ctx.restoreGState()
ctx.addPath(framePath)
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(2)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
