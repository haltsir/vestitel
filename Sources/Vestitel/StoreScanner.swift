import Foundation
import AppKit

/// A product recorded by a listing scan. Deliberately independent of
/// `Article`: scan results never enter the inbox — they are reported in a
/// throwaway HTML page instead, because a single scan can surface hundreds
/// of products and the listing itself holds thousands.
struct ScannedProduct: Codable, Hashable, Identifiable {
    /// The product URL — stable across pages and across scans.
    var id: String
    var title: String
    var link: URL?
    var imageURL: URL?
    /// Price (and any listed attribute), as StorePageParser composes it.
    var detail: String?
    /// Position in the listing when it was found: page number, 1-based.
    var page: Int
}

/// The outcome of one full walk over the listing. Persisted, so the report
/// stays openable from the notification after a restart.
struct StoreScanResult: Codable {
    var scannedAt: Date
    var pagesScanned: Int
    var pageCount: Int
    var totalProducts: Int
    var newProducts: [ScannedProduct]
    /// First scan: everything is "new", so nothing is reported — the run
    /// only records what the listing holds today.
    var isBaseline: Bool
    /// Set when the walk stopped early (network error, bot challenge,
    /// cancelled). The products found before that point still count.
    var error: String?

    var isPartial: Bool { error != nil }
}

/// Live progress of a running scan, for the Store tab / Settings UI.
struct StoreScanProgress {
    var page: Int
    var pageCount: Int
    var found: Int
}

enum StoreScan {
    /// Ozone's "latest additions" listing. `limit=100` is the largest page
    /// size the site offers — fewer, bigger pages means fewer requests.
    /// The listing is NOT reliably ordered by the date a product appeared,
    /// which is the whole reason the scan walks every page instead of
    /// watching the first one.
    /// VESTITEL_STORE_SCAN_URL points a throwaway instance at a local stand-in
    /// listing, so the crawl can be exercised without hitting the real site.
    static let listingURL: URL = {
        let override = ProcessInfo.processInfo.environment["VESTITEL_STORE_SCAN_URL"] ?? ""
        return URL(string: override) ?? URL(string: "https://www.ozone.bg/posledno-dobaveni/?limit=100")!
    }()
    static let siteName = "Ozone"

    /// Daily trigger, local time.
    static let dailyHour = 8
    static let dailyMinute = 30

    /// Pause between page requests. Deliberately long and jittered: the scan
    /// makes dozens of sequential requests to one host and must not look like
    /// a crawler worth blocking. ~47 pages ≈ 5 minutes.
    static let pageDelay: ClosedRange<Double> = 4.0...9.0
    /// A walk is dozens of requests long, so a single flaky one is likely —
    /// and giving up on it throws away the whole five-minute pass. Retry
    /// twice, backing off well past the pause between pages.
    static let retryDelays: [Double] = [15, 45]
    /// Safety stop in case a pager ever reports an absurd page count.
    static let maxPages = 300
    /// Products that dropped out of the listing are forgotten after this long,
    /// so the record doesn't grow forever. Anything still listed is kept
    /// regardless of age — pruning a listed product would re-report it.
    static let seenRetention: TimeInterval = 365 * 24 * 60 * 60

    /// The nth page of a listing URL (`?p=n`; page 1 is the bare URL).
    static func pageURL(_ base: URL, page: Int) -> URL {
        guard page > 1, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = components.queryItems?.filter { $0.name != "p" } ?? []
        items.append(URLQueryItem(name: "p", value: String(page)))
        components.queryItems = items
        return components.url ?? base
    }
}

extension AppStore {

    // MARK: - Running a scan

    /// Walk every page of the listing, slowly, and record what wasn't there
    /// before. Safe to call while one is running (it does nothing).
    func startStoreScan() {
        guard storeScanTask == nil else { return }
        // Published synchronously so the button flips to "Scanning…" on the
        // click, not whenever the task happens to start.
        storeScanProgress = StoreScanProgress(page: 0, pageCount: 1, found: 0)
        storeScanTask = Task { [weak self] in
            await self?.runStoreScan()
            self?.storeScanTask = nil
            self?.storeScanProgress = nil
        }
    }

    func cancelStoreScan() {
        storeScanTask?.cancel()
    }

    var isStoreScanning: Bool { storeScanProgress != nil }

