import Foundation

// MARK: - Feed

enum FeedKind: String, Codable {
    case rss
    /// A store product-listing page watched for new products (ozone.bg-style
    /// category pages). Products land in the separate Store inbox, and their
    /// `seen` entries are kept forever so a cleared product never reappears.
    case store
    /// A source that lives on this Mac: another app or a script posting
    /// "things that happened" through the events drop folder or the
    /// vestitel:// URL scheme (see LocalSources.swift). Never fetched; its
    /// URL is a synthetic vestitel://source/<slug> that only serves as a
    /// stable identity (article ids, sync matching, colour).
    case local
}

struct Feed: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var url: URL
    var title: String
    var addedAt: Date = Date()
    var lastFetched: Date? = nil
    var lastError: String? = nil
    /// Index into SourcePalette; nil = automatic (derived from the URL).
    var colorIndex: Int? = nil
    /// nil = rss (pre-store state files decode tolerantly).
    var kind: FeedKind? = nil

    var isStore: Bool { kind == .store }
    var isLocal: Bool { kind == .local }

    /// Host to look a favicon up for; nil when the feed has no site (local
    /// sources would otherwise resolve to the synthetic URL's host).
    var faviconHost: String? { isLocal ? nil : url.host }
}

// MARK: - Article

enum ArticleState: String, Codable {
    case inbox      // visible in the inbox (unread or read-and-counting-down)
    case cleared    // cleared; recoverable for 24h, then purged
}

struct Article: Identifiable, Codable, Hashable {
    var id: String              // stable: feed URL + guid/link
    var feedID: UUID
    var sourceTitle: String
    var title: String
    var link: URL?
    var summary: String?
    var imageURL: URL? = nil
    var published: Date
    var fetchedAt: Date

    var state: ArticleState = .inbox
    var readAt: Date? = nil     // set when clicked; auto-clears 15 min later
    var clearedAt: Date? = nil  // set when cleared; purged 24h later

    var isRead: Bool { readAt != nil }
}

// MARK: - Archive

struct ArchiveEntry: Identifiable, Codable, Hashable {
    var id: String              // article id
    var title: String
    var link: URL?
    var sourceTitle: String
    var openedAt: Date
}

// MARK: - Bookmarks

struct BookmarkEntry: Identifiable, Codable, Hashable {
    var id: String              // article id
    var title: String
    var link: URL?
    var sourceTitle: String
    var bookmarkedAt: Date
}

// MARK: - Topic group

struct TopicGroup: Identifiable {
    var id: String
    var headline: String?       // nil for singleton groups
    var articles: [Article]

    var newest: Date { articles.map(\.published).max() ?? .distantPast }
}

// MARK: - Settings

struct AppSettings: Codable {
    var refreshMinutes: Int = 15
    var groupingEnabled: Bool = true
    /// 0...1 — higher groups more aggressively (looser similarity threshold)
    var groupingSensitivity: Double = 0.5
    var maxArticlesPerFeed: Int = 50
    /// When true the menu bar icon may use colour (new-article signal,
    /// popover-open head, arrival animation); when false it is strictly
    /// monochrome in every state.
    var allowColoredIcon: Bool = true
    var compactRows: Bool = false
    /// Absolute path of a cloud-synced folder shared between Macs (Google
    /// Drive etc.); nil = sync off. Each machine writes only its own
    /// vestitel-<machineID>.json there and merges the others'.
    var syncFolderPath: String? = nil
    /// Walk every page of the Ozone "latest additions" listing once a day at
    /// StoreScan.dailyHour:dailyMinute and report what wasn't there before.
    /// Off by default — the scan makes dozens of slow requests.
    var storeScanEnabled: Bool = false
    /// Check GitHub releases once a day and install a signed newer build
    /// while the app is idle (see Updater.swift).
    var autoUpdateEnabled: Bool = true

    init() {}

    // Tolerant decoding: missing keys (older state files / exports) fall back
    // to defaults instead of failing the whole state load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 15
        groupingEnabled = try c.decodeIfPresent(Bool.self, forKey: .groupingEnabled) ?? true
        groupingSensitivity = try c.decodeIfPresent(Double.self, forKey: .groupingSensitivity) ?? 0.5
        maxArticlesPerFeed = try c.decodeIfPresent(Int.self, forKey: .maxArticlesPerFeed) ?? 50
        allowColoredIcon = try c.decodeIfPresent(Bool.self, forKey: .allowColoredIcon) ?? true
        compactRows = try c.decodeIfPresent(Bool.self, forKey: .compactRows) ?? false
        syncFolderPath = try c.decodeIfPresent(String.self, forKey: .syncFolderPath)
        storeScanEnabled = try c.decodeIfPresent(Bool.self, forKey: .storeScanEnabled) ?? false
        autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
    }

    static let readClearInterval: TimeInterval = 15 * 60       // 15 minutes
    static let clearedRetention: TimeInterval = 24 * 60 * 60   // 24 hours
    static let seenRetention: TimeInterval = 30 * 24 * 60 * 60 // don't resurrect purged articles
}

// MARK: - Import/export document

struct SettingsExport: Codable {
    var app: String = "Vestitel"
    var version: Int = 1
    var exportedAt: Date = Date()
    var settings: AppSettings
    var feeds: [ExportedFeed]

    struct ExportedFeed: Codable {
        var url: URL
        var title: String
        var colorIndex: Int? = nil
        var kind: FeedKind? = nil
    }
}
