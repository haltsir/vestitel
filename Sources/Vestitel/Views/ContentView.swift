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
            store.popoverOpen = true
            // hold before markSeen: its sync merge must land behind the hold
            store.updateInboxHold(active: tab == .inbox)
            store.markSeen()
        }
        .onDisappear {
            store.popoverOpen = false
            store.updateInboxHold(active: false)
            // a staged update installs the moment the popover closes,
            // instead of waiting for the next sweep tick
            store.installStagedUpdateIfIdle()
        }
        .onChange(of: tab) { _, newTab in
            store.updateInboxHold(active: store.popoverOpen && newTab == .inbox)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if tab == .inbox, store.inboxFilterShown {
                    // The filter takes the title's place: an inbox typed
                    // for the moment is what the tab is showing. It unfolds
                    // leftwards from the magnifier, like a toolbar search.
                    InboxFilterField()
                        .transition(.revealFromTrailing)
                } else {
                    Image(systemName: tab.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                    Text(tab.rawValue)
                        .font(.title3.weight(.semibold))
                        .transition(.opacity)
                }

                if tab == .inbox, store.unreadCount > 0, !store.inboxFilterShown {
                    Text("\(store.unreadCount) unread")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }
                // Articles fetched while reading wait behind this button so
                // the list never shifts underneath the user (see inboxHoldStart).
                if tab == .inbox, store.heldCount > 0 {
                    Button {
                        store.revealHeldArticles()
                    } label: {
                        Label("\(store.heldCount) new", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show the articles that arrived while you were reading")
                }

                if !(tab == .inbox && store.inboxFilterShown) { Spacer() }

                if tab == .inbox {
                    HeaderButton(
                        icon: store.inboxFilterShown ? "magnifyingglass.circle.fill" : "magnifyingglass",
                        help: store.inboxFilterShown ? "Hide the filter" : "Filter by title, summary or source",
                        shortcut: KeyboardShortcut("f", modifiers: .command)
                    ) {
                        withAnimation(.filterReveal) { store.toggleInboxFilter() }
                    }
                    HeaderButton(
                        icon: store.settings.groupBySource ? "rectangle.3.group.fill" : "rectangle.3.group",
                        help: store.settings.groupBySource ? "Show topic groups" : "Group by source"
                    ) {
                        store.settings.groupBySource.toggle()
                    }
                }
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

extension Animation {
    /// The header filter's open/close: a settled spring, no bounce.
    static let filterReveal = Animation.spring(duration: 0.28, bounce: 0)
}

/// Reveals the view from its trailing edge: a mask whose width grows from
/// zero, so the field's pill extends leftwards instead of stretching or
/// sliding in over the header.
private struct RevealFromTrailing: ViewModifier, Animatable {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask(alignment: .trailing) {
                GeometryReader { geo in
                    Rectangle()
                        .frame(width: geo.size.width * fraction)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .opacity(Double(min(1, fraction * 2)))
    }
}

extension AnyTransition {
    static let revealFromTrailing = AnyTransition.modifier(
        active: RevealFromTrailing(fraction: 0),
        identity: RevealFromTrailing(fraction: 1))
}

struct HeaderButton: View {
    let icon: String
    let help: String
    var shortcut: KeyboardShortcut? = nil
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
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Footer button that opens every item of the current list in the browser.
/// Asks first when that means more than 20 tabs. The confirmation is inline
/// (the button swaps into a question) — a system dialog would be a second
/// window, and the menu bar popover closes on any focus change.
struct OpenAllButton: View {
    let count: Int
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            if confirming {
                Text("Open \(count) tabs?")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("Open") {
                    confirming = false
                    action()
                }
                .buttonStyle(HoverButtonStyle(prominent: true))
                .help("Open all \(count) items in your browser")
                Button("Cancel") {
                    confirming = false
                }
                .buttonStyle(HoverButtonStyle())
                .help("Don't open anything")
            } else {
                Button {
                    if count > 20 {
                        confirming = true
                    } else {
                        action()
                    }
                } label: {
                    Label("Open All", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(count == 0)
                .help("Open every item in this list in your browser")
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirming)
        // popover closed or tab switched: never keep a stale question
        .onDisappear { confirming = false }
    }
}

// MARK: - Shared row

/// Where a row sits inside a topic group. The group shows one photo as a
/// full-width banner under its header, so no member row carries a
/// thumbnail; the lead row keeps the full action bar, members keep their
/// actions as small icons at the end of the meta line, so a group reads as
/// one story with its variants, not as N identical cards.
enum GroupPlacement {
    case standalone
    case lead
    case member
}

struct ArticleRow: View {
    @EnvironmentObject var store: AppStore
    let article: Article
    var showsActions = true
    var placement: GroupPlacement = .standalone
    /// In a source block every row is from the same feed, so the meta
    /// line skips the source mark and name.
    var hidesSource = false

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
        .hoverRefresh($hovering)
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

    /// The producer's reason for posting ("last stock"), with its SF Symbol
    /// when one was given. The symbol name was validated at ingest, but the
    /// article may have synced from a Mac with a newer symbol set, so it is
    /// checked again here rather than handed to Image blindly.
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        Group {
            if let symbol = LocalEvent.validSymbol(article.symbol) {
                Label(tag, systemImage: symbol)
            } else {
                Text(tag)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
    }

    /// Bookmark, copy link, share. The lead and standalone rows show them
    /// as a bar under the meta line; group members at the end of it.
    private func actionButtons(small: Bool) -> some View {
        let isBookmarked = store.isBookmarked(article.id)
        return HStack(spacing: small ? 6 : 10) {
            RowActionButton(
                icon: isBookmarked ? "bookmark.fill" : "bookmark",
                tint: isBookmarked ? .orange : .secondary,
                help: isBookmarked ? "Remove bookmark" : "Bookmark",
                small: small, quiet: true
            ) {
                store.toggleBookmark(article)
            }
            RowActionButton(
                icon: justCopied ? "checkmark" : "link",
                tint: justCopied ? .green : .secondary,
                help: "Copy link",
                disabled: article.link == nil,
                small: small, quiet: true
            ) {
                store.copyLink(article)
                justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
            }
            InlineShareButton(url: article.link, small: small)
        }
    }

    private var openButton: some View {
        RowActionButton(
            icon: "arrow.up.forward.app",
            help: "Open in browser",
            visible: hovering
        ) {
            store.open(article)
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

                // Compact rows drop the meta line, but the tag is what makes
                // an event row meaningful ("last stock" vs "price drop"), so
                // it keeps a line of its own.
                if compact, let tag = article.tag {
                    tagChip(tag)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !compact {
                HStack(spacing: 5) {
                    if !hidesSource {
                        SourceMark(
                            host: store.sourceHost(feedID: article.feedID, title: article.sourceTitle),
                            color: store.sourceColor(feedID: article.feedID, title: article.sourceTitle)
                        )
                        Text(article.sourceTitle)
                            .fontWeight(.medium)
                    }
                    if let tag = article.tag {
                        if !hidesSource { Text("·") }
                        tagChip(tag)
                    }
                    if !hidesSource || article.tag != nil { Text("·") }
                    Text(article.published.articleDisplay)
                    if let minutes = store.minutesUntilClear(article) {
                        Text("·")
                        Label("clears in \(minutes) min", systemImage: "clock")
                            .foregroundStyle(.tertiary)
                    }
                    if let keyword = article.filteredBy {
                        Text("·")
                        Label("muted: \(keyword)", systemImage: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.tertiary)
                    }
                    if showsActions, placement == .member {
                        // group members keep their actions on this line,
                        // always present, small enough not to read as a bar
                        Spacer(minLength: 8)
                        actionButtons(small: true)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                // Tweet-style action bar, always visible: fixed layout.
                if showsActions, placement != .member {
                    actionButtons(small: false)
                        .padding(.top, 3)
                }
                }  // if !compact
            }

            Spacer(minLength: 0)

            // grouped rows have no thumbnail: the group's banner is the photo
            if !compact, placement == .standalone, let imageURL = article.imageURL {
                ArticleThumbnail(url: imageURL)
            }

            // Clear lives at the top-right corner, same spot on every card
            // regardless of how tall the article text is, with Open in
            // Browser under it (beside it in compact rows, which are too
            // short for two); shown on hover, the frames stay reserved so
            // nothing shifts.
            if showsActions, canClear || article.link != nil {
                let layout = compact ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
                layout {
                    if compact, article.link != nil { openButton }
                    if canClear {
                        RowActionButton(
                            icon: "xmark",
                            help: "Clear now (recoverable for 24 hours)",
                            visible: hovering
                        ) {
                            store.clear(article)
                        }
                    }
                    if !compact, article.link != nil { openButton }
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

/// Hover tracking that ignores a momentary exit. A `.help()` tooltip
/// installs its tracking area the first time the pointer arrives, which
/// AppKit reports as an exit followed by an enter within a frame; bound
/// straight to a highlight that reads as a double hover, a quick flash of
/// the button background. The exit is applied only if the pointer is still
/// out 40 ms later.
struct DebouncedHover: ViewModifier {
    @Binding var hovering: Bool
    var enabled = true
    @State private var pendingExit: DispatchWorkItem?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pendingExit?.cancel()
            if inside && enabled {
                hovering = true
            } else {
                let work = DispatchWorkItem { hovering = false }
                pendingExit = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
            }
        }
    }
}

extension View {
    func debouncedHover(_ hovering: Binding<Bool>, enabled: Bool = true) -> some View {
        modifier(DebouncedHover(hovering: hovering, enabled: enabled))
    }

    /// Keeps a hover state right when the view moves under a *stationary*
    /// pointer: `onHover` only fires on pointer movement, so after clearing
    /// a row the next row slides under the cursor without ever learning it
    /// is hovered, and its × stays hidden until the mouse twitches. The
    /// probe re-checks the pointer against the view's frame whenever that
    /// frame changes (and when the view appears).
    func hoverRefresh(_ hovering: Binding<Bool>, enabled: Bool = true) -> some View {
        background(GeometryReader { proxy in
            PointerProbe(frame: proxy.frame(in: .global)) { inside in
                let value = inside && enabled
                if hovering.wrappedValue != value { hovering.wrappedValue = value }
            }
        })
    }
}

/// AppKit side of `hoverRefresh`: sized to the view it backs, it asks its
/// window where the pointer is and reports whether that is inside. `frame`
/// is only there so SwiftUI calls `updateNSView` when the view moves.
struct PointerProbe: NSViewRepresentable {
    var frame: CGRect
    var report: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, window.isVisible else { return }
            let local = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            report(view.bounds.contains(local))
        }
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
    /// Meta-line size for group members, where a full-height button would
    /// grow the line.
    var small = false
    /// No box at rest and no hover animation (see `rowActionLook`).
    var quiet = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .rowActionLook(hovering: hovering, tint: tint, small: small, quiet: quiet)
        }
        .buttonStyle(.plain)
        .disabled(disabled || !visible)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .debouncedHover($hovering, enabled: visible)
        .hoverRefresh($hovering, enabled: visible)

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
                // clipped here, not only by the clipShape below: a filled
                // image overflows its frame, and the invisible overflow
                // still takes clicks meant for the × beside it
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipped()
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

/// A topic group's one photo, full width under the header. The band takes
/// the photo's own aspect ratio so nothing is cropped, until the photo is
/// taller than `minAspect` (about 2.4:1, ~190 pt in the popover): from
/// there it is a centred cover crop, like CSS object-fit: cover. A fixed
/// wide band would throw away half of a 16:9 news photo.
struct GroupBanner: View {
    let url: URL
    /// Edge to edge under the group's header band: square corners, no
    /// hairline (the block's own border frames it).
    var flush = false
    @State private var image: NSImage? = nil

    private static let minAspect: CGFloat = 2.4
    /// Decoded photos, kept for the life of the process so a group that
    /// scrolls in and out doesn't re-fetch. Main-thread only.
    private static var cache: [URL: NSImage] = [:]

    var body: some View {
        let aspect = image.map { max($0.size.width / max($0.size.height, 1), Self.minAspect) }
            ?? Self.minAspect
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    // clipped inside the overlay: the clipShape below only
                    // trims what is drawn, and a photo cropped to the band
                    // otherwise keeps intercepting clicks above and below
                    // it, including the group's × in the header
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Color.primary.opacity(0.05)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: flush ? 0 : 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(flush ? 0 : 0.1), lineWidth: 1)
            )
            .allowsHitTesting(false)
            .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = Self.cache[url] {
            image = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let loaded = NSImage(data: data), loaded.size.height > 0 else { return }
        Self.cache[url] = loaded
        image = loaded
    }
}

/// The one look for every icon button on a row: nothing at rest, a box
/// that appears in one step on hover (no animation, because a background
/// fading in from transparent is what reads as a blink). `quiet` only
/// dims the icon a little more at rest (the bookmark/link/share bar).
extension Image {
    func rowActionLook(hovering: Bool, tint: Color, small: Bool = false, quiet: Bool = false) -> some View {
        font(.system(size: small ? 11 : 13, weight: .medium))
            .frame(width: small ? 22 : 26, height: small ? 20 : 26)
            .background(
                Color.primary.opacity(hovering ? 0.18 : 0),
                in: RoundedRectangle(cornerRadius: small ? 5 : 6)
            )
            .foregroundStyle(hovering ? tint.opacity(1) : tint.opacity(quiet ? 0.7 : 0.85))
    }
}

/// Share via the system share sheet, styled like RowActionButton.
struct InlineShareButton: View {
    let url: URL?
    var small = false
    @State private var hovering = false

    var body: some View {
        if let url {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .rowActionLook(hovering: hovering, tint: .secondary, small: small, quiet: true)
            }
            .buttonStyle(.plain)
            .debouncedHover($hovering)
            .hoverRefresh($hovering)
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

/// Forces overlay-style scrollers on the enclosing NSScrollView. With
/// legacy (always-visible) scrollers, which macOS turns on whenever a mouse
/// is connected, the content area narrows by the scroller's width the
/// moment a list overflows, and every trailing × jumps 15 pt to the left.
/// Overlay scrollers draw over the content instead, so the row layout is
/// the same whether or not the list scrolls. Applied when the probe view
/// lands in a window (a one-shot dispatch from updateNSView ran before the
/// hierarchy existed and silently did nothing) and again whenever AppKit
/// re-applies the system preference.
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in self?.apply() }
            }
        }

        func apply() {
            var current: NSView? = self
            while let candidate = current, !(candidate is NSScrollView) {
                current = candidate.superview
            }
            guard let scrollView = current as? NSScrollView else { return }
            if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
            }
            scrollView.autohidesScrollers = true
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.apply()
    }
}

extension View {
    /// Put this on the content of a ScrollView (see `OverlayScrollers`).
    func overlayScrollers() -> some View {
        background(OverlayScrollers().frame(width: 0, height: 0))
    }
}
