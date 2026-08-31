import SwiftUI

/// The Store tab: new products from store-watch feeds, kept apart from the
/// news inbox. Rows behave like articles (open, swipe to clear/bookmark);
/// clearing a product hides it for good — its seen entry never expires.
struct StoreView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let items = store.storeInbox

        VStack(spacing: 0) {
            if store.settings.storeScanEnabled {
                StoreScanCard()
                Divider()
            }

            if items.isEmpty {
                if !store.hasStoreFeeds {
                    EmptyStateView(
                        icon: "cart",
                        title: "No store watches yet",
                        subtitle: "Add a store listing page (like an ozone.bg category URL) in the Settings tab to watch it for new products."
                    )
                } else {
                    EmptyStateView(
                        icon: "cart",
                        title: "Nothing new in store",
                        subtitle: "New products will appear here when they show up in the watched listings."
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { article in
                            ArticleRow(article: article)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
            }

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            if let last = store.lastRefresh {
                Text("Updated \(last.articleDisplay)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            OpenAllButton(count: store.storeInbox.count) {
                store.openAll(store.storeInbox)
            }
            Button {
                store.clearStoreInbox()
            } label: {
                Label("Clear All", systemImage: "cart.badge.minus")
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(store.storeInbox.isEmpty)
            .help("Clear every product (recoverable for 24 hours — cleared products never reappear here)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The latest-additions scan, at the top of the Store tab: what the last
/// walk found, and the two things you can do about it — run one now, or
/// open the report. Results never enter the inbox (a scan can surface
/// hundreds of products), so this card is the whole UI for them.
struct StoreScanCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(StoreScan.siteName) latest additions")
                    .font(.system(size: 12.5, weight: .semibold))
                if let result = store.lastStoreScanResult,
                   !result.isBaseline, !result.newProducts.isEmpty,
                   store.storeScanProgress == nil {
                    Text("\(result.newProducts.count) new")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                if let progress = store.storeScanProgress {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressText(progress))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if store.storeScanProgress != nil {
                    Button {
                        store.cancelStoreScan()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Stop walking pages — what was found so far is still reported")
                } else {
                    Button {
                        store.startStoreScan()
                    } label: {
                        Label("Scan Now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Walk every page of the listing now. Takes a few minutes — the scan is paced so the site doesn't block it.")
                }
                Button {
                    store.openStoreScanReport()
                } label: {
                    Label("Open Report", systemImage: "doc.text")
                }
                .buttonStyle(HoverButtonStyle(prominent: hasReport))
                .disabled(!hasReport)
                .help("Build an HTML page of everything the last scan found new, and open it in your browser")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var hasReport: Bool { store.lastStoreScanResult != nil }

    private func progressText(_ p: StoreScanProgress) -> String {
        p.page == 0
            ? "Starting…"
            : "Page \(p.page) of \(p.pageCount) · \(p.found) products"
    }

    private var statusText: String {
        guard let result = store.lastStoreScanResult else {
            return store.settings.storeScanEnabled
                ? "No scan yet. The first run records what's listed today as the starting point."
                : "Scanning is off."
        }
        var parts: [String] = []
        if result.isBaseline {
            parts.append("Baseline of \(result.totalProducts) products")
        } else if result.newProducts.isEmpty {
            parts.append("Nothing new")
        } else {
            parts.append("\(result.newProducts.count) new of \(result.totalProducts)")
        }
        parts.append(result.scannedAt.articleDisplay)
        if let error = result.error {
            parts.append(error)
        } else if let next = store.nextStoreScanDate {
            parts.append("next \(next.articleDisplay)")
        }
        return parts.joined(separator: " · ")
    }
}
