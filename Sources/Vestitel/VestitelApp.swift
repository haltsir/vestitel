import SwiftUI
import AppKit

@main
struct VestitelApp: App {
    @StateObject private var store = AppStore()

    init() {
        // Menu-bar-only app: no Dock icon even when run outside a bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        // Colour is a signal (new articles, popover open, arrival animation).
        // The setting decides whether colour is allowed at all — off means
        // strictly monochrome in every state.
        let allowColor = store.settings.allowColoredIcon
        let hasInboxArticles = store.articles.contains { $0.state == .inbox }
        // Head tilt + downcast eyes only while the popover is open (and
        // there's something in the inbox to look at); upright when closed.
        let lookDown = store.popoverOpen && hasInboxArticles
        let icon: NSImage = {
            if let frame = store.iconAnimationFrame {
                return allowColor ? MenuBarIcon.coloredFrames[frame] : MenuBarIcon.templateFrames[frame]
            }
            if allowColor {
                if store.hasUnseenArticles {
                    return lookDown ? MenuBarIcon.coloredDown : MenuBarIcon.colored
                }
                // popover open: the head lights up, waves stay neutral
                if store.popoverOpen {
                    return lookDown ? MenuBarIcon.headColoredDown : MenuBarIcon.headColored
                }
            } else if store.popoverOpen {
                return lookDown ? MenuBarIcon.templateDown : MenuBarIcon.template
            }
            return MenuBarIcon.template
        }()
        Image(nsImage: icon)
    }
}
