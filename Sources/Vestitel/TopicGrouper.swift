import Foundation
import NaturalLanguage

/// Groups articles about the same topic across sources.
///
/// Two signals, either can link a pair of articles:
///  1. Keyword overlap (Jaccard over significant title tokens) — cheap, precise.
///  2. NaturalLanguage sentence-embedding cosine distance — catches paraphrased
///     headlines; gated on sharing at least one significant token to avoid
///     grouping merely same-genre stories.
/// Linked pairs are merged with union-find.
enum TopicGrouper {

    /// Words too generic to link two stories (words under 3 characters are
    /// dropped before this check, so short glue like "за"/"на"/"of" never
    /// reaches it). English + Bulgarian.
    private static let stopwords: Set<String> = [
        // English: function words
        "the", "and", "for", "with", "that", "this", "from", "have", "has",
        "was", "are", "will", "you", "your", "its", "his", "her", "their",
        "but", "not", "all", "can", "how", "why", "what", "when", "who",
        "new", "says", "said", "after", "into", "over", "out", "about",
        "more", "than", "just", "now", "get", "gets", "here", "there",
        "one", "two", "amid", "may", "could", "would", "should", "been",
        "off", "our", "were", "via", "per", "top", "big",
        "also", "some", "any", "other", "others", "another", "only", "even",
        "ever", "never", "must", "might", "being", "does", "did", "doing",
        "done", "had", "having", "because", "while", "where", "which",
        "whose", "them", "they", "then", "these", "those", "still", "back",
        "again", "against", "during", "between", "around", "through",
        "under", "without", "within", "among", "before", "behind",
        "despite", "due", "since", "until", "toward", "towards", "onto",
        "above", "below", "across", "along", "beyond", "near", "upon",
        "inside", "outside", "beside", "besides", "throughout", "amidst",
        "each", "every", "both", "either", "neither", "although", "though",
        "whether",
        "very", "much", "many", "few", "own", "several", "first", "last",
        "next", "best", "worst", "most", "least", "old", "major",
        "everything", "anything", "nothing", "something", "everyone",
        "anyone", "someone",
        // English: generic verbs
        "make", "makes", "made", "making", "take", "takes", "took", "taken",
        "see", "seen", "look", "looks", "say", "saying", "tell", "tells",
        "told", "show", "shows", "showed", "shown", "announced",
        "announces", "reveals", "revealed",
        // English: news-rubric and quantity noise
        "video", "videos", "photo", "photos", "watch", "live", "news",
        "breaking", "report", "reports", "reported", "latest", "update",
        "updates", "updated", "exclusive", "opinion", "analysis",
        "explained", "million", "billion", "millions", "billions", "percent",
        "year", "years", "day", "days", "week", "weeks", "month", "months",
        "today", "tomorrow", "yesterday", "tonight", "people", "man",
        "woman", "men", "women", "way", "ways", "thing", "things",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december",
        "including", "dozens", "hundreds", "thousands", "together",
        // Bulgarian: prepositions and conjunctions
        "без", "във", "със", "като", "ако", "или", "нито", "обаче",
        "затова", "защото", "защо", "докато", "след", "преди", "между",
        "върху", "около", "срещу", "заради", "против", "чрез", "освен",
        "според", "въпреки", "относно", "покрай", "тъй", "пък", "ето",
        "най", "през", "включително", "към", "при", "над", "под", "пред",
        "зад", "сред",
        // Bulgarian: pronouns and demonstratives
        "това", "тази", "този", "тези", "онзи", "онази", "онова", "онези",
        "какво", "каква", "какви", "какъв", "кой", "коя", "кое", "кои",
        "кого", "който", "която", "което", "които", "всичко", "всички",
        "всеки", "всяка", "всяко", "него", "нея", "тях", "нас", "вас",
        "ние", "вие", "той", "нещо", "някой", "някоя", "някои", "нищо",
        "никой", "сам", "сама", "само", "себе", "свой", "своя", "свои",
        // Bulgarian: adverbs
        "още", "вече", "също", "дори", "пак", "там", "тук", "къде",
        "кога", "как", "така", "тогава", "сега", "днес", "утре", "вчера",
        "снощи", "много", "малко", "повече", "почти", "живо",
        // Bulgarian: generic verbs
        "има", "имат", "няма", "нямат", "беше", "бяха", "бъде", "бъдат",
        "били", "било", "била", "бил", "съм", "сме", "сте", "иска",
        "искат", "може", "могат", "можем", "трябва", "трябвало", "става",
        "стават", "стана", "станала", "станало", "станаха", "случва",
        "случват", "случи", "случило", "прави", "правят", "направи",
        "каза", "казва", "казват", "казаха", "заяви", "заявиха", "съобщи",
        "съобщиха", "съобщава", "обяви", "обявиха", "обявява", "разкри",
        "разкриха", "разкрива", "показа", "показва", "показват",
        "показаха", "дойде", "идва", "идват", "вижте", "гледайте",
        "очаква", "очакват", "излезе", "излиза", "дава", "дават", "даде",
        "получи", "получава",
        // Bulgarian: news-rubric and quantity noise
        "видео", "снимки", "снимка", "новини", "новина", "нови", "новият",
        "новия", "новите", "нова", "ново", "млн", "млрд", "хил",
        "души", "човек", "хора",
        "жена", "жени", "мъж", "мъже", "година", "години", "годишен",
        "годишна", "ден", "дни", "седмица", "седмици", "месец", "месеца",
        "месеци", "час", "часа", "часът", "минути", "процент", "процента",
        "хиляди", "милиона", "милиони", "милиарда", "милиарди", "брой",
        "част", "път", "пъти", "коментар", "анализ", "мнение", "интервю",
        "официално", "десетки", "стотици", "заедно",
        // Bulgarian: months
        "януари", "февруари", "март", "април", "май", "юни", "юли",
        "август", "септември", "октомври", "ноември", "декември",
    ]

    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// Sentence embeddings are expensive (~ms each); memoize per title so a
    /// regroup only pays for titles it hasn't seen. Main-thread only.
    private static var vectorCache: [String: [Double]?] = [:]

