import Foundation

/// How common each title token is in the long run: every title the app
/// has ingested over the last few months, not the ~900 in the inbox
/// today. `TopicGrouper` asks it whether a shared word is *specific*
/// (rare enough to pin two titles to one story). The inbox-local test it
/// replaces called anything in at most four titles rare, and on any given
/// day that is most content words: "борят" was in three, because the
/// stock phrasing of a casualty report ("борят се за живота") is rare on
/// a quiet day and daily over a month. The hand-kept stopword list in
/// `TopicGrouper` is the same knowledge written down by hand, one burned
/// pair at a time; this table learns it from the feeds.
///
/// Counts are per title (a token counted once per title however often it
/// repeats), halved whenever the title count reaches `cap`, so the table
/// follows the feeds' vocabulary as it drifts and stays bounded. Until it
/// has seen `matureAt` titles it answers nothing and the local test
/// stands. Kept in its own file next to state.json (`token-frequencies.json`):
/// it changes on every ingest and is far larger than the state.
struct TokenFrequencies: Codable, Equatable {
    /// Titles seen before the table's answers are trusted.
    static let matureAt = 5000.0
    /// Halve everything at this many titles: with ~400 new titles a day
    /// the table reflects the last two to four months.
    static let cap = 60_000.0
    /// A token in at most this share of titles is specific. The old
    /// local test came to 4 in ~900 (0.44 %); the long run is stricter,
    /// since one day's rare word is often a month's common one.
    static let specificRate = 0.003

    private(set) var titles: Double = 0
    private(set) var counts: [String: Double] = [:]

    var isMature: Bool { titles >= Self.matureAt }

    /// One title's distinct tokens and anchors (`TitleTokens.recorded`):
    /// an adjacent pair counts as a thing of its own, so "лекарите
    /// продължават" can be as common as either word.
    mutating func record(_ tokens: Set<String>) {
        titles += 1
        for token in tokens { counts[token, default: 0] += 1 }
        if titles >= Self.cap { decay() }
    }

    /// Halve every count; a token seen fewer than twice since the last
    /// halving drops out, which is what keeps the table from growing forever.
    mutating func decay() {
        titles /= 2
        counts = counts.compactMapValues { count in
            let half = count / 2
            return half >= 1 ? half : nil
        }
    }

    /// Share of titles carrying `token`, 0 when never seen.
    func rate(_ token: String) -> Double {
        titles > 0 ? (counts[token] ?? 0) / titles : 0
    }

    /// Whether `token` is rare in the long run; nil while the table is
    /// too young to say.
    func isRare(_ token: String) -> Bool? {
        isMature ? rate(token) <= Self.specificRate : nil
    }

    static func load(from url: URL) -> TokenFrequencies? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TokenFrequencies.self, from: data)
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
