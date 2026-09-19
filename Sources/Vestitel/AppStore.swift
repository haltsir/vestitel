import Foundation
import AppKit
import Combine
import SwiftUI

/// A feed request answered with a bot-protection page (Cloudflare challenge
/// etc.) instead of feed content.
struct FeedBlockedError: Error, LocalizedError {
    let host: String
    var errorDescription: String? {
        "\(host) is blocking automated feed readers — a browser check is required."
    }
}

/// The site answered with an error status and no feed (a WordPress
/// "500 Internal Server Error" page, a 404 for a moved feed…).
struct FeedHTTPError: Error, LocalizedError {
    let status: Int
    var errorDescription: String? {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        return "The server answered HTTP \(status) (\(reason)) instead of a feed."
    }
}

@MainActor
final class AppStore: ObservableObject {

    @Published var feeds: [Feed] = []
    @Published var articles: [Article] = [] {
        didSet { inboxCache = nil }
    }
    @Published var archive: [ArchiveEntry] = []
    @Published var bookmarks: [BookmarkEntry] = []
    @Published var settings: AppSettings = AppSettings() {
        didSet {
            scheduleRefreshTimer()
            if settings.mutedKeywords != oldValue.mutedKeywords { applyMutedKeywords() }
            if let selected = selectedSmartInboxID,
               !settings.smartInboxes.contains(where: { $0.id == selected }) {
                selectedSmartInboxID = nil   // the selected view was deleted
            }
            if !adoptingSettings,
               Self.syncableSettings(settings) != Self.syncableSettings(oldValue) {
                settingsUpdatedAt = Date()
            }
            save()
            updateSyncFolderWatcher()
        }
    }
    @Published var isRefreshing = false
    /// Feeds being fetched by the per-feed refresh button (row spinners).
    @Published var refreshingFeedIDs: Set<UUID> = []
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
    /// (internal, not private: SyncEngine merges into it)
    var seen: [String: Date] = [:]

    // MARK: Sync state (see SyncEngine.swift)

    /// Stable identity of this machine in the sync folder.
    var machineID: String = UUID().uuidString
    /// Deletion tombstones so merges can't resurrect removed records.
    var removedFeeds: [String: Date] = [:]       // feed URL -> removedAt
    var removedBookmarks: [String: Date] = [:]   // article id -> removedAt
    var archiveClearedAt: Date? = nil
    /// When the syncable preferences last changed on this machine (or the
    /// stamp of the remote settings last adopted): last-writer-wins for
    /// preference sync. Machine-local fields (folder path, syncPreferences)
    /// never bump it, so enabling sync on a second Mac can't clobber the
    /// first Mac's setup.
    var settingsUpdatedAt: Date? = nil
    /// Set while assigning `settings` from load() or a sync merge, so the
    /// didSet doesn't stamp settingsUpdatedAt as if the user edited them.
    var adoptingSettings = false
    @Published var syncStatus: String? = nil
    var syncInFlight = false
    /// A sync trigger arrived while one was running — run once more after.
    var syncQueued = false
    /// FSEvents watcher on the sync folder (see SyncEngine.swift).
    var syncWatcher: FolderWatcher? = nil
    /// FSEvents watcher on the local events drop folder (see LocalSources.swift).
    var eventsWatcher: FolderWatcher? = nil
    /// Path the current watcher observes, so settings.didSet (which fires on
    /// every settings mutation) only rebuilds it when the path changes.
    var watchedSyncFolderPath: String? = nil
    /// Feeds we've already notified about being bot-blocked: one
    /// notification per block episode, cleared on the next successful fetch.
    private var notifiedBlockedFeeds: Set<UUID> = []
    /// Last written sync payload (updatedAt zeroed) — skip no-op writes.
    var lastSyncPayload: Data? = nil

    // MARK: Updater state (see Updater.swift)

    /// Human-readable progress/result of the last update check, for Settings.
    @Published var updateStatus = ""
    /// When a check last started (successful or not): the daily trigger
    /// uses it to know today is done.
    var lastUpdateCheck: Date? = nil
    /// Version that ran last time, so the launch after a swap can notify.
    var lastRunVersion: String? = nil
    /// A downloaded, verified bundle waiting for an idle moment (in-memory:
    /// the temp dir may not survive a restart, and the next check re-stages).
    @Published var stagedUpdatePath: String? = nil
    var stagedUpdateVersion: String? = nil
    var updaterTask: Task<Void, Never>? = nil

