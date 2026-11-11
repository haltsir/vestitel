import Foundation
import Testing
@testable import Vestitel

/// The long-run vocabulary and how the grouper's rarity test uses it.
struct TokenFrequenciesTests {

    private func article(_ title: String, minutesAgo: Int = 0) -> Article {
        Article(id: UUID().uuidString, feedID: UUID(), sourceTitle: "Dir.bg", title: title, link: nil,
                summary: nil, published: Date().addingTimeInterval(-Double(minutesAgo) * 60), fetchedAt: Date())
    }

    /// A mature table where `common` tokens are in a tenth of all titles
    /// and everything else is unseen.
    private func mature(common: Set<String>) -> TokenFrequencies {
        var table = TokenFrequencies()
        let n = Int(TokenFrequencies.matureAt)
        for i in 0..<n { table.record(i % 10 == 0 ? common : ["filler\(i)"]) }
        return table
    }

    @Test func ratesAreShareOfTitlesAndYoungTablesAbstain() {
        var table = TokenFrequencies()
        #expect(table.isRare("x") == nil && table.rate("x") == 0)
        table.record(["a", "b"])
        table.record(["a"])
        #expect(table.rate("a") == 1 && table.rate("b") == 0.5 && table.rate("c") == 0)
        #expect(table.isRare("c") == nil)   // 2 titles: too young to say
        let big = mature(common: ["бор"])
        #expect(big.isMature)
        #expect(big.isRare("бор") == false)
        #expect(big.isRare("гавриил") == true)
    }

    @Test func decayHalvesAndDropsSingletons() {
        var table = TokenFrequencies()
        table.record(["a", "once"])
        table.record(["a"])
        table.record(["a"])
        table.decay()
        #expect(table.titles == 1.5)
        #expect(table.counts["a"] == 1.5)
        #expect(table.counts["once"] == nil)
        #expect(table.rate("a") == 1)
    }

    @Test func roundTripsThroughItsFile() throws {
        var table = TokenFrequencies()
        table.record(["a", "b"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tf-\(UUID().uuidString).json")
        table.save(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TokenFrequencies.load(from: url) == table)
        #expect(TokenFrequencies.load(from: url.appendingPathExtension("missing")) == nil)
    }

    /// The pair that started this: three injured on Trakia and an ailing
    /// metropolitan share only the casualty report's stock words. With no
    /// table (or a young one) the inbox-local count calls them rare and
    /// links the pair; a table that has seen them daily does not.
    @Test @MainActor func longRunFrequenciesOverruleTheInboxLocalCount() {
        let a = article("Трима от пострадалите на магистралата остават в тежко положение, лекарите продължават")
        let b = article("Ловчанският митрополит е в критично положение, лекарите продължават усилията", minutesAgo: 5)
        let c = article("Левски победи ЦСКА", minutesAgo: 9)
        let tokens = TopicGrouper.tokens(a.title).recorded.intersection(TopicGrouper.tokens(b.title).recorded)
        #expect(tokens == ["положени", "лекар", "продължават", "положени лекар", "лекар продължават"])
        #expect(TopicGrouper.group([a, b, c], sensitivity: 0.5).count == 2)
        let young = TokenFrequencies()
        #expect(TopicGrouper.group([a, b, c], sensitivity: 0.5, frequencies: young).count == 2)
        let seasoned = mature(common: tokens)
        #expect(TopicGrouper.group([a, b, c], sensitivity: 0.5, frequencies: seasoned).count == 3)
        // a name the table has never seen is still specific: the link stands
        let named = mature(common: ["положени"])
        #expect(TopicGrouper.group([a, b, c], sensitivity: 0.5, frequencies: named).count == 2)
    }
}
