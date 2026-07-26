import SwiftUI

/// The Store tab: new products from store-watch feeds, kept apart from the
/// news inbox. Rows behave like articles (open, swipe to clear/bookmark);
/// clearing a product hides it for good — its seen entry never expires.
struct StoreView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let items = store.storeInbox

        VStack(spacing: 0) {
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