    private var sweepTimer: Timer?
    private var refreshTimer: Timer?
    let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Vestitel/1.0 (macOS RSS reader)"]
        return URLSession(configuration: config)
    }()

    // MARK: - Derived collections

    // MARK: Inbox hold (list stability while reading)

    /// While the popover is open on the Inbox tab, articles that arrive keep
    /// out of the visible list so it never shifts mid-read. Non-nil = hold
    /// active: anything fetched after this instant is hidden until the user
    /// taps the "N new" button (which moves the cutoff forward) or the hold
    /// ends (popover closed / tab left — then everything flows in).
    /// In-memory only: a restart shows everything, which is correct.
    @Published var inboxHoldStart: Date? = nil {
        didSet { inboxCache = nil }
    }

    private func isHeld(_ article: Article) -> Bool {
        guard let holdStart = inboxHoldStart else { return false }
        return article.fetchedAt > holdStart
    }

    /// Articles waiting behind the hold — the "N new" button's count.
    var heldCount: Int {
        guard inboxHoldStart != nil else { return 0 }
        return articles.lazy.filter { $0.state == .inbox && self.isHeld($0) }.count
    }

    /// Called by ContentView whenever popover visibility or the selected tab
    /// changes. Starting an already-running hold keeps the original cutoff.
    func updateInboxHold(active: Bool) {
        if active {
            if inboxHoldStart == nil { inboxHoldStart = Date() }
        } else {
            inboxHoldStart = nil
        }
    }

    /// The "N new" button: reveal what's waiting, keep holding new arrivals.
    func revealHeldArticles() {
        guard inboxHoldStart != nil else { return }
        inboxHoldStart = Date()
        hasUnseenArticles = false   // the user is looking at them right now
    }

    /// `inbox` is read many times per render (header count, every smart
    /// inbox chip, the grouping); filtering and sorting ~900 articles each
    /// time added up on popover open, so it is computed once per change
    /// of `articles` or the hold.
    private var inboxCache: [Article]?

    var inbox: [Article] {
        if let inboxCache { return inboxCache }
        let list = articles.filter { $0.state == .inbox && !isHeld($0) }
            .sorted { $0.published > $1.published }
        inboxCache = list
        return list
    }

    var unreadCount: Int {
        // excludes held articles so the chip matches the visible list
        articles.lazy.filter { $0.state == .inbox && !$0.isRead && !self.isHeld($0) }.count
    }

    /// Cleared by the user or the read countdown; keyword-filtered articles
    /// are listed separately so they don't bury the ones you cleared.
    var cleared: [Article] {
        articles.filter { $0.state == .cleared && !$0.isFiltered }
            .sorted { ($0.clearedAt ?? .distantPast) > ($1.clearedAt ?? .distantPast) }
    }

    /// Articles a muted keyword caught, newest first (the Cleared tab's
    /// "Filtered" view, for checking that the filters do what you meant).
    var filtered: [Article] {
        articles.filter { $0.state == .cleared && $0.isFiltered }
            .sorted { ($0.clearedAt ?? .distantPast) > ($1.clearedAt ?? .distantPast) }
    }

    // MARK: Smart inboxes

    /// The subtab the Inbox tab is showing; nil = All. In-memory only.
    @Published var selectedSmartInboxID: UUID? = nil

    var selectedSmartInbox: SmartInbox? {
        guard let id = selectedSmartInboxID else { return nil }
        return settings.smartInboxes.first { $0.id == id }
    }

    private var feedURLByID: [UUID: URL] {
        Dictionary(feeds.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
    }

    /// Lowercased title + summary + tag, the haystack for keyword rules
    /// (muted keywords and smart-inbox filters). The tag is in so a local
    /// source's kind ("last stock") can be filtered on or muted by itself.
    private static func searchText(of article: Article) -> String {
        if let cached = searchTextCache[article.id] { return cached }
        if searchTextCache.count > 4000 { searchTextCache.removeAll() }
        let text = [article.title, article.summary ?? "", article.tag ?? ""].joined(separator: "\n").lowercased()
        searchTextCache[article.id] = text
        return text
    }

    /// Lowercasing title + summary for every article on every smart inbox
    /// count was a measurable share of popover open; an article's text
    /// never changes for its id, so it is done once. Main-thread only.
    private static var searchTextCache: [String: String] = [:]

    func matches(_ article: Article, _ inbox: SmartInbox) -> Bool {
        matches(article, inbox, feedURLByID: feedURLByID)
    }

    private func matches(_ article: Article, _ inbox: SmartInbox, feedURLByID: [UUID: URL]) -> Bool {
        guard !inbox.filters.isEmpty else { return true }
        let text = Self.searchText(of: article)
        return inbox.filters.contains { filter in
            if !filter.sourceURLs.isEmpty {
                guard let url = feedURLByID[article.feedID],
                      filter.sourceURLs.contains(url) else { return false }
            }
            let keywords = filter.keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
            guard !keywords.isEmpty else { return true }
            return filter.matchAllKeywords
                ? keywords.allSatisfy(text.contains)
                : keywords.contains(where: text.contains)
        }
    }

    // MARK: Ad-hoc filter

    /// The Inbox tab's on-the-fly filter (the magnifier in the header): a
    /// smart inbox typed for the moment, never saved. Every whitespace-
    /// separated term must occur in the title, summary, tag or source name.
    /// In-memory only; survives popover close so a filter isn't lost when
    /// opening a link takes the focus away.
    @Published var inboxFilterText = ""
    @Published var inboxFilterShown = false

    var inboxFilterTerms: [String] {
        inboxFilterText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isInboxFiltering: Bool { !inboxFilterTerms.isEmpty }

    func toggleInboxFilter() {
        if inboxFilterShown { dismissInboxFilter() } else { inboxFilterShown = true }
    }

    func dismissInboxFilter() {
        inboxFilterShown = false
        inboxFilterText = ""
    }

    /// Everything that narrows the Inbox tab, resolved once per render:
    /// the selected smart inbox AND the ad-hoc filter terms.
    struct InboxScope {
        let smartInbox: SmartInbox?
        let terms: [String]
        let feedURLByID: [UUID: URL]
        let feedTitleByID: [UUID: String]
        var isNarrowing: Bool { smartInbox != nil || !terms.isEmpty }
    }

    var inboxScope: InboxScope {
        InboxScope(smartInbox: selectedSmartInbox, terms: inboxFilterTerms,
                   feedURLByID: feedURLByID,
                   feedTitleByID: Dictionary(feeds.map { ($0.id, $0.title.lowercased()) },
                                             uniquingKeysWith: { a, _ in a }))
    }

    private func matches(_ article: Article, _ scope: InboxScope) -> Bool {
        if let inbox = scope.smartInbox,
           !matches(article, inbox, feedURLByID: scope.feedURLByID) { return false }
        guard !scope.terms.isEmpty else { return true }
        let text = Self.searchText(of: article)
        let source = scope.feedTitleByID[article.feedID] ?? ""
        return scope.terms.allSatisfy { text.contains($0) || source.contains($0) }
    }

    /// `list` narrowed to a smart inbox; nil passes everything through.
    func articles(_ list: [Article], in inbox: SmartInbox?) -> [Article] {
        guard let inbox else { return list }
        let urls = feedURLByID
        return list.filter { matches($0, inbox, feedURLByID: urls) }
    }

    /// What the Inbox tab currently shows (All or the selected smart inbox,
    /// narrowed further by the ad-hoc filter).
    var visibleInbox: [Article] {
        let scope = inboxScope
        guard scope.isNarrowing else { return inbox }
        return inbox.filter { matches($0, scope) }
    }

    /// Topic groups narrowed to the selected smart inbox and filter: groups
    /// are built once over the whole inbox (that's the expensive part) and
    /// members that don't match are dropped, so a story stays grouped
    /// inside a view.
    var visibleGroupedInbox: [TopicGroup] {
        let scope = inboxScope
        guard scope.isNarrowing else { return groupedInbox }
        return groupedInbox.compactMap { group in
            let members = group.articles.filter { matches($0, scope) }
            guard !members.isEmpty else { return nil }
            return TopicGroup(id: group.id, headline: group.headline, articles: members,
                              sourceFeedID: group.sourceFeedID)
        }
    }

    func unreadCount(in inbox: SmartInbox) -> Int {
        let urls = feedURLByID
        return self.inbox.lazy.filter { !$0.isRead && self.matches($0, inbox, feedURLByID: urls) }.count
    }

    /// Unread count per smart inbox in one pass over the inbox, for the
    /// chip strip (which otherwise asks per chip, per ViewThatFits
    /// candidate layout).
    var smartInboxUnreadCounts: [UUID: Int] {
        let urls = feedURLByID
        var counts: [UUID: Int] = [:]
        for article in inbox where !article.isRead {
            for smart in settings.smartInboxes where matches(article, smart, feedURLByID: urls) {
                counts[smart.id, default: 0] += 1
            }
        }
        return counts
    }

    /// "Clear Inbox" scoped to what's on screen: with a smart inbox selected
    /// or a filter typed only the shown articles go (held ones are already
    /// excluded by `inbox`).
    func clearVisibleInbox() {
        let ids = Set(visibleInbox.map(\.id))
        let now = Date()
        for i in articles.indices where ids.contains(articles[i].id) && articles[i].state == .inbox {
            articles[i].state = .cleared
            articles[i].clearedAt = now
        }
        save()
    }

    func addSmartInbox(_ inbox: SmartInbox) {
        settings.smartInboxes.append(inbox)
    }

    func updateSmartInbox(_ inbox: SmartInbox) {
        guard let idx = settings.smartInboxes.firstIndex(where: { $0.id == inbox.id }) else { return }
        settings.smartInboxes[idx] = inbox
    }

    func removeSmartInbox(_ inbox: SmartInbox) {
        settings.smartInboxes.removeAll { $0.id == inbox.id }
    }

    /// Move one step up (-1) or down (+1) in display order.
    func moveSmartInbox(_ inbox: SmartInbox, by delta: Int) {
        guard let idx = settings.smartInboxes.firstIndex(where: { $0.id == inbox.id }) else { return }
        let target = idx + delta
        guard settings.smartInboxes.indices.contains(target) else { return }
        settings.smartInboxes.swapAt(idx, target)
    }

    // MARK: Muted keywords

    /// The first muted keyword found in the title, summary or tag, or nil.
    /// Case-insensitive substring match, so "меркурий" also catches
    /// "Меркурий" and "ретроградния Меркурий".
    func mutedKeyword(matching article: Article) -> String? {
        let keywords = settings.mutedKeywords
        guard !keywords.isEmpty else { return nil }
        let haystack = Self.searchText(of: article)
        return keywords.first { keyword in
            let needle = keyword.lowercased()
            return !needle.isEmpty && haystack.contains(needle)
        }
    }

    /// Re-run the filters over the whole inbox: adding a keyword should
    /// remove what's already there, not just what arrives next. Also
    /// releases articles a since-deleted keyword had caught, as long as
    /// they still hold up as cleared-by-filter, so a wrong keyword can be
    /// undone by removing it. Doesn't touch anything cleared by hand.
    func applyMutedKeywords() {
        let now = Date()
        for i in articles.indices {
            let match = mutedKeyword(matching: articles[i])
            if articles[i].state == .inbox, let match {
                articles[i].state = .cleared
                articles[i].clearedAt = now
                articles[i].filteredBy = match
            } else if articles[i].state == .cleared, articles[i].isFiltered, match == nil {
                articles[i].state = .inbox
                articles[i].clearedAt = nil
                articles[i].readAt = nil
                articles[i].filteredBy = nil
                articles[i].fetchedAt = now   // respects the inbox hold like any arrival
            }
        }
    }

    func addMutedKeyword(_ raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              !settings.mutedKeywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame })
        else { return }
        settings.mutedKeywords.append(keyword)
    }

    func removeMutedKeyword(_ keyword: String) {
        settings.mutedKeywords.removeAll { $0 == keyword }
    }

    /// Cached grouping structure: recomputing runs sentence embeddings over
    /// every title (slow), so it only happens when the inbox composition or
    /// sensitivity changes — not on every render/tab switch. The cache holds
    /// ids, not Article values, so read/cleared state is always current.
    private var groupCache: (key: Int, sensitivity: Double, ids: Set<String>,
                             structure: [(headline: String?, ids: [String])])?

    var groupedInbox: [TopicGroup] {
        let inbox = self.inbox
        if settings.groupBySource { return Self.sourceGroups(inbox) }
        guard settings.groupingEnabled else {
            return inbox.map { TopicGroup(id: $0.id, headline: nil, articles: [$0]) }
        }

        var hasher = Hasher()
        for article in inbox { hasher.combine(article.id) }
        hasher.combine(settings.groupingSensitivity)
        let key = hasher.finalize()

        let byID = Dictionary(inbox.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(byID.keys)
        let sensitivity = settings.groupingSensitivity
        var structure: [(headline: String?, ids: [String])]
        if let cache = groupCache, cache.key == key {
            structure = cache.structure
        } else if let cache = groupCache, cache.sensitivity == sensitivity, ids.isSubset(of: cache.ids) {
            // Only removals since the last grouping (a clear, a read
            // countdown, a hold release never removes). Groups are connected
            // components, so a removal can only split the group it left:
            // regroup that one group's survivors, keep every other as is.
            // A full regrouping of a large inbox costs hundreds of ms on the
            // main thread, which is what made clearing one row feel slow.
            structure = []
            for entry in cache.structure {
                let survivors = entry.ids.filter { ids.contains($0) }
                if survivors.count == entry.ids.count {
                    structure.append(entry)
                } else if survivors.count > 1 {
                    let members = survivors.compactMap { byID[$0] }
                    for group in TopicGrouper.regroup(members, sensitivity: sensitivity) {
                        structure.append((group.headline, group.articles.map(\.id)))
                    }
                } else if let only = survivors.first {
                    structure.append((nil, [only]))
                }
            }
            structure.sort {
                let a = $0.ids.compactMap { byID[$0]?.published }.max() ?? .distantPast
                let b = $1.ids.compactMap { byID[$0]?.published }.max() ?? .distantPast
                return a > b
            }
            groupCache = (key, sensitivity, ids, structure)
        } else {
            let groups = TopicGrouper.group(inbox, sensitivity: sensitivity)
            structure = groups.map { ($0.headline, $0.articles.map(\.id)) }
            groupCache = (key, sensitivity, ids, structure)
        }

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

    /// One block per feed, newest feed first, members newest first (the
    /// inbox is already sorted). A feed with one article is still a block,
    /// so the mode reads the same top to bottom.
    private static func sourceGroups(_ inbox: [Article]) -> [TopicGroup] {
        var order: [UUID] = []
        var members: [UUID: [Article]] = [:]
        for article in inbox {
            if members[article.feedID] == nil { order.append(article.feedID) }
            members[article.feedID, default: []].append(article)
        }
        return order.map { feedID in
            let articles = members[feedID] ?? []
            return TopicGroup(
                id: "source|\(feedID.uuidString)",
                headline: articles.first?.sourceTitle,
                articles: articles,
                sourceFeedID: feedID
            )
        }
    }

    // MARK: - Lifecycle

    init() {
        NotificationManager.shared.setup()
        load()
        // Local sources: files already waiting in the drop folder, then
        // whatever arrives later (folder watcher, vestitel:// URLs).
        startLocalEventsWatcher()
        ingestLocalEventFiles()
        OpenURLQueue.shared.handler = { [weak self] urls in
            self?.handleOpenURLs(urls)
        }
        noteVersionChange()
        sweep()
        // Warm the grouping caches (tokens, name tags, embeddings) now, on
        // the loaded inbox: cold they cost over a second for a large inbox,
        // which would otherwise land on the first popover open.
        DispatchQueue.main.async { [weak self] in _ = self?.groupedInbox }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweep() }
        }
        scheduleRefreshTimer()
        // Sync before the first refresh so a fresh machine adopts feeds from
        // the folder; refreshAll ends with another sync to push new articles.
        Task {
            await syncNow()
            await refreshAll()
        }
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
            let (data, response) = try await session.data(from: url)
            let parsed: ParsedFeed
            if let rss = try? FeedParser.parse(data: data) {
                parsed = rss
            } else if Self.looksBlocked(response: response, data: data) {
                return FeedBlockedError(host: url.host ?? "The site").localizedDescription
            } else {
                return "The URL did not return a recognizable RSS/Atom feed."
            }
            var feed = Feed(url: url, title: parsed.title.isEmpty ? (url.host ?? raw) : parsed.title, kind: .rss)
            feed.lastFetched = Date()
            feeds.append(feed)
            removedFeeds[url.absoluteString] = nil  // re-adding beats any old tombstone
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

    /// True if the URL fetches and parses as an RSS/Atom feed, i.e. anything
    /// addFeed would accept.
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

    /// Host of the feed a source label belongs to, for favicon lookup.
    func sourceHost(feedID: UUID? = nil, title: String) -> String? {
        (feeds.first(where: { $0.id == feedID })
            ?? feeds.first(where: { $0.title == title }))?.faviconHost
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
        removedFeeds[feed.url.absoluteString] = Date()
        save()
    }

    // MARK: - Refresh

    /// Fetch and parse one feed; never touches state (safe off-main).
    nonisolated private func fetchParsed(for feed: Feed) async -> Result<ParsedFeed, Error> {
        do {
            let (data, response) = try await session.data(from: feed.url)
            do {
                return .success(try FeedParser.parse(data: data))
            } catch {
                if Self.looksBlocked(response: response, data: data) {
                    return .failure(FeedBlockedError(host: feed.url.host ?? "The site"))
                }
                // A server error page is HTML, so the parser's complaint
                // about it is noise: the status code is the real story.
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return .failure(FeedHTTPError(status: http.statusCode))
                }
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Record a fetch result on the feed (lastFetched/lastError, blocked
    /// notification) and ingest its items. Returns how many were new.
    private func applyFetchResult(_ result: Result<ParsedFeed, Error>, to feedID: UUID) -> Int {
        guard let idx = feeds.firstIndex(where: { $0.id == feedID }) else { return 0 }
        switch result {
        case .success(let parsed):
            feeds[idx].lastFetched = Date()
            feeds[idx].lastError = nil
            notifiedBlockedFeeds.remove(feedID)
            if feeds[idx].title.isEmpty, !parsed.title.isEmpty {
                feeds[idx].title = parsed.title
            }
            return ingest(parsed.items, into: feeds[idx])
        case .failure(let error):
            feeds[idx].lastError = error.localizedDescription
            if error is FeedBlockedError, !notifiedBlockedFeeds.contains(feedID) {
                notifiedBlockedFeeds.insert(feedID)
                let host = feeds[idx].url.host ?? ""
                NotificationManager.shared.notifyFeedBlocked(
                    feedTitle: feeds[idx].title,
                    host: host,
                    siteURL: URL(string: "https://\(host)") ?? feeds[idx].url
                )
            }
            return 0
        }
    }

    func refreshAll() async {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
            save()
        }

        var newCount = 0
        // A refresh is also a good moment to sweep the events drop folder,
        // in case the folder watcher missed something.
        newCount += ingestLocalEventFiles()
        await withTaskGroup(of: (UUID, Result<ParsedFeed, Error>).self) { group in
            // local sources are never fetched: their content is pushed in
            for feed in feeds where !feed.isLocal {
                group.addTask {
                    (feed.id, await self.fetchParsed(for: feed))
                }
            }
            for await (feedID, result) in group {
                newCount += applyFetchResult(result, to: feedID)
            }
        }
        if newCount > 0 {
            hasUnseenArticles = true
            animateMenuBarIcon()
            // warm the grouping cache now, so the cost lands at refresh time
            // instead of when the user next opens the inbox
            _ = groupedInbox
        }
        await syncNow()
    }

    /// Fetch a single feed right now — the per-feed refresh button in
    /// Settings (retry a blocked feed, pull a listing without waiting for
    /// the timer). Same ingest semantics as a timed refresh.
    func refreshFeed(_ feed: Feed) async {
        guard !feed.isLocal, !refreshingFeedIDs.contains(feed.id) else { return }
        refreshingFeedIDs.insert(feed.id)
        defer { refreshingFeedIDs.remove(feed.id) }

        let result = await fetchParsed(for: feed)
        if applyFetchResult(result, to: feed.id) > 0 {
            hasUnseenArticles = true
            animateMenuBarIcon()
            _ = groupedInbox
        }
        save()
    }

    /// True while the popover is open — the menu bar icon shows its
    /// head-coloured "you're looking at me" variant.
    @Published var popoverOpen = false

    /// The user opened the popover — acknowledge the new-articles indicator
    /// and pull the latest state from the other machines.
    func markSeen() {
        hasUnseenArticles = false
        Task { await syncNow() }
    }

    /// True when a response is a bot-protection page rather than content:
    /// an explicit Cloudflare challenge header, or a block-ish status code
    /// carrying HTML where a feed should be.
    nonisolated static func looksBlocked(response: URLResponse?, data: Data) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if http.value(forHTTPHeaderField: "cf-mitigated") != nil { return true }
        guard [401, 403, 429, 503].contains(http.statusCode) else { return false }
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    /// Returns how many articles were actually new *and* reached the inbox:
    /// keyword-filtered arrivals are stored as cleared and don't count, so
    /// they never trigger the new-articles signal.
    /// (internal, not private: LocalSources ingests through it)
    @discardableResult
    func ingest(_ items: [ParsedItem], into feed: Feed) -> Int {
        let now = Date()
        var added = 0
        // Local sources aren't capped: every posted event was posted on purpose.
        let cap = feed.isLocal ? items.count : settings.maxArticlesPerFeed
        // Items older than this are skipped (and marked seen) when the
        // option is on; local events are posted on purpose, so never.
        let oldestAllowed: Date? = (settings.skipOldArticles && !feed.isLocal)
            ? now.addingTimeInterval(-Double(settings.maxArticleAgeDays) * 24 * 60 * 60)
            : nil
        for item in items.prefix(cap) {
            let key = item.guid ?? item.link?.absoluteString ?? item.title
            let id = "\(feed.url.absoluteString)#\(key)"
            // The seen date is refreshed on every fetch that still lists the
            // item, so an entry expires 30 days after the feed dropped it,
            // not 30 days after it was first met: a slow feed that keeps
            // months of items in its file would otherwise resurrect them
            // all the moment their first-seen dates aged out.
            let alreadySeen = seen[id] != nil
            seen[id] = now
            if alreadySeen { continue }
            if let oldestAllowed, let published = item.published, published < oldestAllowed {
                continue
            }
            if !feed.isLocal, let idx = duplicateIndex(feedID: feed.id, title: item.title) {
                // Same feed, same title, new guid: a republished story (dir.bg
                // files one piece under two sections with "-1" appended).
                // The existing row takes the newer link, image and time
                // (feeds list newest first, so the duplicate met here is
                // often the older one); if it was already read or cleared,
                // the re-post stays gone.
                let published = item.published ?? now
                if articles[idx].state == .inbox, published > articles[idx].published {
                    if let link = item.link { articles[idx].link = link }
                    if let image = item.imageURL { articles[idx].imageURL = image }
                    articles[idx].published = published
                }
                continue
            }
            var article = Article(
                id: id,
                feedID: feed.id,
                sourceTitle: feed.title,
                title: item.title,
                link: item.link,
                summary: item.summary,
                imageURL: item.imageURL,
                published: item.published ?? now,
                fetchedAt: now,
                tag: item.tag,
                symbol: item.symbol
            )
            if let keyword = mutedKeyword(matching: article) {
                article.state = .cleared
                article.clearedAt = now
                article.filteredBy = keyword
            } else {
                added += 1
            }
            articles.append(article)
        }
        return added
    }

    /// The article this feed already holds under the same title (case- and
    /// whitespace-insensitive), or nil. One source repeating itself is not
    /// a group of related stories, it is one story twice. Local sources are
    /// exempt at the call sites: a script posting "Backup finished" nightly
    /// means every one of them.
    /// (internal, not private: SyncEngine checks adoptions the same way)
    func duplicateIndex(feedID: UUID, title: String) -> Int? {
        let key = Self.titleKey(title)
        return articles.firstIndex { $0.feedID == feedID && Self.titleKey($0.title) == key }
    }

    /// Letters and digits only: a re-post that swaps straight quotes for
    /// curly ones, or drops a trailing full stop, is still the same title.
    private static func titleKey(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Collapse same-feed same-title inbox articles that got in before the
    /// ingest-time check existed, or through an older build on the other
    /// Mac: the newest stays, the rest go (their ids remain seen). A read
    /// mark on a dropped copy carries over, so reading the older copy
    /// doesn't resurface the story as unread. Runs at load and after every
    /// sync merge; returns whether anything changed.
    @discardableResult
    func collapseDuplicateReposts() -> Bool {
        let localFeedIDs = Set(feeds.filter(\.isLocal).map(\.id))
        var keptIndexByKey: [String: Int] = [:]
        var drop = Set<Int>()
        let ordered = articles.indices.sorted { articles[$0].published > articles[$1].published }
        for idx in ordered {
            let article = articles[idx]
            guard article.state == .inbox, !localFeedIDs.contains(article.feedID) else { continue }
            let key = "\(article.feedID.uuidString)\n\(Self.titleKey(article.title))"
            if let kept = keptIndexByKey[key] {
                if let readAt = article.readAt, readAt < (articles[kept].readAt ?? .distantFuture) {
                    articles[kept].readAt = readAt
                }
                drop.insert(idx)
            } else {
                keptIndexByKey[key] = idx
            }
        }
        guard !drop.isEmpty else { return false }
        articles = articles.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        return true
    }

    /// Play the menu bar wiggle for ~2.5 s (two loops of the frame cycle).
    /// (internal, not private: SyncEngine plays it when a merge brings news)
    func animateMenuBarIcon() {
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

    /// Open every article in the list at once — single save at the end
    /// instead of per-item (a full store inbox would write state 100×).
    func openAll(_ list: [Article]) {
        let now = Date()
        for article in list {
            if let url = article.link {
                NSWorkspace.shared.open(url)
            }
            recordInArchive(id: article.id, title: article.title, link: article.link, sourceTitle: article.sourceTitle)
            mutate(article) { if $0.readAt == nil { $0.readAt = now } }
        }
        save()
    }

    func openAllBookmarks() {
        for bookmark in bookmarks {
            if let url = bookmark.link {
                NSWorkspace.shared.open(url)
            }
            recordInArchive(id: bookmark.id, title: bookmark.title, link: bookmark.link, sourceTitle: bookmark.sourceTitle)
        }
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
            removedBookmarks[article.id] = Date()
        } else {
            bookmarks.insert(BookmarkEntry(
                id: article.id,
                title: article.title,
                link: article.link,
                sourceTitle: article.sourceTitle,
                bookmarkedAt: Date()
            ), at: 0)
            removedBookmarks[article.id] = nil
        }
        save()
    }

    func removeBookmark(_ bookmark: BookmarkEntry) {
        bookmarks.removeAll { $0.id == bookmark.id }
        removedBookmarks[bookmark.id] = Date()
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

    /// Move a cleared article back to the inbox (unread). Restoring a
    /// filtered article overrides the filter for that article only; the
    /// keyword stays.
    func restore(_ article: Article) {
        mutate(article) {
            $0.state = .inbox
            $0.clearedAt = nil
            $0.readAt = nil
            $0.filteredBy = nil
            // the stamp that lets this restore win over the other Macs'
            // cleared records of the article (see mergeSyncDocument)
            $0.restoredAt = Date()
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
        // held articles are exempt: "Clear Inbox" clears what the user sees,
        // never articles they were never shown
        for i in articles.indices where articles[i].state == .inbox && !isHeld(articles[i]) {
            articles[i].state = .cleared
            articles[i].clearedAt = now
        }
        save()
    }

    func clearArchive() {
        archive.removeAll()
        archiveClearedAt = Date()
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

        // The daily update check rides this timer instead of a one-shot timer
        // aimed at 12:30, which sleep or a late launch would silently miss.
        maybeRunDailyUpdateCheck()
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
            feeds: feeds.map { .init(url: $0.url, title: $0.title, colorIndex: $0.colorIndex, kind: $0.kind) }
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
        var incoming = doc.settings
        // machine-local: never taken from another Mac's export
        incoming.syncFolderPath = settings.syncFolderPath
        incoming.syncPreferences = settings.syncPreferences
        settings = incoming
        var added = 0
        for exported in doc.feeds where !feeds.contains(where: { $0.url == exported.url }) {
            feeds.append(Feed(url: exported.url, title: exported.title, colorIndex: exported.colorIndex, kind: exported.kind))
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
        // sync additions — all optional so older state files still decode
        var machineID: String?
        var removedFeeds: [String: Date]?
        var removedBookmarks: [String: Date]?
        var archiveClearedAt: Date?
        var settingsUpdatedAt: Date?
        // updater additions, optional likewise
        var lastUpdateCheck: Date?
        var lastRunVersion: String?
    }

    /// Application Support/Vestitel (also home to the local events drop
    /// folder). VESTITEL_STATE_DIR points a throwaway instance at its own
    /// state so it can run alongside the real app. Overriding $HOME does NOT
    /// work: FileManager resolves Application Support from the user record,
    /// so without this a "sandboxed" second instance silently shares (and
    /// fights over) the real state file.
    static var stateDirectory: URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["VESTITEL_STATE_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Vestitel", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stateURL: URL {
        stateDirectory.appendingPathComponent("state.json")
    }

    func save() {
        let state = PersistedState(
            feeds: feeds, articles: articles, archive: archive,
            bookmarks: bookmarks, settings: settings, seen: seen,
            machineID: machineID, removedFeeds: removedFeeds,
            removedBookmarks: removedBookmarks, archiveClearedAt: archiveClearedAt,
            settingsUpdatedAt: settingsUpdatedAt,
            lastUpdateCheck: lastUpdateCheck, lastRunVersion: lastRunVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
        writeSyncDocument()
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
        seen = state.seen
        machineID = state.machineID ?? machineID
        removedFeeds = state.removedFeeds ?? [:]
        removedBookmarks = state.removedBookmarks ?? [:]
        archiveClearedAt = state.archiveClearedAt
        lastUpdateCheck = state.lastUpdateCheck
        lastRunVersion = state.lastRunVersion
        settingsUpdatedAt = state.settingsUpdatedAt
        // last: its didSet fires save() → writeSyncDocument(), which must see
        // the fully loaded state (machineID above all). adoptingSettings:
        // loading is not a user edit, so it must not re-stamp settingsUpdatedAt.
        adoptingSettings = true
        settings = state.settings
        adoptingSettings = false
        if collapseDuplicateReposts() { save() }
    }
}
