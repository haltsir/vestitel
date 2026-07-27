import Foundation

/// One machine's contribution to the shared sync folder. Every machine
/// writes exactly one file (vestitel-<machineID>.json) and merges everyone
/// else's — no file is ever written by two machines, so dumb folder sync
/// (Google Drive, iCloud Drive, Syncthing…) can never produce conflicts.
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
}

extension AppStore {

    var syncFolderURL: URL? {
        guard let path = settings.syncFolderPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var ownSyncFileName: String { "vestitel-\(machineID).json" }

    private static func syncEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // sortedKeys: stable bytes, so "did anything change" is a data compare
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Read every other machine's document and merge it, then write our own.
    /// Reentrancy-guarded; reading happens off the main actor because cloud
    /// placeholder files can block on download.
    func syncNow() async {
        guard let folder = syncFolderURL, !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }

        let ownFile = ownSyncFileName
        let docs: [SyncDocument]? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var docs: [SyncDocument] = []
            for name in names where name.hasPrefix("vestitel-") && name.hasSuffix(".json") && name != ownFile {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let doc = try? decoder.decode(SyncDocument.self, from: data) else { continue }
                docs.append(doc)
            }
            return docs
        }.value

        guard let docs else {
            syncStatus = "Sync folder is unavailable."
            return
        }

        var changed = false
        for doc in docs where mergeSyncDocument(doc) {
            changed = true
        }
        if changed {
            save()   // save() also rewrites our sync document
        } else {
            writeSyncDocument()
        }
        let time = Date().formatted(date: .omitted, time: .shortened)
        syncStatus = docs.isEmpty
            ? "No other Macs found yet · checked \(time)"
            : "Merged \(docs.count) other Mac\(docs.count == 1 ? "" : "s") · \(time)"
    }

    /// Write our document if its content changed since the last write.
    /// Called from save(), so every local mutation propagates promptly.
    func writeSyncDocument() {
        guard let folder = syncFolderURL else { return }
        var doc = SyncDocument(
            machineID: machineID,
            machineName: Host.current().localizedName ?? "Mac",
            updatedAt: .distantPast,   // placeholder: excluded from change compare
            feeds: feeds, articles: articles, seen: seen,
            archive: archive, bookmarks: bookmarks,
            removedFeeds: removedFeeds, removedBookmarks: removedBookmarks,
            archiveClearedAt: archiveClearedAt
        )
        let encoder = Self.syncEncoder()
        guard let payload = try? encoder.encode(doc), payload != lastSyncPayload else { return }
        doc.updatedAt = Date()
        guard let data = try? encoder.encode(doc) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try data.write(to: folder.appendingPathComponent(ownSyncFileName), options: .atomic)
            lastSyncPayload = payload
        } catch {
            syncStatus = "Couldn't write to the sync folder."
        }
    }

    /// Remove our file from the sync folder (turning sync off).
    func deleteSyncDocument() {
        guard let folder = syncFolderURL else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(ownSyncFileName))
        lastSyncPayload = nil
    }

    /// Merge one remote machine's document into local state. Returns true if
    /// anything changed. Rules: unions everywhere, tombstones beat records
    /// they postdate, cleared beats inbox (bias toward hiding — the whole
    /// point of sync is not seeing things twice), earliest timestamps win so
    /// countdowns (read → clear, cleared → purge) don't restart per machine.
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
                if let readAt = remote.readAt, readAt < (a.readAt ?? .distantFuture) {
                    a.readAt = readAt
                }
                if remote.state == .cleared {
                    if a.state == .inbox {
                        a.state = .cleared
                        a.clearedAt = remote.clearedAt ?? now
                    } else if let clearedAt = remote.clearedAt,
                              clearedAt < (a.clearedAt ?? .distantFuture) {
                        a.clearedAt = clearedAt
                    }
                }
                if a != articles[idx] {
                    articles[idx] = a
                    changed = true
                }
            } else if seen[remote.id] == nil {
                // Never seen here — genuinely new. (A local seen entry with
                // no article means we already cleared and purged it.)
                var a = remote
                a.feedID = localFeed.id
                a.sourceTitle = localFeed.title
                articles.append(a)
                localIndexByID[a.id] = articles.count - 1
                seen[a.id] = doc.seen[a.id] ?? a.fetchedAt
                changed = true
            }
        }

        // Seen: union, earliest first-seen date wins. This is what keeps a
        // store product cleared on one Mac from ever resurfacing on another.
        for (id, date) in doc.seen where date < (seen[id] ?? .distantFuture) {
            seen[id] = date
            changed = true
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
