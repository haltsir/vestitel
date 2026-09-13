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
        "зад", "сред", "край",
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
                    let phrase = words.map { normalize($0.lowercased()) }.joined(separator: " ")
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
        for name in capitalisedRuns(in: remainder) {
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
                let words = words(in: text[range]).map { normalize($0.lowercased()) }
                if words.count > 1 {
                    phrases.append(words.joined(separator: " "))
                }
            }
            return true
        }
        return phrases
    }

    /// The Bulgarian stand-in for the name tagger: in a Cyrillic title, a
    /// run of two or more capitalised words is a name ("Матилд Арсел",
    /// "Северна Корея") or a foreign title ("Woman Unknown", "Steam Deck"),
    /// since Bulgarian doesn't capitalise anything else mid-sentence. The
    /// sentence-initial word is skipped unless it is Latin script (a foreign
    /// name opening the title). Not applied to Latin-script titles, where
    /// Title Case headlines would turn every title into one phrase.
    private static func capitalisedRuns(in text: String) -> [String] {
        var cyrillic = 0, latin = 0
        for s in text.unicodeScalars {
            if (0x400...0x4FF).contains(s.value) { cyrillic += 1 }
            else if (65...90).contains(s.value) || (97...122).contains(s.value) { latin += 1 }
        }
        guard cyrillic > latin else { return [] }

        var phrases: [String] = []
        var run: [String] = []
        func flush() {
            if run.count > 1 {
                let phrase = run.map { normalize($0.lowercased()) }.joined(separator: " ")
                if phrase.count >= 3 { phrases.append(phrase) }
            }
            run = []
        }
        let chunks = text.split(whereSeparator: { $0.isWhitespace })
        for (index, chunk) in chunks.enumerated() {
            let chunkWords = words(in: chunk)
            guard let first = chunkWords.first, let letter = first.first, letter.isUppercase else {
                flush()
                continue
            }
            let isLatin = letter.isASCII
            if index == 0, !isLatin {
                continue
            }
            run.append(contentsOf: chunkWords)
            // punctuation after the word ends the name: "Арсел, която"
            if let last = chunk.last, !(last.isLetter || last.isNumber) { flush() }
        }
        flush()
        return phrases
    }

    private static func words(in text: Substring) -> [String] {
        // A hyphen between alphanumerics is part of the word: "22-годишна"
        // and "Е-79" are single, highly distinctive tokens — split apart,
        // the number is dropped and (for ages) the noun is a stopword.
        var words: [String] = []
        var current = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            if CharacterSet.alphanumerics.contains(s) {
                current.append(s)
            } else if s == "-", !current.isEmpty, i + 1 < scalars.count,
                      CharacterSet.alphanumerics.contains(scalars[i + 1]) {
                current.append(s)
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// Strip the Bulgarian definite-article suffix so "детска" and
    /// "детската" become the same keyword. Deliberately context-gated —
    /// naive suffix stripping mangles words that end in those letters
    /// naturally ("злато", "място", "карта", "дете"):
    ///  - -та only after а/я ("жената") or т/щ ("радостта", "нощта");
    ///    never after other consonants, which is where "карта"/"лента" live
    ///  - -то only after о/е ("морето", "детето") — "злато"/"място" keep
    ///  - -те only after и/е ("колите", "мъжете")
    ///  - -ът always ("градът"); -ят only after a consonant ("конят" → кон,
    ///    but "краят" keeps its я — it's the stem's elided й, край)
    /// The stem must keep ≥3 characters ("дете" survives its -те ending).
    private static func normalize(_ word: String) -> String {
        guard let last = word.unicodeScalars.last,
              (0x400...0x4FF).contains(last.value) else { return word }
        for ending in ["ата", "ята", "тта", "щта", "ото", "ето", "ите", "ете"]
        where word.hasSuffix(ending) {
            let stem = String(word.dropLast(2))
            return stem.count >= 3 ? stem : word
        }
        if word.hasSuffix("ът") {
            let stem = String(word.dropLast(2))
            return stem.count >= 3 ? stem : word
        }
        if word.hasSuffix("ят") {
            let stem = String(word.dropLast(2))
            if stem.count >= 3, let c = stem.last, !"аъоуеияюй".contains(c) {
                return stem
            }
        }
        return word
    }

    private static func insertWord(_ word: String, into result: inout Set<String>) {
        let raw = word.lowercased()
        let word = normalize(raw)
        // both forms checked: "годината" normalizes into the stopword
        // "година"; "правят" is a stopword only in its raw form
        if word.count >= 3, !stopwords.contains(raw), !stopwords.contains(word),
           Int(word) == nil {
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

        // Inverted index: a pair can only link with shared weight >= 2, i.e.
        // two shared tokens or one shared quoted phrase, so every other
        // pair is skipped without touching a Set. Against all-pairs this is
        // the difference between ~400k intersections and a few thousand for
        // an inbox of ~900 titles.
        var postings: [String: [Int]] = [:]
        for i in articles.indices {
            for token in tokenSets[i].tokens { postings[token, default: []].append(i) }
        }
        var sharedCount: [Int: Int] = [:]
        var quotedHit = Set<Int>()
        for i in articles.indices {
            sharedCount.removeAll(keepingCapacity: true)
            quotedHit.removeAll(keepingCapacity: true)
            for token in tokenSets[i].tokens {
                guard let list = postings[token] else { continue }
                let quoted = tokenSets[i].quoted.contains(token)
                for j in list where j > i {
                    sharedCount[j, default: 0] += 1
                    if quoted || tokenSets[j].quoted.contains(token) { quotedHit.insert(j) }
                }
            }
            for (j, count) in sharedCount where count >= 2 || quotedHit.contains(j) {
                let shared = tokenSets[i].tokens.intersection(tokenSets[j].tokens)

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

    /// Regroup the members of one group after some were removed (exact:
    /// clusters are connected components of the link graph, so losing a
    /// member can only split its own component). Same output shape as
    /// `group`, sorted newest first.
    static func regroup(_ members: [Article], sensitivity: Double) -> [TopicGroup] {
        group(members, sensitivity: sensitivity)
    }

    /// Human-readable label for a group: the tokens shared by most member
    /// titles, rendered in their original casing from the first title that
    /// contains them. Names come first: a quoted title or a named entity
    /// labels a story, a shared verb ("спечели") or common noun does not,
    /// so phrases rank above capitalised words, which rank above the rest,
    /// and two or more phrases make a complete label on their own. The
    /// picks are shown in the order they appear in the newest title.
    private static func headline(for tokenSets: [Set<String>], titles: [String]) -> String {
        var counts: [String: Int] = [:]
        for set in tokenSets {
            for t in set { counts[t, default: 0] += 1 }
        }
        let majority = (tokenSets.count + 1) / 2
        let candidates = counts.filter { $0.value > majority || $0.value == tokenSets.count }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        // A common phrase makes its component words redundant: without this
        // a name group would label itself "South Korea · Korea · South".
        let phrases = candidates.filter { $0.contains(" ") }
        let common = candidates.filter { token in
            token.contains(" ") || !phrases.contains { phrase in
                phrase.split(separator: " ").contains(Substring(token))
            }
        }
        guard !common.isEmpty else { return "Related stories" }

        struct Pick {
            var display: String
            var isPhrase: Bool
            var isProper: Bool   // capitalised somewhere other than a title's first word
            var order: Int       // candidate rank (count, then alphabetical)
            var position: Int    // word index in the newest title (Int.max if absent)
            var words: Int       // how many words the pick spans there
        }
        func wordIndex(of range: Range<String.Index>, in title: String) -> Int {
            title[..<range.lowerBound].split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        }
        var picks: [Pick] = []
        for (order, token) in common.enumerated() {
            var display: String? = nil
            var proper = false
            var position = Int.max
            let words = token.split(separator: " ").count
            if token.contains(" ") {
                for (t, title) in titles.enumerated() {
                    if let range = title.range(of: token, options: .caseInsensitive) {
                        display = String(title[range])
                        if t == 0 { position = wordIndex(of: range, in: title) }
                        break
                    }
                }
            } else {
                outer: for (t, title) in titles.enumerated() {
                    for (w, word) in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).enumerated() {
                        // normalized compare: token "детска" is recovered
                        // from a title that spells it "Детската"
                        if normalize(word.lowercased()) == token {
                            display = String(word)
                            proper = w > 0 && (word.first?.isUppercase ?? false)
                            if t == 0 { position = w }
                            break outer
                        }
                    }
                }
            }
            picks.append(Pick(display: display ?? token.capitalized, isPhrase: token.contains(" "),
                              isProper: proper, order: order, position: position, words: words))
        }
        picks.sort {
            if $0.isPhrase != $1.isPhrase { return $0.isPhrase }
            if $0.isProper != $1.isProper { return $0.isProper }
            return $0.order < $1.order
        }
        let phraseCount = picks.filter(\.isPhrase).count
        let chosen = picks.prefix(phraseCount >= 2 ? min(phraseCount, 3) : 3)
            .sorted { $0.position < $1.position }
        // Adjacent capitalised picks are one name: "Асен Василев" opens its
        // titles, so the tokenizer (which skips the sentence-initial word)
        // never made it a phrase, but shown side by side it reads as one.
        var parts: [String] = []
        var previous: Pick? = nil
        for pick in chosen {
            if let last = previous, !parts.isEmpty,
               pick.position != Int.max, pick.position == last.position + last.words,
               last.display.first?.isUppercase == true, pick.display.first?.isUppercase == true {
                parts[parts.count - 1] += " " + pick.display
            } else {
                parts.append(pick.display)
            }
            previous = pick
        }
        return parts.joined(separator: " · ")
    }
}
