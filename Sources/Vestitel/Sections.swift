import Foundation

/// A feed's sections ("Футбол", "Политика"), read off the article links:
/// one big feed is dozens of rubrics (Dir.bg: 89 in a 1 600-article
/// backlog, football alone 208), and group-by-source splits such a feed
/// into one block per section so a whole rubric is one decision.
///
/// The key is the link's host and first path segment
/// ("corner.dir.bg/futbol", "capital.bg/biznes"): every article already has
/// it, where a `<category>` would only exist for articles ingested after
/// the parser learned to read it, and some feeds put a number there
/// (Капитал: `<category>2274</category>`). The category, when it is text,
/// only names the key (`AppStore.sectionLabels`, learned from every fetch).
enum Sections {
    /// Smaller sections stay together in the feed's "Other" block.
    static let minimumSize = 5

    private static var keyCache: [URL: String?] = [:]

    /// Nil for a link with no section in it (a bare slug, a non-web URL).
    static func key(for link: URL?) -> String? {
        guard let link else { return nil }
        if let cached = keyCache[link] { return cached }
        let key = computeKey(link)
        if keyCache.count > 20_000 { keyCache.removeAll() }
        keyCache[link] = key
        return key
    }

    private static func computeKey(_ link: URL) -> String? {
        guard let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = link.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = link.path.split(separator: "/")
        // the last segment is the article itself
        guard parts.count >= 2 else { return nil }
        return host + "/" + parts[0].lowercased()
    }

    /// A readable stand-in until a fetch names the section: "energien pazar".
    static func slugLabel(_ key: String) -> String {
        let slug = key.split(separator: "/").last.map(String.init) ?? key
        let words = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A `<category>` worth showing: text, not an id, of a sane length.
    static func cleanCategory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40, value.contains(where: \.isLetter) else { return nil }
        return value
    }

    /// One feed's articles (newest first) as section buckets, largest
    /// first, the small sections and section-less links together at the
    /// end under an empty key. Nil when that would be a single bucket: the
    /// feed then stays one block.
    static func buckets(_ articles: [Article]) -> [(key: String, articles: [Article])]? {
        var order: [String] = []
        var bySection: [String: [Article]] = [:]
        for article in articles {
            let key = Self.key(for: article.link) ?? ""
            if bySection[key] == nil { order.append(key) }
            bySection[key, default: []].append(article)
        }
        let big = order.filter { !$0.isEmpty && (bySection[$0]?.count ?? 0) >= minimumSize }
        let bigSet = Set(big)
        let rest = articles.filter { !bigSet.contains(Self.key(for: $0.link) ?? "") }
        guard big.count + (rest.isEmpty ? 0 : 1) >= 2 else { return nil }
        // stable: equal counts keep the order of their newest article
        let rank = Dictionary(uniqueKeysWithValues: big.enumerated().map { ($1, $0) })
        var result = big.sorted {
            let a = bySection[$0]?.count ?? 0, b = bySection[$1]?.count ?? 0
            return a == b ? (rank[$0] ?? 0) < (rank[$1] ?? 0) : a > b
        }.map { (key: $0, articles: bySection[$0] ?? []) }
        if !rest.isEmpty { result.append((key: "", articles: rest)) }
        return result
    }
}
