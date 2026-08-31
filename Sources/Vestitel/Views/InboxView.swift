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
                if let selected {
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
                            if group.articles.count > 1 {
                                GroupBlock(group: group)
                            } else {
                                ArticleRow(article: group.articles[0])
                            }
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
            let visible = store.visibleInbox
            let scoped = store.selectedSmartInbox != nil
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
                  ? "Move the articles in this smart inbox to Cleared (recoverable for 24 hours)"
                  : "Move all inbox articles to Cleared (recoverable for 24 hours)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Subtabs for the smart inboxes: "All" first, then as many as fit in
/// display order, the rest behind a "More" menu. ViewThatFits tries the
/// widest layout first, so the user's ordering decides what stays visible.
struct SmartInboxBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let inboxes = store.settings.smartInboxes
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: inboxes.count, through: 0, by: -1)), id: \.self) { visibleCount in
                strip(visible: Array(inboxes.prefix(visibleCount)), overflow: Array(inboxes.dropFirst(visibleCount)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func strip(visible: [SmartInbox], overflow: [SmartInbox]) -> some View {
        HStack(spacing: 6) {
            chip(name: "All", count: store.unreadCount, selected: store.selectedSmartInboxID == nil) {
                store.selectedSmartInboxID = nil
            }
            ForEach(visible) { inbox in
                chip(name: inbox.name, count: store.unreadCount(in: inbox),
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
                            let n = store.unreadCount(in: inbox)
                            Text(n > 0 ? "\(inbox.name)  (\(n))" : inbox.name)
                            if inbox.id == store.selectedSmartInboxID { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    chipLabel(name: overflowSelected?.name ?? "More",
                              count: overflowSelected.map(store.unreadCount(in:)) ?? 0,
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
    @State private var hovering = false
    @State private var dragOffset: CGFloat = 0
    @State private var armed = false
    @State private var dragIsHorizontal: Bool? = nil

    private static let actionWidth: CGFloat = 84
    private static let commitFraction: CGFloat = 0.75

    private var collapsed: Bool { store.collapsedGroupIDs.contains(group.id) }

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

    private var groupContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                // Only the title cluster toggles collapse — a separate button
                // so it can never swallow clicks meant for the clear ×.
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if collapsed {
                            store.collapsedGroupIDs.remove(group.id)
                        } else {
                            store.collapsedGroupIDs.insert(group.id)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                        Text(group.headline ?? "Related stories")
                            .font(.system(size: 11.5, weight: .bold))
                            .textCase(.uppercase)
                            .lineLimit(1)
                        Text("\(group.articles.count)")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand group" : "Collapse group")

                Spacer(minLength: 4)

                RowActionButton(
                    icon: "xmark",
                    help: "Clear all \(group.articles.count) articles in this group",
                    visible: hovering
                ) {
                    store.clearGroup(group)
                }
            }
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 7)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
            .gesture(headerDragGesture)

            if !collapsed {
                ForEach(group.articles) { article in
                    ArticleRow(article: article)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.bottom, 4)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 3.5)
        }
        .padding(.vertical, 5)
    }
}
