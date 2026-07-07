import SwiftUI

enum Tab: String, CaseIterable {
    case inbox = "Inbox"
    case cleared = "Cleared"
    case bookmarks = "Bookmarks"
    case archive = "Archive"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .inbox: return "tray.full"
        case .cleared: return "clock.arrow.circlepath"
        case .bookmarks: return "bookmark"
        case .archive: return "archivebox"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab: Tab = .inbox

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .inbox: InboxView()
            case .cleared: ClearedView()
            case .bookmarks: BookmarksView()
            case .archive: ArchiveView()
            case .settings: SettingsView()
            }
        }
        .frame(width: 500, height: 600)
        .onAppear {
            store.markSeen()
            store.popoverOpen = true
        }
        .onDisappear { store.popoverOpen = false }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(tab.rawValue)
                    .font(.title3.weight(.semibold))

                if tab == .inbox, store.unreadCount > 0 {
                    Text("\(store.unreadCount) unread")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                HeaderButton(
                    icon: store.settings.compactRows ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                    help: store.settings.compactRows ? "Full article cards" : "Compact: titles only"
                ) {
                    store.settings.compactRows.toggle()
                }

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    HeaderButton(icon: "arrow.clockwise", help: "Refresh all feeds now") {
                        Task { await store.refreshAll() }
                    }
                }
                HeaderButton(icon: "power", help: "Quit Vestitel") {
                    NSApplication.shared.terminate(nil)
                }
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct HeaderButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Shared row

struct ArticleRow: View {
    @EnvironmentObject var store: AppStore
    let article: Article
    var showsActions = true

    @State private var hovering = false
    @State private var justCopied = false
    @State private var dragOffset: CGFloat = 0
    @State private var armed = false   // drag is past the commit point
    @State private var dragIsHorizontal: Bool? = nil  // nil until direction is known

    /// The action button behind the row is this wide, at full size from the
    /// first pixel of drag — it never resizes while dragging.
    private static let actionWidth: CGFloat = 84
    /// Dragging past 75% of the button arms the action; releasing then commits.
    private static let commitFraction: CGFloat = 0.75

    private var canClear: Bool { article.state == .inbox }
    private var compact: Bool { store.settings.compactRows }

    /// Article description shown as a tooltip on stationary hover; nil when
    /// the feed provides none or it just repeats the title.
    private var summaryTooltip: String? {
        guard let raw = article.summary else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.caseInsensitiveCompare(article.title) != .orderedSame else { return nil }
        if s.count > 400 {
            s = String(s.prefix(400)) + "…"
        }
        return s
    }

    var body: some View {
        ZStack {
            rowContent
                .offset(x: dragOffset)
            if dragOffset != 0 {
                targetPane
            }
        }
        .onHover { hovering = $0 }
    }

    // MARK: Swipe to act — right = clear, left = bookmark.
    // A drop-target button appears at the edge you're dragging TOWARD, above
    // the row, and the article slides into it. Dragging 75% of the way in
    // highlights the target (armed); releasing while armed commits.
    // Releasing earlier springs back — nothing happens.

    @ViewBuilder
    private var targetPane: some View {
        let isBookmarked = store.isBookmarked(article.id)
        HStack(spacing: 0) {
            if dragOffset < 0 {
                actionPane(
                    icon: isBookmarked ? "bookmark.slash.fill" : "bookmark.fill",
                    text: isBookmarked ? "Remove" : "Bookmark",
                    color: .orange
                )
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                actionPane(icon: "xmark.circle.fill", text: "Clear", color: .gray)
            }
        }
    }

