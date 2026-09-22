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
        struct Snapshot: Decodable { var articles: [Article] }
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
        for group in TopicGrouper.group(inbox, sensitivity: 0.5) where group.articles.count > 1 {
            print("=== [\(group.articles.count)] \(group.headline ?? "-")")
            for article in group.articles { print("   - \(article.title)") }
        }
    }
}
