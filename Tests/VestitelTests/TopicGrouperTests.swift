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

    @Test @MainActor func threeCommonScatteredWordsDoNotLink() {
        // "нов", "план" and "София" each sit in many headlines: shared
        // between an office move and a transport loan they are noise,
        // and with none of them specific the three-word shortcut is off.
        var fillers: [Article] = []
        for i in 0..<4 {
            // each filler shares nothing with the others but the common word
            fillers.append(article("Нов ресторант\(i) отвори\(i) в квартал\(i)"))
            fillers.append(article("Кабинетът\(i) прие\(i) план за язовир\(i)"))
            fillers.append(article("В София засадиха\(i) дървета\(i) по булевард\(i)"))
        }
        let scattered = fillers + [
            article("Waracle се премести в нов офис в София, запазва плановете си за разрастване"),
            article("София поема дълг от 367 млн. евро за мащабен план за нов транспорт и булеварди"),
        ]
        let groups = TopicGrouper.group(scattered, sensitivity: 0.5)
        #expect(groups.allSatisfy { $0.articles.count == 1 })

        // An adjacent pair shared by both titles ("руски военни") pins
        // them to one story even when every shared word is common.
        var soldiers: [Article] = []
        for i in 0..<4 {
            soldiers.append(article("Руски кораб\(i) акостира\(i) в пристанище\(i)"))
            soldiers.append(article("Военни учения\(i) край полигон\(i) събраха\(i)"))
            soldiers.append(article("България подписа\(i) договор\(i) за мост\(i)"))
        }
        soldiers += [
            article("\"Алфа Метал\" отрича британски публикации: Не обучаваме руски военни в България"),
            article("\"Да, България\" пита службите обучавани ли са руски военни в България"),
        ]
        let linked = TopicGrouper.group(soldiers, sensitivity: 0.5).filter { $0.articles.count > 1 }
        #expect(linked.count == 1)
        #expect(linked.first?.articles.count == 2)
    }

    @Test @MainActor func rareSharedNamePlusOneWordLinks() {
        // Same person, one more shared word, wording too different for
        // Jaccard: the shared full name is what makes it one story.
        let obituary = [
            article("Първа версия за смъртта на Пресли Гербер, починал е от предполагаемо предозиране"),
            article("Свръхдоза е вероятната причина за смъртта на Пресли Гербер", minutesAgo: 5),
        ]
        #expect(TopicGrouper.group(obituary, sensitivity: 0.5).count == 1)

        // A name every match report carries ("US Open") is a rubric, not
        // a story: with it in more than a few titles the rule stays off.
        let tournament = [
            article("Александър Зверев спечели US Open и вече има две титли от Шлема"),
            article("Рибакина свали Сабаленка от трона и спечели US Open за първи път"),
            article("Пълна драма на US Open, шампионът бе детрониран посред нощ"),
            article("Нощ за историята на US Open, първи белгийски четвъртфиналист"),
            article("Спортът по телевизията: дербита, Левски, Барса и финал на US Open"),
        ]
        #expect(TopicGrouper.group(tournament, sensitivity: 0.5).count == 5)
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

    @Test @MainActor func rubricPrefixesAreDroppedButAttributionsKept() {
        let rubric = TopicGrouper.tokens("Бизнес глобус: Euronext е отворена за сделка с Deutsche Börse")
        #expect(!rubric.tokens.contains("бизнес"))
        #expect(!rubric.tokens.contains("глобус"))
        #expect(rubric.tokens.contains("euronext"))
        let speaker = TopicGrouper.tokens("Асен Василев: Йотова да се оттегли от надпреварата")
        #expect(speaker.tokens.contains("асен"))
        let single = TopicGrouper.tokens("Радев: В ГЕРБ има страх и объркване")
        #expect(single.tokens.contains("радев"))
        let score = TopicGrouper.tokens("Левски - ЦСКА 0:0, изненадващ титуляр")
        #expect(score.tokens.contains("левск"))
        // Digest columns of the same rubric no longer share anything
        let digests = [
            article("Бизнес глобус: Paramount обмисля да закрие SkyShowtime; Exein привлече 270 млн. долара"),
            article("Бизнес глобус: Дизелът в САЩ надхвърли 6 долара за галон; Microsoft утроява капацитета си", minutesAgo: 60),
        ]
        #expect(TopicGrouper.group(digests, sensitivity: 0.5).count == 2)
    }

    @Test @MainActor func headlineKeepsOnePlainWordNextToAName() {
        let articles = [
            article("От \"Да, България\" поискаха документи за петима помилвани наркотрафиканти"),
            article("\"Отговорът на Йотова не дава яснота\": \"Да, България\" ще иска всички документи за помилвания наркобос", minutesAgo: 60),
        ]
        let groups = TopicGrouper.group(articles, sensitivity: 0.5)
        #expect(groups.count == 1)
        #expect(groups.first?.headline == "„Да, България“ · документи")
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
        #expect(groups.first?.headline == "„Златен лъв“ · Woman Unknown")
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
