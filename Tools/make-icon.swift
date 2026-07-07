// Generates the Vestitel app icon: a googly-eyed RSS-dot blob broadcasting
// rainbow waves. Run: swift Tools/make-icon.swift <output-iconset-dir>
// Then:  iconutil -c icns <dir> -o Resources/AppIcon.icns

import AppKit
import ImageIO
import UniformTypeIdentifiers

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func starPath(center: CGPoint, radius r: CGFloat) -> CGPath {
    let s = r * 0.28
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x, y: center.y + r))
    p.addLine(to: CGPoint(x: center.x + s, y: center.y + s))
    p.addLine(to: CGPoint(x: center.x + r, y: center.y))
    p.addLine(to: CGPoint(x: center.x + s, y: center.y - s))
    p.addLine(to: CGPoint(x: center.x, y: center.y - r))
    p.addLine(to: CGPoint(x: center.x - s, y: center.y - s))
    p.addLine(to: CGPoint(x: center.x - r, y: center.y))
    p.addLine(to: CGPoint(x: center.x - s, y: center.y + s))
    p.closeSubpath()
    return p
}

func drawIcon(size: Int) -> CGImage {
    let S = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // --- Squircle background (Apple icon grid: ~80% of canvas) ---
    let margin = 0.095 * S
    let plate = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let squircle = CGPath(roundedRect: plate, cornerWidth: 0.185 * S, cornerHeight: 0.185 * S, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // diagonal violet gradient, deep at bottom-left where the blob sits
    let bg = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgba(0x2A1458), rgba(0x6A3DE8), rgba(0x8B5CF6)] as CFArray,
        locations: [0, 0.65, 1]
    )!
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: plate.minX, y: plate.minY),
        end: CGPoint(x: plate.maxX, y: plate.maxY),
        options: []
    )

    // soft glow behind the blob
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgba(0xFFB24D, 0.55), rgba(0xFFB24D, 0)] as CFArray,
        locations: [0, 1]
    )!
    let blobCenter = CGPoint(x: 0.375 * S, y: 0.375 * S)
    ctx.drawRadialGradient(
        glow, startCenter: blobCenter, startRadius: 0,
        endCenter: blobCenter, endRadius: 0.34 * S, options: []
    )

    // --- Broadcast waves: three rainbow arcs, bottom-left to top-right ---
    let waveColors: [CGColor] = [rgba(0x7CFFCB), rgba(0xFFD166), rgba(0xFF6FB5)]
    let waveRadii: [CGFloat] = [0.30, 0.435, 0.57]
    ctx.setLineCap(.round)
    for (color, radius) in zip(waveColors, waveRadii) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(0.062 * S)
        ctx.addArc(
            center: blobCenter, radius: radius * S,
            startAngle: 0.06 * .pi, endAngle: 0.44 * .pi, clockwise: false
        )
        ctx.strokePath()
    }

    // sparkles
    ctx.setFillColor(rgba(0xFFFFFF, 0.9))
    ctx.addPath(starPath(center: CGPoint(x: 0.245 * S, y: 0.77 * S), radius: 0.038 * S))
    ctx.addPath(starPath(center: CGPoint(x: 0.80 * S, y: 0.24 * S), radius: 0.028 * S))
    ctx.addPath(starPath(center: CGPoint(x: 0.33 * S, y: 0.665 * S), radius: 0.018 * S))
    ctx.fillPath()

    // --- The blob (the RSS dot, alive and thrilled about it) ---
    let R = 0.155 * S

    // antennae first (behind the body)
    ctx.setStrokeColor(rgba(0xE06D00))
    ctx.setLineWidth(0.014 * S)
    for (dx, tip) in [(-0.05, CGPoint(x: -0.10, y: 0.30)), (0.05, CGPoint(x: 0.13, y: 0.28))] {
        ctx.move(to: CGPoint(x: blobCenter.x + CGFloat(dx) * S, y: blobCenter.y + 0.10 * S))
        ctx.addQuadCurve(
            to: CGPoint(x: blobCenter.x + tip.x * S, y: blobCenter.y + tip.y * S),
            control: CGPoint(x: blobCenter.x + CGFloat(dx) * 3.2 * S, y: blobCenter.y + 0.22 * S)
        )
        ctx.strokePath()
        ctx.setFillColor(rgba(0xFFD166))
        ctx.fillEllipse(in: CGRect(
            x: blobCenter.x + tip.x * S - 0.022 * S,
            y: blobCenter.y + tip.y * S - 0.022 * S,
            width: 0.044 * S, height: 0.044 * S
        ))
    }

    // body: slightly squashed circle
    ctx.setFillColor(rgba(0xFF8A00))
    ctx.fillEllipse(in: CGRect(
        x: blobCenter.x - R * 1.06, y: blobCenter.y - R,
        width: R * 2.12, height: R * 1.95
    ))

    // googly eyes: frog-style, poking above the body, deliberately mismatched
    struct Eye { let cx: CGFloat; let cy: CGFloat; let r: CGFloat; let px: CGFloat; let py: CGFloat }
    let eyes = [
        Eye(cx: -0.062, cy: 0.075, r: 0.062, px: 0.018, py: 0.022),   // looking up-right
        Eye(cx: 0.075, cy: 0.085, r: 0.048, px: -0.012, py: 0.014),   // looking up-left (cross-eyed)
    ]
    for e in eyes {
        let c = CGPoint(x: blobCenter.x + e.cx * S, y: blobCenter.y + e.cy * S)
        ctx.setFillColor(rgba(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: c.x - e.r * S, y: c.y - e.r * S, width: e.r * 2 * S, height: e.r * 2 * S))
        ctx.setStrokeColor(rgba(0xE06D00))
        ctx.setLineWidth(0.008 * S)
        ctx.strokeEllipse(in: CGRect(x: c.x - e.r * S, y: c.y - e.r * S, width: e.r * 2 * S, height: e.r * 2 * S))
        let pr = e.r * 0.42 * S
        ctx.setFillColor(rgba(0x1A1030))
        ctx.fillEllipse(in: CGRect(x: c.x + e.px * S - pr, y: c.y + e.py * S - pr, width: pr * 2, height: pr * 2))
        let hr = pr * 0.35
        ctx.setFillColor(rgba(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: c.x + e.px * S - pr * 0.2, y: c.y + e.py * S + pr * 0.3, width: hr * 2, height: hr * 2))
    }

    // big open grin with one tooth
    let mouth = CGRect(
        x: blobCenter.x - 0.055 * S, y: blobCenter.y - 0.095 * S,
        width: 0.115 * S, height: 0.085 * S
    )
    ctx.setFillColor(rgba(0x6B1D00))
    ctx.addPath(CGPath(ellipseIn: mouth, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(rgba(0xFFFFFF))
    ctx.fill(CGRect(x: mouth.midX - 0.017 * S, y: mouth.maxY - 0.026 * S, width: 0.034 * S, height: 0.024 * S))

    // blush cheeks
    ctx.setFillColor(rgba(0xFF5CA8, 0.55))
    ctx.fillEllipse(in: CGRect(x: blobCenter.x - 0.145 * S, y: blobCenter.y - 0.045 * S, width: 0.05 * S, height: 0.034 * S))
    ctx.fillEllipse(in: CGRect(x: blobCenter.x + 0.10 * S, y: blobCenter.y - 0.035 * S, width: 0.05 * S, height: 0.034 * S))

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - main

guard CommandLine.arguments.count > 1 else {
    print("usage: swift Tools/make-icon.swift <output-iconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    writePNG(drawIcon(size: size), to: outDir.appendingPathComponent(name))
}
print("wrote \(variants.count) images to \(outDir.path)")
