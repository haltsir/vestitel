import Foundation

/// The Claude assist for topic grouping: an optional helper, never the
/// grouper. After a refresh the articles that arrived (and have not been
/// looked at yet) go to Claude Haiku together with the stories already in
/// the inbox, and its verdicts ("A3 is the story G12 covers", "A1 and A4
/// are one new story") come back as `GroupingHints`: extra links that
/// `TopicGrouper.group` unions before its own pass, plus a headline per
/// story it formed. The heuristics stay the baseline: with the toggle off,
/// no key, no network or a refused request the grouping is exactly what it
/// is today.
///
/// Verdicts are remembered per article id (`AppStore.groupingHints`,
/// `aiAssessed`) and pruned with the articles, so every arrival is asked
/// about once in its life and the grouping stays stable after the answer.
/// A verdict that lands while the inbox is held (popover open on the Inbox
/// tab) waits in `pendingHints`: regrouping under the reader would shift
/// the list the hold exists to keep still.
///
/// Raw HTTP to the Messages API (there is no Swift SDK): structured output
/// pins the answer to `outputSchema`, effort is low (this is
/// classification), and nothing but titles, sources and the first lines
/// of summaries ever leaves the Mac. `VESTITEL_AI_URL` points a test
/// instance at a stand-in endpoint (same response shape).
enum GroupingAssistant {
    static let model = "claude-haiku-5-5"
    static let apiVersion = "2026-10-21"
    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Arrivals per request; a first run over a large inbox takes several.
    static let batchSize = 60
    /// Existing articles older than this (before the oldest arrival in the
    /// batch) are not shown: a same-story pair is days apart at most, and
    /// the whole inbox would be tokens for nothing.
    static let window: TimeInterval = 3 * 24 * 60 * 60
    /// Member titles shown per existing story.
    static let titlesPerStory = 4
    static let summaryLength = 220

    static var endpoint: URL {
        if let override = ProcessInfo.processInfo.environment["VESTITEL_AI_URL"],
           let url = URL(string: override) {
            return url
        }
        return defaultEndpoint
    }

    /// A newly arrived article, not yet judged.
    struct Arrival {
        var id: String
        var title: String
        var source: String
        var summary: String?
    }

    /// A story already in the inbox: one group of the current grouping,
    /// singletons included (most are).
    struct Story {
        var ids: [String]
        var headline: String?
        /// (title, source), newest first.
        var members: [(title: String, source: String)]
    }

    struct Verdict {
        var hints = GroupingHints()
        /// Every arrival the request covered: asked once, whatever the answer.
        var assessed: Set<String> = []
        var joined = 0
        var formed = 0
    }

    enum AssistError: Error, Equatable {
        case refused
        case truncated
        case badResponse
    }

