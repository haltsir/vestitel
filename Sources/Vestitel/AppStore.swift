import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppStore: ObservableObject {

    @Published var feeds: [Feed] = []
    @Published var articles: [Article] = []
    @Published var archive: [ArchiveEntry] = []
    @Published var bookmarks: [BookmarkEntry] = []
    @Published var settings: AppSettings = AppSettings() {
        didSet { scheduleRefreshTimer(); save() }
    }
    @Published var isRefreshing = false
    @Published var lastRefresh: Date? = nil
    /// Non-nil while the menu bar icon plays its new-articles animation.
    @Published var iconAnimationFrame: Int? = nil
    /// True when articles arrived since the popover was last opened —
    /// the menu bar icon shows in colour until the user looks.
    @Published var hasUnseenArticles = false
    /// Topic groups the user collapsed. Transient: group ids change when
    /// membership changes, so stale entries simply never match again.
    @Published var collapsedGroupIDs: Set<String> = []
    private var iconAnimationTimer: Timer?

    /// Every article id we've ever ingested, with first-seen date, so purged
    /// articles don't reappear on the next fetch. Pruned after 30 days.
    private var seen: [String: Date] = [:]

    private var sweepTimer: Timer?
    private var refreshTimer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Vestitel/1.0 (macOS RSS reader)"]
        return URLSession(configuration: config)
    }()

    // MARK: - Derived collections

    var inbox: [Article] {
        articles.filter { $0.state == .inbox }.sorted { $0.published > $1.published }
    }

    var unreadCount: Int {
        articles.lazy.filter { $0.state == .inbox && !$0.isRead }.count
    }

    var cleared: [Article] {
        articles.filter { $0.state == .cleared }
            .sorted { ($0.clearedAt ?? .distantPast) > ($1.clearedAt ?? .distantPast) }
    }

    /// Cached grouping structure: recomputing runs sentence embeddings over
    /// every title (slow), so it only happens when the inbox composition or
    /// sensitivity changes — not on every render/tab switch. The cache holds
    /// ids, not Article values, so read/cleared state is always current.
    private var groupCache: (key: Int, structure: [(headline: String?, ids: [String])])?

    var groupedInbox: [TopicGroup] {
        let inbox = self.inbox
        guard settings.groupingEnabled else {
            return inbox.map { TopicGroup(id: $0.id, headline: nil, articles: [$0]) }
        }

        var hasher = Hasher()
        for article in inbox { hasher.combine(article.id) }
        hasher.combine(settings.groupingSensitivity)
        let key = hasher.finalize()

        let structure: [(headline: String?, ids: [String])]
        if let cache = groupCache, cache.key == key {
            structure = cache.structure
        } else {
            let groups = TopicGrouper.group(inbox, sensitivity: settings.groupingSensitivity)
            structure = groups.map { ($0.headline, $0.articles.map(\.id)) }
            groupCache = (key, structure)
        }

        let byID = Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return structure.compactMap { headline, ids in
            let members = ids.compactMap { byID[$0] }
            guard !members.isEmpty else { return nil }
            return TopicGroup(
                id: ids.sorted().joined(separator: "|"),
                headline: headline,
                articles: members
            )
        }
    }

    // MARK: - Lifecycle

    init() {
        load()
        sweep()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
        scheduleRefreshTimer()
        Task { await refreshAll() }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes)) * 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: - Feed management

    @discardableResult
    func addFeed(urlString: String) async -> String? {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), url.host != nil else {
            return "Not a valid URL."
        }
        if feeds.contains(where: { $0.url == url }) {
            return "That feed is already added."
        }
        do {
            let (data, _) = try await session.data(from: url)
            let parsed = try FeedParser.parse(data: data)
            var feed = Feed(url: url, title: parsed.title.isEmpty ? (url.host ?? raw) : parsed.title)
            feed.lastFetched = Date()
            feeds.append(feed)
            if ingest(parsed.items, into: feed) > 0 {
                hasUnseenArticles = true
                animateMenuBarIcon()
            }
            save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True if the URL fetches and parses as an RSS/Atom feed.
    func isFeed(url: URL) async -> Bool {
        guard let (data, _) = try? await session.data(from: url) else { return false }
        return (try? FeedParser.parse(data: data)) != nil
    }

    // MARK: - Source colours

    /// Deterministic, similarity-aware automatic colours, measured in real
    /// perceptual distance (CIELAB ΔE) — index distance lies (systemPink is
    /// nearly systemRed). Each auto feed prefers its URL-hash slot; if that
    /// is confusable with an assigned colour it probes for a clearly
    /// different one (ΔE ≥ 35), relaxing to merely-different (≥ 15), then any
    /// free slot. Feeds are processed in URL order, so the same set of feeds
    /// always produces the same assignment — deleting and re-adding a feed
    /// lands on the same colour.
    private var autoColorAssignments: [UUID: Int] {
        let n = SourcePalette.count
        var taken = Set(feeds.compactMap { $0.colorIndex.map { (($0 % n) + n) % n } })
        var result: [UUID: Int] = [:]
        let autoFeeds = feeds.filter { $0.colorIndex == nil }
            .sorted { $0.url.absoluteString < $1.url.absoluteString }

        for feed in autoFeeds {
            let preferred = SourcePalette.autoIndex(forURL: feed.url)
            func fits(_ slot: Int, _ minDeltaE: Double) -> Bool {
                taken.allSatisfy { SourcePalette.deltaE($0, slot) >= minDeltaE }
            }
            func bestSlot() -> Int {
                for threshold in [35.0, 15.0] {
                    var candidate = preferred
                    for _ in 0..<n {
                        if fits(candidate, threshold) { return candidate }
                        candidate = (candidate + 5) % n
                    }
                }
                var candidate = preferred
                for _ in 0..<n {
                    if !taken.contains(candidate) { return candidate }
                    candidate = (candidate + 5) % n
                }
                return preferred
            }

            let slot = bestSlot()
            taken.insert(slot)
            result[feed.id] = slot
        }
        return result
    }

    func resolvedColorIndex(_ feed: Feed) -> Int {
        feed.colorIndex
            ?? autoColorAssignments[feed.id]
            ?? SourcePalette.autoIndex(forURL: feed.url)
    }

    func feedColor(_ feed: Feed) -> Color {
        SourcePalette.color(at: resolvedColorIndex(feed))
    }

    /// Colour for a source label. Resolves via the feed when possible; for
    /// records that outlive their feed (archive/bookmarks) falls back to a
    /// deterministic colour from the source name.
    func sourceColor(feedID: UUID? = nil, title: String) -> Color {
        if let feed = feeds.first(where: { $0.id == feedID })
            ?? feeds.first(where: { $0.title == title }) {
            return feedColor(feed)
        }
        return SourcePalette.color(at: SourcePalette.autoIndex(forString: title))
    }

    func setFeedColor(_ feed: Feed, to index: Int?) {
        guard let idx = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[idx].colorIndex = index
        save()
    }

    /// Rename a feed and propagate the new source name to everything that
    /// displays it — inbox/cleared articles, archive, and bookmarks.
    func renameFeed(_ feed: Feed, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let idx = feeds.firstIndex(where: { $0.id == feed.id }),
              feeds[idx].title != title else { return }
        let oldTitle = feeds[idx].title
        feeds[idx].title = title
        for i in articles.indices where articles[i].feedID == feed.id {
            articles[i].sourceTitle = title
        }
        // archive/bookmark entries don't carry feed ids; match the old name
        for i in archive.indices where archive[i].sourceTitle == oldTitle {
            archive[i].sourceTitle = title
        }
        for i in bookmarks.indices where bookmarks[i].sourceTitle == oldTitle {
            bookmarks[i].sourceTitle = title
        }
        save()
    }

    func removeFeed(_ feed: Feed) {
        feeds.removeAll { $0.id == feed.id }
        articles.removeAll { $0.feedID == feed.id && $0.state == .inbox && !$0.isRead }
        save()
    }

    // MARK: - Refresh

    func refreshAll() async {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
            save()
        }

        var newCount = 0
        await withTaskGroup(of: (UUID, Result<ParsedFeed, Error>).self) { group in
            for feed in feeds {
                group.addTask { [session] in
                    do {
                        let (data, _) = try await session.data(from: feed.url)
                        return (feed.id, .success(try FeedParser.parse(data: data)))
                    } catch {
                        return (feed.id, .failure(error))
                    }
                }
            }
            for await (feedID, result) in group {
                guard let idx = feeds.firstIndex(where: { $0.id == feedID }) else { continue }
                switch result {
                case .success(let parsed):
                    feeds[idx].lastFetched = Date()
                    feeds[idx].lastError = nil
                    if feeds[idx].title.isEmpty, !parsed.title.isEmpty {
                        feeds[idx].title = parsed.title
                    }
                    newCount += ingest(parsed.items, into: feeds[idx])
                case .failure(let error):
                    feeds[idx].lastError = error.localizedDescription
                }
            }
        }
        if newCount > 0 {
            hasUnseenArticles = true
            animateMenuBarIcon()
            // warm the grouping cache now, so the cost lands at refresh time
            // instead of when the user next opens the inbox
            _ = groupedInbox
        }
    }

    /// True while the popover is open — the menu bar icon shows its
    /// head-coloured "you're looking at me" variant.
    @Published var popoverOpen = false

    /// The user opened the popover — acknowledge the new-articles indicator.
    func markSeen() {
        hasUnseenArticles = false
    }

    /// Returns how many articles were actually new.
    @discardableResult
    private func ingest(_ items: [ParsedItem], into feed: Feed) -> Int {
        let now = Date()
        var added = 0
        for item in items.prefix(settings.maxArticlesPerFeed) {
            let key = item.guid ?? item.link?.absoluteString ?? item.title
            let id = "\(feed.url.absoluteString)#\(key)"
            guard seen[id] == nil else { continue }
            seen[id] = now
            added += 1
            articles.append(Article(
                id: id,
                feedID: feed.id,
                sourceTitle: feed.title,
                title: item.title,
                link: item.link,
                summary: item.summary,
                imageURL: item.imageURL,
                published: item.published ?? now,
                fetchedAt: now
            ))
        }
        return added
    }

    /// Play the menu bar wiggle for ~2.5 s (two loops of the frame cycle).
    private func animateMenuBarIcon() {
        iconAnimationTimer?.invalidate()
        var tick = 0
        let total = MenuBarIcon.frameCount * 2
        iconAnimationFrame = 0
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                tick += 1
                if tick >= total {
                    self.iconAnimationTimer?.invalidate()
                    self.iconAnimationTimer = nil
                    self.iconAnimationFrame = nil
                } else {
                    self.iconAnimationFrame = tick % MenuBarIcon.frameCount
                }
            }
        }
    }

    // MARK: - Article actions

    /// Open in browser, record in archive, mark read (clears in 15 min).
    func open(_ article: Article) {
        if let url = article.link {
            NSWorkspace.shared.open(url)
        }
        recordInArchive(id: article.id, title: article.title, link: article.link, sourceTitle: article.sourceTitle)
        mutate(article) { if $0.readAt == nil { $0.readAt = Date() } }
        save()
    }

    private func recordInArchive(id: String, title: String, link: URL?, sourceTitle: String) {
        guard !archive.contains(where: { $0.id == id && $0.openedAt.timeIntervalSinceNow > -60 }) else { return }
        archive.insert(ArchiveEntry(
            id: id, title: title, link: link,
            sourceTitle: sourceTitle, openedAt: Date()
        ), at: 0)
        if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
    }

    // MARK: - Bookmarks

    func isBookmarked(_ id: String) -> Bool {
        bookmarks.contains { $0.id == id }
    }

    func toggleBookmark(_ article: Article) {
        if let idx = bookmarks.firstIndex(where: { $0.id == article.id }) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.insert(BookmarkEntry(
                id: article.id,
                title: article.title,
                link: article.link,
                sourceTitle: article.sourceTitle,
                bookmarkedAt: Date()
            ), at: 0)
        }
        save()
    }

    func removeBookmark(_ bookmark: BookmarkEntry) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    /// Open a bookmarked article in the browser and record it in the archive.
    func openBookmark(_ bookmark: BookmarkEntry) {
        if let url = bookmark.link {
            NSWorkspace.shared.open(url)
        }
        recordInArchive(id: bookmark.id, title: bookmark.title, link: bookmark.link, sourceTitle: bookmark.sourceTitle)
        save()
    }

    func copyLink(_ article: Article) {
        guard let url = article.link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func toggleRead(_ article: Article) {
        mutate(article) { $0.readAt = $0.readAt == nil ? Date() : nil }
        save()
    }

    func clear(_ article: Article) {
        mutate(article) {
            $0.state = .cleared
            $0.clearedAt = Date()
        }
        save()
    }

    /// Move a cleared article back to the inbox (unread).
    func restore(_ article: Article) {
        mutate(article) {
            $0.state = .inbox
            $0.clearedAt = nil
            $0.readAt = nil
        }
        save()
    }

    /// Clear every inbox article belonging to a topic group at once.
    func clearGroup(_ group: TopicGroup) {
        let ids = Set(group.articles.map(\.id))
        let now = Date()
        for i in articles.indices where ids.contains(articles[i].id) && articles[i].state == .inbox {
            articles[i].state = .cleared
            articles[i].clearedAt = now
        }
        save()
    }

    func clearInbox() {
        let now = Date()
        for i in articles.indices where articles[i].state == .inbox {
            articles[i].state = .cleared
            articles[i].clearedAt = now
        }
        save()
    }

    func clearArchive() {
        archive.removeAll()
        save()
    }

    private func mutate(_ article: Article, _ change: (inout Article) -> Void) {
        guard let idx = articles.firstIndex(where: { $0.id == article.id }) else { return }
        change(&articles[idx])
    }

    // MARK: - Sweep (time-based transitions)

    func sweep() {
        let now = Date()
        var changed = false

        for i in articles.indices {
            // read articles clear themselves after 15 minutes
            if articles[i].state == .inbox,
               let readAt = articles[i].readAt,
               now.timeIntervalSince(readAt) >= AppSettings.readClearInterval {
                articles[i].state = .cleared
                articles[i].clearedAt = now
                changed = true
            }
        }

        // cleared articles are purged after 24 hours
        let purgeCount = articles.count
        articles.removeAll {
            $0.state == .cleared &&
            now.timeIntervalSince($0.clearedAt ?? now) >= AppSettings.clearedRetention
        }
        if articles.count != purgeCount { changed = true }

        let seenCount = seen.count
        seen = seen.filter { now.timeIntervalSince($0.value) < AppSettings.seenRetention }
        if seen.count != seenCount { changed = true }

        if changed { save() }
    }

    /// Minutes until a read article auto-clears; nil if unread.
    func minutesUntilClear(_ article: Article) -> Int? {
        guard let readAt = article.readAt, article.state == .inbox else { return nil }
        let remaining = AppSettings.readClearInterval - Date().timeIntervalSince(readAt)
        return max(0, Int((remaining / 60).rounded(.up)))
    }

    // MARK: - Import / export

    func exportSettings() -> Data? {
        let doc = SettingsExport(
            settings: settings,
            feeds: feeds.map { .init(url: $0.url, title: $0.title, colorIndex: $0.colorIndex) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(doc)
    }

    /// Returns an error message, or nil on success.
    func importSettings(from data: Data) -> String? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let doc = try? decoder.decode(SettingsExport.self, from: data) else {
            return "The file is not a valid Vestitel settings export."
        }
        settings = doc.settings
        var added = 0
        for exported in doc.feeds where !feeds.contains(where: { $0.url == exported.url }) {
            feeds.append(Feed(url: exported.url, title: exported.title, colorIndex: exported.colorIndex))
            added += 1
        }
        save()
        Task { await refreshAll() }
        return added == 0 && doc.feeds.isEmpty ? "Import contained no feeds." : nil
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        var feeds: [Feed]
        var articles: [Article]
        var archive: [ArchiveEntry]
        var bookmarks: [BookmarkEntry]?  // optional: absent in pre-bookmarks state files
        var settings: AppSettings
        var seen: [String: Date]
    }

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vestitel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func save() {
        let state = PersistedState(
            feeds: feeds, articles: articles, archive: archive,
            bookmarks: bookmarks, settings: settings, seen: seen
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PersistedState.self, from: data) else { return }
        feeds = state.feeds
        articles = state.articles
        archive = state.archive
        bookmarks = state.bookmarks ?? []
        settings = state.settings
        seen = state.seen
    }
}
