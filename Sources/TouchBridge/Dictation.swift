import AppKit
import ApplicationServices
import Carbon
import CoreAudio

/// Native macOS dictation, started in whatever app has the text cursor.
///
/// macOS has no public call to start dictation in another app, but AppKit puts "Start Dictation"
/// into the Edit menu of practically every app (Safari, Chrome, Telegram, VS Code, Notion, Claude…)
/// with the identifier `startDictation:`. Pressing that item through Accessibility is exactly the
/// same as choosing Edit → Start Dictation by hand — the dictation itself is the system's.
/// Pressing it again while dictation listens only pauses/resumes it, so stopping uses Escape,
/// the documented way to end dictation.
enum Dictation {
    /// Presses Start Dictation in the frontmost app's menu (start, or resume a paused dictation).
    @discardableResult
    static func start() -> Bool {
        guard let (app, item, title) = findItem() else { return false }
        AXUIElementSetMessagingTimeout(item, 0.5)
        let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
        tlog("Диктовка: «\(title)» в «\(app.localizedName ?? "?")» → \(r == .success ? "ок" : "ошибка \(r.rawValue)")")
        return r == .success || r == .cannotComplete
    }

    /// Ends dictation: Escape, as macOS documents it ("press the shortcut or Escape").
    static func stop() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
        tlog("Диктовка: стоп (Escape)")
    }

    /// DictationIM can get stuck after a language change: "start listening" arrives, the start sound
    /// plays, but its recognizer never comes up. It is an ordinary per-user input method process that
    /// macOS relaunches on the next dictation request, so restarting it is safe.
    static func restartService() {
        func pids() -> [pid_t] {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            ps.arguments = ["-x", "DictationIM"]
            let out = Pipe()
            ps.standardOutput = out
            guard (try? ps.run()) != nil else { return [] }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            ps.waitUntilExit()
            return text.split(separator: "\n").compactMap { pid_t($0) }
        }
        let before = pids()
        for pid in before { kill(pid, SIGKILL) } // it ignores SIGTERM
        usleep(300_000)
        let alive = Set(pids()).intersection(before)
        tlog(before.isEmpty ? "Диктовка: службы DictationIM нет — запустится сама"
             : alive.isEmpty ? "Диктовка: служба DictationIM перезапущена" : "⚠️  Диктовка: не удалось перезапустить DictationIM")
    }


    /// The Start Dictation menu item of the frontmost app (nothing is pressed).
    static func findItem() -> (NSRunningApplication, AXUIElement, String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            tlog("Диктовка: нет активного приложения с полем ввода")
            return nil
        }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        guard let barRef = AX.attr(el, kAXMenuBarAttribute) else {
            tlog("Диктовка: у «\(app.localizedName ?? "?")» нет строки меню")
            return nil
        }
        var tops = AX.children(barRef as! AXUIElement)
        if tops.count > 3 { tops.insert(tops.remove(at: 3), at: 0) } //  Apple, App, File, Edit — Edit first
        for top in tops {
            for menu in AX.children(top) {
                for item in AX.children(menu) {
                    let id = AX.string(item, "AXIdentifier") ?? ""
                    let title = AX.string(item, kAXTitleAttribute) ?? ""
                    let t = title.lowercased()
                    guard id == "startDictation:" || t.contains("dictation") || t.contains("диктовк") else { continue }
                    return (app, item, title)
                }
            }
        }
        tlog("Диктовка: в меню «\(app.localizedName ?? "?")» нет пункта «Start Dictation»")
        return nil
    }

    private static let prefsDomain = "com.apple.speech.recognition.AppleSpeechRecognition.prefs" as CFString
    private static let languagesKey = "DictationIMPreferredLanguageIdentifiers" as CFString

    /// Dictation languages chosen in System Settings → Keyboard → Dictation (e.g. ["en_US", "ru_RU"]).
    /// Dictation starts in the first one.
    static var languages: [String] {
        CFPreferencesAppSynchronize(prefsDomain)
        return (CFPreferencesCopyAppValue(languagesKey, prefsDomain) as? [String]) ?? []
    }

    /// The language dictation will start in: the keyboard layout's one, if it is a dictation language.
    static var current: String? {
        let l = languages
        if let code = KeyboardLayouts.currentLanguage, let match = l.first(where: { $0.hasPrefix(code) }) { return match }
        return l.first
    }

    /// Makes `lang` the language dictation starts in.
    /// macOS ties the dictation language to the keyboard layout: DictationIM follows layout changes
    /// and puts the layout's language first in its list (it even undoes a reordering that disagrees
    /// with the layout). So: switch to a layout of that language, then also reorder the list and
    /// notify DictationIM, as System Settings does.
    static func makeCurrent(_ lang: String) {
        if !KeyboardLayouts.select(language: lang) {
            tlog("⚠️  Нет раскладки клавиатуры для \(lang) — macOS выбирает язык диктовки по раскладке")
        }
        var list = languages
        guard let i = list.firstIndex(of: lang), i != 0 else { return }
        list.remove(at: i)
        list.insert(lang, at: 0)
        CFPreferencesSetAppValue(languagesKey, list as CFArray, prefsDomain)
        CFPreferencesAppSynchronize(prefsDomain)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("DictationIMNotificationLanguageChanged"), object: nil, userInfo: nil, deliverImmediately: true)
        tlog("Язык диктовки → \(lang) (порядок: \(list.joined(separator: ", ")))")
    }

    /// The next enabled language after the current one.
    static func next() -> String? {
        let l = languages
        guard l.count > 1 else { return nil }
        return l[1]
    }

    /// "ru_RU" → "Русский", "en_US" → "English" (in the language itself).
    static func displayName(_ lang: String) -> String {
        let code = String(lang.prefix(2))
        let name = Locale(identifier: lang).localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "en-US" / "ru_RU" → "EN" / "RU"
    static func badge(_ lang: String) -> String { String(lang.prefix(2)).uppercased() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum AudioInput {
    /// Name of the default input device — the one dictation uses with "Microphone source: Automatic".
    static var defaultInputName: String {
        var dev = AudioObjectID(0)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return "?" }
        var name: Unmanaged<CFString>?
        a.mSelector = kAudioObjectPropertyName
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
        return n.takeRetainedValue() as String
    }
}

/// Keyboard layouts (Text Input Sources): macOS picks the dictation language by the layout.
enum KeyboardLayouts {
    private static func primaryLanguage(_ s: TISInputSource) -> String? {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceLanguages) else { return nil }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String])?.first
    }

    /// "ru", "en"… of the current layout.
    static var currentLanguage: String? {
        primaryLanguage(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    /// Selects an enabled layout whose main language matches ("en_US" → ABC, "ru_RU" → Russian).
    @discardableResult
    static func select(language lang: String) -> Bool {
        let code = String(lang.prefix(2))
        if currentLanguage == code { return true }
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        guard let src = list.first(where: { primaryLanguage($0) == code }) else { return false }
        let r = TISSelectInputSource(src)
        tlog("Раскладка → \(code) (\(r == noErr ? "ок" : "ошибка \(r)"))")
        return r == noErr
    }
}

/// Follows the system dictation through its own log, live (`log stream`, no admin rights needed):
/// listening / paused / stopped, the language it actually recognizes, and every partial result —
/// the proof that it hears speech. (CoreAudio can't tell: with AirPods the voice comes over
/// Siri's Bluetooth route, not through an audio device; opening the AirPods mic ourselves would
/// switch them to call mode and disturb the dictation.)
final class DictationMonitor {
    struct State: Equatable {
        var listening = false
        var paused = false
        var language: String?
    }

    var onChange: ((State) -> Void)?
    var onSpeech: (() -> Void)?
    private(set) var state = State()
    private(set) var available = false
    /// When DictationIM last accepted a start request (it may still fail to come up after that).
    private(set) var lastStartAck: Date?
    private var process: Process?
    private var buffer = Data()
    private var stopped = true

    private static let predicate = """
        (process == "DictationIM" AND (eventMessage CONTAINS "listenig state" OR eventMessage CONTAINS "Keyboard Dictation] " \
        OR eventMessage CONTAINS "did recognize text" OR eventMessage CONTAINS "start listening by user action")) OR (process == "corespeechd" AND \
        (eventMessage CONTAINS "Preheated for language" OR eventMessage CONTAINS "didReceivePartialResult"))
        """

    /// `log stream` helpers left behind by a TouchBridge that was killed (they are re-parented to launchd).
    private static func killOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1] == "1", let pid = pid_t(parts[0]),
                  parts[2].hasPrefix("/usr/bin/log stream --style ndjson --predicate (process == \"DictationIM\"") else { continue }
            kill(pid, SIGTERM)
        }
    }

    func start() {
        stopped = false
        guard process == nil else { return }
        resetState() // nothing is known until DictationIM says otherwise
        Self.killOrphans()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.available = false
                if !self.stopped { // log stream died — try again shortly
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !self.stopped { self.start() } }
                }
            }
        }
        do {
            try p.run()
            process = p
            available = true
        } catch {
            available = false
            tlog("⚠️  Не могу следить за диктовкой (log stream): \(error.localizedDescription)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
        available = false
        resetState()
    }

    /// While we don't follow the log, the last state we saw goes stale — forget it
    /// (otherwise a re-shown button looked "recording" and a tap sent Escape instead of starting).
    private func resetState() {
        if state != State() {
            state = State()
            onChange?(state)
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard line.first == UInt8(ascii: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let msg = obj["eventMessage"] as? String else { continue }
            handle(msg)
        }
    }

    private func handle(_ msg: String) {
        var s = state
        if msg.contains("start listening by user action") {
            lastStartAck = Date()
        } else if msg.contains("listenig state = 1") {
            s.listening = true
            s.paused = false
        } else if msg.contains("listenig state = 0") {
            s.listening = false
            s.paused = false
        } else if msg.hasPrefix("[Keyboard Dictation] Pause Dictation") {
            s.paused = true
        } else if msg.hasPrefix("[Keyboard Dictation] Resume Dictation") {
            s.paused = false
        } else if let r = msg.range(of: "Preheated for language ") {
            s.language = msg[r.upperBound...].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        } else if msg.contains("didReceivePartialResult") || msg.contains("did recognize text") {
            if let lang = msg.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
               lang.count == 5, lang.contains("-") { s.language = lang }
            onSpeech?()
        }
        if s != state {
            state = s
            onChange?(s)
        }
    }
}

/// Never becomes key or main: tapping it leaves the text cursor where it was.
private final class MicPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Parts of the dictation button (and its language list) a touch or click can hit.
enum MicPart: Equatable { case main, language, close, option(String), settings }

private let micBackground = NSColor(white: 0.12, alpha: 0.88)

private final class MicView: NSView {
    static let circle: CGFloat = 76
    static let row: CGFloat = 30
    static let gap: CGFloat = 6
    static let size = NSSize(width: 190, height: circle + gap + row)

    enum Mode { case idle, listening, paused }
    var mode = Mode.idle { didSet { if mode != oldValue { needsDisplay = true } } }
    var language = "" { didSet { if language != oldValue { needsDisplay = true } } }
    var pickerOpen = false { didSet { if pickerOpen != oldValue { needsDisplay = true } } }
    /// 0…1 bar heights, set by the animation.
    var bars = [CGFloat](repeating: 0, count: 5) { didSet { needsDisplay = true } }
    var onPart: ((MicPart) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var downAt: NSPoint?
    private var downPart: MicPart?
    private var startOrigin = NSPoint.zero
    private var dragging = false

    private let font = NSFont.systemFont(ofSize: 15, weight: .semibold)

    var circleRect: NSRect {
        NSRect(x: (bounds.width - Self.circle) / 2, y: bounds.height - Self.circle, width: Self.circle, height: Self.circle)
    }

    /// Under the microphone: the current-language pill ("RU ▾") and, to its right, a close button.
    private var rowLayout: (label: NSRect, close: NSRect) {
        let text = NSAttributedString(string: language.isEmpty ? "?" : language, attributes: [.font: font])
        let labelW = ceil(text.size().width) + 20 + 16
        let spacing: CGFloat = 8
        let x0 = (bounds.width - labelW - spacing - Self.row) / 2
        let label = NSRect(x: x0, y: 0, width: labelW, height: Self.row)
        return (label, NSRect(x: label.maxX + spacing, y: 0, width: Self.row, height: Self.row))
    }
    var labelRect: NSRect { rowLayout.label }
    var closeRect: NSRect { rowLayout.close }

    func part(at p: NSPoint) -> MicPart? {
        let c = circleRect
        if hypot(p.x - c.midX, p.y - c.midY) <= c.width / 2 { return .main }
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { return .close }
        if labelRect.insetBy(dx: -4, dy: -4).contains(p) { return .language }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let c = circleRect
        let circle = NSBezierPath(ovalIn: c.insetBy(dx: 3, dy: 3))
        let fill: NSColor
        switch mode {
        case .idle: fill = micBackground
        case .listening: fill = .systemRed
        case .paused: fill = .systemOrange
        }
        fill.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        circle.lineWidth = 2
        circle.stroke()

        if mode == .listening {
            let w: CGFloat = 6, gap: CGFloat = 5
            let total = 5 * w + 4 * gap
            NSColor.white.setFill()
            for (i, l) in bars.enumerated() {
                let h = max(6, min(42, 6 + l * 36))
                let x = c.midX - total / 2 + CGFloat(i) * (w + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: c.midY - h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
            }
        } else {
            let conf = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            let name = mode == .paused ? "pause.fill" : "mic.fill"
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Диктовка")?.withSymbolConfiguration(conf) {
                let s = img.size
                img.draw(in: NSRect(x: c.midX - s.width / 2, y: c.midY - s.height / 2, width: s.width, height: s.height))
            }
        }

        // Current language with a chevron: tap → custom list of dictation languages.
        let r = labelRect
        (pickerOpen ? NSColor.controlAccentColor.withAlphaComponent(0.85) : micBackground).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let text = NSAttributedString(string: language.isEmpty ? "?" : language,
                                      attributes: [.font: font, .foregroundColor: NSColor.white])
        let ts = text.size()
        text.draw(at: NSPoint(x: r.minX + 10, y: r.midY - ts.height / 2))
        let conf = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: pickerOpen ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(conf) {
            let s = img.size
            img.draw(in: NSRect(x: r.maxX - 10 - s.width, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
        // Close: hides the dictation button (it can be shown again from the TouchBridge menu).
        let x = closeRect
        micBackground.setFill()
        NSBezierPath(ovalIn: x).fill()
        let xconf = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Убрать кнопку диктовки")?.withSymbolConfiguration(xconf) {
            let s = img.size
            img.draw(in: NSRect(x: x.midX - s.width / 2, y: x.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    // Mouse / trackpad. (Touches are handled by MicTouches without any mouse event.)
    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        downPart = part(at: convert(event.locationInWindow, from: nil))
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, let w = window else { return }
        let p = NSEvent.mouseLocation
        if !dragging && hypot(p.x - d.x, p.y - d.y) > 5 { dragging = true }
        if dragging { w.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - d.x, y: startOrigin.y + p.y - d.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onMoved?(window?.frame.origin ?? .zero) }
        else if let p = downPart { onPart?(p) }
        downAt = nil
        downPart = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

/// Our own list of dictation languages (not a macOS menu), shown next to the button.
private final class PickerView: NSView {
    static let rowH: CGFloat = 38
    static let pad: CGFloat = 6
    var items: [(lang: String, name: String)] = [] { didSet { needsDisplay = true } }
    var current: String?
    var onPart: ((MicPart) -> Void)?
    private var downPart: MicPart?

    static func height(for n: Int) -> CGFloat { CGFloat(n + 1) * rowH + 2 * pad + 1 }

    /// Rows from the top: the languages, then "Настроить языки…".
    func part(at p: NSPoint) -> MicPart? {
        guard bounds.contains(p) else { return nil }
        let fromTop = bounds.maxY - Self.pad - p.y
        let i = Int(floor(fromTop / Self.rowH))
        if i >= 0 && i < items.count { return .option(items[i].lang) }
        if i >= items.count { return .settings }
        return nil
    }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: Self.pad, y: bounds.maxY - Self.pad - CGFloat(i + 1) * Self.rowH, width: bounds.width - 2 * Self.pad, height: Self.rowH)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        micBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        for (i, item) in items.enumerated() {
            let r = rowRect(i)
            let isCurrent = item.lang == current
            if isCurrent {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 2), xRadius: 9, yRadius: 9).fill()
            }
            let text = NSAttributedString(string: item.name, attributes: [.font: font, .foregroundColor: NSColor.white])
            text.draw(at: NSPoint(x: r.minX + 12, y: r.midY - text.size().height / 2))
            if isCurrent {
                let conf = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(conf) {
                    let s = img.size
                    img.draw(in: NSRect(x: r.maxX - 12 - s.width, y: r.midY - s.height / 2, width: s.width, height: s.height))
                }
            }
        }
        // separator + settings row
        let sr = rowRect(items.count)
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSRect(x: sr.minX + 8, y: sr.maxY, width: sr.width - 16, height: 1).fill()
        let s = NSAttributedString(string: "Настроить языки…", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
        s.draw(at: NSPoint(x: sr.minX + 12, y: sr.midY - s.size().height / 2))
    }

    override func mouseDown(with event: NSEvent) { downPart = part(at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        if let p = downPart, p == part(at: convert(event.locationInWindow, from: nil)) { onPart?(p) }
        downPart = nil
    }
}

private final class LanguagePicker {
    private var panel: MicPanel?
    private var view: PickerView?
    private var closeTimer: Timer?
    private var outsideMonitor: Any?
    var onPart: ((MicPart) -> Void)?
    var onClose: (() -> Void)?

    var isShown: Bool { panel?.isVisible == true }

    /// `anchor` — the button panel's frame (AppKit screen coordinates).
    func show(languages: [String], current: String?, anchor: NSRect) {
        let items = languages.map { ($0, Self.name($0, among: languages)) }
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let widest = items.map { NSAttributedString(string: $0.1, attributes: [.font: font]).size().width }.max() ?? 80
        let w = max(190, ceil(widest) + 64)
        let h = PickerView.height(for: items.count)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? anchor
        var frame = NSRect(x: anchor.midX - w / 2, y: anchor.maxY + 6, width: w, height: h)  // above the button…
        if frame.maxY > screen.maxY { frame.origin.y = anchor.minY - h - 6 }                   // …or below it
        frame.origin.x = min(max(frame.minX, screen.minX + 4), screen.maxX - w - 4)

        let p = panel ?? {
            let p = MicPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = PickerView(frame: NSRect(origin: .zero, size: frame.size))
            v.autoresizingMask = [.width, .height]
            v.onPart = { [weak self] part in self?.onPart?(part) }
            p.contentView = v
            panel = p
            view = v
            return p
        }()
        view?.current = current
        view?.items = items.map { (lang: $0.0, name: $0.1) }
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()

        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.hide() }
        if outsideMonitor == nil { // a mouse click anywhere else closes it
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
    }

    func hide() {
        guard isShown else { return }
        panel?.orderOut(nil)
        closeTimer?.invalidate()
        closeTimer = nil
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil
        onClose?()
    }

    /// Global CoreGraphics point → part of the list, if it is open and the point is on it.
    func part(at p: CGPoint) -> MicPart? {
        guard let w = panel, w.isVisible, let v = view else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return v.part(at: NSPoint(x: p.x - w.frame.minX, y: (primaryTop - p.y) - w.frame.minY))
    }

    /// "Русский", "English (US)" when two English variants are on.
    static func name(_ lang: String, among all: [String]) -> String {
        let base = Dictation.displayName(lang)
        let code = lang.prefix(2)
        guard all.filter({ $0.prefix(2) == code }).count > 1, let region = lang.split(separator: "_").last else { return base }
        return "\(base) (\(region))"
    }
}

/// What MicTouches drives (the real button, or a fake in tests).
protocol MicTarget: AnyObject {
    /// Which part of the button or its language list is at this point (global CoreGraphics coordinates).
    func part(at p: CGPoint) -> MicPart?
    func activate(_ part: MicPart)
    /// A touch somewhere else (closes the language list).
    func touchedElsewhere()
    func beginDrag()
    func drag(dx: CGFloat, dy: CGFloat)
    func endDrag()
    func showMenu(event: NSEvent?)
}

/// Floating microphone button: tap = start / stop dictation in the app with the text cursor,
/// drag = move it (the place is remembered), hold or right-click = menu.
/// Under it: the language dictation will use; tap it for our own list of the enabled languages.
/// Red with moving bars while dictation listens — the bars jump whenever the recognizer hears
/// speech; orange with ⏸ while paused. Like native dictation it stops by itself a few seconds
/// after you stop talking.
final class DictationButton: MicTarget {
    var onHideRequested: (() -> Void)?
    private var panel: MicPanel?
    private var view: MicView?
    private let picker = LanguagePicker()
    private let monitor = DictationMonitor()
    private var anim: Timer?
    private var prefsPoll: Timer?
    private var energy: CGFloat = 0
    private var phase: CGFloat = 0
    private let originKey = "dictationButtonOrigin"
    private var listenStart: Date?
    private var lastSpeech: Date?
    private var autoStopSent = false
    private var wasListening = false
    private var lastStopSent = Date.distantPast
    private var pendingLanguage: String?
    private var startGeneration = 0
    private var lastServiceRestart = Date.distantPast
    private var menuOpen = false

    /// Seconds of silence after the last recognized words before stopping (UserDefaults override).
    private var silenceStop: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "dictationSilenceStop")
        return v > 0 ? v : 3.0
    }
    /// Stop if nothing at all was recognized for this long after starting.
    private var noSpeechStop: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "dictationNoSpeechStop")
        return v > 0 ? v : 8.0
    }

    var isShown: Bool { panel?.isVisible == true }

    init() {
        monitor.onChange = { [weak self] s in self?.stateChanged(s) }
        monitor.onSpeech = { [weak self] in
            self?.energy = 1
            self?.lastSpeech = Date()
        }
        picker.onPart = { [weak self] part in self?.activate(part) }
        picker.onClose = { [weak self] in self?.view?.pickerOpen = false }
    }

    func show() {
        let p = panel ?? makePanel()
        p.orderFrontRegardless()
        monitor.start()
        refreshLanguage()
        if prefsPoll == nil { // the language can also be changed in System Settings
            let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshLanguage() }
            RunLoop.main.add(t, forMode: .common)
            prefsPoll = t
        }
    }

    func hide() {
        picker.hide()
        panel?.orderOut(nil)
        monitor.stop()
        anim?.invalidate()
        anim = nil
        prefsPoll?.invalidate()
        prefsPoll = nil
    }

    private func makePanel() -> MicPanel {
        let p = MicPanel(contentRect: NSRect(origin: savedOrigin(), size: MicView.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = MicView(frame: NSRect(origin: .zero, size: MicView.size))
        v.onPart = { [weak self] part in self?.activate(part) }
        v.onMoved = { [weak self] o in self?.save(o) }
        v.onMenu = { [weak self] e in self?.showMenu(event: e) }
        p.contentView = v
        panel = p
        view = v
        return p
    }

    private func save(_ o: NSPoint) { UserDefaults.standard.set(NSStringFromPoint(o), forKey: originKey) }

    private func savedOrigin() -> NSPoint {
        let f = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let s = UserDefaults.standard.string(forKey: originKey) {
            var o = NSPointFromString(s)
            if let scr = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -20, dy: -20).contains(o) }) {
                o.x = min(o.x, scr.visibleFrame.maxX - MicView.size.width) // keep the (bigger) button on screen
                o.y = max(o.y, scr.visibleFrame.minY)
                return o
            }
        }
        return NSPoint(x: f.maxX - MicView.size.width - 10, y: f.minY + 110)
    }

    private func refreshLanguage() {
        view?.language = Dictation.current.map(Dictation.badge) ?? "?"   // "RU", "EN"
    }

    private func stateChanged(_ s: DictationMonitor.State) {
        // DictationIM "pauses" by itself in the silence between phrases: for the button that is
        // still one dictation — red, counting the silence towards the auto stop.
        view?.mode = s.listening ? .listening : .idle
        if s.listening {
            if listenStart == nil { listenStart = Date(); lastSpeech = nil; autoStopSent = false }
            startAnimation()
        } else {
            stopAnimation()
            listenStart = nil
            lastSpeech = nil
        }
        if s.listening != wasListening {
            wasListening = s.listening
            tlog(s.listening ? "Диктовка слушает (\(Dictation.current ?? "?"))" : "Диктовка остановлена")
            if s.listening { startGeneration += 1 } // the start watchdog is satisfied
            if !s.listening, pendingLanguage != nil {
                // let DictationIM settle after stopping before it has to switch recognizers
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.applyPendingLanguage() }
            }
        }
    }

    /// Gentle idle motion while listening; a burst every time the recognizer hears speech.
    /// Also runs the native-like auto stop.
    private func startAnimation() {
        guard anim == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        anim = t
    }

    private func tick() {
        guard let v = view else { return }
        phase += 0.35
        energy *= 0.93
        let base: CGFloat = 0.12
        v.bars = (0..<5).map { i in
            let wobble = (sin(phase + CGFloat(i) * 1.3) + 1) / 2
            let shape: CGFloat = [0.55, 0.8, 1.0, 0.8, 0.55][i]
            return min(1, base * wobble + energy * shape * (0.7 + 0.3 * wobble))
        }
        // Native-like end: a few seconds after the last recognized words (or if nothing is heard at all).
        guard !autoStopSent, let start = listenStart else { return }
        let now = Date()
        let silent = lastSpeech.map { now.timeIntervalSince($0) > silenceStop } ?? (now.timeIntervalSince(start) > noSpeechStop)
        if silent {
            autoStopSent = true
            tlog(lastSpeech == nil ? "Диктовка: ничего не распознано за \(Int(noSpeechStop)) с — останавливаю"
                                   : "Диктовка: тишина \(silenceStop) с после речи — останавливаю")
            stopOnce()
        }
    }

    private func stopAnimation() {
        anim?.invalidate()
        anim = nil
        energy = 0
    }

    // MARK: Actions (mouse and touch)

    func part(at p: CGPoint) -> MicPart? {
        if menuOpen { return nil } // our menu is up: let the touch click it
        if let o = picker.part(at: p) { return o }
        guard let w = panel, w.isVisible, let v = view else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return v.part(at: NSPoint(x: p.x - w.frame.minX, y: (primaryTop - p.y) - w.frame.minY)) // CG → view
    }

    func activate(_ part: MicPart) {
        switch part {
        case .main:
            picker.hide()
            tap()
        case .language:
            if picker.isShown { picker.hide() } else if let f = panel?.frame {
                picker.show(languages: Dictation.languages, current: Dictation.current, anchor: f)
                view?.pickerOpen = true
            }
        case .option(let lang):
            picker.hide()
            choose(lang)
        case .settings:
            picker.hide()
            Dictation.openSettings()
        case .close:
            picker.hide()
            onHideRequested?()
        }
    }

    func touchedElsewhere() { picker.hide() }

    private func tap() {
        if monitor.available && monitor.state.listening { // listening or paused between phrases → stop
            autoStopSent = true
            stopOnce()
        } else {
            startWithWatchdog()
        }
    }

    /// One Escape per stop: a second one would reach the app itself.
    private func stopOnce() {
        guard Date().timeIntervalSince(lastStopSent) > 1 else { return }
        lastStopSent = Date()
        Dictation.stop()
    }

    /// Start, and make sure dictation really starts listening. If DictationIM accepted the request
    /// but its recognizer doesn't come up within 3 s (it can hang after a language change or a
    /// dropped connection), restart DictationIM and press once more. No repeated presses otherwise:
    /// pressing again while it is starting only confuses it.
    private func startWithWatchdog(attempt: Int = 1) {
        startGeneration += 1
        let gen = startGeneration
        let ackBefore = monitor.lastStartAck
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pressed = Dictation.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let self, pressed, gen == self.startGeneration, !self.monitor.state.listening, self.monitor.available else { return }
                let acked = self.monitor.lastStartAck.map { a in ackBefore.map { a > $0 } ?? true } ?? false
                if attempt == 1 && acked && Date().timeIntervalSince(self.lastServiceRestart) > 20 {
                    tlog("Диктовка приняла запуск, но не начала слушать за 3 с — перезапускаю службу диктовки macOS")
                    self.lastServiceRestart = Date()
                    Dictation.restartService()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.startWithWatchdog(attempt: 2) }
                } else {
                    tlog(acked ? "⚠️  Диктовка не запускается (служба macOS не поднимает распознавание — проверьте интернет/микрофон)"
                               : "⚠️  Диктовка не запустилась: похоже, нет активного поля ввода — коснитесь поля и попробуйте снова")
                }
            }
        }
    }

    /// Makes `lang` the dictation language. A running dictation is stopped first, and the switch
    /// happens only once it has really stopped — switching recognizers mid-stop used to hang DictationIM.
    /// The next tap starts in the new language.
    private func choose(_ lang: String) {
        guard lang != Dictation.current else { return }
        if monitor.state.listening {
            pendingLanguage = lang
            autoStopSent = true
            stopOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.applyPendingLanguage() } // fallback
        } else {
            pendingLanguage = lang
            applyPendingLanguage()
        }
    }

    private func applyPendingLanguage() {
        guard let lang = pendingLanguage else { return }
        pendingLanguage = nil
        Dictation.makeCurrent(lang)
        refreshLanguage()
    }

    func beginDrag() { picker.hide() }

    /// Delta in CoreGraphics points (y down).
    func drag(dx: CGFloat, dy: CGFloat) {
        guard let p = panel else { return }
        p.setFrameOrigin(NSPoint(x: p.frame.minX + dx, y: p.frame.minY - dy))
    }

    func endDrag() { if let o = panel?.frame.origin { save(o) } }

    func showMenu(event: NSEvent?) {
        guard let v = view else { return }
        picker.hide()
        let m = NSMenu()
        let settings = NSMenuItem(title: "Языки диктовки и микрофон…", action: #selector(MenuTarget.fire), keyEquivalent: "")
        let settingsTarget = MenuTarget { Dictation.openSettings() }
        settings.target = settingsTarget
        settings.representedObject = settingsTarget
        m.addItem(settings)
        m.addItem(.separator())
        let hide = NSMenuItem(title: "Убрать кнопку диктовки", action: #selector(MenuTarget.fire), keyEquivalent: "")
        let hideTarget = MenuTarget { [weak self] in self?.onHideRequested?() }
        hide.target = hideTarget
        hide.representedObject = hideTarget // keeps the target alive while the menu is open
        m.addItem(hide)
        menuOpen = true
        defer { menuOpen = false }
        if let e = event {
            NSMenu.popUpContextMenu(m, with: e, for: v)
        } else {
            m.popUp(positioning: nil, at: NSPoint(x: v.circleRect.midX, y: v.circleRect.minY), in: v)
        }
    }
}

/// Fingers on the dictation button never become mouse events: a click would make macOS pause
/// the dictation "for user interaction". One finger — microphone: tap = start/stop, hold ≥ 0.6 s
/// = menu; language: tap = our list of languages; drag = move the button.
/// A finger on the button is held back for `decideAfter`: if a second finger lands meanwhile it's
/// a two-finger gesture, and both go to the gesture engine — a two-finger tap there right-clicks
/// the button (see `preferredPoint`), opening its menu. Fingers landing while another finger is
/// already down are never taken. Actions run after the touch frame is processed: a menu runs its
/// own event loop, and opening it inside the touch callback scrambled the following touches.
final class MicTouches {
    weak var button: MicTarget?
    var decideAfter: TimeInterval = 0.12
    private struct Gesture {
        var part: MicPart
        var start: CGPoint
        var last: CGPoint
        var t0: TimeInterval
        var id: Int
        var decided = false
        var dragging = false
        var extras = Set<Int>()
        var hadExtras = false
    }
    private var g: Gesture?
    private var known = Set<Int>()

    func route(_ pts: [Int: CGPoint], time: TimeInterval) -> [Int: CGPoint] {
        // Lifts.
        for id in known where pts[id] == nil {
            known.remove(id)
            guard var cur = g else { continue }
            if cur.id == id {
                g = nil
                finish(cur, time)
            } else if cur.extras.remove(id) != nil {
                g = cur
            }
        }
        // New fingers.
        for (id, p) in pts.sorted(by: { $0.key < $1.key }) where known.insert(id).inserted {
            if var cur = g {
                if !cur.decided {
                    g = nil // second finger while undecided: a two-finger gesture → all to the gesture engine
                } else if !cur.dragging && hypot(p.x - cur.start.x, p.y - cur.start.y) < 250 {
                    cur.extras.insert(id) // press on the button + tap with another finger → menu
                    cur.hadExtras = true
                    g = cur
                }
                continue
            }
            if pts.count == 1, let part = button?.part(at: p) {
                g = Gesture(part: part, start: p, last: p, t0: time, id: id)
            } else if button?.part(at: p) == nil {
                let b = button
                DispatchQueue.main.async { b?.touchedElsewhere() }
            }
        }
        // The button's own finger.
        if var cur = g, let p = pts[cur.id] {
            let moved = hypot(p.x - cur.start.x, p.y - cur.start.y)
            if !cur.decided && (time - cur.t0 >= decideAfter || moved > 8) { cur.decided = true }
            let movable = cur.part == .main || cur.part == .language
            if cur.decided && movable && !cur.hadExtras && !cur.dragging && moved > 8 {
                cur.dragging = true
                button?.beginDrag()
            }
            if cur.dragging { button?.drag(dx: p.x - cur.last.x, dy: p.y - cur.last.y) }
            cur.last = p
            g = cur
        }
        guard let cur = g else { return pts }
        return pts.filter { $0.key != cur.id && !cur.extras.contains($0.key) }
    }

    /// For the gesture engine: of the fingers of a two-finger tap, the one on the microphone.
    func preferredPoint(_ pts: [CGPoint]) -> CGPoint? {
        pts.filter { button?.part(at: $0) == .main }.min { $0.x < $1.x }
    }

    private func finish(_ gesture: Gesture, _ time: TimeInterval) {
        let b = button
        DispatchQueue.main.async {
            if gesture.dragging { b?.endDrag() }
            else if gesture.part == .main && (gesture.hadExtras || time - gesture.t0 >= 0.6) { b?.showMenu(event: nil) }
            else { b?.activate(gesture.part) }
        }
    }

    func reset() {
        g = nil
        known = []
    }
}

private final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func fire() { action() }
}

