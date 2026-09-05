import Foundation
import Testing
@testable import Vestitel

/// Parsing of local events (drop-folder JSON and vestitel://add URLs), with
/// the focus on the optional `tag` / `symbol` pair.
struct LocalEventTests {

    private func event(_ json: String) -> LocalEvent? {
        LocalEvent.from(json: try! JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    @Test func tagAndSymbolArePreserved() {
        let e = event(#"{"source": "Ozonko", "title": "Kindle", "tag": "последни бройки", "symbol": "tag"}"#)
        #expect(e?.tag == "последни бройки")
        #expect(e?.symbol == "tag")
    }

    @Test func tagAndSymbolAreOptional() {
        let e = event(#"{"source": "Ozonko", "title": "Kindle"}"#)
        #expect(e != nil)
        #expect(e?.tag == nil)
        #expect(e?.symbol == nil)
    }

    @Test func emptyOrBlankTagIsAbsent() {
        #expect(event(#"{"source": "s", "title": "t", "tag": ""}"#)?.tag == nil)
        #expect(event(#"{"source": "s", "title": "t", "tag": "  \n"}"#)?.tag == nil)
        #expect(event(#"{"source": "s", "title": "t", "tag": " намаление "}"#)?.tag == "намаление")
    }

    @Test func tagIsCutAtTheLimit() {
        let long = String(repeating: "я", count: 60)
        let e = event(#"{"source": "s", "title": "t", "tag": "\#(long)"}"#)
        #expect(e?.tag?.count == LocalEvent.tagLimit)
        #expect(e?.tag == String(repeating: "я", count: LocalEvent.tagLimit))
        // exactly at the limit stays whole
        let exact = String(repeating: "a", count: LocalEvent.tagLimit)
        #expect(event(#"{"source": "s", "title": "t", "tag": "\#(exact)"}"#)?.tag == exact)
    }

    @Test func unknownSymbolIsDroppedButTagStays() {
        let e = event(#"{"source": "s", "title": "t", "tag": "promo", "symbol": "definitely.not.a.symbol"}"#)
        #expect(e?.tag == "promo")
        #expect(e?.symbol == nil)
    }

    @Test func symbolWithoutTagIsDropped() {
        let e = event(#"{"source": "s", "title": "t", "symbol": "tag"}"#)
        #expect(e != nil)
        #expect(e?.symbol == nil)
    }

    @Test func nonStringTagIsIgnored() {
        let e = event(#"{"source": "s", "title": "t", "tag": 42, "symbol": ["tag"]}"#)
        #expect(e != nil)
        #expect(e?.tag == nil)
        #expect(e?.symbol == nil)
    }

    @Test func urlTransportCarriesTagAndSymbol() {
        let url = URL(string: "vestitel://add?source=Ozonko&title=Kindle&tag=%D0%BD%D0%B0%D0%BC%D0%B0%D0%BB%D0%B5%D0%BD%D0%B8%D0%B5&symbol=arrow.down.circle")!
        let e = LocalEvent.from(url: url)
        #expect(e?.source == "Ozonko")
        #expect(e?.tag == "намаление")
        #expect(e?.symbol == "arrow.down.circle")
    }

    @Test func addURLRoundTrips() {
        let url = LocalEvent.addURL(source: "Ozonko", title: "Kindle back in stock",
                                    url: "https://example.com/kindle", tag: "back in stock", symbol: "clock")
        let e = url.flatMap(LocalEvent.from(url:))
        #expect(e?.title == "Kindle back in stock")
        #expect(e?.url?.absoluteString == "https://example.com/kindle")
        #expect(e?.tag == "back in stock")
        #expect(e?.symbol == "clock")
        // omitted companions stay out of the URL entirely
        let plain = LocalEvent.addURL(source: "s", title: "t", url: nil)?.absoluteString ?? ""
        #expect(!plain.contains("tag="))
        #expect(!plain.contains("symbol="))
    }

    @Test func eventsFileArrayKeepsTagsPerEvent() throws {
        let data = Data(#"""
        [{"source": "Ozonko", "title": "A", "tag": "last stock"},
         {"source": "Ozonko", "title": "B"}]
        """#.utf8)
        let events = try LocalEvent.events(fromFile: data)
        #expect(events.map(\.tag) == ["last stock", nil])
    }
}

/// State files written before `tag` / `symbol` existed must keep loading.
struct ArticleDecodingTests {

    private static let legacyJSON = #"""
    {"id": "https://example.com/feed#1", "feedID": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
     "sourceTitle": "Example", "title": "Old article", "summary": "Body",
     "published": 0, "fetchedAt": 0, "state": "inbox"}
    """#

    @Test func articleWithoutTagOrSymbolDecodes() throws {
        let article = try JSONDecoder().decode(Article.self, from: Data(Self.legacyJSON.utf8))
        #expect(article.title == "Old article")
        #expect(article.tag == nil)
        #expect(article.symbol == nil)
        #expect(article.state == .inbox)
    }

    @Test func tagAndSymbolRoundTripThroughCodable() throws {
        var article = try JSONDecoder().decode(Article.self, from: Data(Self.legacyJSON.utf8))
        article.tag = "намаление"
        article.symbol = "arrow.down.circle"
        let data = try JSONEncoder().encode(article)
        let back = try JSONDecoder().decode(Article.self, from: data)
        #expect(back.tag == "намаление")
        #expect(back.symbol == "arrow.down.circle")
        #expect(back == article)
    }
}
