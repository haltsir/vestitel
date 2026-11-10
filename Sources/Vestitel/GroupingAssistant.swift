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
/// A second request per run reviews the groups the heuristics formed
/// (`runReviewPass`): members that do not belong become exclusions the
/// heuristics honour, and groups that are one story get linked. A group
/// is reviewed once per composition (`aiReviewed`, with subsets of a
/// reviewed group counting as reviewed, so a clear never costs a call);
/// groups Claude itself formed (every member carries its headline) are
/// never second-guessed.
///
/// Verdicts are remembered per article id (`AppStore.groupingHints`,
/// `aiAssessed`) and pruned with the articles, so every arrival is asked
/// about once in its life and the grouping stays stable after the answer.
/// A verdict that lands while the inbox is held (popover open on the Inbox
/// tab) waits in `pendingHints`: regrouping under the reader would shift
/// the list the hold exists to keep still.
///
/// Every number in an answer travels with an echo of the title it names
/// (`echoRule`, the first words of the article's headline, or of a
/// group's first member), and a verdict whose echo does not open that
/// title is dropped (`echoMatches`): at low effort Haiku once wrote the
/// right headline with one index off by one, and two unrelated articles
/// with adjacent numbers became "one story". A dropped verdict costs
/// nothing; a wrong link sticks until the articles purge.
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
        /// (title, source), newest first, in the order of `ids`.
        var members: [(title: String, source: String)]
        /// The headline the assist gave this story earlier, if any: an
        /// arrival joining it adopts that label rather than renaming the
        /// story after itself ("Телефонна линия за близките" was the
        /// twelfth article of the Trakia crash, and became its title).
        var label: String? = nil
        /// What an echo of this group must open (`echoRule`).
        var firstTitle: String { members.first?.title ?? "" }
    }

    struct Verdict {
        var hints = GroupingHints()
        /// Every arrival the request covered: asked once, whatever the answer.
        var assessed: Set<String> = []
        var joined = 0
        var formed = 0
        /// Verdicts dropped because the echoed title did not match the number.
        var mismatched = 0
    }

    enum AssistError: Error, Equatable {
        case refused
        case truncated
        case badResponse
    }

    static let sameStoryDefinition = """
    Two articles belong together only when they report the same concrete event or development: \
    the same thing happened to the same people or organisations at the same time. The same topic, \
    rubric, sport, competition, politician or ongoing conflict is not enough: different matches of \
    one tournament, different days of one war, two unrelated price reports, or two statements by \
    the same minister on different matters are separate stories. A follow-up to an event (a \
    reaction, a verdict, the next step) is the same story when the headlines clearly refer to that \
    one event. When unsure, keep articles apart.
    """

    static let headlineRule = """
    A headline is the story in two to six words, in the language of its articles, sentence case, \
    no final punctuation, naming the subject (who or what happened), never a generic rubric like \
    "Политика" or "Sports".
    """

    static let echoRule = """
    Next to every number you give, put in "title" the first three words of the headline that \
    number stands for, copied exactly from the list (for a group, the first three words of its \
    first listed member). An entry whose words do not match its number is discarded, so check \
    the number against the words before you write it.
    """

    static let systemPrompt = """
    You help a news reader cluster headlines that report the same story. You get the reader's \
    current story groups (G1, G2, …; most hold a single article) and newly arrived articles \
    (A1, A2, …), mostly Bulgarian and English news.

    \(sameStoryDefinition)

    For each new article that reports a story an existing group already covers, list it under \
    assignments with that group's number. New articles that report the same story as each other \
    and match no existing group form one entry under newGroups. Leave out every article that fits \
    nowhere; most will. Never list an article in both places or twice.

    \(echoRule)

    Give every assignment and new group a headline. \(headlineRule)
    """

    static let reviewSystemPrompt = """
    You review story groups that a news reader's app formed by matching words across headlines, \
    mostly Bulgarian and English news. Groups to review come first (G1, G2, …), each with \
    numbered members, newest first; "other recent groups" follow and are only there for merges.

    \(sameStoryDefinition)

    For every group to review that mixes different stories, add a splits entry listing its \
    stories: each story is the members that report one and the same concrete event, and a \
    member that shares its event with nobody else in the group is left out (it stands alone). \
    Follow-ups of one event (reactions, condolences, the toll rising, officials responding, the \
    next step) belong to that event's story; separate stories means separate events. A group \
    that is one story needs no entry. Then, among all listed groups, add a merges entry \
    for each set of groups that report one and the same story, with a headline for the merged \
    story. \(headlineRule) When unsure, leave a group as it is and do not merge.

    \(echoRule)
    """

    /// A number plus the echoed title it stands for (`echoRule`).
    private static func numbered(_ key: String) -> [String: Any] {
        [
            "type": "object",
            "properties": [key: ["type": "integer"], "title": ["type": "string"]],
            "required": [key, "title"],
            "additionalProperties": false,
        ]
    }

    static let reviewSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "splits": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "group": ["type": "integer"],
                        "title": ["type": "string"],
                        "stories": ["type": "array", "items": ["type": "array", "items": numbered("member")]],
                    ],
                    "required": ["group", "title", "stories"],
                    "additionalProperties": false,
                ],
            ],
            "merges": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "groups": ["type": "array", "items": numbered("group")],
                        "headline": ["type": "string"],
                    ],
                    "required": ["groups", "headline"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["splits", "merges"],
        "additionalProperties": false,
    ]

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "assignments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "article": ["type": "integer"],
                        "title": ["type": "string"],
                        "group": ["type": "integer"],
                        "groupTitle": ["type": "string"],
                        "headline": ["type": "string"],
                    ],
                    "required": ["article", "title", "group", "groupTitle", "headline"],
                    "additionalProperties": false,
                ],
            ],
            "newGroups": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "articles": ["type": "array", "items": numbered("article")],
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
        body(system: systemPrompt, schema: outputSchema, prompt: prompt(stories: stories, arrivals: arrivals))
    }

    static func reviewRequestBody(subjects: [Story], context: [Story]) -> Data {
        body(system: reviewSystemPrompt, schema: reviewSchema, prompt: reviewPrompt(subjects: subjects, context: context))
    }

    private static func body(system: String, schema: [String: Any], prompt: String) -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": system,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [
                ["role": "user", "content": prompt],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func request(apiKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("Vestitel", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 90
        return request
    }

    /// The review message: the groups to judge, members numbered within
    /// each, then the other recent groups (merge candidates only).
    static func reviewPrompt(subjects: [Story], context: [Story]) -> String {
        var lines: [String] = []
        func emit(_ story: Story, number: Int) {
            var head = "G\(number)"
            if let headline = story.headline, !headline.isEmpty { head += " (\(headline))" }
            lines.append(head + ":")
            for (m, member) in story.members.enumerated() {
                lines.append("  \(m + 1). \(oneLine(member.title)) [\(member.source)]")
            }
        }
        lines.append("Groups to review:")
        for (n, story) in subjects.enumerated() { emit(story, number: n + 1) }
        lines.append("")
        lines.append("Other recent groups (for merges only):")
        if context.isEmpty { lines.append("(none)") }
        for (n, story) in context.enumerated() { emit(story, number: subjects.count + n + 1) }
        return lines.joined(separator: "\n")
    }

    struct ReviewVerdict {
        var hints = GroupingHints()
        /// Compositions judged (the subjects as sent, and what a split kept).
        var reviewed: [[String]] = []
        var splits = 0
        var merges = 0
        var mismatched = 0
    }

    /// A split is a partition: members in different stories (an unlisted
    /// member is a story of its own) become exclusions, and each story of
    /// two or more counts as reviewed. Merges link the groups' first
    /// members and label all of them. Group numbers run over subjects
    /// then context, as in the prompt; a split may only name a subject.
    static func parseReview(_ data: Data, subjects: [Story], context: [Story]) throws -> ReviewVerdict {
        let answer = try answerObject(data)
        let all = subjects + context
        var verdict = ReviewVerdict()
        verdict.reviewed = subjects.map(\.ids)
        let subjectTitles = subjects.map(\.firstTitle), allTitles = all.map(\.firstTitle)

        for item in answer["splits"] as? [[String: Any]] ?? [] {
            guard let g = index(item, key: "group", echo: "title", in: subjectTitles, mismatched: &verdict.mismatched) else { continue }
            let story = subjects[g]
            let memberTitles = story.members.map(\.title)
            // story number per member; unlisted members get one each
            var part = Array(repeating: -1, count: story.ids.count)
            var listed: [[Int]] = []
            for list in item["stories"] as? [[[String: Any]]] ?? [] {
                var members: [Int] = []
                for entry in list {
                    if let m = index(entry, key: "member", echo: "title", in: memberTitles, mismatched: &verdict.mismatched),
                       story.ids.indices.contains(m), part[m] == -1 {
                        part[m] = listed.count
                        members.append(m)
                    }
                }
                if !members.isEmpty { listed.append(members) }
            }
            // nothing matched: no story to keep, nothing to keep apart
            guard !listed.isEmpty else { continue }
            var parts = listed.count
            for m in part.indices where part[m] == -1 { part[m] = parts; parts += 1 }
            // one story holding everyone is the group as it stands
            guard parts > 1 else { continue }
            for members in listed where members.count > 1 { verdict.reviewed.append(members.map { story.ids[$0] }) }
            for a in story.ids.indices {
                for b in story.ids.indices where a < b && part[a] != part[b] {
                    verdict.hints.exclude(GroupingHints.key(story.ids[a], story.ids[b]))
                }
            }
            verdict.splits += 1
        }

        var merged = Set<Int>()
        for item in answer["merges"] as? [[String: Any]] ?? [] {
            var groups: [Int] = []
            for entry in item["groups"] as? [[String: Any]] ?? [] {
                guard let g = index(entry, key: "group", echo: "title", in: allTitles, mismatched: &verdict.mismatched),
                      !merged.contains(g), !groups.contains(g) else { continue }
                groups.append(g)
            }
            guard groups.count >= 2 else { continue }
            merged.formUnion(groups)
            for (x, y) in zip(groups, groups.dropFirst()) {
                guard let a = all[x].ids.first, let b = all[y].ids.first else { continue }
                verdict.hints.link(GroupingHints.key(a, b))
            }
            if let headline = cleanHeadline(item["headline"]) {
                for g in groups { for id in all[g].ids { verdict.hints.headlines[id] = headline } }
            }
            verdict.merges += 1
        }
        return verdict
    }

    /// Turns a Messages API response into hints. Indices are 1-based (G1,
    /// A1) as in the prompt; anything out of range, a duplicate, a number
    /// whose echoed title does not match, or a "group" of one is ignored
    /// rather than failing the batch.
    static func parse(_ data: Data, stories: [Story], arrivals: [Arrival]) throws -> Verdict {
        let answer = try answerObject(data)
        var verdict = Verdict()
        verdict.assessed = Set(arrivals.map(\.id))
        var placed = Set<Int>()
        let arrivalTitles = arrivals.map(\.title), storyTitles = stories.map(\.firstTitle)

        for item in answer["assignments"] as? [[String: Any]] ?? [] {
            guard let a = index(item, key: "article", echo: "title", in: arrivalTitles, mismatched: &verdict.mismatched),
                  let g = index(item, key: "group", echo: "groupTitle", in: storyTitles, mismatched: &verdict.mismatched),
                  !placed.contains(a) else { continue }
            placed.insert(a)
            let arrival = arrivals[a], story = stories[g]
            guard let anchor = story.ids.first else { continue }
            verdict.hints.link(GroupingHints.key(arrival.id, anchor))
            if let headline = story.label ?? cleanHeadline(item["headline"]) {
                for id in story.ids + [arrival.id] { verdict.hints.headlines[id] = headline }
            }
            verdict.joined += 1
        }

        for item in answer["newGroups"] as? [[String: Any]] ?? [] {
            var members: [Int] = []
            for entry in item["articles"] as? [[String: Any]] ?? [] {
                guard let a = index(entry, key: "article", echo: "title", in: arrivalTitles, mismatched: &verdict.mismatched),
                      !placed.contains(a), !members.contains(a) else { continue }
                members.append(a)
            }
            guard members.count >= 2 else { continue }
            placed.formUnion(members)
            for (x, y) in zip(members, members.dropFirst()) {
                verdict.hints.link(GroupingHints.key(arrivals[x].id, arrivals[y].id))
            }
            if let headline = cleanHeadline(item["headline"]) {
                for m in members { verdict.hints.headlines[arrivals[m].id] = headline }
            }
            verdict.formed += 1
        }
        return verdict
    }

    /// The structured answer inside a Messages response, or why there is none.
    private static func answerObject(_ data: Data) throws -> [String: Any] {
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
        return answer
    }

    /// The API's error message for a non-200 answer, if it sent one.
    static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }

    /// The 0-based index the 1-based number under `key` names, provided the
    /// title echoed under `echo` opens that item's title. Out of range is
    /// nil; in range but echoing another title is nil and counted.
    private static func index(_ item: [String: Any], key: String, echo: String, in titles: [String], mismatched: inout Int) -> Int? {
        guard let n = item[key] as? Int, titles.indices.contains(n - 1) else { return nil }
        guard echoMatches(item[echo], titles[n - 1]) else { mismatched += 1; return nil }
        return n - 1
    }

    /// Letters and digits only, lowercased: the echo need not get quotes,
    /// dashes or spacing right, only the words.
    static func echoMatches(_ echo: Any?, _ title: String) -> Bool {
        func letters(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        guard let echo = echo as? String else { return false }
        let key = letters(echo)
        return !key.isEmpty && letters(title).hasPrefix(key)
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

    /// A status line for a non-200 answer, and whether asking again could
    /// help (a 400 is ours to fix; the rest is the network's or Anthropic's).
    private func describeHTTPFailure(_ status: Int, data: Data) -> (message: String, permanent: Bool) {
        let message = GroupingAssistant.errorMessage(in: data)
        switch status {
        case 401: return ("The API key was rejected.", false)
        case 429: return ("Rate limited; will retry after the next refresh.", false)
        case 400: return ("Anthropic API: \(message ?? "request rejected").", true)
        case 500...: return ("Anthropic API unavailable; will retry.", false)
        default: return ("Anthropic API answered \(status).", false)
        }
    }

    private func runGroupingAssist(manual: Bool) async {
        var rounds = 0
        var checked = 0, joined = 0, formed = 0, mismatched = 0
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
                let body = GroupingAssistant.requestBody(stories: stories, arrivals: arrivals)
                let (data, response) = try await session.data(for: GroupingAssistant.request(apiKey: key, body: body))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    let (message, permanent) = describeHTTPFailure(status, data: data)
                    failure = message
                    if permanent { aiAssessed.formUnion(batchIDs) }
                    break
                }
                let verdict = try GroupingAssistant.parse(data, stories: stories, arrivals: arrivals)
                aiAssessed.formUnion(verdict.assessed)
                stage(verdict.hints)
                checked += arrivals.count
                joined += verdict.joined
                formed += verdict.formed
                mismatched += verdict.mismatched
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
        // the heuristic groups, as they stand after the arrivals were placed
        let review: ReviewOutcome = failure == nil && !Task.isCancelled ? await runReviewPass() : ReviewOutcome()
        mismatched += review.mismatched
        if checked > 0 || review.reviewed > 0 || failure != nil || review.failure != nil { save() }

        var parts: [String] = []
        if checked > 0 {
            parts.append(joined + formed == 0
                ? "Checked \(checked) new article\(checked == 1 ? "" : "s"), no new stories."
                : "Checked \(checked) new article\(checked == 1 ? "" : "s"): \(joined) joined a story, \(formed) new.")
        }
        if review.reviewed > 0 {
            parts.append("Reviewed \(review.reviewed) group\(review.reviewed == 1 ? "" : "s"): \(review.splits) split, \(review.merges) merged.")
        }
        if mismatched > 0 {
            parts.append("\(mismatched) verdict\(mismatched == 1 ? "" : "s") dropped: title did not match.")
        }
        if let failure = failure ?? review.failure {
            aiStatus = failure
        } else if !parts.isEmpty {
            aiStatus = parts.joined(separator: " ")
        } else if manual {
            aiStatus = "Everything in the inbox has been checked."
        }
    }

    /// Sends the multi-member groups the heuristics formed and nobody has
    /// judged yet, with the other recent groups as merge candidates. One
    /// request; whatever is left over waits for the next run.
    struct ReviewOutcome {
        var reviewed = 0, splits = 0, merges = 0, mismatched = 0
        var failure: String?
    }

    private func runReviewPass() async -> ReviewOutcome {
        guard let key = aiKey, aiAssistActive, !settings.groupBySource else { return ReviewOutcome() }
        let cutoff = Date() - GroupingAssistant.window
        var subjects: [GroupingAssistant.Story] = []
        var context: [GroupingAssistant.Story] = []
        for group in groupedInbox where group.articles.count > 1 && group.newest >= cutoff {
            let ids = group.articles.map(\.id)
            let story = GroupingAssistant.Story(ids: ids, headline: group.headline,
                                                members: group.articles.map { ($0.title, $0.sourceTitle) })
            if isClaudeFormed(ids) || isReviewed(ids) {
                context.append(story)
            } else {
                subjects.append(story)
            }
        }
        guard !subjects.isEmpty else { return ReviewOutcome() }
        subjects = Array(subjects.prefix(40))
        context = Array(context.prefix(60))

        do {
            let body = GroupingAssistant.reviewRequestBody(subjects: subjects, context: context)
            let (data, response) = try await session.data(for: GroupingAssistant.request(apiKey: key, body: body))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let (message, permanent) = describeHTTPFailure(status, data: data)
                if permanent { markReviewed(subjects.map(\.ids)) }
                return ReviewOutcome(failure: message)
            }
            let verdict = try GroupingAssistant.parseReview(data, subjects: subjects, context: context)
            markReviewed(verdict.reviewed)
            stage(verdict.hints)
            return ReviewOutcome(reviewed: subjects.count, splits: verdict.splits, merges: verdict.merges, mismatched: verdict.mismatched)
        } catch GroupingAssistant.AssistError.refused {
            markReviewed(subjects.map(\.ids))
            return ReviewOutcome(failure: "Claude declined the group review.")
        } catch GroupingAssistant.AssistError.truncated, GroupingAssistant.AssistError.badResponse {
            markReviewed(subjects.map(\.ids))
            return ReviewOutcome(failure: "Couldn't read Claude's group review.")
        } catch is CancellationError {
            return ReviewOutcome()
        } catch {
            return ReviewOutcome(failure: "Couldn't reach the Anthropic API.")
        }
    }

    /// Every member carries the same assist headline: Claude put this
    /// story together (or joined it), so it is not second-guessed.
    private func isClaudeFormed(_ ids: [String]) -> Bool {
        guard let headline = groupingHints.headline(for: ids) else { return false }
        return ids.allSatisfy { groupingHints.headlines[$0] == headline }
    }

    /// Judged already, as this composition or as part of a larger one that
    /// was found to be one story (a clear shrinks groups; it must not cost
    /// a request).
    private func isReviewed(_ ids: [String]) -> Bool {
        let set = Set(ids)
        return aiReviewed.contains { $0.count >= set.count && set.isSubset(of: $0) }
    }

    private func markReviewed(_ compositions: [[String]]) {
        for ids in compositions where ids.count > 1 { aiReviewed.insert(Set(ids)) }
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
                                     members: members.map { ($0.title, $0.sourceTitle) },
                                     label: groupingHints.headline(for: members.map(\.id))))
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
        guard !hints.isEmpty else { return }
        if inboxHoldStart != nil {
            var pending = pendingHints ?? GroupingHints()
            pending.merge(hints)
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
        groupingHints.merge(hints)
        hintsVersion += 1
    }

    /// Forget verdicts about articles that are gone (purged); called from
    /// `sweep()` whenever articles were removed.
    func pruneGroupingHints() {
        let present = Set(articles.map(\.id))
        groupingHints.prune(keeping: present)
        pendingHints?.prune(keeping: present)
        aiAssessed = aiAssessed.intersection(present)
        aiReviewed = Set(aiReviewed.compactMap { ids in
            let alive = ids.intersection(present)
            return alive.count > 1 ? alive : nil
        })
    }
}