    private func actionPane(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(armed ? Color.white : color)
        .frame(width: Self.actionWidth)
        .frame(maxHeight: .infinity)
        .background(
            armed ? AnyShapeStyle(color) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color.opacity(armed ? 0 : 0.6), lineWidth: 1)
        )
        .opacity(min(1.0, Double(abs(dragOffset)) / 20.0))  // materializes over the first pixels
        .animation(.easeOut(duration: 0.12), value: armed)
    }

    private var swipeGesture: some Gesture {
        // .global is load-bearing: the row moves with dragOffset, so a local-
        // space translation would feed back into itself and oscillate.
        // Zero minimum distance: the row tracks from the very first pixel.
        // Clicks are detected manually in onEnded (no movement = open).
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // classify direction once, after ~3px of movement
                if dragIsHorizontal == nil {
                    let t = value.translation
                    guard abs(t.width) + abs(t.height) >= 3 else { return }
                    dragIsHorizontal = abs(t.width) > abs(t.height)
                }
                guard dragIsHorizontal == true else { return }

                var w = value.translation.width
                if w > 0, !canClear { w /= 8 }  // nothing to clear: stiff resistance
                // soft stop just past the button's width
                let cap = Self.actionWidth
                if w > cap { w = cap + (w - cap) / 4 }
                if w < -cap { w = -cap - (-w - cap) / 4 }
                dragOffset = w

                let nowArmed = abs(w) >= cap * Self.commitFraction && (w < 0 || canClear)
                if nowArmed != armed {
                    armed = nowArmed
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                let commit = armed
                let wasClick = dragIsHorizontal == nil  // released without moving
                armed = false
                dragIsHorizontal = nil
                if wasClick {
                    store.open(article)
                } else if commit, dragOffset > 0, canClear {
                    withAnimation(.easeOut(duration: 0.2)) {
                        store.clear(article)
                        dragOffset = 0
                    }
                } else {
                    if commit, dragOffset < 0 {
                        store.toggleBookmark(article)
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(.system(size: 13.5, weight: article.isRead ? .regular : .medium))
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .lineLimit(compact ? 2 : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .helpIfAvailable(summaryTooltip)

                if !compact {
                HStack(spacing: 5) {
                    SourceMark(
                        host: store.sourceHost(feedID: article.feedID, title: article.sourceTitle),
                        color: store.sourceColor(feedID: article.feedID, title: article.sourceTitle)
                    )
                    Text(article.sourceTitle)
                        .fontWeight(.medium)
                    Text("·")
                    Text(article.published.articleDisplay)
                    if summaryTooltip != nil {
                        // marks articles whose title reveals a description on hover
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Hover the title to preview the article")
                    }
                    if let minutes = store.minutesUntilClear(article) {
                        Text("·")
                        Label("clears in \(minutes) min", systemImage: "clock")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                // Tweet-style action bar, always visible: fixed layout.
                if showsActions {
                    let isBookmarked = store.isBookmarked(article.id)
                    HStack(spacing: 14) {
                        InlineActionButton(
                            icon: isBookmarked ? "bookmark.fill" : "bookmark",
                            tint: isBookmarked ? .orange : .secondary,
                            help: isBookmarked ? "Remove bookmark" : "Bookmark"
                        ) {
                            store.toggleBookmark(article)
                        }
                        InlineActionButton(
                            icon: justCopied ? "checkmark" : "link",
                            tint: justCopied ? .green : .secondary,
                            help: "Copy link",
                            disabled: article.link == nil
                        ) {
                            store.copyLink(article)
                            justCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
                        }
                        InlineShareButton(url: article.link)
                    }
                    .padding(.top, 3)
                }
                }  // if !compact
            }

            Spacer(minLength: 0)

            if !compact, let imageURL = article.imageURL {
                ArticleThumbnail(url: imageURL)
            }

            // Clear lives at the top-right corner, same spot on every card
            // regardless of how tall the article text is.
            if showsActions, canClear {
                InlineActionButton(
                    icon: "xmark",
                    help: "Clear now (recoverable for 24 hours)"
                ) {
                    store.clear(article)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        // Opaque while swiping so the full-size action button behind the row
        // is only visible in the vacated space, never through the row.
        .background(
            dragOffset != 0 ? Color(nsColor: .windowBackgroundColor) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Open in Browser") { store.open(article) }
            Button("Copy Link") { store.copyLink(article) }
                .disabled(article.link == nil)
            Button(store.isBookmarked(article.id) ? "Remove Bookmark" : "Bookmark") {
                store.toggleBookmark(article)
            }
            Divider()
            if article.state == .inbox {
                Button(article.isRead ? "Mark as Unread" : "Mark as Read") {
                    store.toggleRead(article)
                }
                Button("Clear Now") { store.clear(article) }
            } else {
                Button("Restore to Inbox") { store.restore(article) }
            }
        }
        .gesture(swipeGesture)
    }
}

/// Small square icon button used at the trailing edge of rows. It always
/// occupies its frame; `visible` only fades it and gates hit-testing, so
/// row layout is identical whether or not the pointer is over the row.
struct RowActionButton: View {
    let icon: String
    var tint: Color = .secondary
    let help: String
    var visible = true
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(
                    Color.primary.opacity(hovering ? 0.18 : 0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(hovering ? tint.opacity(1) : tint.opacity(0.85))
        }
        .buttonStyle(.plain)
        .disabled(disabled || !visible)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { hovering = visible && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

/// Small article image preview, sized to sit inside the card next to the ×.
struct ArticleThumbnail: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Color.primary.opacity(0.05)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

/// Small quiet icon button for the always-visible action bar under articles.
/// No background at rest; a subtle one appears on hover.
struct InlineActionButton: View {
    let icon: String
    var tint: Color = .secondary
    let help: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .background(
                    hovering ? Color.primary.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(hovering ? tint : tint.opacity(0.7))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hovering = !disabled && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

/// Share via the system share sheet, styled to match InlineActionButton.
struct InlineShareButton: View {
    let url: URL?
    @State private var hovering = false

    var body: some View {
        if let url {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
                    .background(
                        hovering ? Color.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Share")
        }
    }
}

extension View {
    /// `.help(_:)` without an optional overload workaround: applies the
    /// tooltip only when there is text to show.
    @ViewBuilder
    func helpIfAvailable(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}

extension Date {
    /// Absolute display for article dates: time for today, day + time for
    /// this year, full date otherwise. No ticking "x min ago" counters.
    var articleDisplay: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if cal.isDate(self, equalTo: Date(), toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated)) + ", "
                + formatted(date: .omitted, time: .shortened)
        }
        return formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Text button with a proper hover state (macOS bordered buttons have none).
/// `prominent` renders it filled with the accent color.
struct HoverButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, prominent: prominent)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(prominent ? Color.white : .primary)
                .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var background: Color {
            if prominent {
                return Color.accentColor.opacity(hovering ? 1 : 0.82)
            }
            return Color.primary.opacity(hovering ? 0.16 : 0.08)
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}
