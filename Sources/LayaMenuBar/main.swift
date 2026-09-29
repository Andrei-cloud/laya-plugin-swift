import AppKit
import Foundation
import LayaCore

// LayaMenuBar — native menu bar companion for the layad daemon.
//
//  • status item: brain glyph + status dot (green warm / amber loading /
//    gray down) + mean-latency readout while warm
//  • polls GET /health every 3 s (calls, mean latency, chains, warm)
//  • self-update: checks GitHub Releases once a day in the background
//    (and on demand via "Check for Updates…"); an available update
//    badges the menu bar glyph with an arrow-in-circle and opens the
//    release-notes window; "Install" downloads the darwin-arm64
//    artifact, verifies its sha256, and swaps binaries via a detached
//    restart script that relaunches daemon + agent.
//  • Start / Stop / Restart through launchctl (gui domain — the daemon
//    stays launchd-managed, the agent never spawns it directly)
//  • Settings window edits ~/.config/laya/daemon.json and regenerates
//    the launchd plist from it (single source of truth; 0600 file)
//  • headless modes for install.sh and scripts:
//        --init-config    write default config, print path
//        --render-plist   regenerate plist from config, print path
//        --status         one-shot health probe, human line, exit 0/1
//
// No secrets in the menu or logs: the Bearer token field is a secure
// text field and is never echoed. Update checks are fully anonymous —
// the releases repo is public and nothing is stored or sent beyond the
// plain GitHub API/download requests.

let argv = CommandLine.arguments

func sharedConfigURL() -> URL {
    URL(fileURLWithPath: DaemonConfig.configFile)
}

// MARK: - headless modes

func writeConfig(_ cfg: DaemonConfig) throws {
    try cfg.save()
    print(DaemonConfig.configFile)
}

func renderPlist() throws {
    let cfg = DaemonConfig.load()
    let data = try cfg.renderedPlist()
    try data.write(to: URL(fileURLWithPath: DaemonConfig.plistFile))
    print(DaemonConfig.plistFile)
}

func oneShotStatus() -> Never {
    let cfg = DaemonConfig.load()
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(cfg.port)/health")!)
    req.timeoutInterval = 4
    let sem = DispatchSemaphore(value: 0)
    // Boxed result: the URLSession completion handler is @Sendable and
    // must not mutate captured vars (Swift 6).
    final class Slot: @unchecked Sendable {
        var line = ""
        var ok = false
    }
    let slot = Slot()
    let task = URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        slot.ok = true
        let warm = (obj["warm"] as? Bool) ?? false
        let calls = (obj["calls"] as? NSNumber)?.int64Value ?? 0
        let mean = (obj["mean_latency_ms"] as? NSNumber)?.doubleValue ?? 0
        let chains = (obj["chains"] as? [String]) ?? []
        slot.line = "layad: \(warm ? "WARM" : "loading") · \(calls) calls · "
            + String(format: "%.1f ms mean", mean) + " · \(chains.count) chains"
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 5)
    print(slot.line.isEmpty
        ? "layad: DOWN (no answer on 127.0.0.1:\(cfg.port))"
        : slot.line)
    exit(slot.ok ? 0 : 1)
}