    private static func vector(for title: String) -> [Double]? {
        let key = title.lowercased()
        if let cached = vectorCache[key] { return cached }
        if vectorCache.count > 2000 { vectorCache.removeAll() }
        // The English model maps text it can't represent (Cyrillic above
        // all) to near-identical vectors, so without this gate any two
        // Bulgarian titles measure as "semantically the same story".
        let v = isLikelyEnglish(title) ? embedding?.vector(for: key) : nil
        vectorCache[key] = v
        return v
    }

    private static func isLikelyEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english
    }

    /// Quote pairs whose content becomes a single token: Bulgarian „…“,
    /// curly “…”, guillemets «…», straight "…". (No apostrophes — they'd
    /// swallow contractions.)
    private static let quotePairs: [(open: String, close: String)] = [
        ("„", "“"), ("“", "”"), ("«", "»"), ("\u{22}", "\u{22}"),
    ]

    /// A title's keyword set, with the multi-word phrase tokens called out by
    /// origin — quoted phrases and named entities weigh differently in
    /// group(). Both subsets contain only space-joined phrases; single words
    /// are indistinguishable from ordinary tokens on purpose.
    struct TitleTokens {
        var tokens: Set<String> = []
        var quoted: Set<String> = []
        var names: Set<String> = []
    }

    /// The name tagger is model-backed and not free; memoize like vectors.
    /// Main-thread only.
    private static var tokenCache: [String: TitleTokens] = [:]

    static func tokens(_ title: String) -> TitleTokens {
        if let cached = tokenCache[title] { return cached }
        if tokenCache.count > 2000 { tokenCache.removeAll() }
        var result = TitleTokens()
        // Original case, not lowercased: the name tagger keys on capitals.
        var remainder = title

        // Quoted text is one keyword: „Има такъв народ“ should link titles
        // quoting the same name, not leak its individual (often generic)
        // words into the keyword set.
        for (open, close) in quotePairs {
            while let openRange = remainder.range(of: open),
                  let closeRange = remainder.range(
                    of: close, range: openRange.upperBound..<remainder.endIndex) {
                let words = words(in: remainder[openRange.upperBound..<closeRange.lowerBound])
                remainder.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                if words.count > 1 {
                    let phrase = words.joined(separator: " ").lowercased()
                    if phrase.count >= 3 {
                        result.tokens.insert(phrase)
                        result.quoted.insert(phrase)
                    }
                } else if let word = words.first {
                    insertWord(word, into: &result.tokens)
                }
            }
        }

        // Multi-word proper names ("South Korea", "Boris Johnson") become one
        // phrase token so a shared name reads as one shared thing, not two.
        // Their component words still enter the set individually — "Trump" in
        // one title must keep matching "Donald Trump" in another.
        for name in namePhrases(in: remainder) {
            result.tokens.insert(name)
            result.names.insert(name)
        }
        for word in words(in: remainder[...]) {
            insertWord(word, into: &result.tokens)
        }
        tokenCache[title] = result
        return result
    }

    private static let nameTagger = NLTagger(tagSchemes: [.nameType])

    /// Multi-word named entities (people, places, organizations), lowercased
    /// and space-joined. English-only in practice — the nameType scheme has
    /// no Bulgarian model, so Bulgarian titles simply return nothing.
    private static func namePhrases(in text: String) -> [String] {
        guard text.contains(where: \.isUppercase) else { return [] }
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]
        nameTagger.string = text
        var phrases: [String] = []
        nameTagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if let tag, nameTags.contains(tag) {
                let words = words(in: text[range]).map { $0.lowercased() }
                if words.count > 1 {
                    phrases.append(words.joined(separator: " "))
                }
            }
            return true
        }
        return phrases
    }

    private static func words(in text: Substring) -> [String] {
        text.unicodeScalars
            .split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
            .map { String(String.UnicodeScalarView($0)) }
    }

    private static func insertWord(_ word: String, into result: inout Set<String>) {
        let word = word.lowercased()
        if word.count >= 3, !stopwords.contains(word), Int(word) == nil {
            result.insert(word)
        }
    }

    static func group(_ articles: [Article], sensitivity: Double) -> [TopicGroup] {
        guard articles.count > 1 else {
            return articles.map { singleton($0) }
        }

        let tokenSets = articles.map { tokens($0.title) }
        // sensitivity 0..1 maps to: jaccard threshold 0.6..0.3, embedding distance 0.55..0.95
        let jaccardThreshold = 0.6 - 0.3 * sensitivity
        let distanceThreshold = 0.55 + 0.4 * sensitivity

        var vectors: [[Double]?] = Array(repeating: nil, count: articles.count)
        if embedding != nil {
            for i in articles.indices {
                vectors[i] = vector(for: articles[i].title)
            }
        }

        var parent = Array(articles.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in articles.indices {
            for j in (i + 1)..<articles.count {
                let shared = tokenSets[i].tokens.intersection(tokenSets[j].tokens)
                guard !shared.isEmpty else { continue }

                let unionCount = tokenSets[i].tokens.union(tokenSets[j].tokens).count
                let jaccard = unionCount == 0 ? 0 : Double(shared.count) / Double(unionCount)
                // A shared quoted phrase is a much stronger signal than a
                // shared word: count it double. A shared multi-word name is
                // the opposite — one shared thing, not several: the phrase
                // token absorbs its component words ("south korea" + "south"
                // + "korea" weigh 1, not 3).
                let quoted = tokenSets[i].quoted.union(tokenSets[j].quoted)
                let names = tokenSets[i].names.union(tokenSets[j].names)
                var sharedWeight = shared.count + shared.lazy.filter { quoted.contains($0) }.count
                for name in shared where names.contains(name) {
                    sharedWeight -= name.split(separator: " ")
                        .filter { shared.contains(String($0)) }.count
                }
                // One shared word or name is never the same story — it takes
                // at least two shared things (or one quoted phrase) to link.
                guard sharedWeight >= 2 else { continue }
                if jaccard >= jaccardThreshold || sharedWeight >= 3 {
                    union(i, j)
                    continue
                }
                // Embedding link: loose semantic similarity backs up the
                // shared tokens to catch paraphrased headlines.
                if let va = vectors[i], let vb = vectors[j],
                   cosineDistance(va, vb) <= distanceThreshold {
                    union(i, j)
                }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for i in articles.indices {
            clusters[find(i), default: []].append(i)
        }

        var groups: [TopicGroup] = clusters.values.map { indices in
            let members = indices.map { articles[$0] }
                .sorted { $0.published > $1.published }
            if members.count == 1 {
                return singleton(members[0])
            }
            let headline = headline(for: indices.map { tokenSets[$0].tokens },
                                    titles: indices.map { articles[$0].title })
            return TopicGroup(
                id: members.map(\.id).sorted().joined(separator: "|"),
                headline: headline,
                articles: members
            )
        }
        groups.sort { $0.newest > $1.newest }
        return groups
    }

    private static func singleton(_ article: Article) -> TopicGroup {
        TopicGroup(id: article.id, headline: nil, articles: [article])
    }

    private static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for k in a.indices {
            dot += a[k] * b[k]
            na += a[k] * a[k]
            nb += b[k] * b[k]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 2 }
        return 1 - dot / denom
    }

    /// Human-readable label for a group: the tokens shared by most member titles,
    /// rendered in their original casing from the first title that contains them.
    private static func headline(for tokenSets: [Set<String>], titles: [String]) -> String {
        var counts: [String: Int] = [:]
        for set in tokenSets {
            for t in set { counts[t, default: 0] += 1 }
        }
        let majority = (tokenSets.count + 1) / 2
        let candidates = counts.filter { $0.value > majority || $0.value == tokenSets.count }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        // A common phrase makes its component words redundant — without this
        // a name group would label itself "South Korea · Korea · South".
        let phrases = candidates.filter { $0.contains(" ") }
        let common = candidates.filter { token in
            token.contains(" ") || !phrases.contains { phrase in
                phrase.split(separator: " ").contains(Substring(token))
            }
        }.prefix(3)
        guard !common.isEmpty else { return "Related stories" }

        // Recover original casing from the titles.
        var display: [String] = []
        for token in common {
            var found: String? = nil
            if token.contains(" ") {
                // quoted-phrase token: find it verbatim in some title
                for title in titles {
                    if let range = title.range(of: token, options: .caseInsensitive) {
                        found = String(title[range])
                        break
                    }
                }
            } else {
                outer: for title in titles {
                    for word in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                        if word.lowercased() == token { found = String(word); break outer }
                    }
                }
            }
            display.append(found ?? token.capitalized)
        }
        return display.joined(separator: " · ")
    }
}