    private func runStoreScan() async {
        let base = StoreScan.listingURL
        // Marks the day as attempted before any request: a scan that fails
        // halfway must not re-trigger every 30 seconds until midnight.
        lastStoreScanAttempt = Date()

        var found: [String: ScannedProduct] = [:]
        var order: [String] = []
        var pageCount = 1
        var pagesScanned = 0
        var failure: String?

        var page = 1
        walk: while page <= min(pageCount, StoreScan.maxPages) {
            switch await fetchPage(StoreScan.pageURL(base, page: page)) {
            case .failure(let error):
                failure = Task.isCancelled
                    ? "Scan cancelled at page \(page) of \(pageCount)."
                    : "Stopped at page \(page) of \(pageCount): \(error.localizedDescription)"
                break walk
            case .success(let listing):
                pagesScanned += 1
                if page == 1 {
                    pageCount = max(1, listing.pageCount)
                }
                for item in listing.feed.items {
                    let key = item.link?.absoluteString ?? item.guid ?? item.title
                    guard found[key] == nil else { continue }
                    order.append(key)
                    found[key] = ScannedProduct(
                        id: key,
                        title: item.title,
                        link: item.link,
                        imageURL: item.imageURL,
                        detail: item.summary,
                        page: page
                    )
                }
                storeScanProgress = StoreScanProgress(
                    page: page, pageCount: pageCount, found: found.count
                )
                page += 1
                guard page <= min(pageCount, StoreScan.maxPages) else { break walk }
                // slow on purpose — see StoreScan.pageDelay
                let pause = UInt64(Double.random(in: StoreScan.pageDelay) * 1_000_000_000)
                guard (try? await Task.sleep(nanoseconds: pause)) != nil else {
                    failure = "Scan cancelled at page \(page - 1) of \(pageCount)."
                    break walk
                }
            }
        }

        let now = Date()
        // A first scan only counts as the baseline once it completes: half a
        // baseline would report the listing's whole tail as "new" next time.
        let isBaseline = !storeScanBaselineDone
        let products = order.compactMap { found[$0] }
        let newProducts = isBaseline ? [] : products.filter { storeScanSeen[$0.id] == nil }
        for product in products where storeScanSeen[product.id] == nil {
            storeScanSeen[product.id] = now
        }
        // Only a complete walk may forget anything: after a partial scan the
        // unvisited pages' products would look "gone" and re-report as new.
        if failure == nil {
            storeScanBaselineDone = true
            let listed = Set(products.map(\.id))
            storeScanSeen = storeScanSeen.filter {
                listed.contains($0.key) || now.timeIntervalSince($0.value) < StoreScan.seenRetention
            }
        }

        let result = StoreScanResult(
            scannedAt: now,
            pagesScanned: pagesScanned,
            pageCount: pageCount,
            totalProducts: products.count,
            newProducts: newProducts,
            isBaseline: isBaseline,
            error: failure
        )
        lastStoreScanResult = result
        save()

        NotificationManager.shared.notifyStoreScanFinished(result: result, siteName: StoreScan.siteName)
    }

    /// One listing page, retrying a transient failure (see
    /// StoreScan.retryDelays). A bot challenge is never retried: backing off
    /// harder doesn't help, and hammering a site that just blocked us is
    /// exactly the wrong move.
    private func fetchPage(_ url: URL) async -> Result<StorePageParser.ListingPage, Error> {
        var attempt = 0
        while true {
            let outcome = await fetchListingPage(url)
            if case .success = outcome { return outcome }
            if case .failure(let error) = outcome, error is FeedBlockedError { return outcome }
            guard attempt < StoreScan.retryDelays.count, !Task.isCancelled else { return outcome }
            let pause = UInt64(StoreScan.retryDelays[attempt] * 1_000_000_000)
            guard (try? await Task.sleep(nanoseconds: pause)) != nil else { return outcome }
            attempt += 1
        }
    }