LayaVersion.handleIfRequested(argv)
if argv.contains("--init-config") {
    try? writeConfig(.defaults)
    exit(0)
}
if argv.contains("--render-plist") {
    do { try renderPlist() } catch {
        FileHandle.standardError.write(Data("render-plist failed: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
if argv.contains("--status") {
    oneShotStatus()
}
if argv.contains("--check-updates") {
    // one-shot update probe for scripts/tests: prints the outcome,
    // exit 0 up-to-date, 2 update available, 1 check failed.
    // URLSession's async plumbing needs the MAIN runloop pumped, so
    // main runs RunLoop.main and the worker exits the process itself.
    let done = false  // never mutated — the while-loop is only the watchdog pump
    Task.detached {
        do {
            let (rel, newer) = try await LayaUpdate.check()
            if newer {
                print("update available: \(rel.tag) (running \(LayaVersion.string))")
                exit(2)
            } else {
                print("up to date: \(LayaVersion.string) (latest \(rel.tag))")
                exit(0)
            }
        } catch {
            print("update check failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    print("update check failed: timed out")
    exit(1)
}

if argv.contains("--preview-update") {
    // dev-branch only: open the notes window against the live latest
    // release (or a fake newer tag with --fake) for visual review.
    let fake = argv.contains("--fake")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let holder = PreviewHolder()
    Task {
        do {
            let rel = try await LayaUpdate.fetchLatestRelease()
            var shown = rel
            if fake { shown.tag = "v9.9.9"; shown.name = "v9.9.9 — preview fixture" }
            await MainActor.run {
                let w = UpdateWindow()
                w.show(release: shown)
                holder.w = w
            }
        } catch {
            print("preview failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    app.run()
}

final class PreviewHolder { var w: AnyObject? }

@MainActor
final class DaemonController {
    let cfg: DaemonConfig
    private let session = URLSession(configuration:
        { let c = URLSessionConfiguration.ephemeral; c.requestCachePolicy = .reloadIgnoringLocalCacheData; return c }())

    init(cfg: DaemonConfig) { self.cfg = cfg }

    // async health probe: URLSession hops back to the MainActor caller
    // itself — a @Sendable completion handoff from a @MainActor class is
    // a region-isolation error under Swift 6 strict concurrency.
    func health() async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(cfg.port)/health")!)
        req.timeoutInterval = 2.5
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    // launchctl argument forms: bootstrap gui/<uid> <plist-path>;
    // bootout/kickstart gui/<uid>/<label> (label GLUED to the domain).
    // All three hop to a detached task: kickstart -k blocks while launchd
    // tears the old job down, and the menu bar must stay responsive.
    static func start()   { Task.detached { launchctl(["bootstrap", "gui/\(getuid())", DaemonConfig.plistFile]) } }
    static func stop()    { Task.detached { launchctl(["bootout", "gui/\(getuid())/\(DaemonConfig.label)"]) } }
    static func restart() { Task.detached { launchctl(["kickstart", "-k", "gui/\(getuid())/\(DaemonConfig.label)"]) } }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let cfg: DaemonConfig
    let onSave: (DaemonConfig) -> Void
    let onCheckUpdates: () -> Void

    private let assetsField = NSTextField(string: "")
    private let unitPopup = NSPopUpButton()
    private let portField = NSTextField(string: "")
    private let grpcField = NSTextField(string: "")
    private let tokenField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(cfg: DaemonConfig, onSave: @escaping (DaemonConfig) -> Void,
         onCheckUpdates: @escaping () -> Void) {
        self.cfg = cfg
        self.onSave = onSave
        self.onCheckUpdates = onCheckUpdates
        super.init()
    }

    func show() {
        if window == nil { build() }
        statusLabel.stringValue = ""
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "layad settings"
        w.isReleasedWhenClosed = false
        w.delegate = self

        assetsField.stringValue = cfg.assets
        assetsField.placeholderString = "model root (hf download --local-dir target)"
        portField.stringValue = String(cfg.port)
        grpcField.stringValue = String(cfg.grpcPort)
        tokenField.placeholderString = "loopback Bearer token (blank = none)"
        tokenField.stringValue = cfg.token
        unitPopup.addItems(withTitles: ["gpu", "ne", "cpu"])
        unitPopup.selectItem(withTitle: cfg.unit)

        let grid = NSGridView(views: [
            [label("model"), assetsField],
            [label("unit"), unitPopup],
            [label("http port"), portField],
            [label("grpc port"), grpcField],
            [label("token"), tokenField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 380

        let save = NSButton(title: "Save & restart daemon",
                            target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        // version + update row: shows what's running, offers a manual check
        let versionLine = NSTextField(labelWithString: "Laya \(LayaVersion.string)")
        versionLine.font = NSFont.systemFont(ofSize: 11)
        versionLine.textColor = .secondaryLabelColor
        let checkBtn = NSButton(title: "Check for Updates…",
                                target: self, action: #selector(checkUpdatesTapped))
        checkBtn.bezelStyle = .rounded
        checkBtn.controlSize = .small
        checkBtn.font = NSFont.systemFont(ofSize: 11)
        let updateRow = NSStackView(views: [versionLine, NSView(), checkBtn])
        updateRow.orientation = .horizontal
        updateRow.spacing = 8

        let stack = NSStackView(views: [grid, statusLabel, save, updateRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        updateRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        w.contentView = NSView(frame: w.contentRect(forFrameRect: w.frame))
        w.contentView?.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
        ])
        window = w
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    @objc private func saveTapped() {
        var next = cfg
        next.assets = assetsField.stringValue.trimmingCharacters(in: .whitespaces)
        next.unit = unitPopup.titleOfSelectedItem ?? "ne"
        next.port = Int(portField.stringValue) ?? cfg.port
        next.grpcPort = Int(grpcField.stringValue) ?? cfg.grpcPort
        next.token = tokenField.stringValue
        do {
            try next.save()
            let data = try next.renderedPlist()
            try data.write(to: URL(fileURLWithPath: DaemonConfig.plistFile))
            onSave(next)
            window?.close()
        } catch {
            statusLabel.stringValue = "save failed: \(error)"
        }
    }

    @objc private func checkUpdatesTapped() { onCheckUpdates() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    let cfg = DaemonConfig.load()
    private var controller: DaemonController!
    private var settings: SettingsWindow?

    private let healthItem = NSMenuItem(title: "daemon: checking…", action: nil, keyEquivalent: "")
    private let callsItem = NSMenuItem(title: "calls", action: nil, keyEquivalent: "")
    private let latItem = NSMenuItem(title: "mean latency", action: nil, keyEquivalent: "")
    private let chainsItem = NSMenuItem(title: "chains", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "Start daemon", action: #selector(startDaemon), keyEquivalent: "s")
    private let restartItem = NSMenuItem(title: "Restart daemon", action: #selector(restartDaemon), keyEquivalent: "r")
    private let stopItem = NSMenuItem(title: "Stop daemon", action: #selector(stopDaemon), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")

    // update state (badge + notes window)
    private var updateState = LayaUpdate.State.load()
    private var pendingRelease: LayaUpdate.Release?
    private var updateWindow: UpdateWindow?
    private var checkingUpdates = false
    private var badgeOn = false

    func applicationDidFinishLaunching(_ note: Notification) {
        controller = DaemonController(cfg: cfg)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setGlyph("brain.head.profile", dot: NSColor.tertiaryLabelColor, extra: "")

        for item in [healthItem, callsItem, latItem, chainsItem] {
            item.isEnabled = false
        }
        startItem.target = self
        restartItem.target = self
        stopItem.target = self
        updateItem.target = self

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(healthItem)
        menu.addItem(callsItem)
        menu.addItem(latItem)
        menu.addItem(chainsItem)
        menu.addItem(.separator())
        menu.addItem(startItem)
        menu.addItem(restartItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(updateItem)
        let logsItem = NSMenuItem(title: "Reveal logs", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.poll() }
        }

        // If a previous run already found a newer release, restore the
        // badge immediately (no network) so it survives agent restarts.
        if let tag = pendingBadgeTag() {
            pendingRelease = nil
            badgeOn = true
            updateItem.title = "Update Available — \(tag)\u{2026}"
            setGlyph(currentGlyph(), dot: currentDot(), extra: currentExtra())
        }

        // Daily background update check: probe now if the last check is
        // older than a day, then re-probe on a slow hourly tick (the
        // tick is cheap — the network call is gated by dueForCheck).
        Task { await runUpdateCheck(auto: true) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.runUpdateCheck(auto: true) }
        }
    }

    private var updateTimer: Timer?

    private func pendingBadgeTag() -> String? {
        let tag = updateState.latestTag
        guard !tag.isEmpty, LayaUpdate.compareVersions(tag, LayaVersion.string) > 0 else { return nil }
        return "v" + tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: glyph rendering (health state + update badge compose here)

    private var glyphName = "brain.head.profile"
    private var glyphDot: NSColor = .tertiaryLabelColor
    private var glyphExtra = ""

    private func currentGlyph() -> String { glyphName }
    private func currentDot() -> NSColor { glyphDot }
    private func currentExtra() -> String { glyphExtra }

    private func setGlyph(_ name: String, dot: NSColor, extra: String) {
        guard let button = statusItem?.button else { return }
        glyphName = name; glyphDot = dot; glyphExtra = extra

        let base = NSImage(systemSymbolName: name, accessibilityDescription: "layad")
        base?.isTemplate = true
        // Update-available badge: a small accent-tinted arrow.down.circle
        // composited onto the glyph's bottom-right — the classic macOS
        // updater pattern (App Store / Sparkle). The brain identity is
        // preserved, the badge reads at 16 pt, and it disappears the
        // moment the update is installed.
        if badgeOn, let base {
            let size = NSSize(width: 18, height: 16)
            let composited = NSImage(size: size)
            composited.lockFocus()
            // Template images drawn into a bitmap lose menu-bar
            // adaptivity — paint the brain with labelColor via
            // sourceIn so it stays legible in light and dark menus.
            let brain = NSImage(size: size)
            brain.lockFocus()
            base.draw(in: NSRect(origin: .zero, size: size))
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: size)
                .fill(using: .sourceAtop)
            brain.unlockFocus()
            brain.draw(in: NSRect(origin: .zero, size: size))
            let badgeSide: CGFloat = 9
            let badgeRect = NSRect(x: size.width - badgeSide - 0.5, y: 0,
                                   width: badgeSide, height: badgeSide)
            NSColor.windowBackgroundColor.setFill()
            let halo = NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1))
            halo.fill()
            if let badge = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                   accessibilityDescription: "update available") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                    .applying(.init(paletteColors: [.white, .controlAccentColor]))
                badge.withSymbolConfiguration(cfg)?.draw(in: badgeRect)
            }
            composited.unlockFocus()
            composited.isTemplate = false
            button.image = composited
        } else {
            button.image = base
        }

        let dotStr = NSAttributedString(string: "●" + (extra.isEmpty ? "" : " " + extra), attributes: [
            .foregroundColor: badgeOn ? NSColor.controlAccentColor : dot,
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ])
        button.imagePosition = .imageLeading
        button.attributedTitle = dotStr
        button.toolTip = badgeOn
            ? "layad \(LayaVersion.string) · update \(updateState.latestTag) available — click to view notes"
            : "layad \(LayaVersion.string)"
    }

    private func poll() async {
        let obj = await controller.health()
        if let obj {
            let warm = (obj["warm"] as? Bool) ?? false
            let calls = (obj["calls"] as? NSNumber)?.int64Value ?? 0
            let mean = (obj["mean_latency_ms"] as? NSNumber)?.doubleValue ?? 0
            let chains = (obj["chains"] as? [String]) ?? []
            setGlyph(warm ? "brain.head.profile" : "brain",
                     dot: warm ? .systemGreen : .systemYellow,
                     extra: warm ? String(format: "%.0fms", mean) : "…")
            healthItem.title = warm
                ? "daemon: warm · port \(cfg.port) · \(cfg.unit)"
                : "daemon: loading (engine warming)"
            callsItem.title = "calls served: \(calls)"
            latItem.title = String(format: "mean latency: %.2f ms", mean)
            chainsItem.title = "chains: \(chains.count)"
            startItem.isHidden = true
            restartItem.isHidden = false
            stopItem.isHidden = false
        } else {
            setGlyph("brain.head.profile", dot: .secondaryLabelColor, extra: "")
            healthItem.title = "daemon: down"
            callsItem.title = "calls served: —"
            latItem.title = "mean latency: —"
            chainsItem.title = "chains: —"
            startItem.isHidden = false
            restartItem.isHidden = true
            stopItem.isHidden = true
        }
    }

    // live-refresh when the menu opens
    func menuWillOpen(_ menu: NSMenu) { Task { await poll() } }

    @objc private func startDaemon() {
        DaemonController.start()
        healthItem.title = "daemon: starting (launchd bootstrap)…"
    }
    @objc private func restartDaemon() {
        DaemonController.restart()
        healthItem.title = "daemon: kickstart sent"
    }
    @objc private func stopDaemon() {
        DaemonController.stop()
        healthItem.title = "daemon: stopping"
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindow(cfg: cfg,
                                      onSave: { _ in DaemonController.restart() },
                                      onCheckUpdates: { [weak self] in
                self?.checkForUpdates()
            })
        }
        settings?.show()
    }

    // MARK: self-update

    /// Background (auto) or manual update check. Auto checks are gated
    /// to once per day by State.dueForCheck; manual checks always hit
    /// the network and show their result in the notes window.
    private func runUpdateCheck(auto: Bool) async {
        if checkingUpdates { return }
        if auto && !updateState.dueForCheck() { return }
        checkingUpdates = true
        defer { checkingUpdates = false }

        if !auto {
            ensureUpdateWindow().showStatus("Checking GitHub releases…", busy: true)
        }

        do {
            let (release, newer) = try await LayaUpdate.check()
            updateState.lastCheck = Date().timeIntervalSince1970
            updateState.latestTag = release.tag
            if newer {
                pendingRelease = release
                if !badgeOn {
                    badgeOn = true
                    setGlyph(currentGlyph(), dot: currentDot(), extra: currentExtra())
                }
                updateItem.title = "Update Available — \(release.tag)\u{2026}"
                if !auto {
                    updateWindow?.show(release: release)
                } else if updateState.seenTag != release.tag {
                    // first time we've seen this release: bring the
                    // notes window forward once (the badge is the
                    // persistent signal; NSUserNotification is dead for
                    // unbundled launchd binaries — no banner here).
                    updateState.seenTag = release.tag
                    updateState.save()
                    ensureUpdateWindow().show(release: release)
                }
            } else {
                // up to date: clear any stale badge from a rollback
                if badgeOn {
                    badgeOn = false
                    setGlyph(currentGlyph(), dot: currentDot(), extra: currentExtra())
                }
                updateItem.title = "Check for Updates…"
                if !auto {
                    ensureUpdateWindow().showStatus("\(LayaVersion.string) is the latest release.")
                }
            }
            updateState.save()
        } catch {
            // Only surface auto-check failures in the log; the daily
            // background probe must never nag — the badge is enough.
            if !auto {
                ensureUpdateWindow().showStatus("", detail: error.localizedDescription)
            } else {
                FileHandle.standardError.write(Data("update check: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    @objc private func checkForUpdates() {
        // If a background check already found a release, don't hit the
        // network again — go straight to the notes.
        if let rel = pendingRelease {
            ensureUpdateWindow().show(release: rel)
            return
        }
        Task { await runUpdateCheck(auto: false) }
    }

    private func ensureUpdateWindow() -> UpdateWindow {
        if updateWindow == nil {
            let w = UpdateWindow()
            w.onInstalled = { [weak self] in
                // the detached swap script needs us gone before it can
                // overwrite the binaries and relaunch us via launchd
                _ = self
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApp.terminate(nil)
                }
            }
            updateWindow = w
        }
        return updateWindow!
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/laya"))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // LSUIElement equivalent
let delegate = AppDelegate()
app.delegate = delegate
app.run()
