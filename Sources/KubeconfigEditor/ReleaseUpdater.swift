import Foundation
import SwiftUI
import AppKit
import Darwin

struct AvailableUpdate: Equatable {
    let version: String
    let downloadURL: URL
    let releaseURL: URL?
}

@MainActor
final class ReleaseUpdater: ObservableObject {
    @Published var availableUpdate: AvailableUpdate?
    @Published var isChecking = false
    @Published var isInstalling = false
    @Published var installStatus = ""
    @Published var latestReleaseVersion: String?
    @Published var latestReleaseURL: URL?
    @Published var currentVersion = "unknown"
    var isUpdateInProgress: Bool {
        isInstalling ||
        installStatus.localizedCaseInsensitiveContains("downloading update") ||
        installStatus.localizedCaseInsensitiveContains("installing update")
    }

    var hasNewerAvailableUpdate: Bool {
        guard let update = availableUpdate else { return false }
        guard let liveVersion = appVersion() else { return false }
        return isVersion(update.version, newerThan: liveVersion)
    }

    private var periodicCheckTask: Task<Void, Never>?
    private let owner = "deadnodes"
    private let repo = "kubeconfig-editor"
    private let installedVersionDefaultsKey = "kce.installedVersion"

    init() {
        if let version = effectiveCurrentVersion() {
            currentVersion = version
        }
    }

    deinit {
        periodicCheckTask?.cancel()
    }

