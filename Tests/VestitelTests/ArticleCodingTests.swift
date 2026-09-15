import Foundation
import Testing
@testable import Vestitel

/// `restoredAt` was added in 1.21; state files and sync documents written
/// before it must keep decoding, and the stamp must round-trip.
struct ArticleCodingTests {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    @Test func articleWithoutRestoredAtDecodes() throws {
        let json = """
        {"id":"a","feedID":"73B19213-175A-4286-8546-3A2DEA6EC0E5","sourceTitle":"Dir.bg","title":"Паста в червено",
         "published":"2026-09-15T12:14:42Z","fetchedAt":"2026-09-15T12:18:12Z","state":"cleared","clearedAt":"2026-09-15T20:13:16Z"}
        """
        let article = try Self.decoder.decode(Article.self, from: Data(json.utf8))
        #expect(article.state == .cleared)
        #expect(article.restoredAt == nil)
    }

    @Test func restoredAtRoundTrips() throws {
        var article = Article(id: "a", feedID: UUID(), sourceTitle: "Dir.bg", title: "Паста в червено", link: nil,
                              summary: nil, published: Date(), fetchedAt: Date())
        article.restoredAt = Date(timeIntervalSince1970: 1_789_500_000)
        let data = try Self.encoder.encode(article)
        let back = try Self.decoder.decode(Article.self, from: data)
        #expect(back.restoredAt == article.restoredAt)
    }
}
