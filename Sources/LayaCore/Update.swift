import Foundation
import CryptoKit

// MARK: - Self-update engine (GitHub Releases — public repo, anonymous)
//
// The release train for this product publishes per-version assets on
// the PUBLIC GitHub repo:
//
//   laya-plugin-swift-<ver>-darwin-arm64.tar.gz         layad, laya, jev, LayaMenuBar
//   laya-plugin-swift-<ver>-darwin-arm64.tar.gz.sha256  "hex  filename" sidecar
//
// Everything runs anonymously: the REST API for release metadata and
// the plain browser_download_url for artifacts. No tokens, no gh CLI,
// no extra tooling — only URLSession, /usr/bin/tar, and CryptoKit.
// Integrity comes from the sha256 sidecar that ships with the release
// (API digest field as fallback), not from authentication.
//
// Install hygiene: download → sha256-verify → tar-extract into an
// isolated staging dir → hand the staged binaries to a detached restart
// script that swaps ~/.local/bin, re-bootstraps launchd, and relaunches
// the menu bar agent. The running process never overwrites itself in
// place (macOS would unlink it mid-write anyway).

public enum LayaUpdate {
    /// GitHub repo that carries the releases (owner/name).
    public static let repoSlug = "Andrei-cloud/laya-plugin-swift"

