import Foundation
import Testing
@testable import Vestitel

/// Group labels and the Bulgarian name-run tokenizer.
struct TopicGrouperTests {

    private func article(_ title: String, minutesAgo: Int = 0) -> Article {
        Article(id: UUID().uuidString, feedID: UUID(), sourceTitle: "Dir.bg", title: title, link: nil,
                summary: nil, published: Date().addingTimeInterval(-Double(minutesAgo) * 60), fetchedAt: Date())
    }

    @Test @MainActor func capitalisedRunsInCyrillicTitlesBecomeNamePhrases() {
        let t = TopicGrouper.tokens("Филмът Woman Unknown спечели „Златен лъв“ на кинофестивала във Венеция")
        #expect(t.names.contains("woman unknown"))
        #expect(t.quoted.contains("златен лъв"))
        // components stay in the set, as with English named entities
        #expect(t.tokens.contains("unknown"))
        // the sentence-initial Cyrillic word never starts a name run
        let lead = TopicGrouper.tokens("Матилд Арсел спечели купа")
        #expect(!lead.names.contains("матилд арсел"))
        let mid = TopicGrouper.tokens("Актрисата Матилд Арсел спечели купа")
        #expect(mid.names.contains("матилд арсел"))
    }

    @Test @MainActor func latinTitlesAreNotSplitIntoRuns() {
        let t = TopicGrouper.tokens("Woman Unknown Wins Golden Lion At Venice Film Festival")
        #expect(!t.names.contains("woman unknown wins golden lion"))
    }

    @Test @MainActor func headlinePrefersNamesOverVerbsInTitleOrder() {
        let articles = [
            article("Матилд Арсел спечели купа \"Волпи\" за най-добра актриса за отличения със \"Златен лъв\" филм Woman Unknown"),
            article("Филмът Woman Unknown спечели \"Златен лъв\" на кинофестивала във Венеция", minutesAgo: 60),
            article("Филмът Woman Unknown спечели \"Златен лъв\" на кинофестивала във Венеция", minutesAgo: 90),
        ]
        let groups = TopicGrouper.group(articles, sensitivity: 1)
        #expect(groups.count == 1)
        #expect(groups.first?.headline == "Златен лъв · Woman Unknown")
    }

    @Test @MainActor func headlineJoinsAdjacentCapitalisedPicks() {
        let articles = [
            article("Асен Василев: Илияна Йотова е помилвала втори наркодилър, рецидивист и част от ОПГ"),
            article("„Трябва да се оттегли“. ПП атакува Йотова за това, че е помилвала наркодилър през 2022", minutesAgo: 10),
            article("Асен Василев: Йотова да се оттегли от президентската надпревара, помилвала е наркодилър", minutesAgo: 20),
            article("Асен Василев поиска обяснение от Йотова за помилването на наркодилъра Огнян Атанасов", minutesAgo: 30),
        ]
        let groups = TopicGrouper.group(articles, sensitivity: 1)
        #expect(groups.count == 1)
        #expect(groups.first?.headline == "Асен Василев · Йотова")
    }
}
