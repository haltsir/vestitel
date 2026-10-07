import Foundation
import CoreServices
import Network

/// One machine's contribution to the shared sync folder. Every machine
/// writes exactly one file (vestitel-<machineID>.json.gz; plain .json
/// before 1.27, still read) and merges everyone else's — no file is ever
/// written by two machines, so dumb folder sync (Google Drive, iCloud
/// Drive, Syncthing…) can never produce conflicts.
struct SyncDocument: Codable {
    var machineID: String
    var machineName: String
    var updatedAt: Date
    var feeds: [Feed]
    var articles: [Article]
    var seen: [String: Date]
    var archive: [ArchiveEntry]
    var bookmarks: [BookmarkEntry]
    /// Tombstones: deletions must outlive the deleted record or merges
    /// from machines that still have it would resurrect it.
    var removedFeeds: [String: Date]       // feed URL -> removedAt
    var removedBookmarks: [String: Date]   // article id -> removedAt
    var archiveClearedAt: Date?
    /// The writer's preferences and their last-edit stamp; present only
    /// when that machine has "Sync preferences" on. Among Macs with it on,
    /// the newest stamp wins (optional, so pre-1.11 documents decode).
    var settings: AppSettings?
    var settingsUpdatedAt: Date?
}

extension AppStore {

    var syncFolderURL: URL? {
        guard let path = settings.syncFolderPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var ownSyncFileName: String { "vestitel-\(machineID).json.gz" }
    /// What this machine wrote before 1.27; removed after the first .gz write.
    private var ownLegacySyncFileName: String { "vestitel-\(machineID).json" }

    nonisolated static func isSyncFileName(_ name: String) -> Bool {
        name.hasPrefix("vestitel-") && (name.hasSuffix(".json.gz") || name.hasSuffix(".json"))
    }

    /// Decodes a sync file of either generation: gzip-wrapped (1.27+) or
    /// plain JSON. nil for torn or foreign content.
    nonisolated static func decodeSyncDocument(_ data: Data) -> SyncDocument? {
        let json: Data
        if Gzip.isGzip(data) {
            guard let inflated = Gzip.decompress(data) else { return nil }
            json = inflated
        } else {
            json = data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncDocument.self, from: json)
    }

    /// The preference fields that travel between Macs: everything except
    /// the machine-local sync wiring itself.
    static func syncableSettings(_ s: AppSettings) -> AppSettings {
        var shared = s
        shared.syncFolderPath = nil
        shared.syncPreferences = false
        // the desktop widget is per-Mac: screens, and taste, differ
        shared.desktopWidgetEnabled = false
        shared.desktopWidgetTitleSize = 32
        shared.desktopWidgetFrame = nil
        shared.desktopWidgetScreen = nil
        return shared
    }

    nonisolated static func syncEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // sortedKeys: stable bytes, so "did anything change" is a data compare
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Read every other machine's document and merge it, then write our own.
    /// Reentrancy-guarded; reading happens off the main actor because cloud
    /// placeholder files can block on download. A trigger that lands mid-sync
    /// (the folder watcher fires while a placeholder download blocks the
    /// read) queues one follow-up pass instead of being dropped.
    func syncNow() async {
        guard let folder = syncFolderURL else { return }
        if syncInFlight {
            syncQueued = true
            return
        }
        syncInFlight = true
        defer {
            syncInFlight = false
            if syncQueued {
                syncQueued = false
                Task { await self.syncNow() }
            }
        }
        let unreadBefore = unreadCount

        let ownFiles: Set<String> = [ownSyncFileName, ownLegacySyncFileName]
        let docs: [SyncDocument]? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
            // One document per machine: a Mac mid-upgrade has both its old
            // .json and its new .json.gz for a while; the newer stamp wins.
            var newest: [String: SyncDocument] = [:]
            for name in names where Self.isSyncFileName(name) && !ownFiles.contains(name) {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let doc = Self.decodeSyncDocument(data) else { continue }
                if let held = newest[doc.machineID], held.updatedAt >= doc.updatedAt { continue }
                newest[doc.machineID] = doc
            }
            return Array(newest.values)
        }.value

        guard let docs else {
            syncStatus = "Sync folder is unavailable."
            return
        }

        var changed = false
        for doc in docs where mergeSyncDocument(doc) {
            changed = true
        }
        if collapseDuplicateReposts() { changed = true }
        adoptRemoteSettings(from: docs)
        if changed {
            save()   // save() also schedules a rewrite of our sync document
        } else {
            scheduleSyncWrite()
        }
        // A merge that brought new articles gets the same signals as a fetch
        // that did — unless the popover is open and the user is looking.
        if !popoverOpen, unreadCount > unreadBefore {
            hasUnseenArticles = true
            animateMenuBarIcon()
            _ = groupedInbox   // warm the grouping cache off the render path
        }
        let time = Date().formatted(date: .omitted, time: .shortened)
        syncStatus = docs.isEmpty
            ? "No other Macs found yet · checked \(time)"
            : "Merged \(docs.count) other Mac\(docs.count == 1 ? "" : "s") · \(time)"
        checkLostAndFound()
    }

