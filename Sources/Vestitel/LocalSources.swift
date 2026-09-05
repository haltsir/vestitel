import Foundation
import AppKit
import os

/// Local sources: other apps and scripts on this Mac posting "things that
/// happened" into Vestitel. Two transports, one model:
///
/// 1. The events drop folder (Application Support/Vestitel/Events). A
///    producer writes a JSON file holding one event or an array of them;
///    Vestitel ingests it within about a second (FSEvents), at launch, and
///    on every refresh, then deletes it. Files that don't parse are moved to
///    Events/Rejected so the producer's author can see what went wrong
///    without the file being retried forever. Durable: events written while
///    Vestitel is not running are picked up at next launch.
/// 2. The vestitel://add URL (query = the same fields), for one-off pushes
///    and shell scripts (`open "vestitel://add?source=…&title=…"`).
///    LaunchServices launches Vestitel if it isn't running.
///
/// Each distinct `source` becomes a Feed of kind .local whose URL is the
/// deterministic vestitel://source/<slug>, so it syncs between Macs by URL,
/// gets a colour, and can be renamed or removed like any feed. Events go
/// through the normal ingest, so the inbox hold, grouping and the
/// read/cleared/seen state machine all apply.
struct LocalEvent {
    var source: String
    var title: String
    var url: URL?
    var summary: String?
    var image: URL?
    var published: Date?
    /// Producer-chosen dedupe key; falls back to the URL, then the title.
    var id: String?
    /// Why the event was posted, one or two words ("last stock", "price
    /// drop"). Shown as a chip in the row and searched by keyword rules.
    var tag: String?
    /// SF Symbol name drawn next to `tag`. Dropped when the name is not a
    /// symbol on this Mac, or when there is no tag to accompany.
    var symbol: String?

    /// Longer tags are cut here; a tag is a label, not a sentence.
    static let tagLimit = 40

    static let scheme = "vestitel"
    static let addHost = "add"
    static let sourceHost = "source"

    /// Identity of the feed a source name maps to. Deterministic: the same
    /// name always yields the same URL, on every Mac.
    static func feedURL(forSource source: String) -> URL {
        let lowered = source.lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if slug.isEmpty { slug = "source" }
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return URL(string: "\(scheme)://\(sourceHost)/\(encoded)")!
    }

    var isValid: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Parsing

    /// Accepts ISO 8601 (with or without fractional seconds) and Unix seconds.
    static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let seconds as Double:
            return Date(timeIntervalSince1970: seconds)
        case let text as String:
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: text) { return date }
            if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
            return nil
        default:
            return nil
        }
    }

    /// A single event from a JSON object; nil if it isn't one or lacks the
    /// required fields.
    static func from(json object: Any) -> LocalEvent? {
        guard let dict = object as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func url(_ key: String) -> URL? {
            guard let text = string(key), !text.isEmpty else { return nil }
            return URL(string: text)
        }
        guard let source = string("source"), let title = string("title") else { return nil }
        let tag = string("tag").flatMap { $0.isEmpty ? nil : String($0.prefix(tagLimit)) }
        let event = LocalEvent(
            source: source, title: title,
            url: url("url") ?? url("link"),
            summary: string("summary").flatMap { $0.isEmpty ? nil : $0 },
            image: url("image"),
            published: parseDate(dict["published"]),
            id: string("id").flatMap { $0.isEmpty ? nil : $0 },
            tag: tag,
            symbol: tag == nil ? nil : validSymbol(string("symbol"))
        )
        return event.isValid ? event : nil
    }

    /// The name back if it is an SF Symbol on this Mac, nil otherwise. A
    /// typo or a symbol from a newer macOS must never crash or draw a blank.
    static func validSymbol(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
        return name
    }

    /// Every event in a drop-folder file: one object, or an array of them.
    /// Throws when the file isn't JSON at all; a JSON file with no usable
    /// event yields an empty array (also a rejection, decided by the caller).
    static func events(fromFile data: Data) throws -> [LocalEvent] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [Any] {
            return array.compactMap(from(json:))
        }
        return from(json: json).map { [$0] } ?? []
    }

    /// vestitel://add?source=…&title=…[&url=…&summary=…&image=…&published=…&id=…&tag=…&symbol=…]
    static func from(url: URL) -> LocalEvent? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == addHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var fields: [String: Any] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { fields[item.name] = value }
        }
        return from(json: fields)
    }

    /// The URL a producer would open to post this event; the Settings
    /// example and a handy way to test the scheme from a terminal.
    static func addURL(source: String, title: String, url: String?,
                       tag: String? = nil, symbol: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = addHost
        var items = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "title", value: title)]
        if let url { items.append(URLQueryItem(name: "url", value: url)) }
        if let tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let symbol { items.append(URLQueryItem(name: "symbol", value: symbol)) }
        components.queryItems = items
        return components.url
    }
}