    static let systemPrompt = """
    You help a news reader cluster headlines that report the same story. You get the reader's \
    current story groups (G1, G2, …; most hold a single article) and newly arrived articles \
    (A1, A2, …), mostly Bulgarian and English news.

    Two articles belong together only when they report the same concrete event or development: \
    the same thing happened to the same people or organisations at the same time. The same topic, \
    rubric, sport, competition, politician or ongoing conflict is not enough: different matches of \
    one tournament, different days of one war, two unrelated price reports, or two statements by \
    the same minister on different matters are separate stories. A follow-up to an event (a \
    reaction, a verdict, the next step) is the same story when the headlines clearly refer to that \
    one event. When unsure, keep articles apart.

    For each new article that reports a story an existing group already covers, list it under \
    assignments with that group's number. New articles that report the same story as each other \
    and match no existing group form one entry under newGroups. Leave out every article that fits \
    nowhere; most will. Never list an article in both places or twice.

    Give every assignment and new group a headline: the story in two to six words, in the \
    language of its articles, sentence case, no final punctuation, naming the subject (who or \
    what happened), never a generic rubric like "Политика" or "Sports".
    """

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "assignments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "article": ["type": "integer"],
                        "group": ["type": "integer"],
                        "headline": ["type": "string"],
                    ],
                    "required": ["article", "group", "headline"],
                    "additionalProperties": false,
                ],
            ],
            "newGroups": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "articles": ["type": "array", "items": ["type": "integer"]],
                        "headline": ["type": "string"],
                    ],
                    "required": ["articles", "headline"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["assignments", "newGroups"],
        "additionalProperties": false,
    ]

    /// The user message: numbered stories, then numbered arrivals.
    static func prompt(stories: [Story], arrivals: [Arrival]) -> String {
        var lines: [String] = []
        lines.append("Existing groups:")
        if stories.isEmpty { lines.append("(none)") }
        for (n, story) in stories.enumerated() {
            var head = "G\(n + 1)"
            if let headline = story.headline, !headline.isEmpty { head += " (\(headline))" }
            lines.append(head + ":")
            for member in story.members.prefix(titlesPerStory) {
                lines.append("  - \(oneLine(member.title)) [\(member.source)]")
            }
            if story.members.count > titlesPerStory {
                lines.append("  - (+\(story.members.count - titlesPerStory) more)")
            }
        }
        lines.append("")
        lines.append("New articles:")
        for (n, arrival) in arrivals.enumerated() {
            lines.append("A\(n + 1): \(oneLine(arrival.title)) [\(arrival.source)]")
            if let summary = arrival.summary, !summary.isEmpty {
                lines.append("    \(snippet(summary))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func requestBody(stories: [Story], arrivals: [Arrival]) -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": outputSchema],
            ],
            "messages": [
                ["role": "user", "content": prompt(stories: stories, arrivals: arrivals)],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func request(apiKey: String, stories: [Story], arrivals: [Arrival]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("Vestitel", forHTTPHeaderField: "User-Agent")
        request.httpBody = requestBody(stories: stories, arrivals: arrivals)
        request.timeoutInterval = 90
        return request
    }

    /// Turns a Messages API response into hints. Indices are 1-based (G1,
    /// A1) as in the prompt; anything out of range, a duplicate, or a
    /// "group" of one is ignored rather than failing the batch.
    static func parse(_ data: Data, stories: [Story], arrivals: [Arrival]) throws -> Verdict {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistError.badResponse
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw AssistError.refused
        case "max_tokens": throw AssistError.truncated
        default: break
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AssistError.badResponse
        }

        var verdict = Verdict()
        verdict.assessed = Set(arrivals.map(\.id))
        var placed = Set<Int>()

        for item in answer["assignments"] as? [[String: Any]] ?? [] {
            guard let a = item["article"] as? Int, let g = item["group"] as? Int,
                  arrivals.indices.contains(a - 1), stories.indices.contains(g - 1),
                  !placed.contains(a - 1) else { continue }
            placed.insert(a - 1)
            let arrival = arrivals[a - 1], story = stories[g - 1]
            guard let anchor = story.ids.first else { continue }
            verdict.hints.links.insert(GroupingHints.key(arrival.id, anchor))
            if let headline = cleanHeadline(item["headline"]) {
                for id in story.ids + [arrival.id] { verdict.hints.headlines[id] = headline }
            }
            verdict.joined += 1
        }

        for item in answer["newGroups"] as? [[String: Any]] ?? [] {
            var members: [Int] = []
            for a in item["articles"] as? [Int] ?? [] where arrivals.indices.contains(a - 1) && !placed.contains(a - 1) && !members.contains(a - 1) {
                members.append(a - 1)
            }
            guard members.count >= 2 else { continue }
            placed.formUnion(members)
            for (x, y) in zip(members, members.dropFirst()) {
                verdict.hints.links.insert(GroupingHints.key(arrivals[x].id, arrivals[y].id))
            }
            if let headline = cleanHeadline(item["headline"]) {
                for m in members { verdict.hints.headlines[arrivals[m].id] = headline }
            }
            verdict.formed += 1
        }
        return verdict
    }

    /// The API's error message for a non-200 answer, if it sent one.
    static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }

    private static func cleanHeadline(_ raw: Any?) -> String? {
        guard var headline = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headline.isEmpty else { return nil }
        while let last = headline.last, ".;:!".contains(last) { headline.removeLast() }
        if headline.count > 80 { headline = String(headline.prefix(80)) }
        return headline.isEmpty ? nil : headline
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func snippet(_ summary: String) -> String {
        let flat = oneLine(summary.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
        guard flat.count > summaryLength else { return flat }
        return String(flat.prefix(summaryLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Store side

extension AppStore {
    /// The key lives in its own file next to state.json, readable by this
    /// user only (0600): state.json is plain JSON that gets exported, read
    /// by tests and mirrored by sync, and the Keychain prompts for every
    /// ad-hoc-signed rebuild and self-update. A test instance
    /// (VESTITEL_STATE_DIR) has its own file.
    static var aiKeyURL: URL { stateDirectory.appendingPathComponent("anthropic-api-key") }

    static func loadAIKey() -> String? {
        guard let data = try? Data(contentsOf: aiKeyURL) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func setAIKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try? Data(key.utf8).write(to: Self.aiKeyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.aiKeyURL.path)
        aiKey = key
        aiStatus = ""
        scheduleGroupingAssist()
    }

    func removeAIKey() {
        try? FileManager.default.removeItem(at: Self.aiKeyURL)
        aiKey = nil
        aiTask?.cancel()
        aiStatus = ""
    }

    var aiKeyPresent: Bool { aiKey != nil }

    /// On, keyed, and grouping is on at all.
    var aiAssistActive: Bool {
        settings.groupingEnabled && settings.aiGroupingEnabled && aiKey != nil
    }

    /// The hints the grouper sees right now: none while the assist is off,
    /// so turning it off returns the inbox to the plain heuristics (the
    /// verdicts are kept, turning it on again costs nothing).
    var activeHints: GroupingHints {
        settings.aiGroupingEnabled ? groupingHints : GroupingHints()
    }

    /// Runs the assist over every inbox article not judged yet, in batches,
    /// at most one run at a time. Called after every refresh; a no-op
    /// unless the assist is active.
    func scheduleGroupingAssist(manual: Bool = false) {
        guard aiAssistActive, aiTask == nil else { return }
        if manual { aiStatus = "Checking…" }
        aiTask = Task { [weak self] in
            await self?.runGroupingAssist(manual: manual)
            self?.aiTask = nil
        }
    }

    private func runGroupingAssist(manual: Bool) async {
        var rounds = 0
        var checked = 0, joined = 0, formed = 0
        var failure: String?
        while rounds < 20, let key = aiKey, aiAssistActive, !Task.isCancelled {
            let all = articles.filter { $0.state == .inbox }
            let waiting = all.filter { !aiAssessed.contains($0.id) }.sorted { $0.published < $1.published }
            guard !waiting.isEmpty else { break }
            let batch = Array(waiting.prefix(GroupingAssistant.batchSize))
            let batchIDs = Set(batch.map(\.id))
            let cutoff = (batch.map(\.published).min() ?? Date()) - GroupingAssistant.window
            let stories = existingStories(excluding: batchIDs, since: cutoff, in: all)
            let arrivals = batch.map {
                GroupingAssistant.Arrival(id: $0.id, title: $0.title, source: $0.sourceTitle, summary: $0.summary)
            }

            do {
                let request = GroupingAssistant.request(apiKey: key, stories: stories, arrivals: arrivals)
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    let message = GroupingAssistant.errorMessage(in: data)
                    switch status {
                    case 401: failure = "The API key was rejected."
                    case 429: failure = "Rate limited; will retry after the next refresh."
                    case 400: failure = "Anthropic API: \(message ?? "request rejected")."
                    case 500...: failure = "Anthropic API unavailable; will retry."
                    default: failure = "Anthropic API answered \(status)."
                    }
                    // a 400 won't get better on retry; everything else will
                    if status == 400 { aiAssessed.formUnion(batchIDs) }
                    break
                }
                let verdict = try GroupingAssistant.parse(data, stories: stories, arrivals: arrivals)
                aiAssessed.formUnion(verdict.assessed)
                stage(verdict.hints)
                checked += arrivals.count
                joined += verdict.joined
                formed += verdict.formed
            } catch GroupingAssistant.AssistError.refused {
                aiAssessed.formUnion(batchIDs)   // asking again changes nothing
                failure = "Claude declined one batch."
            } catch GroupingAssistant.AssistError.truncated, GroupingAssistant.AssistError.badResponse {
                aiAssessed.formUnion(batchIDs)
                failure = "Couldn't read Claude's answer for one batch."
            } catch is CancellationError {
                break
            } catch {
                failure = "Couldn't reach the Anthropic API."
                break
            }
            rounds += 1
        }
        if checked > 0 || failure != nil { save() }
        if let failure {
            aiStatus = failure
        } else if checked > 0 {
            let stories = joined + formed
            aiStatus = stories == 0
                ? "Checked \(checked) new article\(checked == 1 ? "" : "s"), no new stories."
                : "Checked \(checked) new article\(checked == 1 ? "" : "s"): \(joined) joined a story, \(formed) new."
        } else if manual {
            aiStatus = "Everything in the inbox has been checked."
        }
    }

    /// The current groups (the grouping the user sees, hints included) with
    /// the batch and anything older than the window removed. In group-by-
    /// source mode the topic grouping is not at hand, so every article is
    /// its own story; Claude still sees them all.
    private func existingStories(excluding batch: Set<String>, since cutoff: Date, in all: [Article]) -> [GroupingAssistant.Story] {
        var covered = Set<String>()
        var stories: [GroupingAssistant.Story] = []
        if settings.groupingEnabled, !settings.groupBySource {
            for group in groupedInbox {
                let members = group.articles.filter { !batch.contains($0.id) && $0.published >= cutoff }
                guard !members.isEmpty else { continue }
                covered.formUnion(members.map(\.id))
                stories.append(.init(ids: members.map(\.id),
                                     headline: members.count > 1 ? group.headline : nil,
                                     members: members.map { ($0.title, $0.sourceTitle) }))
            }
        }
        // held arrivals that are not in this batch, and everything in
        // group-by-source mode
        for article in all where !batch.contains(article.id) && !covered.contains(article.id) && article.published >= cutoff {
            stories.append(.init(ids: [article.id], headline: nil, members: [(article.title, article.sourceTitle)]))
        }
        return stories
    }

    /// Verdicts apply at once unless the inbox is held; then they wait for
    /// the hold to lift (`inboxHoldStart` didSet calls `applyPendingHints`).
    private func stage(_ hints: GroupingHints) {
        guard !hints.links.isEmpty || !hints.headlines.isEmpty else { return }
        if inboxHoldStart != nil {
            var pending = pendingHints ?? GroupingHints()
            pending.links.formUnion(hints.links)
            pending.headlines.merge(hints.headlines) { _, new in new }
            pendingHints = pending
        } else {
            merge(hints)
        }
    }

    func applyPendingHints() {
        guard let pending = pendingHints else { return }
        pendingHints = nil
        merge(pending)
        save()
    }

    private func merge(_ hints: GroupingHints) {
        groupingHints.links.formUnion(hints.links)
        groupingHints.headlines.merge(hints.headlines) { _, new in new }
        hintsVersion += 1
    }

    /// Forget verdicts about articles that are gone (purged); called from
    /// `sweep()` whenever articles were removed.
    func pruneGroupingHints() {
        let present = Set(articles.map(\.id))
        groupingHints.prune(keeping: present)
        pendingHints?.prune(keeping: present)
        aiAssessed = aiAssessed.intersection(present)
    }
}