    /// Fetch and parse one listing page. Never touches state (safe off-main).
    nonisolated private func fetchListingPage(_ url: URL) async -> Result<StorePageParser.ListingPage, Error> {
        do {
            let (data, response) = try await session.data(from: url)
            do {
                return .success(try StorePageParser.parseListing(data: data, pageURL: url))
            } catch {
                if Self.looksBlocked(response: response, data: data) {
                    return .failure(FeedBlockedError(host: url.host ?? "The site"))
                }
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Daily schedule

    /// Called from `sweep()` (every 30 s), so the daily run survives sleep,
    /// a late launch and a clock change — a one-shot timer aimed at 08:30
    /// would silently miss all three.
    func maybeRunDailyStoreScan() {
        guard settings.storeScanEnabled, storeScanTask == nil else { return }
        guard let trigger = storeScanTriggerToday, Date() >= trigger else { return }
        // already attempted since today's trigger
        if let last = lastStoreScanAttempt, last >= trigger { return }
        startStoreScan()
    }

    /// Today's 08:30, local time.
    var storeScanTriggerToday: Date? {
        Calendar.current.date(
            bySettingHour: StoreScan.dailyHour,
            minute: StoreScan.dailyMinute,
            second: 0,
            of: Date()
        )
    }

    /// When the next automatic scan is due, for the Settings subtitle.
    var nextStoreScanDate: Date? {
        guard settings.storeScanEnabled, let trigger = storeScanTriggerToday else { return nil }
        if Date() < trigger, lastStoreScanAttempt.map({ $0 < trigger }) ?? true {
            return trigger
        }
        if let last = lastStoreScanAttempt, last < trigger {
            return trigger   // due right now (app was asleep)
        }
        return Calendar.current.date(byAdding: .day, value: 1, to: trigger)
    }

    // MARK: - Report

    /// Render the last scan into a throwaway HTML page and open it in the
    /// browser. The file lives in the temp directory — the report is a view
    /// of the scan, regenerated on demand, never something to keep.
    func openStoreScanReport() {
        guard let result = lastStoreScanResult else { return }
        let html = StoreScanReport.html(for: result, siteName: StoreScan.siteName, listingURL: StoreScan.listingURL)
        let stamp = Int(result.scannedAt.timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vestitel-\(StoreScan.siteName.lowercased())-\(stamp).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("Vestitel: could not write scan report: \(error.localizedDescription)")
        }
    }
}

// MARK: - Report rendering

enum StoreScanReport {

    static func html(for result: StoreScanResult, siteName: String, listingURL: URL) -> String {
        let stamp = result.scannedAt.formatted(date: .abbreviated, time: .shortened)
        let count = result.newProducts.count
        let heading: String
        if result.isBaseline {
            heading = "Baseline recorded"
        } else if count == 0 {
            heading = "Nothing new"
        } else {
            heading = "\(count) new \(count == 1 ? "product" : "products")"
        }

        var notes: [String] = [
            "\(result.totalProducts) products across \(result.pagesScanned) of \(result.pageCount) pages",
            stamp,
        ]
        if result.isBaseline {
            notes.append("First scan — everything listed today was recorded as the starting point. The next scan reports what appeared since.")
        }
        if let error = result.error {
            notes.append(error)
        }

        let cards = result.newProducts.map(card).joined(separator: "\n")
        let body = result.newProducts.isEmpty
            ? "<p class=\"empty\">\(escape(result.isBaseline ? "Nothing to report yet — come back after the next scan." : "No products appeared in the listing since the previous scan."))</p>"
            : "<div class=\"grid\">\n\(cards)\n</div>"

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(siteName)) — \(escape(heading))</title>
        <style>
        :root {
          color-scheme: light dark;
          --bg: #f6f6f7; --card: #ffffff; --line: #e2e2e6;
          --text: #16161a; --dim: #6a6a73; --accent: #1f6feb;
        }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #16161a; --card: #1f1f25; --line: #33333b;
                  --text: #f2f2f5; --dim: #9a9aa4; --accent: #6aa8ff; }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 28px 24px 56px;
          background: var(--bg); color: var(--text);
          font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
        }
        header { max-width: 1180px; margin: 0 auto 24px; }
        h1 { margin: 0 0 6px; font-size: 26px; letter-spacing: -0.02em; }
        header p { margin: 2px 0; color: var(--dim); font-size: 13px; }
        header a { color: var(--accent); }
        .grid {
          max-width: 1180px; margin: 0 auto;
          display: grid; gap: 14px;
          grid-template-columns: repeat(auto-fill, minmax(230px, 1fr));
        }
        .card {
          display: flex; flex-direction: column;
          background: var(--card); border: 1px solid var(--line); border-radius: 12px;
          overflow: hidden; text-decoration: none; color: inherit;
          transition: border-color .12s ease, transform .12s ease;
        }
        .card:hover { border-color: var(--accent); transform: translateY(-2px); }
        .thumb {
          aspect-ratio: 1 / 1; background: var(--bg);
          display: flex; align-items: center; justify-content: center; overflow: hidden;
        }
        .thumb img { width: 100%; height: 100%; object-fit: contain; }
        .meta { padding: 11px 12px 13px; display: flex; flex-direction: column; gap: 5px; flex: 1; }
        .title { font-size: 13.5px; font-weight: 600; line-height: 1.35; }
        .detail { font-size: 12.5px; color: var(--dim); margin-top: auto; }
        .page { font-size: 11px; color: var(--dim); opacity: .75; }
        .empty { max-width: 1180px; margin: 0 auto; color: var(--dim); }
        </style>
        </head>
        <body>
        <header>
          <h1>\(escape(heading))</h1>
          \(notes.map { "<p>\(escape($0))</p>" }.joined(separator: "\n  "))
          <p><a href="\(escape(listingURL.absoluteString))">\(escape(listingURL.absoluteString))</a></p>
        </header>
        \(body)
        </body>
        </html>
        """
    }

    private static func card(_ product: ScannedProduct) -> String {
        let href = product.link?.absoluteString ?? "#"
        let thumb = product.imageURL.map {
            "<div class=\"thumb\"><img src=\"\(escape($0.absoluteString))\" alt=\"\" loading=\"lazy\"></div>"
        } ?? ""
        let detail = product.detail.map { "<div class=\"detail\">\(escape($0))</div>" } ?? ""
        return """
        <a class="card" href="\(escape(href))" target="_blank" rel="noreferrer">
          \(thumb)
          <div class="meta">
            <div class="title">\(escape(product.title))</div>
            \(detail)
            <div class="page">page \(product.page)</div>
          </div>
        </a>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
