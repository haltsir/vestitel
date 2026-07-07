import SwiftUI
import AppKit

/// The predefined set of source colours. A feed's default colour is derived
/// from its URL with a deterministic hash, so deleting and re-adding the same
/// feed always lands on the same colour; users can override per feed.
enum SourcePalette {

    static let entries: [(name: String, nsColor: NSColor)] = [
        ("Red", .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Mint", .systemMint),
        ("Teal", .systemTeal),
        ("Cyan", .systemCyan),
        ("Blue", .systemBlue),
        ("Indigo", .systemIndigo),
        ("Purple", .systemPurple),
        ("Pink", .systemPink),
        ("Brown", .systemBrown),
    ]

    static var count: Int { entries.count }

    static func color(at index: Int) -> Color {
        let i = ((index % count) + count) % count
        return Color(nsColor: entries[i].nsColor)
    }

    /// FNV-1a over the URL string — deterministic across launches, unlike
    /// Swift's seeded Hasher.
    static func autoIndex(forURL url: URL) -> Int {
        autoIndex(forString: url.absoluteString)
    }

    static func autoIndex(forString s: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }

    // MARK: Perceptual distance (CIELAB ΔE)
    // Index distance lies about similarity — systemPink is nearly systemRed,
    // teal/cyan are ΔE 12 apart. Assignment logic uses real ΔE instead.

    private static let labValues: [(l: Double, a: Double, b: Double)] = entries.map { entry in
        let s = entry.nsColor.usingColorSpace(.sRGB) ?? NSColor.gray.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = lin(s.redComponent), g = lin(s.greenComponent), b = lin(s.blueComponent)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = (0.2126 * r + 0.7152 * g + 0.0722 * b)
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116) }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// ΔE76 between two palette entries. ≥35 reads as clearly different at
    /// label size; ≤25 is confusable.
    static func deltaE(_ i: Int, _ j: Int) -> Double {
        let a = labValues[((i % count) + count) % count]
        let b = labValues[((j % count) + count) % count]
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    // Colored circle images for menu items (SwiftUI menus render label views
    // monochrome, but NSImage colors survive).
    private static var swatchCache: [Int: NSImage] = [:]

    static func swatchImage(at index: Int) -> NSImage {
        let i = ((index % count) + count) % count
        if let cached = swatchCache[i] { return cached }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            entries[i].nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        swatchCache[i] = image
        return image
    }
}
