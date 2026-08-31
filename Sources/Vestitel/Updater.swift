import Foundation
import AppKit
import CryptoKit

/// Self-update from GitHub releases. Once a day the app asks the releases
/// API for the newest version; a newer one is downloaded together with its
/// detached ed25519 signature (made by Tools/sign-release.swift at release
/// time), verified against the embedded public key, unpacked, and staged.
/// The swap itself waits until the app is idle (popover closed, no scan
/// running): a helper script replaces the bundle after the app exits and
/// relaunches it. Self-downloaded updates carry no quarantine flag, so
/// Gatekeeper never re-blocks an updated install.
enum Updater {
    static let dailyHour = 12
    static let dailyMinute = 30

    /// ed25519 public key; the private half lives in
    /// ~/.config/vestitel/release-key on the release machine only.
    static let publicKeyBase64 = "fTV1XiiE0DB2L7LfJF0V26DpDvG6C/gFPqVFhl3n1WM="

    /// VESTITEL_UPDATE_URL points a test instance at a stand-in releases
    /// document (same JSON shape as the GitHub API).
    static let releasesAPI = URL(string:
        ProcessInfo.processInfo.environment["VESTITEL_UPDATE_URL"]
            ?? "https://api.github.com/repos/haltsir/vestitel/releases/latest")!

    /// "1.2.3" → [1,2,3]; true when b is strictly newer than a. Missing
    /// components count as 0, so "1.7" and "1.7.0" are the same version
    /// (the plist carries two parts, tags three).
    static func isNewer(_ b: String, than a: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if y != x { return y > x }
        }
        return false
    }

    static func sameVersion(_ a: String, _ b: String) -> Bool {
        !isNewer(a, than: b) && !isNewer(b, than: a)
    }
}

extension AppStore {

    var currentAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Updates are off for test instances (they'd replace their own
    /// throwaway bundles) unless the stand-in API seam is set.
    var updaterAvailable: Bool {
        guard currentAppVersion != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return false }
        if ProcessInfo.processInfo.environment["VESTITEL_STATE_DIR"] != nil {
            return ProcessInfo.processInfo.environment["VESTITEL_UPDATE_URL"] != nil
        }
        return true
    }

    /// Rides sweep(): a one-shot timer aimed at 12:30
    /// would be missed by sleep or a late launch.
    func maybeRunDailyUpdateCheck() {
        guard updaterAvailable, updaterTask == nil else { return }
        // A verified update is staged: swap as soon as the app sits idle.
        // Deliberately not gated on autoUpdateEnabled: a manual check can
        // stage an update while the daily check is off, and it must still
        // install once the popover closes.
        if stagedUpdatePath != nil {
            installStagedUpdateIfIdle()
            return
        }
        guard settings.autoUpdateEnabled else { return }
        guard let trigger = Calendar.current.date(
            bySettingHour: Updater.dailyHour, minute: Updater.dailyMinute, second: 0, of: Date()
        ), Date() >= trigger else { return }
        if let last = lastUpdateCheck, last >= trigger { return }
        startUpdateCheck()
    }

    /// The Settings button forces a check regardless of the daily stamp.
    func startUpdateCheck(manual: Bool = false) {
        guard updaterAvailable, updaterTask == nil else { return }
        lastUpdateCheck = Date()
        if manual { updateStatus = "Checking…" }
        updaterTask = Task { [weak self] in
            await self?.runUpdateCheck(manual: manual)
            self?.updaterTask = nil
        }
    }

