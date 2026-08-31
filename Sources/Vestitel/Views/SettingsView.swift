import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    @State private var newFeedURL = ""
    @State private var addingFeed = false
    @State private var feedError: String?
    @State private var clipboardHint: String?
    @State private var importResult: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                feedsSection
                Divider()
                behaviorSection
                Divider()
                storeScanSection
                Divider()
                syncSection
                Divider()
                localSourcesSection
                Divider()
                importExportSection
                Divider()
                aboutSection
            }
            .padding(14)
        }
        .onAppear(perform: offerClipboardFeed)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: Feeds

    private var feedsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Feeds")

            HStack(spacing: 8) {
                TextField("https://example.com/feed.xml", text: $newFeedURL)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 13))
                    .onSubmit(addFeed)
                Button(action: addFeed) {
                    if addingFeed {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 34)
                    } else {
                        Text("Add")
                            .frame(width: 34)
                    }
                }
                .buttonStyle(HoverButtonStyle(prominent: true))
                .disabled(newFeedURL.trimmingCharacters(in: .whitespaces).isEmpty || addingFeed)
            }

            if let feedError {
                Label(feedError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            } else if let clipboardHint, !newFeedURL.isEmpty {
                Label(clipboardHint, systemImage: "doc.on.clipboard")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if store.feeds.isEmpty {
                Text("No feeds added yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.feeds) { feed in
                        FeedRowView(feed: feed)
                        if feed.id != store.feeds.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// If the clipboard holds a URL that actually parses as an RSS/Atom feed,
    /// pre-fill the add-feed box with it. Never overwrites typed input and
    /// never adds anything by itself.
    private func offerClipboardFeed() {
        guard newFeedURL.isEmpty else { return }
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard raw.count <= 2048, !raw.contains(" "), !raw.contains("\n"),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return }
        guard !store.feeds.contains(where: { $0.url == url }) else { return }

        Task {
            guard await store.isFeed(url: url) else { return }
            // re-check: the user may have started typing while we verified
            guard newFeedURL.isEmpty else { return }
            newFeedURL = raw
            clipboardHint = "Feed URL taken from your clipboard. Press Add to subscribe."
        }
    }

    private func addFeed() {
        let url = newFeedURL
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        addingFeed = true
        feedError = nil
        Task {
            let error = await store.addFeed(urlString: url)
            addingFeed = false
            if let error {
                feedError = error
            } else {
                newFeedURL = ""
                clipboardHint = nil
            }
        }
    }

    // MARK: Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Behavior")

            SettingRow(
                title: "Refresh interval",
                subtitle: "How often feeds are checked for new articles."
            ) {
                Picker("", selection: $store.settings.refreshMinutes) {
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                }
                .labelsHidden()
                .frame(width: 110)
            }

            SettingRow(
                title: "Start Vestitel at login",
                subtitle: launchAtLoginError ?? "Opens automatically when you log in to your Mac.",
                onTap: { launchAtLogin.toggle() }
            ) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, wantEnabled in
                        setLaunchAtLogin(wantEnabled)
                    }
            }

            SettingRow(
                title: "Coloured menu bar icon",
                subtitle: "Colour signals new articles and an open popover. Off keeps the icon strictly monochrome.",
                onTap: { store.settings.allowColoredIcon.toggle() }
            ) {
                Toggle("", isOn: $store.settings.allowColoredIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingRow(
                title: "Group articles by topic",
                subtitle: "Cluster the same story across different sources.",
                onTap: { store.settings.groupingEnabled.toggle() }
            ) {
                Toggle("", isOn: $store.settings.groupingEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if store.settings.groupingEnabled {
                SettingRow(
                    title: "Grouping sensitivity",
                    subtitle: "Strict groups only near-identical headlines; loose also groups related coverage."
                ) {
                    Picker("", selection: sensitivityLevel) {
                        Text("Strict").tag(0)
                        Text("Balanced").tag(1)
                        Text("Loose").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            Label(
                "Clicked articles are marked read and clear after 15 minutes. Cleared articles stay recoverable for 24 hours.",
                systemImage: "info.circle"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
        }
    }

    /// The stored 0...1 sensitivity, exposed as three discrete steps.
    private var sensitivityLevel: Binding<Int> {
        Binding {
            let s = store.settings.groupingSensitivity
            return s < 0.35 ? 0 : (s > 0.65 ? 2 : 1)
        } set: { level in
            store.settings.groupingSensitivity = [0.15, 0.5, 0.85][level]
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        // no-op if the toggle already matches reality (e.g. we reverted it below)
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }

    // MARK: Latest-additions scan

    private var storeScanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("\(StoreScan.siteName) Latest Additions")

            SettingRow(
                title: "Scan the whole listing daily",
                subtitle: scanSubtitle,
                onTap: { store.settings.storeScanEnabled.toggle() }
            ) {
                Toggle("", isOn: $store.settings.storeScanEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Text("The \"latest additions\" page doesn't reliably order products by when they appeared: something added today can sit ten pages deep. The scan therefore walks every page, pausing several seconds between requests so the site doesn't take it for a crawler; a full pass takes a few minutes. Results don't enter the Store inbox: when the scan finishes you get a notification whose Open Report button builds a temporary HTML page of everything new. Run one ad-hoc from the Store tab.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var scanSubtitle: String {
        guard store.settings.storeScanEnabled else {
            return "Off. Turning it on records a baseline right away, then scans every day at \(String(format: "%d:%02d", StoreScan.dailyHour, StoreScan.dailyMinute))."
        }
        if let progress = store.storeScanProgress {
            return progress.page == 0
                ? "Scanning…"
                : "Scanning page \(progress.page) of \(progress.pageCount), \(progress.found) products so far."
        }
        if let next = store.nextStoreScanDate {
            return "Next scan \(next.articleDisplay)."
        }
        return "Runs daily at \(String(format: "%d:%02d", StoreScan.dailyHour, StoreScan.dailyMinute))."
    }

    // MARK: Sync between Macs

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Sync Between Macs")

            if let path = store.settings.syncFolderPath {
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    if let status = store.syncStatus {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(status.hasPrefix("Merged") || status.hasPrefix("No other")
                                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await store.syncNow() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        chooseSyncFolder()
                    } label: {
                        Label("Change Folder…", systemImage: "folder")
                    }
                    Button {
                        store.deleteSyncDocument()
                        store.settings.syncFolderPath = nil
                        store.syncStatus = nil
                    } label: {
                        Label("Turn Off", systemImage: "xmark.circle")
                    }
                }
                .buttonStyle(HoverButtonStyle())
            } else {
                Button {
                    chooseSyncFolder()
                } label: {
                    Label("Choose Sync Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(HoverButtonStyle())
            }

            Text("Pick a cloud-synced folder (e.g. inside Google Drive) and choose the same folder on every Mac. Feeds, read/cleared state, bookmarks and the never-show-again list merge automatically; each Mac writes only its own file, so there are no conflicts. Preferences stay per-Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a synced folder, and pick the same one on every Mac."
        if store.settings.syncFolderPath == nil, let root = defaultCloudRoot {
            panel.directoryURL = root
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.settings.syncFolderPath = url.path
            Task { await store.syncNow() }
        }
    }

    /// Google Drive's mount if present (the panel's starting point).
    private var defaultCloudRoot: URL? {
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        guard let mounts = try? FileManager.default.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil) else { return nil }
        return mounts.first { $0.lastPathComponent.hasPrefix("GoogleDrive-") }?
            .appendingPathComponent("My Drive")
    }

    // MARK: Import / export

    private var importExportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Import & Export")

            HStack(spacing: 10) {
                Button {
                    exportSettings()
                } label: {
                    Label("Export Settings…", systemImage: "square.and.arrow.up")
                }
                Button {
                    importSettings()
                } label: {
                    Label("Import Settings…", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(HoverButtonStyle())

            if let importResult {
                Text(importResult)
                    .font(.system(size: 11.5))
                    .foregroundStyle(importResult.hasPrefix("Imported") || importResult.hasPrefix("Exported") ? .green : .red)
            }

            Text("Exports feeds and preferences as JSON. Importing merges feeds with your current list.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Local sources

    private static let exampleEventJSON =
        #"{"source": "Ozonko", "title": "Kindle back in stock", "url": "https://example.com/kindle"}"#
    private static let exampleAddURL = LocalEvent.addURL(
        source: "Ozonko", title: "Kindle back in stock", url: "https://example.com/kindle"
    )?.absoluteString ?? ""

    private var localSourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Local Sources")

            Text("Other apps and scripts on this Mac can post things that happened. Each source name becomes a feed in the list above, and its events show up in the Inbox like articles.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Drop a JSON file (one event, or an array) into:")
                    .font(.system(size: 12))
                Text(AppStore.eventsFolderURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(Self.exampleEventJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    store.revealEventsFolder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    copyToClipboard(AppStore.eventsFolderURL.path)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .buttonStyle(HoverButtonStyle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Or open a URL (from any app, or `open` in a shell):")
                    .font(.system(size: 12))
                Text(Self.exampleAddURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                copyToClipboard(Self.exampleAddURL)
            } label: {
                Label("Copy Example URL", systemImage: "link")
            }
            .buttonStyle(HoverButtonStyle())

            Text("Required: source, title. Optional: url, summary, image, published (ISO 8601 or Unix seconds), id (deduplication key; defaults to the url, then the title). Processed files are deleted; files that don't parse are moved to Events/Rejected. Write files atomically (write elsewhere, then move) so they aren't read half-written.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("About")
            HStack(spacing: 6) {
                Text("Vestitel")
                    .font(.system(size: 13, weight: .medium))
                Text("Version \(Self.appVersion)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            SettingRow(
                title: "Update automatically",
                subtitle: "Checks GitHub once a day and installs a signed newer version while the popover is closed.",
                onTap: { store.settings.autoUpdateEnabled.toggle() }
            ) {
                Toggle("", isOn: $store.settings.autoUpdateEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingRow(
                title: "Check for updates",
                subtitle: store.updateStatus.isEmpty ? "Downloads from GitHub releases; only signed builds are installed." : store.updateStatus
            ) {
                Button("Check Now") { store.startUpdateCheck(manual: true) }
                    .buttonStyle(HoverButtonStyle())
                    .disabled(store.updaterTask != nil || !store.updaterAvailable)
            }
        }
    }

    /// Reads the marketing version from Info.plist; shows the build number too
    /// when it differs (they are kept equal by the release process, so normally
    /// only the version appears).
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (nil, b?): return b
        default: return "unknown"
        }
    }

    private func exportSettings() {
        guard let data = store.exportSettings() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "vestitel-settings.json"
        panel.title = "Export Vestitel Settings"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                importResult = "Exported to \(url.lastPathComponent)."
            } catch {
                importResult = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Vestitel Settings"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                if let error = store.importSettings(from: data) {
                    importResult = error
                } else {
                    importResult = "Imported settings from \(url.lastPathComponent)."
                }
            } catch {
                importResult = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Title + explanatory subtitle on the left, control on the right.
/// Highlights on hover so every setting reads as interactive; the negative
/// padding keeps the highlight from shifting the layout. When `onTap` is set
/// (toggle rows), clicking anywhere on the row activates the control.
struct SettingRow<Control: View>: View {
    let title: String
    let subtitle: String
    var onTap: (() -> Void)? = nil
    @ViewBuilder let control: Control

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(subtitle.hasPrefix("Couldn't") ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control
        }
        .padding(7)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(-7)
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct FeedRowView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var favicons = FaviconStore.shared
    let feed: Feed
    @State private var hovering = false
    @State private var editing = false
    @State private var draftTitle = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            colorMenu

            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Source name", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 260)
                        .focused($titleFieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { editing = false }  // Esc cancels
                } else {
                    HStack(spacing: 6) {
                        Text(feed.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .onTapGesture(count: 2) { beginRename() }
                            .help("Double-click to rename")
                        if feed.isStore {
                            Text("STORE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                                .help("Store watch: new products land in the Store tab; cleared products never reappear")
                        }
                        if feed.isLocal {
                            Text("LOCAL")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                                .help("Local source: another app on this Mac posts events here (see Local Sources below)")
                        }
                    }
                }
                Text(feed.url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let error = feed.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if feed.isLocal {
                // nothing to fetch: events are pushed in by the producer
            } else if store.refreshingFeedIDs.contains(feed.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                // always offered on a failing feed, so retry is discoverable
                RowActionButton(
                    icon: "arrow.clockwise",
                    help: "Fetch this feed now",
                    visible: (hovering || feed.lastError != nil) && !editing
                ) {
                    Task { await store.refreshFeed(feed) }
                }
            }
            if editing {
                RowActionButton(icon: "checkmark", tint: .green, help: "Save name") {
                    commitRename()
                }
            } else {
                RowActionButton(
                    icon: "pencil",
                    help: "Rename source",
                    visible: hovering
                ) {
                    beginRename()
                }
            }
            RowActionButton(
                icon: "trash",
                tint: .red,
                help: "Remove feed (keeps read/cleared history)",
                visible: hovering && !editing
            ) {
                store.removeFeed(feed)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Colour swatch; clicking opens the palette. "Automatic" restores the
    /// URL-derived colour.
    private var colorMenu: some View {
        Menu {
            Button {
                store.setFeedColor(feed, to: nil)
            } label: {
                Image(nsImage: SourcePalette.swatchImage(at: SourcePalette.autoIndex(forURL: feed.url)))
                Text(feed.colorIndex == nil ? "Automatic ✓" : "Automatic")
            }
            Divider()
            ForEach(0..<SourcePalette.count, id: \.self) { i in
                Button {
                    store.setFeedColor(feed, to: i)
                } label: {
                    Image(nsImage: SourcePalette.swatchImage(at: i))
                    Text(feed.colorIndex == i ? "\(SourcePalette.entries[i].name) ✓" : SourcePalette.entries[i].name)
                }
            }
        } label: {
            // favicon when the site has one; coloured swatch otherwise.
            // (Menu labels only render NSImages, at intrinsic size, so the
            // favicon must be pre-resized, not framed.)
            if let host = feed.faviconHost, let icon = favicons.menuIcon(for: host) {
                Image(nsImage: icon)
            } else {
                Image(nsImage: SourcePalette.swatchImage(at: store.resolvedColorIndex(feed)))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Source colour (used when the site has no icon)")
        .onAppear {
            if let host = feed.faviconHost {
                FaviconStore.shared.load(host: host)
            }
        }
    }

    private func beginRename() {
        draftTitle = feed.title
        editing = true
        titleFieldFocused = true
    }

    private func commitRename() {
        store.renameFeed(feed, to: draftTitle)
        editing = false
    }
}