    /// Adopt the newest remote preferences (last writer wins) when this
    /// Mac has preference sync on. Machine-local fields (the folder path,
    /// the syncPreferences toggle itself) always keep their local values,
    /// and adoption re-stamps with the REMOTE date, so merely adopting
    /// never makes this Mac look like the newest editor.
    private func adoptRemoteSettings(from docs: [SyncDocument]) {
        guard settings.syncPreferences else { return }
        let candidates = docs.compactMap { doc in
            doc.settings.map { (settings: $0, updatedAt: doc.settingsUpdatedAt ?? .distantPast) }
        }
        guard let best = candidates.max(by: { $0.updatedAt < $1.updatedAt }),
              best.updatedAt > (settingsUpdatedAt ?? .distantPast) else { return }
        var adopted = best.settings
        adopted.syncFolderPath = settings.syncFolderPath
        adopted.syncPreferences = settings.syncPreferences
        settingsUpdatedAt = best.updatedAt
        guard adopted != settings else { return }   // stamp caught up; nothing to change
        adoptingSettings = true
        settings = adopted   // didSet applies muted keywords, saves, rewrites our doc
        adoptingSettings = false
    }

    // MARK: Writing our document

    /// Trailing debounce on the sync write: a burst of saves (a merge
    /// followed by its save, a run of clears while reading) becomes one
    /// upload instead of several back to back, each of which rewrote the
    /// file while the cloud client was still uploading the previous one.
    static let syncWriteDebounce: TimeInterval = 3
    /// …but never later than this after the first request of a burst.
    static let syncWriteMaxDelay: TimeInterval = 20

