import AppKit

/// The app-icon blob, simplified for the menu bar: no squircle plate, two
/// waves instead of three, details sized to survive ~18 pt.
/// Same character as Tools/make-icon.swift — keep them visually in sync.
///
/// Two variants: `template` (monochrome; isTemplate, so macOS tints it for
/// light/dark menu bars — eyes and mouth are punched out of the silhouette)
/// and `colored`. Rendered into explicit 1x/2x/3x bitmaps so the alpha
/// punch-out is self-contained and never erases menu bar pixels.
enum MenuBarIcon {

    static let pointSize: CGFloat = 19

    static let template: NSImage = make(monochrome: true)
    static let colored: NSImage = make(monochrome: false)
    // Eyes-down variants: shown while the inbox has articles — the blob is
    // looking at what you haven't read yet.
    static let templateDown: NSImage = make(monochrome: true, lookDown: true)
    static let coloredDown: NSImage = make(monochrome: false, lookDown: true)
    // Popover-open variants: only the head is coloured, waves stay neutral.
    // Can't be a template (system would tint it whole), so the waves use a
    // mid-gray that reads on both light and dark menu bars.
    static let headColored: NSImage = make(monochrome: false, grayWaves: true)
    static let headColoredDown: NSImage = make(monochrome: false, lookDown: true, grayWaves: true)

    // Animation shown when a refresh brings new articles: the blob wiggles
    // and the waves pulse outward. Frames are pre-rendered and cycled by
    // AppStore on a timer.
    static let frameCount = 16
    static let templateFrames: [NSImage] = (0..<frameCount).map {
        make(monochrome: true, phase: Double($0) / Double(frameCount))
    }
    static let coloredFrames: [NSImage] = (0..<frameCount).map {
        make(monochrome: false, phase: Double($0) / Double(frameCount))
    }

    private static func make(monochrome: Bool, phase: Double? = nil, lookDown: Bool = false, grayWaves: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [1, 2, 3] {
            let px = Int(pointSize) * scale
            let ctx = CGContext(
                data: nil, width: px, height: px,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            draw(in: ctx, S: CGFloat(px), monochrome: monochrome, phase: phase, lookDown: lookDown, grayWaves: grayWaves)
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            rep.size = NSSize(width: pointSize, height: pointSize)
            image.addRepresentation(rep)
        }
        image.isTemplate = monochrome
        return image
    }

    private static func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func draw(in ctx: CGContext, S: CGFloat, monochrome: Bool, phase: Double? = nil, lookDown: Bool = false, grayWaves: Bool = false) {
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            monochrome ? rgba(0x000000, alpha) : rgba(hex, alpha)
        }
        let ink = color(0x000000)

        // Everything must stay inside the unit square: outermost wave extent =
        // blob.y + 0.66S + half its 0.115S stroke ≈ 0.98S.
        let blob = CGPoint(x: 0.27 * S, y: 0.26 * S)
        let R = 0.23 * S

        // animation: wiggle the whole character around the blob's center
        if let phase {
            let tilt = sin(phase * 4 * .pi) * (8 * .pi / 180)
            ctx.translateBy(x: blob.x, y: blob.y)
            ctx.rotate(by: tilt)
            ctx.translateBy(x: -blob.x, y: -blob.y)
        }

        // waves: mint + pink (yellow is illegible on light menu bars).
        // While animating, a brightness pulse travels outward through them.
        ctx.setLineCap(.round)
        for (k, wave) in [(UInt32(0x00C486), 0.44), (UInt32(0xF4429B), 0.66)].enumerated() {
            let (hex, radius) = wave
            var alpha: CGFloat = 1
            if let phase {
                let pulse = sin(2 * .pi * (phase - Double(k) * 0.3))
                alpha = 0.35 + 0.65 * CGFloat(max(0, pulse))
            }
            ctx.setStrokeColor(grayWaves ? rgba(0x98989D, alpha) : color(hex, alpha))
            ctx.setLineWidth(0.115 * S)
            ctx.addArc(
                center: blob, radius: radius * S,
                startAngle: 0.05 * .pi, endAngle: 0.45 * .pi, clockwise: false
            )
            ctx.strokePath()
        }

        // Inbox-has-articles pose: a small head tilt to go with the lowered
        // eyes. Applied after the waves so only the character leans, and
        // clockwise (away from the left edge) so antennae stay in-canvas.
        if lookDown {
            ctx.translateBy(x: blob.x, y: blob.y)
            ctx.rotate(by: -14 * .pi / 180)
            ctx.translateBy(x: -blob.x, y: -blob.y)
        }

        // antennae
        ctx.setStrokeColor(color(0xE06D00))
        ctx.setLineWidth(0.045 * S)
        for (dx, tip) in [(-0.09, CGPoint(x: -0.19, y: 0.42)), (0.09, CGPoint(x: 0.20, y: 0.38))] {
            ctx.move(to: CGPoint(x: blob.x + CGFloat(dx) * S, y: blob.y + 0.16 * S))
            ctx.addLine(to: CGPoint(x: blob.x + tip.x * S, y: blob.y + tip.y * S))
            ctx.strokePath()
            ctx.setFillColor(color(0xFFD166))
            let br = 0.05 * S
            ctx.fillEllipse(in: CGRect(
                x: blob.x + tip.x * S - br, y: blob.y + tip.y * S - br,
                width: br * 2, height: br * 2
            ))
        }

        // body
        ctx.setFillColor(color(0xFF8A00))
        ctx.fillEllipse(in: CGRect(x: blob.x - R * 1.06, y: blob.y - R, width: R * 2.12, height: R * 1.95))

        // googly eyes (mismatched, cross-eyed — same as the app icon).
        // Monochrome: whites are punched out of the silhouette, pupils stay.
        // Pupils look up at the waves normally; down when the inbox has
        // articles waiting.
        let eyes: [(cx: CGFloat, cy: CGFloat, r: CGFloat, px: CGFloat, py: CGFloat)] = lookDown
            ? [
                (-0.093, 0.115, 0.10, 0.022, -0.034),
                (0.11, 0.13, 0.08, -0.014, -0.028),
            ]
            : [
                (-0.093, 0.115, 0.10, 0.03, 0.035),
                (0.11, 0.13, 0.08, -0.02, 0.023),
            ]
        for e in eyes {
            let c = CGPoint(x: blob.x + e.cx * S, y: blob.y + e.cy * S)
            if monochrome { ctx.setBlendMode(.clear) }
            ctx.setFillColor(monochrome ? ink : rgba(0xFFFFFF))
            ctx.fillEllipse(in: CGRect(x: c.x - e.r * S, y: c.y - e.r * S, width: e.r * 2 * S, height: e.r * 2 * S))
            ctx.setBlendMode(.normal)
            let pr = e.r * 0.5 * S
            ctx.setFillColor(monochrome ? ink : rgba(0x1A1030))
            ctx.fillEllipse(in: CGRect(x: c.x + e.px * S - pr, y: c.y + e.py * S - pr, width: pr * 2, height: pr * 2))
        }

        // mouth — punched out in monochrome
        if monochrome { ctx.setBlendMode(.clear) }
        ctx.setFillColor(monochrome ? ink : rgba(0x6B1D00))
        ctx.fillEllipse(in: CGRect(x: blob.x - 0.08 * S, y: blob.y - 0.15 * S, width: 0.17 * S, height: 0.115 * S))
        ctx.setBlendMode(.normal)
    }
}