    /// Where update bookkeeping lives (last check, seen version).
    public static var stateFile: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/laya/update-state.json")
    }

    // MARK: Release model

    public struct Asset: Sendable {
        public var name: String
        public var url: String       // browser_download_url (public, anonymous)
        public var size: Int64
        public var digest: String    // "sha256:<hex>" from the API, "" if absent
    }

    public struct Release: Sendable {
        public var tag: String
        public var name: String
        public var body: String          // release notes, GitHub markdown
        public var publishedAt: String
        public var assets: [Asset]
        public var url: String           // release page (human-facing)

        /// The installable macOS arm64 payload (excludes the .sha256
        /// sidecar and the -source archive).
        public var installable: Asset? {
            assets.first { $0.name.contains(Self.marker) && !$0.name.hasSuffix(".sha256") }
        }
        public var checksumSidecar: Asset? {
            assets.first { $0.name.hasSuffix(Self.marker + ".sha256") }
        }
        private static let marker = "-darwin-arm64.tar.gz"
    }

    public enum UpdateError: LocalizedError, Sendable {
        case notFound
        case http(Int)
        case noAsset
        case checksumMismatch(expected: String, got: String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No published release found for \(repoSlug)."
            case .http(let code):
                return "GitHub returned HTTP \(code)."
            case .noAsset:
                return "The latest release has no darwin-arm64 binary asset to install."
            case .checksumMismatch(let want, let got):
                return "Checksum mismatch — expected \(want.prefix(12))…, got \(got.prefix(12))…. Download refused."
            case .network(let m):
                return "Network error: \(m)"
            }
        }
    }

    // MARK: Persisted bookkeeping

    public struct State: Codable {
        /// Epoch seconds of the last successful-or-attempted check.
        public var lastCheck: TimeInterval
        /// Tag we already told the user about (dedupe the daily nudge).
        public var seenTag: String
        /// Tag of the newest release found at last check ("" = none).
        public var latestTag: String
        public init(lastCheck: TimeInterval = 0, seenTag: String = "", latestTag: String = "") {
            self.lastCheck = lastCheck; self.seenTag = seenTag; self.latestTag = latestTag
        }

        public static func load() -> State {
            guard let data = FileManager.default.contents(atPath: stateFile),
                  let s = try? JSONDecoder().decode(State.self, from: data)
            else { return State() }
            return s
        }
        public func save() {
            let dir = (Self.stateFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(self) {
                try? data.write(to: URL(fileURLWithPath: Self.stateFile))
            }
        }
        public static var stateFile: String { LayaUpdate.stateFile }

        /// Daily cadence: re-check when the last attempt is older than
        /// this (the UI timer polls cheaply, this gates the network).
        public func dueForCheck(now: Date = Date()) -> Bool {
            now.timeIntervalSince1970 - lastCheck > 20 * 3600
        }
    }

    // MARK: Version compare

    /// Numeric semver compare ("v" prefix tolerated, leading segments
    /// only — a "v0.4.0-beta1" tag compares as 0.4.0). Returns -1/0/1.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
                .split(whereSeparator: { $0 == "." || $0 == "-" })
                .prefix(3)
                .map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<3 {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: Fetch latest release (anonymous REST call)

    public static func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw UpdateError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.network("no HTTP response") }
        switch http.statusCode {
        case 200: break
        case 404: throw UpdateError.notFound
        default: throw UpdateError.http(http.statusCode)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { throw UpdateError.network("unreadable release JSON") }

        var assets: [Asset] = []
        for a in (obj["assets"] as? [[String: Any]]) ?? [] {
            guard let name = a["name"] as? String, let dl = a["browser_download_url"] as? String
            else { continue }
            assets.append(Asset(
                name: name,
                url: dl,
                size: (a["size"] as? NSNumber)?.int64Value ?? 0,
                digest: (a["digest"] as? String) ?? ""))
        }
        return Release(
            tag: tag,
            name: (obj["name"] as? String) ?? tag,
            body: (obj["body"] as? String) ?? "",
            publishedAt: (obj["published_at"] as? String) ?? "",
            assets: assets,
            url: (obj["html_url"] as? String) ?? "https://github.com/\(repoSlug)/releases")
    }

    /// One-shot: fetch + compare against the running build.
    public static func check() async throws -> (release: Release, updateAvailable: Bool) {
        let rel = try await fetchLatestRelease()
        let newer = compareVersions(rel.tag, LayaVersion.string) > 0
        return (rel, newer)
    }

    // MARK: Download + verify + stage (plain HTTPS, anonymous)

    /// Downloads one release asset over its public URL. Status is
    /// checked — a deleted asset answers 404 with a text body, which
    /// tar would otherwise reject with a confusing "unrecognized
    /// archive".
    private static func fetchAsset(_ asset: Asset) async throws -> URL {
        var req = URLRequest(url: URL(string: asset.url)!)
        req.timeoutInterval = 240
        let (dl, resp): (URL, URLResponse)
        do { (dl, resp) = try await URLSession.shared.download(for: req) }
        catch { throw UpdateError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.network("no HTTP response") }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        return dl
    }

    /// Downloads the darwin-arm64 payload of `release`, verifies its
    /// sha256 (sidecar file preferred, API digest fallback), extracts it
    /// into an isolated staging directory and returns that directory.
    /// Throws .checksumMismatch on any digest disagreement — nothing is
    /// installed on mismatch.
    public static func stageDownload(of release: Release) async throws -> URL {
        guard let asset = release.installable else { throw UpdateError.noAsset }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory
            .appendingPathComponent("laya-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        // Download (~13 MB) straight from the public release URL.
        let dl = try await fetchAsset(asset)

        // Expected digest: sidecar first (authoritative, ships with the
        // release), then the API's digest field.
        var expected: String? = nil
        if let side = release.checksumSidecar {
            if let sdURL = try? await fetchAsset(side),
               let sd = try? Data(contentsOf: sdURL) {
                let text = String(decoding: sd, as: UTF8.self)
                // "6974039c…  laya-plugin-swift-….tar.gz"
                if let hex = text.split(whereSeparator: { $0.isWhitespace || $0 == "\n" }).first,
                   hex.count == 64, hex.allSatisfy(\.isHexDigit) {
                    expected = hex.lowercased()
                }
            }
        }
        if expected == nil, asset.digest.hasPrefix("sha256:") {
            expected = String(asset.digest.dropFirst("sha256:".count)).lowercased()
        }
        if let expected {
            let got = try sha256Hex(of: dl)
            if got != expected { throw UpdateError.checksumMismatch(expected: expected, got: got) }
        }

        // Extract; tar only follows the archive's own layout
        // (darwin-arm64/…). The archive is trusted ONLY after the
        // checksum check above.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", dl.path, "-C", stage.path]
        try tar.run(); tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw UpdateError.network("tar extraction failed (exit \(tar.terminationStatus))") }

        // Locate the payload dir (tar ships a darwin-arm64/ leaf).
        let inner = stage.appendingPathComponent("darwin-arm64", isDirectory: true)
        let payload = fm.fileExists(atPath: inner.appendingPathComponent("layad").path) ? inner : stage
        guard fm.fileExists(atPath: payload.appendingPathComponent("layad").path),
              fm.fileExists(atPath: payload.appendingPathComponent("LayaMenuBar").path)
        else { throw UpdateError.noAsset }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.appendingPathComponent("layad").path)
        return payload
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Restart script

    /// Bash script that swaps the staged binaries into ~/.local/bin,
    /// re-bootstraps the daemon launchd job, and relaunches the menu bar
    /// agent, then deletes itself. Detached via /bin/sh so it survives
    /// this process terminating.
    public static func restartScript(stagedDir: String, healthPort: Int) -> String {
        let home = NSHomeDirectory()
        let bin = (home as NSString).appendingPathComponent(".local/bin")
        let daemonPlist = DaemonConfigPaths.daemonPlist
        let menubarLabel = "com.laya.menubar"
        let menubarPlist = (home as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(menubarLabel).plist")
        let uid = getuid()
        let health = "http://127.0.0.1:\(healthPort)/health"
        return """
        #!/bin/bash
        # laya self-update — staged swap + relaunch (generated; self-deletes)
        set -u
        STAGED="\(stagedDir)"
        BIN="\(bin)"
        UID_NUM=\(uid)
        sleep 2                      # let the calling agent exit cleanly

        # verify the staged payload one more time before touching anything
        [ -x "$STAGED/layad" ] && [ -x "$STAGED/LayaMenuBar" ] || exit 1

        # retire the running jobs (bootout also kills them)
        launchctl bootout "gui/$UID_NUM/com.laya.daemon" 2>/dev/null
        launchctl bootout "gui/$UID_NUM/\(menubarLabel)" 2>/dev/null

        # swap binaries; jev is a symlink to laya (dual naming)
        install -m 755 "$STAGED/layad"       "$BIN/layad"       || exit 1
        install -m 755 "$STAGED/laya"        "$BIN/laya"        || exit 1
        install -m 755 "$STAGED/LayaMenuBar" "$BIN/laya-menubar" || exit 1
        ln -sf laya "$BIN/jev"

        # bring the daemon back (plist already on disk, config untouched)
        if [ -f "\(daemonPlist)" ]; then
            launchctl bootstrap "gui/$UID_NUM" "\(daemonPlist)" || true
        fi

        # wait for the engine to warm (up to ~75 s), then relaunch the agent
        i=0
        while [ $i -lt 75 ]; do
            curl -sf --max-time 2 "\(health)" >/dev/null 2>&1 && break
            i=$((i+1)); sleep 1
        done
        if [ -f "\(menubarPlist)" ]; then
            launchctl bootstrap "gui/$UID_NUM" "\(menubarPlist)" || true
        else
            "\(bin)/laya-menubar" >/dev/null 2>&1 &
        fi

        rm -rf "$STAGED"
        [ -f "$0" ] && rm -f "$0"
        """
    }

    /// Paths needed by the restart script without importing AppKit here.
    enum DaemonConfigPaths {
        static var daemonPlist: String {
            (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/LaunchAgents/com.laya.daemon.plist")
        }
    }

    /// Writes the restart script to a private temp file and detaches it.
    public static func detachRestart(stagedDir: String, healthPort: Int) throws {
        let script = restartScript(stagedDir: stagedDir, healthPort: healthPort)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("laya-update-\(UUID().uuidString.prefix(8)).sh")
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