    /// Ask for our document to be rewritten soon. Called from save(), so
    /// every local mutation propagates within seconds. Nothing is written
    /// while the Mac is offline: Google Drive, failing to upload a change
    /// made during an outage, has reverted the file and filed the bytes
    /// under "Lost & Found" instead of retrying; the pending write flushes
    /// once the network is back (`networkReachabilityChanged`).
    func scheduleSyncWrite() {
        guard syncFolderURL != nil else { return }
        let now = Date()
        let first = syncWriteRequestedAt ?? now
        syncWriteRequestedAt = first
        syncWriteTimer?.invalidate()
        let fireAt = min(now.addingTimeInterval(Self.syncWriteDebounce),
                         first.addingTimeInterval(Self.syncWriteMaxDelay))
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushSyncWrite() }
        }
        RunLoop.main.add(timer, forMode: .common)   // fires while the popover tracks the mouse too
        syncWriteTimer = timer
    }

    /// Perform the pending write now, unless offline (it stays pending).
    func flushSyncWrite() {
        syncWriteTimer?.invalidate()
        syncWriteTimer = nil
        guard syncWriteRequestedAt != nil, networkReachable else { return }
        syncWriteRequestedAt = nil
        writeSyncDocument()
    }

    func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in self?.networkReachabilityChanged(reachable) }
        }
        monitor.start(queue: DispatchQueue(label: "vestitel.network-monitor"))
        networkMonitor = monitor
    }

    func networkReachabilityChanged(_ reachable: Bool) {
        guard reachable != networkReachable else { return }
        networkReachable = reachable
        if reachable, syncWriteRequestedAt != nil {
            // a fresh debounce from now: give the cloud client a moment to
            // reconnect before handing it the file
            syncWriteRequestedAt = Date()
            scheduleSyncWrite()
        }
    }

    /// Write our document if its content changed since the last write.
    /// Immediate; the debounced entry point is `scheduleSyncWrite`.
    func writeSyncDocument() {
        guard let folder = syncFolderURL else { return }
        // lastFetched/lastError are per-machine fetch status, not shared
        // state — included, every refresh becomes a payload change and the
        // cloud client re-uploads the whole file even when nothing new came.
        let sharedFeeds = feeds.map { feed in
            var f = feed
            f.lastFetched = nil
            f.lastError = nil
            return f
        }
        var doc = SyncDocument(
            machineID: machineID,
            machineName: Host.current().localizedName ?? "Mac",
            updatedAt: .distantPast,   // placeholder: excluded from change compare
            feeds: sharedFeeds, articles: articles, seen: seen,
            archive: archive, bookmarks: bookmarks,
            removedFeeds: removedFeeds, removedBookmarks: removedBookmarks,
            archiveClearedAt: archiveClearedAt,
            settings: settings.syncPreferences ? Self.syncableSettings(settings) : nil,
            settingsUpdatedAt: settings.syncPreferences ? settingsUpdatedAt : nil
        )
        let encoder = Self.syncEncoder()
        guard let payload = try? encoder.encode(doc), payload != lastSyncPayload else { return }
        doc.updatedAt = Date()
        guard let json = try? encoder.encode(doc), let data = Gzip.compress(json) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Written in place, never atomically: an atomic save is a temp file
        // renamed over the original, which Google Drive sees as delete + new
        // file and, when it catches one mid-upload, files the orphan under
        // "Lost & Found". Only we write this file and readers skip a torn
        // decode (a gzip member fails its CRC), so in-place is safe.
        do {
            try data.write(to: folder.appendingPathComponent(ownSyncFileName))
            lastSyncPayload = payload
            try? fm.removeItem(at: folder.appendingPathComponent(ownLegacySyncFileName))
        } catch {
            syncStatus = "Couldn't write to the sync folder."
        }
    }

    /// (Re)start the folder watcher after a sync-folder change. Called from
    /// settings.didSet, which fires on every settings mutation — hence the
    /// no-op guard on the watched path.
    func updateSyncFolderWatcher() {
        guard syncFolderURL?.path != watchedSyncFolderPath else { return }
        watchedSyncFolderPath = syncFolderURL?.path
        syncWatcher = nil
        guard let folder = syncFolderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ownFiles: Set<String> = [ownSyncFileName, ownLegacySyncFileName]
        syncWatcher = FolderWatcher(
            folder: folder,
            latency: 2.0,   // cloud clients write in bursts
            isRelevant: { name in Self.isSyncFileName(name) && !ownFiles.contains(name) }
        ) { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
    }

    /// Remove our file from the sync folder (turning sync off).
    func deleteSyncDocument() {
        guard let folder = syncFolderURL else { return }
        syncWriteTimer?.invalidate()
        syncWriteTimer = nil
        syncWriteRequestedAt = nil
        for name in [ownSyncFileName, ownLegacySyncFileName] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        lastSyncPayload = nil
        lostAndFoundCopies = []
    }

    // MARK: Google Drive's Lost & Found

    /// Where Google Drive for desktop parks a file whose upload it gave up
    /// on (one account folder per signed-in account). It then repeats a
    /// "File not synced" notice at every start until the copy is gone,
    /// which is baffling when the file is one Vestitel rewrites every few
    /// minutes anyway: the live document has long superseded the copy.
    static var driveLostAndFoundRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/DriveFS/lost_and_found", isDirectory: true)
    }

    /// Vestitel sync files under `root`, one directory level down.
    nonisolated static func lostAndFoundCopies(under root: URL) -> [LostAndFoundCopy] {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var copies: [LostAndFoundCopy] = []
        for account in accounts {
            guard (try? account.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where isSyncFileName(file.lastPathComponent) {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                copies.append(LostAndFoundCopy(url: file, date: date))
            }
        }
        return copies.sorted { $0.date > $1.date }
    }

    func checkLostAndFound() {
        let copies = Self.lostAndFoundCopies(under: Self.driveLostAndFoundRoot)
        if copies != lostAndFoundCopies { lostAndFoundCopies = copies }
    }

    /// Move a stale copy to the Trash (reversible) and re-check.
    func trashLostAndFoundCopy(_ copy: LostAndFoundCopy) {
        try? FileManager.default.trashItem(at: copy.url, resultingItemURL: nil)
        checkLostAndFound()
    }

    /// Merge one remote machine's document into local state. Returns true if
    /// anything changed. Rules: unions everywhere, tombstones beat records
    /// they postdate, cleared beats inbox (bias toward hiding — the whole
    /// point of sync is not seeing things twice) unless the article was
    /// restored after that clear (`restoredAt`, the latest action wins),
    /// earliest timestamps win so countdowns (read → clear, cleared → purge)
    /// don't restart per machine.
    private func mergeSyncDocument(_ doc: SyncDocument) -> Bool {
        var changed = false
        let now = Date()

        // Tombstones: keep the latest removal date.
        for (url, date) in doc.removedFeeds where date > (removedFeeds[url] ?? .distantPast) {
            removedFeeds[url] = date
            changed = true
        }
        for (id, date) in doc.removedBookmarks where date > (removedBookmarks[id] ?? .distantPast) {
            removedBookmarks[id] = date
            changed = true
        }
        if let cleared = doc.archiveClearedAt, cleared > (archiveClearedAt ?? .distantPast) {
            archiveClearedAt = cleared
            changed = true
        }

        // Apply feed tombstones locally (mirrors removeFeed).
        for feed in feeds {
            if let removed = removedFeeds[feed.url.absoluteString], removed > feed.addedAt {
                feeds.removeAll { $0.id == feed.id }
                articles.removeAll { $0.feedID == feed.id && $0.state == .inbox && !$0.isRead }
                changed = true
            }
        }

        // Adopt remote feeds we don't have (matched by URL — ids are
        // per-machine). Keeping the remote id makes its articles line up.
        var localFeedByURL = Dictionary(feeds.map { ($0.url.absoluteString, $0) },
                                        uniquingKeysWith: { a, _ in a })
        for remote in doc.feeds {
            let key = remote.url.absoluteString
            guard localFeedByURL[key] == nil else { continue }
            if let removed = removedFeeds[key], removed > remote.addedAt { continue }
            feeds.append(remote)
            localFeedByURL[key] = remote
            changed = true
        }

        // Articles: remote feed id -> URL -> local feed.
        let remoteFeedByID = Dictionary(doc.feeds.map { ($0.id, $0) },
                                        uniquingKeysWith: { a, _ in a })
        var localIndexByID = Dictionary(articles.enumerated().map { ($0.element.id, $0.offset) },
                                        uniquingKeysWith: { a, _ in a })
        for remote in doc.articles {
            guard let remoteFeed = remoteFeedByID[remote.feedID],
                  let localFeed = localFeedByURL[remoteFeed.url.absoluteString] else { continue }
            if let idx = localIndexByID[remote.id] {
                var a = articles[idx]
                // A restore is the latest action on the article: remote
                // read/cleared records from before it are stale (the other
                // Mac adopted our own earlier clear and still carries it),
                // and would otherwise re-clear the article within seconds
                // of every restore. Latest stamp from any Mac is kept.
                if let restoredAt = remote.restoredAt, restoredAt > (a.restoredAt ?? .distantPast) {
                    a.restoredAt = restoredAt
                }
                let restoredAt = a.restoredAt ?? .distantPast
                if let readAt = remote.readAt, readAt > restoredAt,
                   readAt < (a.readAt ?? .distantFuture) {
                    a.readAt = readAt
                }
                if remote.state == .cleared, (remote.clearedAt ?? .distantPast) > restoredAt || a.restoredAt == nil {
                    if a.state == .inbox {
                        a.state = .cleared
                        a.clearedAt = remote.clearedAt ?? now
                    } else if let clearedAt = remote.clearedAt,
                              clearedAt < (a.clearedAt ?? .distantFuture) {
                        a.clearedAt = clearedAt
                    }
                } else if remote.state == .inbox, a.state == .cleared,
                          let remoteRestore = remote.restoredAt,
                          remoteRestore > (a.clearedAt ?? .distantPast) {
                    // restored on the other Mac after this one cleared it
                    a.state = .inbox
                    a.clearedAt = nil
                    a.readAt = nil
                    a.filteredBy = nil
                    a.fetchedAt = now   // arrives like a new article: inbox hold applies
                }
                if a != articles[idx] {
                    articles[idx] = a
                    changed = true
                }
            } else if seen[remote.id] == nil {
                // Never seen here — genuinely new. (A local seen entry with
                // no article means we already cleared and purged it.)
                if !localFeed.isLocal, duplicateIndex(feedID: localFeed.id, title: remote.title) != nil {
                    // the other Mac fetched a re-post of a story this one
                    // already holds; same rule as ingest, keep one row
                    seen[remote.id] = now
                    changed = true
                    continue
                }
                var a = remote
                a.feedID = localFeed.id
                a.sourceTitle = localFeed.title
                seen[a.id] = doc.seen[a.id] ?? a.fetchedAt
                // local arrival time, not the remote's fetch time — the
                // inbox hold compares fetchedAt against its cutoff, and a
                // remote timestamp would predate it and skip the hold
                a.fetchedAt = now
                // this Mac's muted keywords apply to what it adopts, too
                if a.state == .inbox, let keyword = mutedKeyword(matching: a) {
                    a.state = .cleared
                    a.clearedAt = now
                    a.filteredBy = keyword
                }
                articles.append(a)
                localIndexByID[a.id] = articles.count - 1
                changed = true
            }
        }

        // Seen: union, latest date wins. Presence is what keeps an article
        // cleared on one Mac from ever resurfacing on another; the date is
        // refreshed by every fetch that still lists the item (see ingest),
        // so the newest stamp from any Mac is the one that reflects whether
        // the feed still carries it. Entries sweep() would immediately prune
        // are not adopted — otherwise a locally-pruned id resurrects from
        // any document that still carries it, and the prune → merge → prune
        // cycle rewrites the sync file (and keeps the cloud client busy)
        // around every entry aging past retention.
        // A newer date for an id already held is taken quietly: both Macs
        // refresh the same ids on every fetch, and flagging each of those
        // would rewrite this Mac's file after every merge.
        for (id, date) in doc.seen where date > (seen[id] ?? .distantPast) {
            if now.timeIntervalSince(date) >= AppSettings.seenRetention { continue }
            if seen[id] == nil { changed = true }
            seen[id] = date
        }

        // Bookmarks: tombstoned union.
        var bookmarksChanged = false
        bookmarks.removeAll { b in
            guard let removed = removedBookmarks[b.id], removed > b.bookmarkedAt else { return false }
            bookmarksChanged = true
            return true
        }
        let localBookmarkIDs = Set(bookmarks.map(\.id))
        for remote in doc.bookmarks {
            guard !localBookmarkIDs.contains(remote.id) else { continue }
            if let removed = removedBookmarks[remote.id], removed > remote.bookmarkedAt { continue }
            bookmarks.append(remote)
            bookmarksChanged = true
        }
        if bookmarksChanged {
            bookmarks.sort { $0.bookmarkedAt > $1.bookmarkedAt }
            changed = true
        }

        // Archive: union above the clear watermark. Keyed on id + whole
        // seconds — ISO8601 round-trips drop sub-second precision.
        var archiveChanged = false
        if let clearedAt = archiveClearedAt {
            let before = archive.count
            archive.removeAll { $0.openedAt < clearedAt }
            archiveChanged = archive.count != before
        }
        func archiveKey(_ e: ArchiveEntry) -> String {
            "\(e.id)|\(Int(e.openedAt.timeIntervalSince1970))"
        }
        let localArchiveKeys = Set(archive.map(archiveKey))
        for entry in doc.archive {
            if let clearedAt = archiveClearedAt, entry.openedAt < clearedAt { continue }
            guard !localArchiveKeys.contains(archiveKey(entry)) else { continue }
            archive.append(entry)
            archiveChanged = true
        }
        if archiveChanged {
            archive.sort { $0.openedAt > $1.openedAt }
            if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
            changed = true
        }

        return changed
    }
}

