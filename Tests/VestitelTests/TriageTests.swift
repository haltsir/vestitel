import Foundation
import Testing
@testable import Vestitel

@MainActor @Suite struct TriageTests {
    private let feed = UUID()

    private func article(_ id: String, _ link: String?, feed: UUID? = nil, minutesAgo: Int = 0) -> Article {
        Article(id: id, feedID: feed ?? self.feed, sourceTitle: "Dir.bg", title: id, link: link.flatMap(URL.init(string:)),
                summary: nil, published: Date().addingTimeInterval(-Double(minutesAgo) * 60), fetchedAt: Date())
    }

    @Test func sectionKeyIsHostAndFirstSegment() {
        func key(_ s: String) -> String? { Sections.key(for: URL(string: s)) }
        #expect(key("https://corner.dir.bg/futbol/ludogorets-s-istoricheski-perdah") == "corner.dir.bg/futbol")
        #expect(key("https://www.capital.bg/biznes/imoti/2026/10/13/4960241_cenite/?ref=rss") == "capital.bg/biznes")
        #expect(key("https://svobodnatochka.bg/novini/ungariya-otmeni/") == "svobodnatochka.bg/novini")
        // nothing but the article itself, or not a web link
        #expect(key("https://www.microids.com/k-pop-rising/") == nil)
        #expect(key("svlachishte://torrent/c726e8ead800") == nil)
        #expect(Sections.key(for: nil) == nil)
        #expect(Sections.slugLabel("business.dir.bg/energien-pazar") == "Energien pazar")
    }

    @Test func categoryNamesASectionOnlyWhenItIsText() {
        #expect(Sections.cleanCategory(" Футбол ") == "Футбол")
        #expect(Sections.cleanCategory("2274") == nil)
        #expect(Sections.cleanCategory("") == nil && Sections.cleanCategory(nil) == nil)
    }

