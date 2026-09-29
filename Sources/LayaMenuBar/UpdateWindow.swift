import AppKit
import WebKit
import LayaCore

// Update window — two faces, one chrome:
//
//   notes face  ("Laya vX.Y.Z is available") — release notes rendered
//               from Markdown in a WKWebView + Install / View on GitHub.
//   status face (checking / up to date / error) — a compact native
//               panel: SF-symbol state icon, one line of text, a Done
//               button. The web view is HIDDEN here — an empty
//               about:blank box in a status dialog is the classic
//               "broken updater" look and must never render.
//
// Design follows the macOS software-update idiom (System Settings /
// App Store): state icon leads, secondary text supports, one primary
// action right-aligned, Escape always dismisses.

@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private let stateIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Laya updates")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let infoLabel = NSTextField(labelWithString: "")
    private let installButton = NSButton(title: "Install update", target: nil, action: nil)
    private let openButton = NSButton(title: "View on GitHub", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    private var release: LayaUpdate.Release?
    private var installing = false
    var onInstalled: (() -> Void)?     // fired after the swap script is detached

    // MARK: faces

    /// Full notes window for an available release.
    func show(release: LayaUpdate.Release) {
        self.release = release
        buildIfNeeded()

        stateIcon.image = symbol("arrow.down.circle.fill", 26, [.white, .controlAccentColor])
        titleLabel.stringValue = "Laya \(trim(release.tag)) is available"
        subtitleLabel.stringValue = "You are running \(LayaVersion.string) · released \(prettyDate(release.publishedAt))"

        infoLabel.stringValue = release.installable
            .map { "Apple Silicon build · \(byteString($0.size)) · sha256-verified" } ?? ""
        infoLabel.textColor = .tertiaryLabelColor
        installButton.title = "Install \(trim(release.tag))"
        installButton.isHidden = false
        installButton.isEnabled = !installing
        openButton.isHidden = false
        doneButton.isHidden = true
        progress.stopAnimation(nil)
        progress.isHidden = true

        webView?.isHidden = false
        webView?.loadHTMLString(page(for: release), baseURL: URL(string: "https://github.com/"))
        resize(to: NSSize(width: 660, height: 580))
        present()
    }

    /// Compact status panel: checking / up to date / error. The notes
    /// web view stays hidden — nothing empty ever renders here.
    func showStatus(_ text: String, detail: String = "", busy: Bool = false) {
        self.release = nil
        buildIfNeeded()

        if busy {
            stateIcon.image = symbol("arrow.triangle.2.circlepath", 26, [.white, .secondaryLabelColor])
            titleLabel.stringValue = "Checking for Updates…"
            subtitleLabel.stringValue = text
            subtitleLabel.textColor = .secondaryLabelColor
            infoLabel.stringValue = ""
        } else if detail.isEmpty {
            stateIcon.image = symbol("checkmark.circle.fill", 26, [.white, .systemGreen])
            titleLabel.stringValue = "You're up to date"
            subtitleLabel.stringValue = text            // e.g. "0.3.1 is the latest release."
            subtitleLabel.textColor = .secondaryLabelColor
            infoLabel.stringValue = ""
        } else {
            stateIcon.image = symbol("exclamationmark.triangle.fill", 26, [.white, .systemOrange])
            titleLabel.stringValue = "Update check failed"
            subtitleLabel.stringValue = detail
            subtitleLabel.textColor = .secondaryLabelColor
            infoLabel.stringValue = ""
        }

        installButton.isHidden = true
        openButton.isHidden = busy || detail.isEmpty    // error offers the releases page
        doneButton.isHidden = false
        doneButton.keyEquivalent = "\u{1b}"             // Escape dismisses the status face
        webView?.isHidden = true
        webView?.loadHTMLString("", baseURL: nil)

        progress.isIndeterminate = busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !busy

        resize(to: NSSize(width: 440, height: 150))
        present()
    }

    private func resize(to size: NSSize) {
        guard let window else { return }
        let wasVisible = window.isVisible
        window.setContentSize(size)
        // Center on first show; a visible window keeps its spot when
        // the face swaps (checking → result) so it doesn't jump.
        if !wasVisible { window.center() }
    }

    private func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: chrome

    private func buildIfNeeded() {
        if window != nil { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Laya — Software Update"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        if #available(macOS 14.0, *) { wv.underPageBackgroundColor = .clear }
        webView = wv

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3

        stateIcon.imageScaling = .scaleProportionallyUpOrDown

        // header row: [state icon] [title / subtitle]
        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let head = NSStackView(views: [stateIcon, texts])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 14

        progress.style = .spinning
        progress.controlSize = .small

        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.target = self
        installButton.action = #selector(installTapped)
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openOnGitHub)
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [infoLabel, NSView(), progress, openButton, doneButton, installButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        let stack = NSStackView(views: [head, wv, footer])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        wv.setContentHuggingPriority(.defaultLow, for: .vertical)
        wv.setContentHuggingPriority(.defaultLow, for: .horizontal)

        w.contentView = NSView(frame: w.contentRect(forFrameRect: w.frame))
        w.contentView?.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 32),
            stateIcon.heightAnchor.constraint(equalToConstant: 32),
        ])
        window = w
    }

    /// Palette-tinted SF Symbol (filled circle + white glyph reads well
    /// on both light and dark window chrome).
    private func symbol(_ name: String, _ size: CGFloat,
                        _ palette: [NSColor]) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: palette)))
    }

    // MARK: actions

    @objc private func doneTapped() { window?.close() }

    @objc private func openOnGitHub() {
        NSWorkspace.shared.open(URL(string: release?.url ?? "https://github.com/\(LayaUpdate.repoSlug)/releases")!)
    }

    @objc private func installTapped() {
        guard let rel = release, !installing else { return }
        installing = true
        installButton.isEnabled = false
        openButton.isEnabled = false
        progress.isHidden = false
        progress.startAnimation(nil)
        infoLabel.stringValue = "Downloading \(rel.installable?.name ?? "payload")…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await LayaUpdate.stageDownload(of: rel)
                self.infoLabel.stringValue = "Verifying checksum and staging…"
                try LayaUpdate.detachRestart(stagedDir: staged.path, healthPort: DaemonConfig.load().port)
                self.infoLabel.stringValue = "Installed — relaunching shortly."
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                self.onInstalled?()
            } catch {
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                self.infoLabel.stringValue = "Update failed: \(error.localizedDescription)"
                self.installButton.isEnabled = true
                self.openButton.isEnabled = true
                self.installing = false
            }
        }
    }

    // Escape dismisses the status face via doneButton.keyEquivalent;
    // the notes face keeps focus on Install (Return).

    // MARK: notes page (Markdown → HTML, system-appearance aware)

    private func page(for rel: LayaUpdate.Release) -> String {
        let body = MarkdownLite.html(rel.body.isEmpty ? "_No release notes were published for this version._" : rel.body)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark;
          --ink: #1d1d1f; --mut: #6e6e73; --line: #e2e2e6; --code: #f5f5f7; --accent: #0a84ff; }
        @media (prefers-color-scheme: dark) { :root {
          --ink: #f5f5f7; --mut: #98989d; --line: #3a3a3c; --code: #1c1c1e; --accent: #64b5ff; } }
        body { margin: 0; padding: 6px 10px 14px 2px; background: transparent;
               font: 13px/1.65 -apple-system, "SF Pro Text", sans-serif; color: var(--ink);
               -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4 { line-height: 1.3; margin: 1.3em 0 .45em; font-weight: 600; }
        h1 { font-size: 19px; } h2 { font-size: 15px; }
        h3 { font-size: 13.5px; } h4 { font-size: 12.5px; color: var(--mut); }
        h2:first-of-type { margin-top: .2em; }
        p { margin: .6em 0; }
        strong { font-weight: 600; }
        a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
        code { background: var(--code); border: 1px solid var(--line); border-radius: 5px;
               padding: .1em .35em; font: 11.5px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
        pre { background: var(--code); border: 1px solid var(--line); border-radius: 8px;
              padding: 10px 12px; overflow-x: auto; }
        pre code { background: none; border: none; padding: 0; }
        ul, ol { margin: .55em 0; padding-left: 1.5em; }
        li { margin: .22em 0; } li::marker { color: var(--mut); }
        blockquote { margin: .7em 0; padding: .3em 1em; border-left: 3px solid var(--line);
                     color: var(--mut); }
        hr { border: none; border-top: 1px solid var(--line); margin: 1.3em 0; }
        em { color: var(--mut); font-style: normal; }
        </style></head><body>\(body)</body></html>
        """
    }

    // MARK: small formatting helpers

    private func trim(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func byteString(_ n: Int64) -> String {
        let mb = Double(n) / 1_048_576.0
        return mb >= 1 ? String(format: "%.0f MB", mb) : String(format: "%.0f KB", Double(n) / 1024)
    }

    private func prettyDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter(); out.dateStyle = .medium
        return out.string(from: d)
    }
}

// MARK: - navigation policy

// The macOS 27 SDK imports decidePolicyForNavigationAction with
// WK_SWIFT_ASYNC(3) — the decisionHandler block arrives in Swift as an
// async requirement returning WKNavigationActionPolicy. The legacy
// completion-handler shape only "nearly matches" (it is not a witness:
// links would silently stop opening), so the async form is the real
// conformance. Links go to the default browser, never navigate the
// notes webview.
extension UpdateWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }
}
