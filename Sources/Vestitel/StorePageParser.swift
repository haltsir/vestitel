import Foundation

/// Parses store product-listing pages (ozone.bg-style category pages) into
/// the same ParsedFeed shape RSS produces, so a listing can be watched like
/// a feed: every product becomes an item keyed by its product URL, and a
/// product is "new" the first time it appears in the listing.
enum StorePageParser {

    enum ParseError: Error, LocalizedError {
        case notAStorePage

        var errorDescription: String? {
            "The page does not contain a recognizable product listing."
        }
    }

    // Each product is an <a class="product-box" href="…"> card containing a
    // <span class="title">, a cover <img>, an attribute list and price data.
    private static let productAnchor = try! NSRegularExpression(
        pattern: "<a\\s+[^>]*?class=\"product-box\"[^>]*?href=\"([^\"]+)\"",
        options: [.caseInsensitive]
    )
    private static let titleSpan = try! NSRegularExpression(
        pattern: "<span class=\"title\">([^<]+)</span>",
        options: [.caseInsensitive]
    )
    private static let imageSrc = try! NSRegularExpression(
        pattern: "<img[^>]*?src=\"([^\"]+)\"",
        options: [.caseInsensitive]
    )
    // The analytics blob is the most reliable price source — the visible
    // price markup splits digits across spans and varies with discounts.
    private static let priceData = try! NSRegularExpression(
        pattern: "value:'([0-9.]+)',\\s*currency:'([A-Z]+)'",
        options: []
    )
    private static let genreAttr = try! NSRegularExpression(
        pattern: "Жанр:[\\s\\S]{0,200}?<span>\\s*([^<]+?)\\s*</span>",
        options: []
    )
    private static let pageTitle = try! NSRegularExpression(
        pattern: "<title>([^<]*)</title>",
        options: [.caseInsensitive]
    )

    static func parse(data: Data, pageURL: URL) throws -> ParsedFeed {
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.notAStorePage
        }

        let matches = productAnchor.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var items: [ParsedItem] = []
        var seenHrefs = Set<String>()

        for (i, match) in matches.enumerated() {
            guard let anchorRange = Range(match.range, in: html),
                  let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard seenHrefs.insert(href).inserted else { continue }

            let chunkEnd = i + 1 < matches.count
                ? Range(matches[i + 1].range, in: html)?.lowerBound ?? html.endIndex
                : html.endIndex
            let chunk = String(html[anchorRange.lowerBound..<chunkEnd])

            let title = FeedParser.cleanHTML(first(titleSpan, in: chunk) ?? "")
            guard !title.isEmpty else { continue }

            var summaryParts: [String] = []
            if let m = priceData.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
               let valueRange = Range(m.range(at: 1), in: chunk),
               let currencyRange = Range(m.range(at: 2), in: chunk),
               let value = Double(chunk[valueRange]) {
                let currency = String(chunk[currencyRange])
                let symbol = ["EUR": "€", "BGN": "лв."][currency] ?? currency
                summaryParts.append(String(format: "%.2f %@", value, symbol))
            }
            if let genre = first(genreAttr, in: chunk) {
                summaryParts.append(FeedParser.cleanHTML(genre))
            }

            var imageURL: URL? = nil
            if let src = first(imageSrc, in: chunk), src.hasPrefix("http") {
                imageURL = URL(string: src)
            }

            items.append(ParsedItem(
                guid: href,
                title: title,
                link: URL(string: href, relativeTo: pageURL)?.absoluteURL,
                summary: summaryParts.isEmpty ? nil : summaryParts.joined(separator: " · "),
                published: nil,   // ingest stamps fetch time = "when it appeared"
                imageURL: imageURL
            ))
        }

        guard !items.isEmpty else { throw ParseError.notAStorePage }

        var feedTitle = FeedParser.cleanHTML(first(pageTitle, in: html) ?? "")
        if let bar = feedTitle.firstIndex(of: "|") {
            feedTitle = String(feedTitle[..<bar]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ParsedFeed(title: feedTitle, items: items)
    }

    private static func first(_ regex: NSRegularExpression, in s: String) -> String? {
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