    @Test func parserReadsTheFirstCategory() throws {
        let rss = """
        <rss version="2.0"><channel><title>T</title>
        <item><title>A</title><category>Тенис</category><category>Спорт</category><link>https://corner.dir.bg/tenis/a</link></item>
        <item><title>B</title><link>https://corner.dir.bg/tenis/b</link></item>
        </channel></rss>
        """
        let items = try FeedParser.parse(data: Data(rss.utf8)).items
        #expect(items.map(\.category) == ["Тенис", nil])
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>
        <entry><title>A</title><id>1</id><category term="news" label="Новини"/><link href="https://x.bg/novini/a"/></entry>
        <entry><title>B</title><id>2</id><category term="news"/><link href="https://x.bg/novini/b"/></entry>
        </feed>
        """
        #expect(try FeedParser.parse(data: Data(atom.utf8)).items.map(\.category) == ["Новини", "news"])
    }

    @Test func aFeedSplitsIntoItsLargeSections() {
        var articles: [Article] = []
        for n in 0..<7 { articles.append(article("f\(n)", "https://corner.dir.bg/futbol/f\(n)")) }
        for n in 0..<5 { articles.append(article("p\(n)", "https://dnes.dir.bg/politika/p\(n)")) }
        for n in 0..<2 { articles.append(article("r\(n)", "https://vkusotii.dir.bg/retsepti/r\(n)")) }
        articles.append(article("bare", "https://dir.bg/bare"))
        // newest first overall, politics leading
        articles.swapAt(0, 7)
        let groups = AppStore.sourceGroups(articles, labels: ["corner.dir.bg/futbol": "Футбол"])
        #expect(groups.map(\.headline) == ["Dir.bg · Футбол", "Dir.bg · Politika", "Dir.bg · Other"])
        #expect(groups.map(\.articles.count) == [7, 5, 3])
        #expect(groups.map(\.id) == ["source|\(feed.uuidString)|corner.dir.bg/futbol",
                                     "source|\(feed.uuidString)|dnes.dir.bg/politika",
                                     "source|\(feed.uuidString)|"])
        #expect(groups.allSatisfy { $0.sourceFeedID == feed })
        #expect(Set(groups[2].articles.map(\.id)) == ["r0", "r1", "bare"])
    }

    @Test func sectionsSharingANameShowTheirSubdomain() {
        var articles = (0..<6).map { article("a\($0)", "https://auto.dir.bg/novini/a\($0)") }
        articles += (0..<5).map { article("t\($0)", "https://trip.dir.bg/novini/t\($0)") }
        articles += (0..<5).map { article("f\($0)", "https://corner.dir.bg/futbol/f\($0)") }
        let labels = ["auto.dir.bg/novini": "Новини", "trip.dir.bg/novini": "Новини", "corner.dir.bg/futbol": "Футбол"]
        #expect(AppStore.sourceGroups(articles, labels: labels).map(\.headline)
                == ["Dir.bg · Новини (auto)", "Dir.bg · Новини (trip)", "Dir.bg · Футбол"])
    }

    @Test func aFeedWithOneSectionStaysOneBlock() {
        let other = UUID()
        var articles = (0..<9).map { article("b\($0)", "https://boulevardbulgaria.bg/articles/b\($0)", feed: other) }
        // small sections only: not worth blocks of their own
        articles += (0..<3).map { article("s\($0)", "https://svobodnatochka.bg/novini/s\($0)") }
        articles += (0..<2).map { article("i\($0)", "https://svobodnatochka.bg/istorii/i\($0)") }
        let groups = AppStore.sourceGroups(articles)
        #expect(groups.map(\.id) == ["source|\(other.uuidString)", "source|\(feed.uuidString)"])
        #expect(groups.map(\.articles.count) == [9, 5])
    }

    private func group(_ ids: [String], source: Bool = false) -> TopicGroup {
        TopicGroup(id: source ? "source|x" : ids.sorted().joined(separator: "|"), headline: "h",
                   articles: ids.map { article($0, nil) }, sourceFeedID: source ? feed : nil)
    }

    @Test func itemsFollowTheListAsDrawn() {
        let groups = [group(["a"]), group(["b", "c"]), group(["d"], source: true)]
        let open = TriageItem.items(groups: groups, collapsed: [])
        #expect(open.map(\.cursor) == ["a", "group:b|c", "b", "c", "group:source|x", "d"])
        let folded = TriageItem.items(groups: groups, collapsed: ["b|c"])
        #expect(folded.map(\.cursor) == ["a", "group:b|c", "group:source|x", "d"])
    }

    @Test func cursorMovesOnToWhatTookTheClearedItemsPlace() {
        let before = TriageItem.items(groups: [group(["a"]), group(["b", "c", "d"]), group(["e"])], collapsed: [])
        // "b" cleared: the group is now c|d under a new id
        var after = TriageItem.items(groups: [group(["a"]), group(["c", "d"]), group(["e"])], collapsed: [])
        #expect(TriageItem.successor(of: 2, in: before, now: after) == "c")
        // the header itself cleared: on to the next row
        after = TriageItem.items(groups: [group(["a"]), group(["e"])], collapsed: [])
        #expect(TriageItem.successor(of: 1, in: before, now: after) == "e")
        // the last row cleared: back to the one before
        after = TriageItem.items(groups: [group(["a"]), group(["b", "c", "d"])], collapsed: [])
        #expect(TriageItem.successor(of: 5, in: before, now: after) == "d")
        // "a" cleared with the cursor on it and the next group's id unchanged
        after = TriageItem.items(groups: [group(["b", "c", "d"]), group(["e"])], collapsed: [])
        #expect(TriageItem.successor(of: 0, in: before, now: after) == "group:b|c|d")
        // a pair losing a member is a lone row: its old header resolves to the survivor
        let pair = TriageItem.items(groups: [group(["a"]), group(["b", "c"])], collapsed: ["b|c"])
        after = TriageItem.items(groups: [group(["b"])], collapsed: [])
        #expect(TriageItem.successor(of: 0, in: pair, now: after) == "b")
        #expect(TriageItem.successor(of: 0, in: [.article(id: "a", groupID: nil)], now: []) == nil)
    }
}
