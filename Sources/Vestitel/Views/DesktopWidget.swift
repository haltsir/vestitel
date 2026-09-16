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
    /// Set from the grabber's mouse-down until the mouse-up: the only time
    /// a move of the panel is the user's. Every other move (a display going
    /// to sleep or unplugging makes the window server relocate the panel
    /// onto a remaining screen) must not touch the remembered frame.
    private var userDragging = false
    private var dragEndMonitors: [Any] = []
    private var reapplyWork: [DispatchWorkItem] = []

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
        // Dragging the list pans it; the window moves by the grabber at
        // the top (WindowDragHandle) and resizes by its edges.
        panel.isMovableByWindowBackground = false
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

        // Synchronous handlers: setFrame posts didMove before it returns,
        // so `applyingFrame` only covers the notification if it is handled
        // right there, not in a Task that runs after the flag is cleared.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.userDragging else { return }
                self.rememberFrame()
            }
        })
        // A live resize is by definition the user's (the edges).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberFrame() }
        })
        // A display going to sleep detaches its screen and the window
        // server relocates the panel onto one that is left; when it wakes
        // nothing moves the panel back. The remembered frame is where the
        // user wants it, so it is re-applied whenever it is on an attached
        // screen again. Screens come back in several steps over some
        // seconds (and the window server may move windows after the
        // notification), hence the retries.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        return panel
    }

    /// Called by the grabber on mouse-down, before `performDrag`: moves
    /// until the button is released are the user's and are remembered.
    func beginUserDrag() {
        endUserDrag()
        userDragging = true
        // performDrag hands the drag to the window server; the release is
        // observed rather than delivered, locally and (the app is inactive
        // behind its non-activating panel) globally, whichever comes first.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            Task { @MainActor in self?.endUserDrag() }
            return event
        }) { dragEndMonitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            Task { @MainActor in self?.endUserDrag() }
        }) { dragEndMonitors.append(m) }
    }

    private func endUserDrag() {
        if userDragging {
            rememberFrame()
            // the release is seen before the window server's last move of
            // the drag lands; pick up the final frame a moment later
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.rememberFrame() }
        }
        userDragging = false
        for m in dragEndMonitors { NSEvent.removeMonitor(m) }
        dragEndMonitors.removeAll()
    }

    /// Store the panel's frame as the user's preferred one. Only reached
    /// from a grabber drag or a live resize, never from a system move.
    private func rememberFrame() {
        guard !applyingFrame, let panel, let store else { return }
        let f = panel.frame
        // never remember a frame that is on no screen
        guard NSScreen.screens.contains(where: { $0.frame.intersects(f) }) else { return }
        let stored: [Double] = [f.origin.x, f.origin.y, f.size.width, f.size.height].map(Double.init)
        if store.settings.desktopWidgetFrame != stored {
            store.settings.desktopWidgetFrame = stored
        }
    }

    private func screensChanged() {
        endUserDrag()   // a screen change is not a drag, whatever the monitors saw
        userDragging = false
        for w in reapplyWork { w.cancel() }
        reapplyWork.removeAll()
        for delay in [0.0, 1.0, 3.0, 8.0] {
            let work = DispatchWorkItem { [weak self] in self?.reapplyPreferredFrame() }
            reapplyWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func reapplyPreferredFrame() {
        guard let panel, store?.settings.desktopWidgetEnabled == true else { return }
        if let preferred = storedFrame() {
            // the preferred frame's display is attached (again): go there
            if panel.frame != preferred { apply(preferred) }
        } else if !NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }) {
            // its display is gone and the panel is stranded: a temporary
            // home on the main screen, the preferred frame stays remembered
            apply(defaultFrame())
        }
    }

    private func apply(_ frame: NSRect) {
        applyingFrame = true
        panel?.setFrame(frame, display: true)
        applyingFrame = false
    }

    /// The remembered frame, or nil when it is on no attached screen (the
    /// caller then uses the default; the setting itself is left alone so
    /// the frame comes back with its display).
    private func storedFrame() -> NSRect? {
        guard let v = store?.settings.desktopWidgetFrame, v.count == 4 else { return nil }
        let rect = NSRect(x: v[0], y: v[1], width: max(v[2], 320), height: max(v[3], 240))
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
/// in from the top as the store's inbox changes. The list scrolls without a
/// scrollbar, by wheel or trackpad and by press-and-drag on the rows: a
/// hand-rolled offset rather than a ScrollView, because ScrollView has no
/// click-drag panning on macOS and a bare offset is what makes both work.
struct DesktopWidgetView: View {
    @EnvironmentObject var store: AppStore
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat? = nil
    @State private var contentHeight: CGFloat = 0

    private static let maxRows = 60

    var body: some View {
        let articles = Array(store.inbox.prefix(Self.maxRows))
        let titleSize = store.settings.desktopWidgetTitleSize
        VStack(spacing: 0) {
            WindowDragHandle()
                .frame(height: 22)
                .overlay {
                    Capsule()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 40, height: 5)
                        .allowsHitTesting(false)
                }
            GeometryReader { geo in
                let viewport = geo.size.height
                let maxOffset = max(0, contentHeight - viewport)
                Group {
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
                        .padding(.bottom, 10)
                    }
                }
                .frame(width: geo.size.width, alignment: .top)
                .background(GeometryReader { inner in
                    // measured directly (a preference set here was never
                    // delivered past the outer GeometryReader)
                    Color.clear
                        .onAppear { contentHeight = inner.size.height }
                        .onChange(of: inner.size.height) { _, h in contentHeight = h }
                })
                .offset(y: -min(offset, maxOffset))
                .frame(width: geo.size.width, height: viewport, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStart == nil { dragStart = offset }
                            offset = min(max((dragStart ?? 0) - value.translation.height, 0), maxOffset)
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .background(ScrollWheelCatcher { delta in
                    offset = min(max(offset - delta, 0), maxOffset)
                })
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: articles.map(\.id))
            }
        }
    }
}

/// A strip that moves the window when pressed and dragged (the panel is
/// not movable by its background, since dragging the list pans it).
private struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            DesktopWidgetController.shared.beginUserDrag()
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {}
}

/// Feeds wheel and trackpad scrolling to the caller. A local event monitor
/// rather than an NSView in the responder chain: a representable under
/// SwiftUI content would win AppKit hit-testing and swallow the clicks.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let v = context.coordinator.view, let window = v.window, event.window === window else { return event }
            let point = v.convert(event.locationInWindow, from: nil)
            guard v.bounds.contains(point) else { return event }
            // precise deltas (trackpad) are points; a mouse wheel reports
            // lines, scaled up so a notch moves a readable amount
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            context.coordinator.onScroll(delta)
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }
}

struct DesktopWidgetRow: View {
    @EnvironmentObject var store: AppStore
    let article: Article
    let titleSize: Double
    @State private var hovering = false

    /// The source and time line, a bit over half the title: readable from
    /// across the room like the title is.
    private var metaSize: Double { max(13, titleSize * 0.55) }

    var body: some View {
        // No unread dot: at this size it cost a column of width for what
        // the title's weight and colour already say.
        HStack(alignment: .top, spacing: titleSize * 0.4) {
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