/// Diagnostics: renders the button and the language list to PNG files (`touchbridge render-dictation <dir>`).
enum DictationPreview {
    static func render(to dir: URL) {
        func save(_ v: NSView, _ name: String) {
            v.wantsLayer = true
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale),
                                             pixelsHigh: Int(v.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            rep.size = v.bounds.size
            // a mid-grey backdrop so the translucent dark parts are visible
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: 0.55, alpha: 1).setFill()
            v.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
        let langs = Dictation.languages.isEmpty ? ["en_US", "ru_RU"] : Dictation.languages
        let idle = MicView(frame: NSRect(origin: .zero, size: MicView.size))
        idle.language = Dictation.badge(langs[0])
        save(idle, "mic-idle.png")
        let listening = MicView(frame: NSRect(origin: .zero, size: MicView.size))
        listening.language = Dictation.badge(langs[0])
        listening.mode = .listening
        listening.pickerOpen = true
        listening.bars = [0.3, 0.7, 1.0, 0.6, 0.25]
        save(listening, "mic-listening-open.png")
        let picker = PickerView(frame: NSRect(x: 0, y: 0, width: 200, height: PickerView.height(for: langs.count)))
        picker.current = langs[0]
        picker.items = langs.map { ($0, LanguagePicker.name($0, among: langs)) }
        save(picker, "picker.png")
    }
}