    private func runUpdateCheck(manual: Bool) async {
        guard let current = currentAppVersion else { return }
        do {
            var request = URLRequest(url: Updater.releasesAPI)
            request.setValue("Vestitel-Updater", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await Self.updateSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 404 also covers a private repo: the API hides it
                throw UpdateError.http(http.statusCode)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                throw UpdateError.badResponse
            }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Updater.isNewer(remote, than: current) else {
                updateStatus = manual ? "You have the latest version." : ""
                save()
                return
            }
            func assetURL(_ suffix: String) -> URL? {
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
            }
            guard let zipURL = assetURL(".zip"), let sigURL = assetURL(".zip.sig") else {
                // an unsigned release is never installed
                updateStatus = "Version \(remote) is not signed; skipped."
                return
            }
            updateStatus = "Downloading \(remote)…"
            let (zipData, _) = try await Self.updateSession.data(from: zipURL)
            let (sigData, _) = try await Self.updateSession.data(from: sigURL)
            guard let keyRaw = Data(base64Encoded: Updater.publicKeyBase64),
                  let signature = Data(base64Encoded:
                    String(decoding: sigData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyRaw),
                  key.isValidSignature(signature, for: zipData) else {
                updateStatus = "Version \(remote) has an invalid signature; skipped."
                return
            }

            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vestitel-update-\(remote)", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let zipFile = staging.appendingPathComponent("update.zip")
            try zipData.write(to: zipFile)
            try await runProcess("/usr/bin/ditto", ["-xk", zipFile.path, staging.path])
            let newApp = staging.appendingPathComponent("Vestitel.app")
            let newPlist = newApp.appendingPathComponent("Contents/Info.plist")
            guard let plist = NSDictionary(contentsOf: newPlist),
                  let newVersion = plist["CFBundleShortVersionString"] as? String,
                  Updater.sameVersion(newVersion, remote) else {
                updateStatus = "Version \(remote): the archive is damaged; skipped."
                try? FileManager.default.removeItem(at: staging)
                return
            }
            stagedUpdatePath = newApp.path
            stagedUpdateVersion = remote
            updateStatus = "Version \(remote) is ready and installs when the popover is closed."
            save()
            installStagedUpdateIfIdle()
        } catch UpdateError.http {
            if manual { updateStatus = "Couldn't reach GitHub releases." }
        } catch {
            if manual { updateStatus = "Couldn't check for updates." }
        }
    }

    /// Swap only while nothing is on screen: replacing the app under the
    /// user's cursor reads as a crash.
    func installStagedUpdateIfIdle(force: Bool = false) {
        guard let staged = stagedUpdatePath,
              FileManager.default.fileExists(atPath: staged) else {
            stagedUpdatePath = nil
            return
        }
        if !force {
            guard !popoverOpen else { return }
        }
        let appPath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        // A test instance must come back as a test instance: relaunch the
        // binary with its state dir instead of `open`, which would start a
        // second real instance on the real state file.
        let relaunch: String
        if let stateDir = ProcessInfo.processInfo.environment["VESTITEL_STATE_DIR"] {
            let updateURL = ProcessInfo.processInfo.environment["VESTITEL_UPDATE_URL"] ?? ""
            relaunch = """
            VESTITEL_STATE_DIR="\(stateDir)" VESTITEL_UPDATE_URL="\(updateURL)" \
            nohup "\(appPath)/Contents/MacOS/Vestitel" >/dev/null 2>&1 &
            """
        } else {
            relaunch = "/usr/bin/open \"\(appPath)\""
        }
        let script = """
        #!/bin/sh
        while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(appPath)"
        /usr/bin/ditto "\(staged)" "\(appPath)"
        rm -rf "\((staged as NSString).deletingLastPathComponent)"
        \(relaunch)
        """
        let scriptFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vestitel-swap.sh")
        do {
            try script.write(to: scriptFile, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptFile.path]
            try process.run()
        } catch {
            updateStatus = "Couldn't install the update."
            return
        }
        NSApp.terminate(nil)
    }

    /// One quiet notification after the relaunch that finished an update.
    func noteVersionChange() {
        let current = currentAppVersion
        if let last = lastRunVersion, let current, last != current {
            NotificationManager.shared.notifyUpdated(version: current)
        }
        if lastRunVersion != current {
            lastRunVersion = current
            save()
        }
    }

    private func runProcess(_ path: String, _ args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else { throw UpdateError.processFailed }
    }

    private enum UpdateError: Error {
        case badResponse
        case processFailed
        case http(Int)
    }

    /// Plain session: GitHub only, separate from the feed session's UA.
    private static let updateSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
}
