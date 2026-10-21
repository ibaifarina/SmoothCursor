import AppKit
import CoreText
import SCCore

/// Rasterizes overlay text (keystroke pills, captions) with CoreText.
enum TextOverlayRasterizer {
    /// Image at 1 pixel per output pixel, plus its size.
    static func image(for o: OverlayText) -> CGImage? {
        let weight: NSFont.Weight = if case .keys = o.style { .semibold } else { .bold }
        let font = NSFont.systemFont(ofSize: o.fontSize, weight: weight)
        let light: Bool = if case let .keys(l) = o.style { l } else { false }
        let foreground: NSColor = light ? NSColor(white: 0.08, alpha: 1) : .white
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: o.text, attributes: [
            .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph, .kern: o.fontSize * 0.01,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: o.maxWidth, height: .greatestFiniteMagnitude), nil
        )
        let padX: CGFloat, padY: CGFloat, radius: CGFloat
        switch o.style {
        case .keys: padX = o.fontSize * 0.75; padY = o.fontSize * 0.42; radius = o.fontSize * 0.62
        case let .caption(boxed): padX = boxed ? o.fontSize * 0.55 : o.fontSize * 0.2; padY = boxed ? o.fontSize * 0.3 : o.fontSize * 0.2; radius = o.fontSize * 0.35
        }
        let shadowPad = o.fontSize * 0.5
        let w = Int((textSize.width + 2 * padX + 2 * shadowPad).rounded(.up)), h = Int((textSize.height + 2 * padY + 2 * shadowPad).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let box = CGRect(x: shadowPad, y: shadowPad, width: CGFloat(w) - 2 * shadowPad, height: CGFloat(h) - 2 * shadowPad)
        switch o.style {
        case .keys:
            ctx.setShadow(offset: CGSize(width: 0, height: -o.fontSize * 0.08), blur: o.fontSize * 0.45, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(light ? CGColor(gray: 1, alpha: 0.92) : CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 0.82))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(light ? CGColor(gray: 0, alpha: 0.08) : CGColor(gray: 1, alpha: 0.12))
            ctx.setLineWidth(max(1, o.fontSize * 0.03))
            ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case let .caption(boxed):
            if boxed {
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -o.fontSize * 0.05), blur: o.fontSize * 0.3, color: CGColor(gray: 0, alpha: 0.8))
            }
        }
        let textRect = CGRect(x: box.minX + padX, y: box.minY + padY, width: textSize.width, height: textSize.height)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }
}
