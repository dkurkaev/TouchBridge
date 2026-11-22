import AppKit
import ApplicationServices

/// Double-tap seeking on browser videos, like YouTube on a phone:
/// - the first tap on a video is held back for `videoDoubleTapWindow` (otherwise it would toggle pause);
/// - a second tap in the left / right 40 % of the video seeks back / forward, using the player's own
///   keyboard shortcut (YouTube: J/L = 10 s, elsewhere ←/→ — the step is the player's);
/// - every further quick tap on a side seeks once more;
/// - a second tap in the middle is an ordinary double click (YouTube: fullscreen);
/// - a single tap is delivered as a normal click once the window has passed.
/// Videos are found through Accessibility: the element under the finger (or its player container)
/// whose role description mentions "video".
final class VideoTaps {
    struct Target {
        let frame: CGRect
        let pid: pid_t
        let back: String
        let forward: String
        let host: String
    }

    var verbose = false
    private let cfg: Config
    private let synth: EventSynth
    private var pending: (p: CGPoint, time: TimeInterval, target: Target, click: () -> Void)?
    private var chain: (target: Target, until: TimeInterval)?
    private var gen = 0
    private var chromiumEnabled = Set<pid_t>()

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS",
        "org.mozilla.firefox", "app.zen-browser.zen",
    ]
    private static let webKit: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"]

    init(config: Config, synth: EventSynth) {
        cfg = config
        self.synth = synth
    }

    /// Chromium builds its web accessibility tree only when asked to; ask the running ones up front.
    func prepareBrowsers() {
        for app in NSWorkspace.shared.runningApplications { enableChromiumAX(app) }
    }

    private func debug(_ s: @autoclosure () -> String) { if verbose { tlog(s()) } }

    /// Returns true if the tap was taken care of (held back, seek, or delivered), false → caller clicks now.
    func handleTap(at p: CGPoint, time: TimeInterval, click: @escaping () -> Void) -> Bool {
        // Further taps of a seek series.
        if let c = chain, time < c.until, c.target.frame.contains(p) {
            if let key = side(p, c.target) {
                seek(key, c.target)
                chain = (c.target, time + cfg.videoSeekChainWindow)
                return true
            }
        }
        chain = nil

        // Second tap of a double tap.
        if let pd = pending, time - pd.time < cfg.videoDoubleTapWindow, pd.target.frame.contains(p) {
            gen += 1
            pending = nil
            if let key = side(p, pd.target) {
                seek(key, pd.target)
                chain = (pd.target, time + cfg.videoSeekChainWindow)
                return true
            }
            debug("видео: двойной тап в середине → обычный двойной клик")
            pd.click()          // the held-back first click; the caller now sends the second one
            return false
        }
        if let pd = pending { // a tap somewhere else: deliver the held-back one first
            gen += 1
            pending = nil
            pd.click()
        }

        // First tap: is it on a video?
        guard let target = videoTarget(at: p) else { return false }
        gen += 1
        let g = gen
        pending = (p, time, target, click)
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.videoDoubleTapWindow) { [weak self] in
            guard let self, self.gen == g, let pd = self.pending else { return }
            self.pending = nil
            pd.click()
        }
        return true
    }

    /// Something other than a tap started (drag, scroll…): deliver a held-back click right away.
    func flush() {
        guard let pd = pending else { return }
        gen += 1
        pending = nil
        pd.click()
    }

    private func side(_ p: CGPoint, _ t: Target) -> String? {
        let x = (p.x - t.frame.minX) / max(t.frame.width, 1)
        if x < 0.4 { return t.back }
        if x > 0.6 { return t.forward }
        return nil
    }

    private func seek(_ key: String, _ t: Target) {
        debug("видео (\(t.host)): двойной тап → \(key == t.back ? "назад" : "вперёд") [\(key)]")
        guard let (code, flags) = Actions.parseCombo(key) else { return }
        // Straight to the browser: works even when another app has keyboard focus.
        synth.key(code, flags: flags, pid: t.pid)
    }

    // MARK: - Finding the video

    private func enableChromiumAX(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, Self.browsers.contains(id), !Self.webKit.contains(id),
              !id.hasPrefix("org.mozilla"), !chromiumEnabled.contains(app.processIdentifier) else { return }
        chromiumEnabled.insert(app.processIdentifier)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Owner of the topmost ordinary window under the point — no Accessibility round trip needed.
    private func windowOwner(at p: CGPoint) -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list { // front to back
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p)
            else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            // Our own floating button (dictation mic) is on top: not a video tap.
            // (The hold ring sits at the screen-saver level and lets clicks through — ignore it.)
            if pid == me { if layer > 0 && layer < 1000 { return nil } else { continue } }
            guard layer == 0 else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    private static func isVideo(_ e: AXUIElement) -> Bool {
        let desc = (AX.string(e, kAXRoleDescriptionAttribute) ?? "").lowercased()
        if desc.contains("video") || desc.contains("видео") { return true }
        let role = (AX.string(e, kAXRoleAttribute) ?? "").lowercased()
        return role.contains("video")
    }

    /// Tests replace the Accessibility lookup with this.
    var targetOverride: ((CGPoint) -> Target?)?

    func videoTarget(at p: CGPoint) -> Target? {
        if let o = targetOverride { return o(p) }
        guard cfg.videoDoubleTapSeek, let app = windowOwner(at: p), let id = app.bundleIdentifier,
              Self.browsers.contains(id) else { return nil }
        enableChromiumAX(app)
        guard let hit = AX.element(at: p, timeout: 0.12), AX.pid(hit) == app.processIdentifier else { return nil }

        // The video itself, or a player container (overlay hit) that holds a video under the finger.
        var video: AXUIElement?
        var e: AXUIElement? = hit
        for _ in 0..<4 {
            guard let cur = e else { break }
            if Self.isVideo(cur) { video = cur; break }
            for c in AX.children(cur).prefix(12) {
                if Self.isVideo(c), let f = AX.frame(c), f.contains(p) { video = c; break }
            }
            if video != nil { break }
            e = AX.parent(cur)
        }
        guard let v = video, let frame = AX.frame(v), frame.width > 120, frame.height > 80 else { return nil }

        // Page address → the player's own seek keys.
        var host = ""
        e = v
        for _ in 0..<24 {
            guard let cur = e else { break }
            if AX.string(cur, kAXRoleAttribute) == "AXWebArea" {
                host = ((AX.attr(cur, "AXURL") as? URL)?.host ?? "").lowercased()
                break
            }
            e = AX.parent(cur)
        }
        let match = cfg.videoSeekKeys.keys
            .filter { $0 != "default" && (host == $0 || host.hasSuffix("." + $0)) }
            .max { $0.count < $1.count }                      // the most specific site wins
        let keys = match.flatMap { cfg.videoSeekKeys[$0] } ?? cfg.videoSeekKeys["default"] ?? "left,right"
        let parts = keys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        debug("видео под пальцем: \(host.isEmpty ? id : host), \(Int(frame.width))×\(Int(frame.height)), клавиши \(parts[0])/\(parts[1])")
        return Target(frame: frame, pid: app.processIdentifier, back: parts[0], forward: parts[1], host: host)
    }
}
