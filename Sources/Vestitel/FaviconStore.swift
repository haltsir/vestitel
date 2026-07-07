import AppKit
import SwiftUI

/// Loads and caches favicons per feed host. Icons are fetched straight from
/// the site (no third-party favicon services), kept in memory, and persisted
/// to Application Support/Vestitel/favicons so relaunches don't refetch.
/// Hosts without a usable icon are remembered per session and not retried.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var icons: [String: NSImage] = [:]
    private var attempted: Set<String> = []
    private var menuIcons: [String: NSImage] = [:]
    /// Hosts whose icon is predominantly dark and needs a light backing
    /// plate to stay visible on dark backgrounds (the "Slack fix").
    private var darkIcons: Set<String> = []

    func needsPlate(for host: String) -> Bool {
        darkIcons.contains(host)
    }

    private func register(_ image: NSImage, for host: String) {
        if Self.isPredominantlyDark(image) {
            darkIcons.insert(host)
        }
        icons[host] = image
    }

    /// Mean luminance of the icon's visible pixels, sampled on a 16×16 grid.
    private static func isPredominantlyDark(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return false }
        var luminance = 0.0
        var samples = 0.0
        let stepX = max(1, w / 16), stepY = max(1, h / 16)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.2 {
                    luminance += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                    samples += 1
                }
                x += stepX
            }
            y += stepY
        }
        guard samples > 8 else { return false }
        return luminance / samples < 0.4
    }

    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vestitel/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(for host: String) -> NSImage? {
        icons[host]
    }

    /// Fixed-size copy for Menu labels, which render NSImages at their
    /// intrinsic size and ignore SwiftUI frame modifiers.
    func menuIcon(for host: String, size: CGFloat = 14) -> NSImage? {
        if let cached = menuIcons[host] { return cached }
        guard let full = icons[host] else { return nil }
        let plated = needsPlate(for: host)
        let resized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2).addClip()
            if plated {
                NSColor.white.withAlphaComponent(0.92).setFill()
                rect.fill()
                full.draw(in: rect.insetBy(dx: size * 0.11, dy: size * 0.11))
            } else {
                full.draw(in: rect)
            }
            return true
        }
        menuIcons[host] = resized
        return resized
    }

    func load(host: String) {
        guard !attempted.contains(host) else { return }
        attempted.insert(host)

        let file = cacheDir.appendingPathComponent("\(host).png")
        if let cached = NSImage(contentsOf: file) {
            register(cached, for: host)
            return
        }

        Task {
            var candidates = ["favicon.ico", "apple-touch-icon.png", "favicon.png"]
                .compactMap { URL(string: "https://\(host)/\($0)") }
            // fall back to the icons the site declares in its HTML
            // (<link rel="icon" ...> / rel="shortcut icon" / apple-touch-icon)
            candidates += await Self.declaredIconURLs(host: host)

            for url in candidates {
                guard let image = await Self.fetchImage(from: url) else { continue }
                register(image, for: host)
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: file)
                }
                return
            }
        }
    }

    private static func fetchImage(from url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count > 16,
              let image = NSImage(data: data), image.isValid, image.size.width > 0
        else { return nil }
        return image
    }

    private static let linkTagRegex = try! NSRegularExpression(pattern: "<link\\s[^>]*>", options: [.caseInsensitive])
    private static let hrefRegex = try! NSRegularExpression(pattern: "href=[\"']([^\"']+)[\"']", options: [.caseInsensitive])
    private static let relRegex = try! NSRegularExpression(pattern: "rel=[\"']([^\"']*)[\"']", options: [.caseInsensitive])

    /// Icon URLs declared in the site's homepage <link> tags, in document
    /// order. Handles absolute and relative hrefs.
    private static func declaredIconURLs(host: String) async -> [URL] {
        guard let pageURL = URL(string: "https://\(host)/"),
              let (data, response) = try? await URLSession.shared.data(from: pageURL),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        // icons are declared in <head>; 300 KB is plenty
        let html = String(decoding: data.prefix(300_000), as: UTF8.self)
        let nsHTML = html as NSString

        var urls: [URL] = []
        for match in linkTagRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let tag = nsHTML.substring(with: match.range)
            let tagRange = NSRange(tag.startIndex..., in: tag)
            guard let relMatch = relRegex.firstMatch(in: tag, range: tagRange),
                  let relRange = Range(relMatch.range(at: 1), in: tag) else { continue }
            let rel = tag[relRange].lowercased()
            guard rel.contains("icon"), !rel.contains("mask") else { continue }
            guard let hrefMatch = hrefRegex.firstMatch(in: tag, range: tagRange),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else { continue }
            let href = tag[hrefRange].replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
               url.scheme?.hasPrefix("http") == true {
                urls.append(url)
            }
        }
        return urls
    }
}

/// The visual identity of a source: its favicon when the site has one,
/// otherwise a deterministic coloured dot.
struct SourceMark: View {
    let host: String?
    let color: Color
    var size: CGFloat = 12

    @ObservedObject private var store = FaviconStore.shared

    init(host: String?, color: Color, size: CGFloat = 12) {
        self.host = host
        self.color = color
        self.size = size
        if let host {
            FaviconStore.shared.load(host: host)
        }
    }

    var body: some View {
        if let host, let image = store.icon(for: host) {
            let plated = store.needsPlate(for: host)
            ZStack {
                if plated {
                    RoundedRectangle(cornerRadius: size * 0.2)
                        .fill(Color.white.opacity(0.92))
                }
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: plated ? size - 3 : size,
                        height: plated ? size - 3 : size
                    )
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
            }
            .frame(width: size, height: size)
        } else {
            Circle()
                .fill(color)
                .frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size)
        }
    }
}
