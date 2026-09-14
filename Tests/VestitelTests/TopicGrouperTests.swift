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
        // phrase tokens are stemmed word by word ("златен" → "златн")
        #expect(t.quoted.contains("златн лъв"))
        // components stay in the set, as with English named entities
        #expect(t.tokens.contains("unknown"))
        // the sentence-initial Cyrillic word never starts a name run
        let lead = TopicGrouper.tokens("Матилд Арсел спечели купа")
        #expect(!lead.names.contains("матилд арсел"))
        let mid = TopicGrouper.tokens("Актрисата Матилд Арсел спечели купа")
        #expect(mid.names.contains("матилд арсел"))
    }

    @Test @MainActor func genericSharedWordsAloneDoNotLink() {
        // Scoreboard words (точки, първа, сезона) are stopwords: two
        // unrelated sports stories from the same day share nothing else.
        let articles = [
            article("96 точки! НФЛ регистрира най-резултатния откриващ мач в първата неделя от сезона"),
            article("\"Левски\" с първа грешна стъпка за сезона, загуби точки във Враца", minutesAgo: 780),
        ]
        #expect(TopicGrouper.group(articles, sensitivity: 0.5).count == 2)
        // Three shared topical words still link, even though the wording
        // differs too much for the Jaccard path.
        let anchored = [
            article("Лавина уби най-малко 11 алпинисти в Северен Кавказ, издирват още шестима туристи"),
            article("Спасители откриха телата на алпинисти след лавина в Кавказ, търсенето продължава", minutesAgo: 60),
        ]
        #expect(TopicGrouper.group(anchored, sensitivity: 0.5).count == 1)
    }

    @Test @MainActor func stemmerFoldsInflections() {
        for (forms, stem) in [
            (["точки", "точка", "точките"], "точк"),
            (["хусите", "хуси"], "хуси"),
            (["сезона", "сезонът", "сезон"], "сезон"),
            (["градът", "градове", "града"], "град"),
            (["наркодилър", "наркодилъра"], "наркодилр"),
            (["детската", "детска"], "детск"),
        ] {
            for form in forms { #expect(TopicGrouper.stem(form) == stem, "\(form)") }
        }
        // short words, Latin words and compounds with digits are untouched
        #expect(TopicGrouper.stem("май") == "май")
        #expect(TopicGrouper.stem("iphone") == "iphone")
        #expect(TopicGrouper.stem("22-годишна") == "22-годишна")
    }

    @Test @MainActor func inflectedTitlesLink() {
        let articles = [
            article("Издирват паднал делтапарапланерист край връх Голям Кадемлия"),
            article("Падналият парапланерист край връх Голям Кадемлия е загинал", minutesAgo: 60),
        ]
        #expect(TopicGrouper.group(articles, sensitivity: 0.5).count == 1)
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
