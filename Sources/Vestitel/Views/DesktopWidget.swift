import SwiftUI
import AppKit
import Combine

/// The desktop widget: a borderless panel that sits on the wallpaper, under
/// every other window and above Finder's desktop background (level
/// desktopIcon - 1, the GeekTool arrangement), on every Space, unaffected by
/// Mission Control and "show desktop". It shows the Inbox in huge type and
/// updates live from the store, so a fetch slides new articles in on top.
/// Not a WidgetKit widget: that needs an extension bundle with its own
/// signing and an app group, which this SwiftPM, ad-hoc-signed build cannot
/// produce; a window under the store's control does the same job with live
/// updates and no refresh budget.
@MainActor
final class DesktopWidgetController {
    static let shared = DesktopWidgetController()

    private var panel: NSPanel?
    private weak var store: AppStore?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    /// Set while applying a stored frame, so the move notification it
    /// triggers doesn't write the same frame back.
    private var applyingFrame = false

    private static let defaultSize = NSSize(width: 560, height: 760)

    func attach(_ store: AppStore) {
        self.store = store
        cancellables.removeAll()
        store.$settings
            .map(\.desktopWidgetEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.setVisible(enabled) }
            }
            .store(in: &cancellables)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { panel = makePanel() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        guard let store else { fatalError("attach the store first") }
        let frame = storedFrame() ?? defaultFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 320, height: 240)

        // Frosted card over the wallpaper; the SwiftUI content sits on it.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: DesktopWidgetView().environmentObject(store))
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect

        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: panel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rememberFrame() }
            })
        }
        return panel
    }

    private func rememberFrame() {
        guard !applyingFrame, let panel, let store else { return }
        let f = panel.frame
        let stored: [Double] = [f.origin.x, f.origin.y, f.size.width, f.size.height].map(Double.init)
        if store.settings.desktopWidgetFrame != stored {
            store.settings.desktopWidgetFrame = stored
        }
    }

    private func storedFrame() -> NSRect? {
        guard let v = store?.settings.desktopWidgetFrame, v.count == 4 else { return nil }
        let rect = NSRect(x: v[0], y: v[1], width: max(v[2], 320), height: max(v[3], 240))
        // a frame from a screen that is no longer attached falls back to the default
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }

    private func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.defaultSize
        return NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24,
                      width: size.width, height: size.height)
    }
}

/// The widget's content: the Inbox, newest first, in huge type. Rows animate
/// in from the top as the store's inbox changes.
struct DesktopWidgetView: View {
    @EnvironmentObject var store: AppStore

    private static let maxRows = 40

    var body: some View {
        let articles = Array(store.inbox.prefix(Self.maxRows))
        let titleSize = store.settings.desktopWidgetTitleSize
        ScrollView {
            if articles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: titleSize * 1.4, weight: .light))
                    Text("Inbox zero")
                        .font(.system(size: titleSize * 0.8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, titleSize * 2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(articles) { article in
                        DesktopWidgetRow(article: article, titleSize: titleSize)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .scrollIndicators(.hidden)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: articles.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DesktopWidgetRow: View {
    @EnvironmentObject var store: AppStore
    let article: Article
    let titleSize: Double
    @State private var hovering = false

    private var metaSize: Double { max(12, titleSize * 0.42) }

    var body: some View {
        HStack(alignment: .top, spacing: titleSize * 0.4) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: titleSize * 0.3, height: titleSize * 0.3)
                .padding(.top, titleSize * 0.42)

            VStack(alignment: .leading, spacing: titleSize * 0.18) {
                Text(article.title)
                    .font(.system(size: titleSize, weight: article.isRead ? .medium : .bold))
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: metaSize * 0.45) {
                    SourceMark(
                        host: store.sourceHost(feedID: article.feedID, title: article.sourceTitle),
                        color: store.sourceColor(feedID: article.feedID, title: article.sourceTitle),
                        size: metaSize
                    )
                    Text(article.sourceTitle)
                        .fontWeight(.medium)
                    Text("·")
                    Text(article.published.articleDisplay)
                    if let tag = article.tag {
                        Text("·")
                        Text(tag)
                    }
                }
                .font(.system(size: metaSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            RowActionButton(
                icon: "xmark",
                help: "Clear now (recoverable for 24 hours)",
                visible: hovering
            ) {
                store.clear(article)
            }
            .padding(.top, titleSize * 0.2)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, titleSize * 0.35)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .onTapGesture { store.open(article) }
        .onHover { hovering = $0 }
        .hoverRefresh($hovering)
        .contextMenu {
            Button("Open in Browser") { store.open(article) }
            Button("Copy Link") { store.copyLink(article) }
                .disabled(article.link == nil)
            Button(store.isBookmarked(article.id) ? "Remove Bookmark" : "Bookmark") {
                store.toggleBookmark(article)
            }
            Divider()
            Button("Clear Now") { store.clear(article) }
        }
    }
}
