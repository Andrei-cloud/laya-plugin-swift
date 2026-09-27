import AppKit
import Foundation

// LayaMenuBar — native menu bar companion for the layad daemon.
//
//  • status item: brain glyph + status dot (green warm / amber loading /
//    gray down) + mean-latency readout while warm
//  • polls GET /health every 3 s (calls, mean latency, chains, warm)
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
// text field and is never echoed.

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
    var line = "layad: DOWN (no answer on 127.0.0.1:\(cfg.port))"
    var ok = false
    let task = URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        ok = true
        let warm = (obj["warm"] as? Bool) ?? false
        let calls = (obj["calls"] as? NSNumber)?.int64Value ?? 0
        let mean = (obj["mean_latency_ms"] as? NSNumber)?.doubleValue ?? 0
        let chains = (obj["chains"] as? [String]) ?? []
        line = "layad: \(warm ? "WARM" : "loading") · \(calls) calls · "
            + String(format: "%.1f ms mean", mean) + " · \(chains.count) chains"
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 5)
    print(line)
    exit(ok ? 0 : 1)
}

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

// MARK: - menu bar agent

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

    private let assetsField = NSTextField(string: "")
    private let sourceField = NSTextField(string: "")
    private let unitPopup = NSPopUpButton()
    private let portField = NSTextField(string: "")
    private let grpcField = NSTextField(string: "")
    private let tokenField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(cfg: DaemonConfig, onSave: @escaping (DaemonConfig) -> Void) {
        self.cfg = cfg
        self.onSave = onSave
        super.init()
    }

    func show() {
        if window == nil { build() }
        statusLabel.stringValue = ""
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "layad settings"
        w.isReleasedWhenClosed = false
        w.delegate = self

        assetsField.stringValue = cfg.assets
        sourceField.stringValue = cfg.source
        portField.stringValue = String(cfg.port)
        grpcField.stringValue = String(cfg.grpcPort)
        tokenField.placeholderString = "loopback Bearer token (blank = none)"
        tokenField.stringValue = cfg.token
        unitPopup.addItems(withTitles: ["gpu", "ne", "cpu"])
        unitPopup.selectItem(withTitle: cfg.unit)

        let grid = NSGridView(views: [
            [label("assets"), assetsField],
            [label("source"), sourceField],
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
        let stack = NSStackView(views: [grid, statusLabel, save])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

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
        next.source = sourceField.stringValue.trimmingCharacters(in: .whitespaces)
        next.unit = unitPopup.titleOfSelectedItem ?? "gpu"
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
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func setGlyph(_ name: String, dot: NSColor, extra: String) {
        guard let button = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "layad")
        img?.isTemplate = true
        button.image = img
        let dotStr = NSAttributedString(string: "●" + (extra.isEmpty ? "" : " " + extra), attributes: [
            .foregroundColor: dot,
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ])
        button.imagePosition = .imageLeading
        button.attributedTitle = dotStr
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
            settings = SettingsWindow(cfg: cfg) { _ in
                DaemonController.restart()
            }
        }
        settings?.show()
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
