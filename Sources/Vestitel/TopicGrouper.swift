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

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has",
        "was", "are", "will", "you", "your", "its", "his", "her", "their",
        "but", "not", "all", "can", "how", "why", "what", "when", "who",
        "new", "says", "said", "after", "into", "over", "out", "about",
        "more", "than", "just", "now", "get", "gets", "here", "there",
        "one", "two", "amid", "may", "could", "would", "should", "been",
        "off", "our", "were", "via", "per", "top", "big",
    ]

    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// Sentence embeddings are expensive (~ms each); memoize per title so a
    /// regroup only pays for titles it hasn't seen. Main-thread only.
    private static var vectorCache: [String: [Double]?] = [:]

    private static func vector(for title: String) -> [Double]? {
        let key = title.lowercased()
        if let cached = vectorCache[key] { return cached }
        if vectorCache.count > 2000 { vectorCache.removeAll() }
        let v = embedding?.vector(for: key)
        vectorCache[key] = v
        return v
    }

    static func tokens(_ title: String) -> Set<String> {
        let lowered = title.lowercased()
        var result: Set<String> = []
        lowered.unicodeScalars.split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
            .forEach { chunk in
                let word = String(String.UnicodeScalarView(chunk))
                if word.count >= 3, !stopwords.contains(word), Int(word) == nil {
                    result.insert(word)
                }
            }
        return result
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
                let shared = tokenSets[i].intersection(tokenSets[j])
                guard !shared.isEmpty else { continue }

                let unionCount = tokenSets[i].union(tokenSets[j]).count
                let jaccard = unionCount == 0 ? 0 : Double(shared.count) / Double(unionCount)
                if jaccard >= jaccardThreshold || shared.count >= 3 {
                    union(i, j)
                    continue
                }
                // Embedding link needs ≥2 shared tokens — one generic shared
                // word ("fixing", "review") plus loose semantic similarity is
                // not the same story.
                if shared.count >= 2, let va = vectors[i], let vb = vectors[j] {
                    if cosineDistance(va, vb) <= distanceThreshold {
                        union(i, j)
                    }
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
            let headline = headline(for: indices.map { tokenSets[$0] },
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
        let common = counts.filter { $0.value > majority || $0.value == tokenSets.count }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        guard !common.isEmpty else { return "Related stories" }

        // Recover original casing from the titles.
        var display: [String] = []
        for token in common {
            var found: String? = nil
            outer: for title in titles {
                for word in title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                    if word.lowercased() == token { found = String(word); break outer }
                }
            }
            display.append(found ?? token.capitalized)
        }
        return display.joined(separator: " · ")
    }
}
