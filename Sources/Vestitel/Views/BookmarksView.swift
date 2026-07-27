import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Bookmarked articles are kept until you remove them.", systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                OpenAllButton(count: store.bookmarks.count) {
                    store.openAllBookmarks()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            Divider()

            if store.bookmarks.isEmpty {
                EmptyStateView(
                    icon: "bookmark",
                    title: "No bookmarks yet",
                    subtitle: "Hover an article and press the bookmark icon to save it here for good."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.bookmarks) { bookmark in
                            BookmarkRow(bookmark: bookmark)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
            }
        }
    }
}

struct BookmarkRow: View {
    @EnvironmentObject var store: AppStore
    let bookmark: BookmarkEntry
    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.title)
                    .font(.system(size: 13.5))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    SourceMark(
                        host: store.sourceHost(title: bookmark.sourceTitle),
                        color: store.sourceColor(title: bookmark.sourceTitle)
                    )
                    Text(bookmark.sourceTitle)
                        .fontWeight(.medium)
                    Text("·")
                    Text("saved \(bookmark.bookmarkedAt.articleDisplay)")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                RowActionButton(
                    icon: justCopied ? "checkmark" : "link",
                    tint: justCopied ? .green : .secondary,
                    help: "Copy link",
                    visible: hovering || justCopied,
                    disabled: bookmark.link == nil
                ) {
                    if let url = bookmark.link {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        justCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
                    }
                }
                RowActionButton(
                    icon: "bookmark.slash",
                    tint: .red,
                    help: "Remove bookmark",
                    visible: hovering
                ) {
                    store.removeBookmark(bookmark)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { store.openBookmark(bookmark) }
        .contextMenu {
            Button("Open in Browser") { store.openBookmark(bookmark) }
            Button("Copy Link") {
                if let url = bookmark.link {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            .disabled(bookmark.link == nil)
            Divider()
            Button("Remove Bookmark") { store.removeBookmark(bookmark) }
        }
    }
}
