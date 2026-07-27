import SwiftUI

struct InboxView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let groups = store.groupedInbox

        VStack(spacing: 0) {
            if groups.isEmpty {
                if store.feeds.isEmpty {
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
            OpenAllButton(count: store.inbox.count) {
                store.openAll(store.inbox)
            }
            Button {
                store.clearInbox()
            } label: {
                Label("Clear Inbox", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(store.inbox.isEmpty)
            .help("Move all inbox articles to Cleared (recoverable for 24 hours)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
