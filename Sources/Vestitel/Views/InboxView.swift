import SwiftUI

struct InboxView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let groups = store.visibleGroupedInbox
        let selected = store.selectedSmartInbox

        VStack(spacing: 0) {
            if !store.settings.smartInboxes.isEmpty {
                SmartInboxBar()
                Divider()
            }
            if groups.isEmpty {
                if store.isInboxFiltering {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No matches",
                        subtitle: selected.map { "Nothing in \($0.name) matches “\(store.inboxFilterText.trimmingCharacters(in: .whitespaces))”." }
                            ?? "No inbox article matches “\(store.inboxFilterText.trimmingCharacters(in: .whitespaces))”."
                    )
                } else if let selected {
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "Nothing in \(selected.name)",
                        subtitle: "No inbox article matches this smart inbox right now."
                    )
                } else if store.feeds.isEmpty {
                    EmptyStateView(
                        icon: "dot.radiowaves.up.forward",
                        title: "No feeds yet",
                        subtitle: "Add RSS feeds in the Settings tab to start receiving articles."
                    )
                } else {
                    EmptyStateView(
                        icon: "tray",
                        title: "Inbox zero",
                        subtitle: "New articles will appear here as your feeds update."
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            if group.articles.count > 1 || group.sourceFeedID != nil {
                                GroupBlock(group: group)
                            } else {
                                ArticleRow(article: group.articles[0])
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .overlayScrollers()
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
            let visible = store.visibleInbox
            let scoped = store.selectedSmartInbox != nil || store.isInboxFiltering
            OpenAllButton(count: visible.count) {
                store.openAll(visible)
            }
            Button {
                store.clearVisibleInbox()
            } label: {
                Label(scoped ? "Clear Shown" : "Clear Inbox", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(visible.isEmpty)
            .help(scoped
                  ? "Move the articles shown to Cleared (recoverable for 24 hours)"
                  : "Move all inbox articles to Cleared (recoverable for 24 hours)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The ad-hoc filter: a smart inbox typed for the moment, shown in the
/// header row in place of the tab title. Takes focus when it appears; Esc
/// (or the header magnifier) dismisses it and drops the text, the × only
/// drops the text.
struct InboxFilterField: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Filter by title, summary or source", text: $store.inboxFilterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onExitCommand { withAnimation(.filterReveal) { store.dismissInboxFilter() } }
            if !store.inboxFilterText.isEmpty {
                Button {
                    store.inboxFilterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter text")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity)
        .background(KeyWindowProbe {
            // A mouse click in the popover doesn't make its window key (the
            // app stays inactive behind the menu bar extra), and a focus
            // request into a non-key window is dropped, so ⌘F focused the
            // field and a click on the magnifier didn't. Set synchronously
            // in onAppear it was dropped as well: the field wasn't in the
            // responder chain yet.
            focused = true
        })
    }
}

/// Makes the hosting window key (activating the app if needed) once the
/// view is in it, then runs `then` on the next turn of the run loop.
private struct KeyWindowProbe: NSViewRepresentable {
    let then: () -> Void

    final class Probe: NSView {
        var then: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let then else { return }
            self.then = nil
            DispatchQueue.main.async {
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                if !window.isKeyWindow { window.makeKey() }
                then()
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.then = then
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Subtabs for the smart inboxes: "All" first, then as many as fit in
/// display order, the rest behind a "More" menu. ViewThatFits tries the
/// widest layout first, so the user's ordering decides what stays visible.
struct SmartInboxBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let inboxes = store.settings.smartInboxes
        let counts = store.smartInboxUnreadCounts
        let all = store.unreadCount
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: inboxes.count, through: 0, by: -1)), id: \.self) { visibleCount in
                strip(visible: Array(inboxes.prefix(visibleCount)), overflow: Array(inboxes.dropFirst(visibleCount)),
                      counts: counts, all: all)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func strip(visible: [SmartInbox], overflow: [SmartInbox],
                       counts: [UUID: Int], all: Int) -> some View {
        HStack(spacing: 6) {
            chip(name: "All", count: all, selected: store.selectedSmartInboxID == nil) {
                store.selectedSmartInboxID = nil
            }
            ForEach(visible) { inbox in
                chip(name: inbox.name, count: counts[inbox.id] ?? 0,
                     selected: store.selectedSmartInboxID == inbox.id) {
                    store.selectedSmartInboxID = inbox.id
                }
            }
            if !overflow.isEmpty {
                let overflowSelected = overflow.first { $0.id == store.selectedSmartInboxID }
                Menu {
                    ForEach(overflow) { inbox in
                        Button {
                            store.selectedSmartInboxID = inbox.id
                        } label: {
                            let n = counts[inbox.id] ?? 0
                            Text(n > 0 ? "\(inbox.name)  (\(n))" : inbox.name)
                            if inbox.id == store.selectedSmartInboxID { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    chipLabel(name: overflowSelected?.name ?? "More",
                              count: overflowSelected.map { counts[$0.id] ?? 0 } ?? 0,
                              selected: overflowSelected != nil, menu: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Other smart inboxes (reorder them in Settings to choose which show here)")
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(name: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(name: name, count: count, selected: selected, menu: false)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(name: String, count: Int, selected: Bool, menu: Bool) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1), in: Capsule())
            }
            if menu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// A topic group: shared headline chip, then member articles from each source.
/// Dragging the header to the right clears the whole group, with the same
/// full-size target / arm-at-75% mechanics as individual article rows.
struct GroupBlock: View {
    @EnvironmentObject var store: AppStore
    let group: TopicGroup
    @State private var dragOffset: CGFloat = 0
    @State private var armed = false
    @State private var dragIsHorizontal: Bool? = nil
    @State private var hovering = false

    private static let actionWidth: CGFloat = 84
    private static let commitFraction: CGFloat = 0.75

    private var collapsed: Bool { store.collapsedGroupIDs.contains(group.id) }
    private var isSourceGroup: Bool { group.sourceFeedID != nil }
    /// Topic groups wear the accent; a source block wears its feed's colour.
    private var tint: Color {
        guard let first = group.articles.first, isSourceGroup else { return .accentColor }
        return store.sourceColor(feedID: first.feedID, title: first.sourceTitle)
    }

    var body: some View {
        ZStack {
            groupContent
                .offset(x: dragOffset)
            if dragOffset != 0 {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    clearPane
                }
                .padding(.vertical, 5)
            }
        }
        .onHover { hovering = $0 }
        .hoverRefresh($hovering)
    }

    private var clearPane: some View {
        VStack(spacing: 3) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text("Clear \(group.articles.count)")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(armed ? Color.white : Color.gray)
        .frame(width: Self.actionWidth)
        .frame(maxHeight: .infinity)
        .background(
            armed ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(armed ? 0 : 0.6), lineWidth: 1)
        )
        .opacity(min(1.0, Double(abs(dragOffset)) / 20.0))
        .animation(.easeOut(duration: 0.12), value: armed)
    }

    private var headerDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if dragIsHorizontal == nil {
                    dragIsHorizontal = abs(value.translation.width) > abs(value.translation.height)
                }
                guard dragIsHorizontal == true else { return }

                var w = value.translation.width
                if w < 0 { w /= 8 }  // only right-drag clears; left just resists
                let cap = Self.actionWidth
                if w > cap { w = cap + (w - cap) / 4 }
                dragOffset = w

                let nowArmed = w >= cap * Self.commitFraction
                if nowArmed != armed {
                    armed = nowArmed
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                let commit = armed
                armed = false
                dragIsHorizontal = nil
                if commit, dragOffset > 0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        store.clearGroup(group)
                        dragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func toggleCollapsed() {
        withAnimation(.easeOut(duration: 0.18)) {
            if collapsed {
                store.collapsedGroupIDs.remove(group.id)
            } else {
                store.collapsedGroupIDs.insert(group.id)
            }
        }
    }

    private var groupContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                if isSourceGroup, let first = group.articles.first {
                    SourceMark(
                        host: store.sourceHost(feedID: first.feedID, title: first.sourceTitle),
                        color: tint
                    )
                }
                Text(group.headline ?? "Related stories")
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)
                Text("\(group.articles.count)")
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .foregroundStyle(.white)
                    .background(tint, in: Capsule())

                Spacer(minLength: 4)

                // the group's own time, so a collapsed group still says when
                Text(group.newest.articleDisplay)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                // on hover, like the × on every row; the frame stays reserved
                RowActionButton(
                    icon: "xmark",
                    help: "Clear all \(group.articles.count) articles in this group",
                    visible: hovering
                ) {
                    store.clearGroup(group)
                }
            }
            // The header sits on the block's own material, no band of its
            // own, so the group is one card in one colour. The group colour
            // is carried by the chevron, the count capsule, the source mark
            // and the border; the bold label and the count keep it from
            // reading as one more article title.
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            // The whole band toggles collapse; the × is a Button and keeps
            // its own clicks. The swipe gesture needs 6 pt of movement, so
            // a plain click never reaches it.
            .onTapGesture { toggleCollapsed() }
            .help(collapsed ? "Expand group" : "Collapse group")
            .gesture(headerDragGesture)

            if !collapsed {
                // The photo runs edge to edge straight under the band, inset
                // by the block's 1 pt border so it touches the border rather
                // than running under it.
                if !isSourceGroup, !store.settings.compactRows,
                   let hero = group.articles.first(where: { $0.imageURL != nil })?.imageURL {
                    GroupBanner(url: hero, flush: true)
                        .padding(.horizontal, 1)
                }
                // Same rhythm as the top-level list (6 pt side inset, 2 pt
                // between rows), so a row's hover box keeps clear of the
                // block's edges, the banner and its neighbours.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(group.articles.enumerated()), id: \.element.id) { index, article in
                        // a source block is a list, not one story: every row the
                        // same, dense (member style), none of them the lead
                        ArticleRow(article: article,
                                   placement: isSourceGroup || index > 0 ? .member : .lead,
                                   hidesSource: isSourceGroup)
                    }
                }
                .padding(6)
            }
        }
        // The body is a thick material with a whisper of the group colour:
        // a bare tint over the popover turned into a saturated block over a
        // same-hue window behind it, an opaque window colour was a black
        // slab in a grey popover, and a neutral lift read as washed out.
        // The material darkens and blurs the backdrop into a card instead.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.thickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.vertical, 5)
    }
}
