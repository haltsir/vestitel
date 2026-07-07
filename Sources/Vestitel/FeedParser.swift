import Foundation

struct ParsedFeed {
    var title: String
    var items: [ParsedItem]
}

struct ParsedItem {
    var guid: String?
    var title: String
    var link: URL?
    var summary: String?
    var published: Date?
    var imageURL: URL? = nil
}

/// Minimal RSS 2.0 / RSS 1.0 / Atom parser built on XMLParser — no dependencies.
final class FeedParser: NSObject, XMLParserDelegate {

    enum ParseError: Error, LocalizedError {
        case notAFeed
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notAFeed: return "The URL did not return a recognizable RSS or Atom feed."
            case .malformed(let detail): return "Feed could not be parsed: \(detail)"
            }
        }
    }

    private var feedTitle: String = ""
    private var items: [ParsedItem] = []

    private var isAtom = false
    private var sawRoot = false
    private var insideItem = false
    private var insideImage = false      // RSS <image> has its own <title>
    private var elementPath: [String] = []
    private var text = ""

    private var current = ParsedItem(guid: nil, title: "", link: nil, summary: nil, published: nil)
    private var atomLinkCandidate: String?

    static func parse(data: Data) throws -> ParsedFeed {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            let msg = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw ParseError.malformed(msg)
        }
        guard delegate.sawRoot else { throw ParseError.notAFeed }
        return ParsedFeed(
            title: delegate.feedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            items: delegate.items
        )
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        elementPath.append(name)
        text = ""

        switch name {
        case "rss", "rdf":
            sawRoot = true
        case "feed":
            sawRoot = true
            isAtom = true
        case "item", "entry":
            insideItem = true
            current = ParsedItem(guid: nil, title: "", link: nil, summary: nil, published: nil)
            atomLinkCandidate = nil
        case "image" where !isAtom:
            insideImage = true
        case "link" where isAtom:
            // Atom links are attributes; prefer rel="alternate" (or missing rel).
            let rel = attributeDict["rel"] ?? "alternate"
            if rel == "alternate", let href = attributeDict["href"],
               insideItem, atomLinkCandidate == nil {
                atomLinkCandidate = href
            }
        case "enclosure", "content", "thumbnail":
            // media:content / media:thumbnail / RSS enclosure — the localName
            // strip maps them here. Atom's <content> has no url attr: skipped.
            if insideItem, current.imageURL == nil, let urlString = attributeDict["url"] {
                let type = attributeDict["type"] ?? ""
                let medium = attributeDict["medium"] ?? ""
                let lower = urlString.lowercased()
                let looksLikeImage = type.hasPrefix("image/") || medium == "image"
                    || name == "thumbnail"
                    || [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains(where: lower.contains)
                if looksLikeImage {
                    current.imageURL = URL(string: urlString)
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        defer { elementPath.removeLast(); text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideItem {
            switch name {
            case "item", "entry":
                if isAtom, let href = atomLinkCandidate {
                    current.link = URL(string: href)
                }
                current.title = Self.cleanHTML(current.title)
                if !current.title.isEmpty {
                    items.append(current)
                }
                insideItem = false
            case "title":
                current.title = value
            case "link" where !isAtom:
                current.link = URL(string: value)
            case "guid", "id":
                if current.guid == nil { current.guid = value }
                // RSS guids are often permalinks — use as link fallback
                if current.link == nil, value.hasPrefix("http") {
                    current.link = URL(string: value)
                }
            case "description", "summary", "encoded":
                if current.summary == nil || name != "encoded" {
                    current.summary = Self.cleanHTML(value)
                }
                if current.imageURL == nil {
                    current.imageURL = Self.firstImageURL(inHTML: value)
                }
            case "pubDate", "published", "updated", "date":
                if current.published == nil || name == "published" || name == "pubDate" {
                    current.published = Self.parseDate(value) ?? current.published
                }
            default:
                break
            }
        } else {
            switch name {
            case "title" where !insideImage && feedTitle.isEmpty:
                feedTitle = value
            case "image":
                insideImage = false
            default:
                break
            }
        }
    }

    // MARK: helpers

    private func localName(_ element: String) -> String {
        // strip namespace prefixes: "dc:date" -> "date", "content:encoded" -> "encoded"
        if let idx = element.lastIndex(of: ":") {
            return String(element[element.index(after: idx)...])
        }
        return element
    }

    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yy HH:mm:ss Z",
    ]

    private static let rfc822Formatters: [DateFormatter] = rfc822Formats.map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFractionalFormatter.date(from: s) { return d }
        for f in rfc822Formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static let imgRegex = try? NSRegularExpression(
        pattern: "<img[^>]+src=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive]
    )

    /// First <img src> in an HTML fragment — fallback image for feeds that
    /// only embed pictures in the description.
    static func firstImageURL(inHTML html: String) -> URL? {
        guard let regex = imgRegex,
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let urlString = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
        guard urlString.hasPrefix("http") else { return nil }
        return URL(string: urlString)
    }

    /// Strip tags and decode common entities; collapse whitespace.
    static func cleanHTML(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
            "&#8217;": "\u{2019}", "&#8216;": "\u{2018}",
            "&#8220;": "\u{201C}", "&#8221;": "\u{201D}",
            "&#8211;": "\u{2013}", "&#8212;": "\u{2014}", "&hellip;": "\u{2026}",
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