/// A Vestitel sync file Google Drive moved to its Lost & Found.
struct LostAndFoundCopy: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: String { url.path }
}

/// FSEvents watcher on a folder: fires when a file the caller cares about
/// changes, so folder-based transports (the sync folder, the local events
/// drop folder) react within seconds instead of at the next timer tick.
/// FSEvents (not a kqueue DispatchSource on the directory) because cloud
/// clients may rewrite a file in place, which a directory-level kqueue
/// watch never sees. Our own writes are ignored (kFSEventStreamCreateFlagIgnoreSelf).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let folderPath: String
    private let isRelevant: (String) -> Bool
    private let onChange: () -> Void

    /// `isRelevant` is asked per changed file name. `latency` is the FSEvents
    /// coalescing window in seconds.
    init?(folder: URL, latency: TimeInterval, isRelevant: @escaping (String) -> Bool,
          onChange: @escaping () -> Void) {
        self.folderPath = (folder.path as NSString).standardizingPath
        self.isRelevant = isRelevant
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(paths: paths)
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagIgnoreSelf   // our own writes don't re-trigger
            )
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func handle(paths: [String]) {
        let relevant = paths.contains { path in
            // An event-queue overflow reports the folder itself with
            // "must scan subdirs": treat it as "something may have changed".
            if (path as NSString).standardizingPath == folderPath { return true }
            return isRelevant((path as NSString).lastPathComponent)
        }
        if relevant { onChange() }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
