import Foundation
import Testing
@testable import Vestitel

/// The Claude grouping assist: prompt shape, answer parsing, and how its
/// hints enter the grouper. No network: answers are canned API responses.
struct GroupingAssistantTests {

    private func article(_ id: String, _ title: String, summary: String? = nil, minutesAgo: Int = 0) -> Article {
        Article(id: id, feedID: UUID(), sourceTitle: "Dir.bg", title: title, link: nil,
                summary: summary, published: Date().addingTimeInterval(-Double(minutesAgo) * 60), fetchedAt: Date())
    }

    private let stories = [
        GroupingAssistant.Story(ids: ["s1", "s2"], headline: "Бюджет 2027",
                                members: [("Парламентът прие бюджета", "Dir.bg"), ("Бюджет 2027 мина на второ четене", "Mediapool")]),
        GroupingAssistant.Story(ids: ["s3"], headline: nil, members: [("Левски победи ЦСКА с 2:1", "Sportal")]),
    ]
    private let arrivals = [
        GroupingAssistant.Arrival(id: "a1", title: "Депутатите гласуваха бюджета", source: "БНР", summary: "Line one.\nLine two."),
        GroupingAssistant.Arrival(id: "a2", title: "Shelly Group продадена на Schneider", source: "Capital", summary: nil),
        GroupingAssistant.Arrival(id: "a3", title: "Шнайдер Електрик купува Шели", source: "Dir.bg", summary: nil),
        GroupingAssistant.Arrival(id: "a4", title: "Времето утре: слънчево", source: "Dir.bg", summary: nil),
    ]

    private func response(stopReason: String = "end_turn", answer: String) -> Data {
        let json: [String: Any] = [
            "stop_reason": stopReason,
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": answer]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func promptNumbersStoriesAndArrivals() {
        let prompt = GroupingAssistant.prompt(stories: stories, arrivals: arrivals)
        #expect(prompt.contains("G1 (Бюджет 2027):\n  - Парламентът прие бюджета [Dir.bg]"))
        #expect(prompt.contains("G2:\n  - Левски победи ЦСКА с 2:1 [Sportal]"))
        #expect(prompt.contains("A1: Депутатите гласуваха бюджета [БНР]\n    Line one. Line two."))
        #expect(prompt.contains("A4: Времето утре: слънчево [Dir.bg]"))
    }

    @Test func requestIsStructuredLowEffortHaiku() throws {
        let body = try #require(JSONSerialization.jsonObject(with: GroupingAssistant.requestBody(stories: stories, arrivals: arrivals)) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "low")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect(body["temperature"] == nil)
    }

    @Test func parseTurnsAssignmentsAndNewGroupsIntoHints() throws {
        let answer = """
        {"assignments":[{"article":1,"group":1,"headline":"Бюджет 2027 приет."}],
         "newGroups":[{"articles":[2,3],"headline":"Schneider купува Shelly"},
                      {"articles":[4],"headline":"lonely"},
                      {"articles":[9,2],"headline":"out of range"}]}
        """
        let verdict = try GroupingAssistant.parse(response(answer: answer), stories: stories, arrivals: arrivals)
        #expect(verdict.assessed == ["a1", "a2", "a3", "a4"])
        #expect(verdict.hints.links == [GroupingHints.key("a1", "s1"), GroupingHints.key("a2", "a3")])
        // the whole joined story carries the headline, trailing punctuation dropped
        #expect(verdict.hints.headlines["s1"] == "Бюджет 2027 приет")
        #expect(verdict.hints.headlines["s2"] == "Бюджет 2027 приет")
        #expect(verdict.hints.headlines["a1"] == "Бюджет 2027 приет")
        #expect(verdict.hints.headlines["a2"] == "Schneider купува Shelly")
        #expect(verdict.hints.headlines["a4"] == nil)
        #expect(verdict.joined == 1)
        #expect(verdict.formed == 1)
    }

    @Test func refusalAndTruncationAreErrors() {
        #expect(throws: GroupingAssistant.AssistError.refused) {
            try GroupingAssistant.parse(response(stopReason: "refusal", answer: ""), stories: stories, arrivals: arrivals)
        }
        #expect(throws: GroupingAssistant.AssistError.truncated) {
            try GroupingAssistant.parse(response(stopReason: "max_tokens", answer: "{\"assign"), stories: stories, arrivals: arrivals)
        }
        #expect(throws: GroupingAssistant.AssistError.badResponse) {
            try GroupingAssistant.parse(Data("not json".utf8), stories: stories, arrivals: arrivals)
        }
        #expect(GroupingAssistant.errorMessage(in: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)) == "invalid x-api-key")
    }

    @Test @MainActor func hintsLinkArticlesTheHeuristicsNeverWould() {
        let a = article("x1", "Shelly Group продадена на Schneider Electric")
        let b = article("x2", "Времето утре: слънчево и топло", minutesAgo: 5)
        let c = article("x3", "Левски победи ЦСКА", minutesAgo: 9)
        let plain = TopicGrouper.group([a, b, c], sensitivity: 0.5)
        #expect(plain.allSatisfy { $0.articles.count == 1 })

        var hints = GroupingHints()
        hints.links.insert(GroupingHints.key("x1", "x2"))
        hints.headlines["x1"] = "Shelly и времето"
        hints.headlines["x2"] = "Shelly и времето"
        let grouped = TopicGrouper.group([a, b, c], sensitivity: 0.5, hints: hints)
        let pair = grouped.first { $0.articles.count == 2 }
        #expect(pair?.articles.map(\.id).sorted() == ["x1", "x2"])
        #expect(pair?.headline == "Shelly и времето")
        #expect(grouped.count == 2)
    }

    @Test func pruneDropsVerdictsAboutGoneArticles() {
        var hints = GroupingHints(links: [GroupingHints.key("a", "b"), GroupingHints.key("b", "c")],
                                  headlines: ["a": "h", "b": "h", "c": "h"])
        hints.prune(keeping: ["a", "b"])
        #expect(hints.links == [GroupingHints.key("a", "b")])
        #expect(hints.headlines == ["a": "h", "b": "h"])
        #expect(hints.headline(for: ["a", "b", "zz"]) == "h")
        #expect(GroupingHints().headline(for: ["a"]) == nil)
    }
}
