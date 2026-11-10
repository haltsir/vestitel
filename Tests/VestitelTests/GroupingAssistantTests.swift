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
        {"assignments":[{"article":1,"title":"Депутатите гласуваха бюджета","group":1,"groupTitle":"Парламентът прие бюджета","headline":"Бюджет 2027 приет."}],
         "newGroups":[{"articles":[{"article":2,"title":"Shelly Group продадена"},{"article":3,"title":"Шнайдер Електрик купува"}],"headline":"Schneider купува Shelly"},
                      {"articles":[{"article":4,"title":"Времето утре"}],"headline":"lonely"},
                      {"articles":[{"article":9,"title":"x"},{"article":2,"title":"Shelly Group продадена"}],"headline":"out of range"}]}
        """
        let verdict = try GroupingAssistant.parse(response(answer: answer), stories: stories, arrivals: arrivals)
        #expect(verdict.assessed == ["a1", "a2", "a3", "a4"])
        #expect(verdict.mismatched == 0)
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

    @Test func reviewPromptNumbersSubjectsThenContext() {
        let prompt = GroupingAssistant.reviewPrompt(subjects: [stories[0]], context: [stories[1]])
        #expect(prompt.contains("Groups to review:\nG1 (Бюджет 2027):\n  1. Парламентът прие бюджета [Dir.bg]\n  2. Бюджет 2027 мина на второ четене [Mediapool]"))
        #expect(prompt.contains("Other recent groups (for merges only):\nG2:\n  1. Левски победи ЦСКА с 2:1 [Sportal]"))
        let body = try! JSONSerialization.jsonObject(with: GroupingAssistant.reviewRequestBody(subjects: [stories[0]], context: [])) as! [String: Any]
        #expect((body["system"] as? String)?.hasPrefix("You review story groups") == true)
    }

    @Test func parseReviewTurnsSplitsIntoExclusionsAndMergesIntoLinks() throws {
        let subjects = [
            GroupingAssistant.Story(ids: ["m1", "m2", "m3"], headline: "Мач", members: [("NFL opener", "ESPN"), ("Левски загуби", "Sportal"), ("Левски: първа загуба", "Dir.bg")]),
            GroupingAssistant.Story(ids: ["b1", "b2"], headline: "Бюджет", members: [("Бюджетът мина", "Dir.bg"), ("Приеха бюджета", "БНР")]),
        ]
        let context = [stories[0]]   // G3: s1, s2
        let answer = """
        {"splits":[{"group":1,"title":"NFL opener","stories":[[{"member":2,"title":"Левски загуби"},{"member":3,"title":"Левски: първа загуба"}]]},
                   {"group":2,"title":"Бюджетът мина","stories":[[{"member":1,"title":"Бюджетът мина"},{"member":2,"title":"Приеха бюджета"}]]},
                   {"group":3,"title":"Парламентът прие бюджета","stories":[[{"member":1,"title":"Парламентът прие бюджета"}]]},
                   {"group":9,"title":"x","stories":[[{"member":1,"title":"x"}]]}],
         "merges":[{"groups":[{"group":2,"title":"Бюджетът мина"},{"group":3,"title":"Парламентът прие"}],"headline":"Бюджет 2027 приет"},
                   {"groups":[{"group":1,"title":"NFL opener"}],"headline":"x"},
                   {"groups":[{"group":3,"title":"Парламентът прие"},{"group":2,"title":"Бюджетът мина"}],"headline":"dup"}]}
        """
        let verdict = try GroupingAssistant.parseReview(response(answer: answer), subjects: subjects, context: context)
        #expect(verdict.mismatched == 0)
        // G1: member 1 unlisted, so it stands apart from the story of 2 and 3
        #expect(verdict.hints.exclusions == [GroupingHints.key("m1", "m2"), GroupingHints.key("m1", "m3")])
        // G2 listing everyone as one story, G3 (context) and G9 are ignored
        #expect(verdict.splits == 1)
        // G2 and G3 become one story: first members linked, all labelled
        #expect(verdict.hints.links == [GroupingHints.key("b1", "s1")])
        #expect(verdict.hints.headlines == ["b1": "Бюджет 2027 приет", "b2": "Бюджет 2027 приет", "s1": "Бюджет 2027 приет", "s2": "Бюджет 2027 приет"])
        #expect(verdict.merges == 1)
        // the subjects as sent, plus what the split kept
        #expect(verdict.reviewed == [["m1", "m2", "m3"], ["b1", "b2"], ["m2", "m3"]])
    }

    /// The real case: the headline was about A3 but the number next to it
    /// said A4, and potatoes met a Volkswagen. The echoed title now catches
    /// the slip and the verdict is dropped, not applied.
    @Test func mismatchedTitleEchoDropsTheVerdict() throws {
        let answer = """
        {"assignments":[{"article":2,"title":"Депутатите гласуваха бюджета","group":1,"groupTitle":"Парламентът прие","headline":"wrong article number"},
                        {"article":1,"title":"Депутатите гласуваха","group":2,"groupTitle":"Парламентът прие","headline":"wrong group number"}],
         "newGroups":[{"articles":[{"article":3,"title":"Шнайдер Електрик купува"},{"article":4,"title":"Shelly Group продадена"}],"headline":"Schneider купува Shelly"}]}
        """
        let verdict = try GroupingAssistant.parse(response(answer: answer), stories: stories, arrivals: arrivals)
        #expect(verdict.hints.isEmpty)
        #expect(verdict.joined == 0 && verdict.formed == 0)
        #expect(verdict.mismatched == 3)
        #expect(verdict.assessed == ["a1", "a2", "a3", "a4"])

        let review = """
        {"splits":[{"group":1,"title":"Парламентът прие","stories":[[{"member":2,"title":"Парламентът прие бюджета"}]]}],
         "merges":[{"groups":[{"group":1,"title":"Парламентът прие"},{"group":2,"title":"Парламентът прие"}],"headline":"x"}]}
        """
        let reviewed = try GroupingAssistant.parseReview(response(answer: review), subjects: [stories[0]], context: [stories[1]])
        #expect(reviewed.hints.isEmpty && reviewed.splits == 0 && reviewed.merges == 0)
        #expect(reviewed.mismatched == 2)
        #expect(reviewed.reviewed == [["s1", "s2"]])
    }

    @Test func echoMatchesOnWordsOnly() {
        #expect(GroupingAssistant.echoMatches("„Да, България“ иска", "„Да, България“ иска оставка"))
        #expect(GroupingAssistant.echoMatches("volkswagen id3 neo", "Volkswagen ID.3 Neo е по-добър"))
        #expect(GroupingAssistant.echoMatches("Смачкайте картофите с чаша и ги сложете във фурната - резултатът е невероятен", "Смачкайте картофите с чаша и ги сложете във фурната - резултатът е невероятен"))
        #expect(!GroupingAssistant.echoMatches("Картофите стават хрупкави", "Смачкайте картофите с чаша"))
        #expect(!GroupingAssistant.echoMatches("", "Anything"))
        #expect(!GroupingAssistant.echoMatches(nil, "Anything"))
        #expect(!GroupingAssistant.echoMatches(3, "3 things"))
    }

    @Test func splitIsAPartitionOfTheGroup() throws {
        let subject = GroupingAssistant.Story(ids: ["t1", "t2", "t3", "t4", "t5"], headline: "x",
                                              members: [("Crash on Trakia", "A"), ("Von der Leyen in Varna", "B"), ("Trakia victims in hospital", "C"), ("Protest against von der Leyen", "D"), ("Spanish minister resigns", "E")])
        let answer = """
        {"splits":[{"group":1,"title":"Crash on Trakia","stories":[[{"member":1,"title":"Crash on Trakia"},{"member":3,"title":"Trakia victims"}],[{"member":2,"title":"Von der Leyen"},{"member":4,"title":"Protest against"}]]}],
         "merges":[]}
        """
        let verdict = try GroupingAssistant.parseReview(response(answer: answer), subjects: [subject], context: [])
        // every pair across stories, the unlisted t5 apart from all
        let k = GroupingHints.key
        #expect(verdict.hints.exclusions == [k("t1", "t2"), k("t1", "t4"), k("t3", "t2"), k("t3", "t4"),
                                             k("t1", "t5"), k("t2", "t5"), k("t3", "t5"), k("t4", "t5")])
        #expect(verdict.hints.links.isEmpty && verdict.splits == 1)
        #expect(verdict.reviewed == [["t1", "t2", "t3", "t4", "t5"], ["t1", "t3"], ["t2", "t4"]])
        // the first of the two equal stories keeps the label, the rest lose it
        #expect(verdict.hints.unlabelled == ["t2", "t4", "t5"])
        var stored = GroupingHints(headlines: ["t1": "x", "t2": "x", "t3": "x", "t4": "x", "t5": "x"])
        stored.merge(verdict.hints)
        #expect(stored.headlines == ["t1": "x", "t3": "x"])

        // one story holding everyone is no split
        let whole = """
        {"splits":[{"group":1,"title":"Crash on Trakia","stories":[[{"member":1,"title":"Crash on Trakia"},{"member":2,"title":"Von der Leyen"},{"member":3,"title":"Trakia victims"},{"member":4,"title":"Protest"},{"member":5,"title":"Spanish minister"}]]}],"merges":[]}
        """
        let none = try GroupingAssistant.parseReview(response(answer: whole), subjects: [subject], context: [])
        #expect(none.hints.isEmpty && none.splits == 0)
    }

    @Test func joiningALabelledStoryKeepsItsLabel() throws {
        var labelled = stories
        labelled[0].label = "Бюджет 2027"
        let answer = """
        {"assignments":[{"article":1,"title":"Депутатите гласуваха","group":1,"groupTitle":"Парламентът прие","headline":"Депутатите гласуваха"}],"newGroups":[]}
        """
        let verdict = try GroupingAssistant.parse(response(answer: answer), stories: labelled, arrivals: arrivals)
        #expect(verdict.hints.headlines == ["s1": "Бюджет 2027", "s2": "Бюджет 2027", "a1": "Бюджет 2027"])
    }

    @Test @MainActor func exclusionsHoldBetweenComponentsNotJustPairs() {
        // a, b, c are word-for-word the same headline: the heuristics link
        // every pair. Excluding a from c must keep them apart even though
        // b links to both.
        let a = article("z1", "Парламентът прие бюджета за 2027 на второ четене")
        let b = article("z2", "Парламентът прие бюджета за 2027 на второ четене", minutesAgo: 3)
        let c = article("z3", "Парламентът прие бюджета за 2027 на второ четене", minutesAgo: 6)
        #expect(TopicGrouper.group([a, b, c], sensitivity: 0.5).count == 1)
        var hints = GroupingHints()
        hints.exclude(GroupingHints.key("z1", "z3"))
        let groups = TopicGrouper.group([a, b, c], sensitivity: 0.5, hints: hints)
        let together = groups.first { $0.articles.count == 2 }?.articles.map(\.id).sorted()
        #expect(groups.count == 2 && together == ["z1", "z2"])
        // an assist link on the excluded pair itself still wins (newest verdict)
        hints.link(GroupingHints.key("z1", "z3"))
        #expect(TopicGrouper.group([a, b, c], sensitivity: 0.5, hints: hints).count == 1)
    }

    @Test func linkAndExclusionForOnePairCannotCoexist() {
        var hints = GroupingHints()
        hints.link("a|b")
        hints.exclude("a|b")
        #expect(hints.links.isEmpty && hints.exclusions == ["a|b"])
        hints.link("a|b")
        #expect(hints.exclusions.isEmpty && hints.links == ["a|b"])
        var other = GroupingHints(); other.exclude("a|b"); other.headlines["a"] = "h"
        hints.merge(other)
        #expect(hints.links.isEmpty && hints.exclusions == ["a|b"] && hints.headlines["a"] == "h")
    }

    @Test @MainActor func exclusionsKeepTheHeuristicsFromLinkingAPair() {
        let a = article("y1", "Парламентът прие бюджета за 2027 на второ четене")
        let b = article("y2", "Парламентът прие бюджета за 2027 на второ четене", minutesAgo: 3)
        let c = article("y3", "Левски победи ЦСКА", minutesAgo: 9)
        let plain = TopicGrouper.group([a, b, c], sensitivity: 0.5)
        #expect(plain.contains { $0.articles.map(\.id).sorted() == ["y1", "y2"] })

        var hints = GroupingHints()
        hints.exclude(GroupingHints.key("y1", "y2"))
        let split = TopicGrouper.group([a, b, c], sensitivity: 0.5, hints: hints)
        #expect(split.allSatisfy { $0.articles.count == 1 })
    }

    @Test func pruneDropsVerdictsAboutGoneArticles() {
        var hints = GroupingHints(links: [GroupingHints.key("a", "b"), GroupingHints.key("b", "c")],
                                  headlines: ["a": "h", "b": "h", "c": "h"],
                                  exclusions: [GroupingHints.key("a", "c"), GroupingHints.key("b", "a2")])
        hints.prune(keeping: ["a", "b", "a2"])
        #expect(hints.links == [GroupingHints.key("a", "b")])
        #expect(hints.exclusions == [GroupingHints.key("b", "a2")])
        #expect(hints.headlines == ["a": "h", "b": "h"])
        #expect(hints.headline(for: ["a", "b", "zz"]) == "h")
        #expect(GroupingHints().headline(for: ["a"]) == nil)
    }
}