/// URLs handed to the app by LaunchServices, buffered until the store is
/// ready to handle them. When the app is *launched* by a vestitel:// URL the
/// delegate callback and the store's creation race; queueing makes the
/// order irrelevant.
@MainActor
final class OpenURLQueue {
    static let shared = OpenURLQueue()
    private var pending: [URL] = []
    var handler: (([URL]) -> Void)? {
        didSet { flush() }
    }

    func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls)
        flush()
    }

    private func flush() {
        guard let handler, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        handler(urls)
    }
}

extension AppStore {

    private static let log = Logger(subsystem: "com.strahil.vestitel", category: "LocalSources")

    /// The drop folder producers write event files into.
    static var eventsFolderURL: URL {
        let dir = stateDirectory.appendingPathComponent("Events", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var rejectedFolderURL: URL {
        eventsFolderURL.appendingPathComponent("Rejected", isDirectory: true)
    }

    private static func isEventFile(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(".json")
    }

    func startLocalEventsWatcher() {
        let folder = Self.eventsFolderURL
        eventsWatcher = FolderWatcher(
            folder: folder,
            latency: 1.0,
            isRelevant: Self.isEventFile
        ) { [weak self] in
            Task { @MainActor in self?.ingestLocalEventFiles() }
        }
    }

    /// Consume every event file waiting in the drop folder. Returns how
    /// many articles were new. Safe to call often: an empty folder costs one
    /// directory listing.
    @discardableResult
    func ingestLocalEventFiles() -> Int {
        let fm = FileManager.default
        let folder = Self.eventsFolderURL
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var events: [LocalEvent] = []
        var consumed: [URL] = []
        var rejected: [URL] = []
        for name in names.sorted() where Self.isEventFile(name) {
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            if let parsed = try? LocalEvent.events(fromFile: data), !parsed.isEmpty {
                events.append(contentsOf: parsed)
                consumed.append(file)
            } else {
                rejected.append(file)
            }
        }
        if !rejected.isEmpty {
            let bin = Self.rejectedFolderURL
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            for file in rejected {
                let target = bin.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: file, to: target)
                Self.log.error("Rejected event file \(file.lastPathComponent, privacy: .public): no usable event")
            }
        }
        let added = ingestLocalEvents(events)
        for file in consumed {
            try? fm.removeItem(at: file)
        }
        return added
    }

    /// Entry point for vestitel:// URLs opened by other apps.
    func handleOpenURLs(_ urls: [URL]) {
        let events = urls.compactMap(LocalEvent.from(url:))
        for url in urls where LocalEvent.from(url: url) == nil {
            Self.log.error("Ignored URL \(url.absoluteString, privacy: .public): not a valid vestitel://add URL")
        }
        ingestLocalEvents(events)
    }

    /// Route events to their source feeds (creating sources as needed) and
    /// ingest them like a fetch. Returns how many articles were new.
    @discardableResult
    func ingestLocalEvents(_ events: [LocalEvent]) -> Int {
        guard !events.isEmpty else { return 0 }
        var added = 0
        let bySource = Dictionary(grouping: events.filter(\.isValid), by: { $0.source })
        for (source, sourceEvents) in bySource.sorted(by: { $0.key < $1.key }) {
            let feed = localFeed(forSource: source)
            let items = sourceEvents.map { event in
                ParsedItem(
                    guid: event.id,
                    title: event.title,
                    link: event.url,
                    summary: event.summary,
                    published: event.published,
                    imageURL: event.image,
                    tag: event.tag,
                    symbol: event.symbol
                )
            }
            added += ingest(items, into: feed)
        }
        if added > 0 {
            hasUnseenArticles = true
            animateMenuBarIcon()
            _ = groupedInbox
        }
        save()
        return added
    }

    /// The feed for a source name, created on first use. A source the user
    /// removed comes back when its producer posts again: the producer is the
    /// authority on whether the source exists, and silently dropping its
    /// events would be worse than a feed reappearing.
    private func localFeed(forSource source: String) -> Feed {
        let url = LocalEvent.feedURL(forSource: source)
        if let existing = feeds.first(where: { $0.url == url }) {
            return existing
        }
        let feed = Feed(url: url, title: source, kind: .local)
        feeds.append(feed)
        removedFeeds[url.absoluteString] = nil
        return feed
    }

    func revealEventsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.eventsFolderURL])
    }
}
