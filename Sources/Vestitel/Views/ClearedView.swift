import SwiftUI

struct ClearedView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let cleared = store.cleared

        VStack(spacing: 0) {
            HStack {
                Label("Cleared articles are kept for 24 hours, then removed.", systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            Divider()

            if cleared.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "Nothing cleared recently",
                    subtitle: "Articles you clear will stay here for 24 hours in case you need them back."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(cleared) { article in
                            HStack(spacing: 6) {
                                ArticleRow(article: article)
                                RestoreButton(article: article)
                                    .padding(.trailing, 8)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
            }
        }
    }
}

struct RestoreButton: View {
    @EnvironmentObject var store: AppStore
    let article: Article
    @State private var hovering = false

    var body: some View {
        Button {
            store.restore(article)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    hovering ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Restore to inbox")
    }
}

struct ArchiveView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Every article you've opened, most recent first.", systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Archive") { store.clearArchive() }
                    .buttonStyle(HoverButtonStyle())
                    .disabled(store.archive.isEmpty)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            Divider()

            if store.archive.isEmpty {
                EmptyStateView(
                    icon: "archivebox",
                    title: "Archive is empty",
                    subtitle: "Articles you open are recorded here so you can find them again."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.archive) { entry in
                            ArchiveRow(entry: entry)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
            }
        }
    }
}

struct ArchiveRow: View {
    @EnvironmentObject var store: AppStore
    let entry: ArchiveEntry
    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 13.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(entry.sourceTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(store.sourceColor(title: entry.sourceTitle))
                    Text("·")
                    Text("opened \(entry.openedAt.articleDisplay)")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            RowActionButton(
                icon: justCopied ? "checkmark" : "link",
                tint: justCopied ? .green : .secondary,
                help: "Copy link",
                visible: hovering || justCopied,
                disabled: entry.link == nil
            ) {
                if let url = entry.link {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture {
            if let url = entry.link { NSWorkspace.shared.open(url) }
        }
        .contextMenu {
            Button("Open in Browser") {
                if let url = entry.link { NSWorkspace.shared.open(url) }
            }
            Button("Copy Link") {
                if let url = entry.link {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            .disabled(entry.link == nil)
        }
    }
}