    func checkForUpdatesIfNeeded() {
        guard periodicCheckTask == nil else { return }
        periodicCheckTask = Task { [weak self] in
            guard let self else { return }
            await self.checkForUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                await self.checkForUpdates()
            }
        }
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            installStatus = "Update check works only from installed .app bundle"
            return
        }
        guard let currentVersion = effectiveCurrentVersion() else { return }
        self.currentVersion = currentVersion
        availableUpdate = nil

        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let latest = normalizedVersion(release.tagName)
            latestReleaseVersion = latest
            latestReleaseURL = release.htmlURL
            guard isVersion(latest, newerThan: currentVersion) else {
                availableUpdate = nil
                installStatus = "You are up to date (\(currentVersion))"
                return
            }
            guard let assetURL = preferredAssetURL(from: release.assets) else {
                availableUpdate = nil
                installStatus = "Latest release has no installable asset (.zip/.dmg/.app)"
                return
            }
            availableUpdate = AvailableUpdate(
                version: latest,
                downloadURL: assetURL,
                releaseURL: release.htmlURL
            )
            installStatus = "Update available: \(latest)"
        } catch {
            installStatus = "Update check failed: \(error.localizedDescription)"
        }
    }

    func dismissUpdate() {
        availableUpdate = nil
    }

    var availableVersion: String {
        availableUpdate?.version ?? latestReleaseVersion ?? "not available"
    }

    func installAvailableUpdate() {
        guard let update = availableUpdate else { return }
        guard !isInstalling else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            installStatus = "Auto-update works only from installed .app bundle"
            return
        }
        guard let liveVersion = effectiveCurrentVersion(), isVersion(update.version, newerThan: liveVersion) else {
            availableUpdate = nil
            installStatus = "You are up to date (\(effectiveCurrentVersion() ?? currentVersion))"
            return
        }
        self.currentVersion = liveVersion
        isInstalling = true
        installStatus = "Installing update..."

        do {
            rememberInstalledVersion(update.version)
            try scheduleDownloadAndReplaceAndRestart(update: update)
            terminateForUpdateInstall()
        } catch {
            isInstalling = false
            installStatus = "Update failed: \(error.localizedDescription)"
        }
    }

    private func terminateForUpdateInstall() {
        NSApp.terminate(nil)

        // Fallback: force-exit if app is still alive after graceful terminate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if NSApp.isRunning {
                Darwin.exit(0)
            }
        }
    }

    private func appVersion() -> String? {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return normalizedVersion(version)
        }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return normalizedVersion(version)
        }
        return nil
    }

    private func storedInstalledVersion() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: installedVersionDefaultsKey) else { return nil }
        let value = normalizedVersion(raw)
        return value.isEmpty ? nil : value
    }

    private func rememberInstalledVersion(_ version: String) {
        let normalized = normalizedVersion(version)
        guard !normalized.isEmpty else { return }
        UserDefaults.standard.set(normalized, forKey: installedVersionDefaultsKey)
    }

    private func effectiveCurrentVersion() -> String? {
        let bundleVersion = appVersion()
        let storedVersion = storedInstalledVersion()

        switch (bundleVersion, storedVersion) {
        case let (bundle?, stored?):
            let effective = isVersion(stored, newerThan: bundle) ? stored : bundle
            rememberInstalledVersion(effective)
            return effective
        case let (bundle?, nil):
            rememberInstalledVersion(bundle)
            return bundle
        case let (nil, stored?):
            return stored
        case (nil, nil):
            return nil
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KubeconfigEditor", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ReleaseUpdater", code: 2001, userInfo: [NSLocalizedDescriptionKey: "GitHub API is unavailable"])
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func preferredAssetURL(from assets: [GitHubRelease.Asset]) -> URL? {
        let ordered = assets.sorted { lhs, rhs in
            let l = lhs.name.lowercased()
            let r = rhs.name.lowercased()
            func rank(_ name: String) -> Int {
                if name.hasSuffix(".zip") { return 0 }
                if name.hasSuffix(".dmg") { return 1 }
                if name.hasSuffix(".app") { return 2 }
                return 3
            }
            return rank(l) < rank(r)
        }
        return ordered.first(where: {
            let n = $0.name.lowercased()
            return n.hasSuffix(".zip") || n.hasSuffix(".dmg") || n.hasSuffix(".app")
        })?.downloadURL
    }

    private func downloadAsset(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ReleaseUpdater", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("kubeconfig-editor-update-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tempURL, to: dst)
        return dst
    }

    private func stageDownloadedApp(from fileURL: URL) throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("kubeconfig-editor-updater-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        if ext == "zip" {
            let extracted = workspace.appendingPathComponent("extracted")
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", fileURL.path, extracted.path])
            guard let app = firstAppBundle(in: extracted) else {
                throw NSError(domain: "ReleaseUpdater", code: 2003, userInfo: [NSLocalizedDescriptionKey: "No .app found in zip"])
            }
            let staged = workspace.appendingPathComponent("KubeconfigEditor.app")
            try run("/usr/bin/ditto", [app.path, staged.path])
            return staged
        }

        if ext == "dmg" {
            let mountPoint = workspace.appendingPathComponent("mount")
            try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, fileURL.path])
            defer {
                _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            }
            guard let app = firstAppBundle(in: mountPoint) else {
                throw NSError(domain: "ReleaseUpdater", code: 2004, userInfo: [NSLocalizedDescriptionKey: "No .app found in dmg"])
            }
            let staged = workspace.appendingPathComponent("KubeconfigEditor.app")
            try run("/usr/bin/ditto", [app.path, staged.path])
            return staged
        }

        if ext == "app" {
            return fileURL
        }

        throw NSError(domain: "ReleaseUpdater", code: 2005, userInfo: [NSLocalizedDescriptionKey: "Unsupported update format: \(ext)"])
    }

    private func scheduleDownloadAndReplaceAndRestart(update: AvailableUpdate) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw NSError(domain: "ReleaseUpdater", code: 2006, userInfo: [NSLocalizedDescriptionKey: "Target is not an app bundle"])
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        set -euo pipefail
        APP_PID=\(pid)
        TARGET_APP='\(shellEscape(target.path))'
        ASSET_URL='\(shellEscape(update.downloadURL.absoluteString))'
        LOG_FILE="$HOME/Library/Logs/KubeconfigEditor-updater.log"
        WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/kubeconfig-editor-updater.XXXXXX")"
        DOWNLOADED="$WORKDIR/update"
        STAGED_APP="$WORKDIR/KubeconfigEditor.app"
        MOUNT_POINT="$WORKDIR/mount"

        log() {
          printf '[%s] %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
        }

        cleanup() {
          if mount | grep -q " on $MOUNT_POINT "; then
            /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
          fi
          rm -rf "$WORKDIR"
        }
        trap cleanup EXIT

        for _ in $(seq 1 120); do
          if ! kill -0 "$APP_PID" 2>/dev/null; then
            break
          fi
          sleep 1
        done

        EXT="${ASSET_URL##*.}"
        EXT="${EXT%%\\?*}"
        EXT="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"
        case "$EXT" in
          zip|dmg|app) ;;
          *) log "Unsupported update format: $EXT"; exit 1 ;;
        esac

        log "Downloading update asset..."
        /usr/bin/curl -L --fail --silent --show-error "$ASSET_URL" -o "$DOWNLOADED.$EXT"

        if [[ "$EXT" == "zip" ]]; then
          mkdir -p "$WORKDIR/extracted"
          /usr/bin/ditto -x -k "$DOWNLOADED.$EXT" "$WORKDIR/extracted"
          APP_SOURCE="$(/usr/bin/find "$WORKDIR/extracted" -name '*.app' -type d | /usr/bin/head -n 1)"
          [[ -n "$APP_SOURCE" ]] || { log "No .app found in zip"; exit 1; }
          /usr/bin/ditto "$APP_SOURCE" "$STAGED_APP"
        elif [[ "$EXT" == "dmg" ]]; then
          mkdir -p "$MOUNT_POINT"
          /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DOWNLOADED.$EXT" >/dev/null
          APP_SOURCE="$(/usr/bin/find "$MOUNT_POINT" -maxdepth 2 -name '*.app' -type d | /usr/bin/head -n 1)"
          [[ -n "$APP_SOURCE" ]] || { log "No .app found in dmg"; exit 1; }
          /usr/bin/ditto "$APP_SOURCE" "$STAGED_APP"
        else
          /usr/bin/ditto "$DOWNLOADED.$EXT" "$STAGED_APP"
        fi

        log "Replacing app bundle..."
        rm -rf "$TARGET_APP"
        /usr/bin/ditto "$STAGED_APP" "$TARGET_APP"
        xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
        open "$TARGET_APP"
        log "Update installed successfully."
        """

        let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("kubeconfig-editor-updater-\(UUID().uuidString).sh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try run("/bin/chmod", ["+x", scriptFile.path])
        try run("/bin/bash", ["-lc", "nohup '\(shellEscape(scriptFile.path))' >/dev/null 2>&1 &"])
    }

    private func firstAppBundle(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "app" {
                return url
            }
        }
        return nil
    }

    private func scheduleReplaceAndRestart(using stagedApp: URL) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw NSError(domain: "ReleaseUpdater", code: 2006, userInfo: [NSLocalizedDescriptionKey: "Target is not an app bundle"])
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        set -euo pipefail
        APP_PID=\(pid)
        TARGET_APP='\(shellEscape(target.path))'
        STAGED_APP='\(shellEscape(stagedApp.path))'
        LOG_FILE="$HOME/Library/Logs/KubeconfigEditor-updater.log"

        for _ in $(seq 1 120); do
          if ! kill -0 "$APP_PID" 2>/dev/null; then
            break
          fi
          sleep 1
        done

        rm -rf "$TARGET_APP"
        /usr/bin/ditto "$STAGED_APP" "$TARGET_APP"
        xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
        open "$TARGET_APP"
        """

        let scriptFile = FileManager.default.temporaryDirectory.appendingPathComponent("kubeconfig-editor-updater-\(UUID().uuidString).sh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try run("/bin/chmod", ["+x", scriptFile.path])
        try run("/bin/bash", ["-lc", "nohup '\(shellEscape(scriptFile.path))' >/dev/null 2>&1 &"])
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(domain: "ReleaseUpdater", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "Command failed: \(launchPath)" : err])
        }
        return out
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

func normalizedVersion(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("v") {
        return String(trimmed.dropFirst())
    }
    return trimmed
}

func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
    let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(l.count, r.count)
    for i in 0..<count {
        let lv = i < l.count ? l[i] : 0
        let rv = i < r.count ? r[i] : 0
        if lv != rv { return lv > rv }
    }
    return false
}

private func shellEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}
