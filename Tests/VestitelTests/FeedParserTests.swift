import Foundation
import Testing
@testable import Vestitel

@Suite("FeedParser")
struct FeedParserTests {

    /// boulevardbulgaria.bg ships media URLs with an unescaped apostrophe
    /// inside a single-quoted attribute; the parser repairs it and keeps
    /// the item, image included.
    @Test func repairsStrayApostropheInAttribute() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <title>Булевард България</title>
          <entry>
            <title>Джиро д'Италия: "финал" в Рим</title>
            <link rel='alternate' href='https://boulevardbulgaria.bg/articles/giro'/>
            <id>tag:boulevardbulgaria.bg,2026:1</id>
            <updated>2026-09-19T07:27:02Z</updated>
            <content type="html"><![CDATA[<p>It's a "quoted" <b>summary</b></p>]]></content>
            <media:content
                 url='https://boulevardbulgaria.bg/blobs/abc/Giro_d'Italia1_23_.jpg'
                 isDefault='true'
                 width='845' />
          </entry>
        </feed>
        """
        let parsed = try FeedParser.parse(data: Data(xml.utf8))
        #expect(parsed.title == "Булевард България")
        #expect(parsed.items.count == 1)
        let item = try #require(parsed.items.first)
        #expect(item.title == "Джиро д'Италия: \"финал\" в Рим")
        #expect(item.link?.absoluteString == "https://boulevardbulgaria.bg/articles/giro")
        #expect(item.imageURL?.absoluteString == "https://boulevardbulgaria.bg/blobs/abc/Giro_d'Italia1_23_.jpg")
    }

    @Test func repairLeavesWellFormedInputAlone() {
        let xml = """
        <rss version="2.0"><channel><title>T</title>
        <!-- a comment with a ' quote -->
        <item><title>It's fine</title><link>https://example.com/a?x='1'</link>
        <enclosure url="https://example.com/o'brien.jpg" type='image/jpeg'/>
        <description><![CDATA[<a href='x'>don't</a>]]></description></item>
        </channel></rss>
        """
        #expect(FeedParser.repairAttributeQuotes(in: Data(xml.utf8)) == nil)
    }

    @Test func repairEscapesOnlyTheStrayQuote() throws {
        let xml = "<a href='x' title='it's here' data-x=\"say \"hi\" now\"/>"
        let repaired = try #require(FeedParser.repairAttributeQuotes(in: Data(xml.utf8)))
        #expect(String(decoding: repaired, as: UTF8.self)
                == "<a href='x' title='it&apos;s here' data-x=\"say &quot;hi&quot; now\"/>")
    }

    @Test func repairSkipsNonUTF8() {
        let latin1 = Data([0x3C, 0x61, 0x20, 0x74, 0x3D, 0x27, 0x69, 0x74, 0x27, 0x73, 0x27, 0x2F, 0x3E, 0xE9])
        #expect(FeedParser.repairAttributeQuotes(in: latin1) == nil)
    }

    @Test func stillReportsUnrepairableFeeds() {
        let xml = "<rss><channel><title>Broken</title><item><title>x</item></channel></rss>"
        #expect(throws: FeedParser.ParseError.self) {
            try FeedParser.parse(data: Data(xml.utf8))
        }
    }
}

