import Foundation
import Testing
@testable import Vestitel

/// Replays a real inbox through the grouper and prints every multi-member
/// group, for judging a grouping change against live headlines:
///
///     VESTITEL_REPLAY=state.json swift test --filter GroupingReplay | grep -E "^===|^   -"
///
/// Capture the output before and after the change and diff the two. A
/// no-op without the variable, so the normal test run is unaffected.
@Suite("Grouping replay") struct GroupingReplay {
    @Test func replay() throws {
        guard let path = ProcessInfo.processInfo.environment["VESTITEL_REPLAY"] else { return }
        // aiLinks/aiHeadlines: the Claude assist's stored verdicts, replayed
        // too when present so the output matches what the app shows
        // (VESTITEL_REPLAY_HINTS=0 replays the heuristics alone).
        struct Snapshot: Decodable { var articles: [Article]; var aiLinks: [String]?; var aiHeadlines: [String: String]?; var aiExclusions: [String]? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let inbox = snapshot.articles.filter { $0.state == .inbox }.sorted { $0.published > $1.published }
        if let needle = ProcessInfo.processInfo.environment["VESTITEL_TOKENS"] {
            for article in inbox where article.title.contains(needle) {
                let t = TopicGrouper.tokens(article.title)
                print("TOK \(article.title)\n    tokens=\(t.tokens.sorted()) names=\(t.names.sorted()) anchors=\(t.anchors.sorted())")
            }
        }
        if let needle = ProcessInfo.processInfo.environment["VESTITEL_LINKS"] {
            TopicGrouper.trace = { a, b, why in
                if a.contains(needle) || b.contains(needle) { print("LINK \(a)\n  <> \(b)\n     \(why)") }
            }
        }
        var hints = GroupingHints()
        if ProcessInfo.processInfo.environment["VESTITEL_REPLAY_HINTS"] != "0" {
            hints = GroupingHints(links: Set(snapshot.aiLinks ?? []), headlines: snapshot.aiHeadlines ?? [:],
                                  exclusions: Set(snapshot.aiExclusions ?? []))
            if !hints.isEmpty { print("HINTS \(hints.links.count) links, \(hints.exclusions.count) exclusions, \(hints.headlines.count) headlines") }
        }
        // VESTITEL_FREQUENCIES=<token-frequencies.json>: the app's long-run
        // vocabulary, so the rarity test runs as it does in the app
        var frequencies: TokenFrequencies?
        if let path = ProcessInfo.processInfo.environment["VESTITEL_FREQUENCIES"] {
            frequencies = TokenFrequencies.load(from: URL(fileURLWithPath: path))
            print("FREQUENCIES \(Int(frequencies?.titles ?? 0)) titles, mature: \(frequencies?.isMature ?? false)")
        }
        for group in TopicGrouper.group(inbox, sensitivity: 0.5, hints: hints, frequencies: frequencies) where group.articles.count > 1 {
            print("=== [\(group.articles.count)] \(group.headline ?? "-")")
            for article in group.articles { print("   - \(article.title)") }
        }
    }
}
