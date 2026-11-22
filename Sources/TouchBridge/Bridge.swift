import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

enum Permissions {
    static var inputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var all: Bool { inputMonitoring && accessibility }

    static func requestInputMonitoring() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        _ = CGRequestPostEventAccess()
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func logStatus() {
        tlog("Разрешения: Мониторинг ввода \(inputMonitoring ? "✅" : "❌"), Универсальный доступ \(accessibility ? "✅" : "❌")")
    }
}

/// Owns the HID reader + gesture engine. Used by both the menu-bar app and the CLI.
final class Bridge {
    private(set) var running = false
    private(set) var config = Config()
    var verbose = false
    var onFingers: ((Int) -> Void)?
    let configPath: String

    private var hid: TouchHID?
    private var engine: GestureEngine?
    private var mapper: ScreenMapper?
    private var watchdog: DispatchSourceTimer?
    private var debouncer: ContactDebouncer?
    private var typer: KeyTyper?
    private var micTouches: MicTouches?
    /// The floating dictation button (set by the app): fingers on it never become mouse events.
    weak var micButton: DictationButton?
    private let feedback = TouchFeedback()
    private var lastCount = 0

    init(configPath: String) { self.configPath = configPath }

    var deviceNames: [String] { hid?.connectedNames ?? [] }
    var displayName: String? { mapper?.display?.name }

    /// inject = false → only print contacts (monitor mode).
    func start(inject: Bool = true, seize: Bool? = nil) {
        guard !running else { return }
        let cfg = Config.load(path: configPath)
        config = cfg
        Permissions.logStatus()
        let synth = EventSynth()
        let mp = ScreenMapper(config: cfg)
        mapper = mp
        let h = TouchHID(config: cfg, seize: seize ?? (inject && cfg.seize), verbose: verbose)
        hid = h
        var lastReport = ProcessInfo.processInfo.systemUptime

        if inject {
            let e = GestureEngine(config: cfg, synth: synth, mapper: mp)
            e.verbose = verbose
            if cfg.holdFeedback { e.feedback = feedback }
            if cfg.videoDoubleTapSeek {
                let vt = VideoTaps(config: cfg, synth: synth)
                vt.verbose = verbose
                vt.prepareBrowsers()
                e.video = vt
            }
            engine = e
            if let s = e.system { tlog(s.summary) }
            let deb = ContactDebouncer(grace: cfg.liftGrace, multiGrace: cfg.liftGraceMulti, maxJump: cfg.rematchDistance,
                                       loneSlop: cfg.rematchLoneSlop)
            debouncer = deb
            let ty: KeyTyper? = cfg.keyboardTypingMode ? KeyTyper(synth: synth) : nil
            ty?.verbose = verbose
            typer = ty
            let mt = MicTouches()
            mt.button = micButton
            micTouches = mt
            e.tapTargetResolver = { [weak mt] pts in mt?.preferredPoint(pts) }
            deb.onFrame = { [weak self] pts, t in
                // The dictation button and the on-screen keyboard take their fingers first;
                // the rest goes to the gesture engine.
                let afterMic = mt.route(pts, time: t)
                e.handle(ty?.route(afterMic, time: t) ?? afterMic, time: t)
                self?.fingers(pts.count)
            }
            if verbose {
                deb.onGapBridged = { id, gap in tlog("  склеил пропуск пальца \(id): \(Int(gap * 1000)) мс") }
                deb.onRenumbered = { tlog("  \($0)") }
            }
            h.onFrame = { contacts in
                lastReport = ProcessInfo.processInfo.systemUptime
                var pts: [Int: CGPoint] = [:]
                for c in contacts { pts[c.id] = mp.map(c) }
                deb.feed(pts, time: lastReport)
            }
            if cfg.staleTouchTimeout > 0 {
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.schedule(deadline: .now() + 0.1, repeating: 0.1)
                t.setEventHandler { [weak self] in
                    let now = ProcessInfo.processInfo.systemUptime
                    if (e.hasContacts || ty?.hasContacts == true) && now - lastReport > cfg.staleTouchTimeout {
                        tlog("Сенсор молчит \(cfg.staleTouchTimeout) с — считаю, что пальцы убраны")
                        deb.reset()
                        ty?.reset()
                        e.handle([:], time: now)
                        self?.fingers(0)
                    }
                }
                t.resume()
                watchdog = t
            }
        } else {
            var lastPrint = 0.0
            var printedCount = -1
            h.onFrame = { [weak self] contacts in
                self?.fingers(contacts.count)
                let t = ProcessInfo.processInfo.systemUptime
                guard contacts.count != printedCount || t - lastPrint > 0.1 else { return }
                printedCount = contacts.count
                lastPrint = t
                let s = contacts.map { c -> String in
                    let p = mp.map(c)
                    return String(format: "#%ld (%.3f, %.3f → %.0f, %.0f)", c.id, c.x, c.y, p.x, p.y)
                }.joined(separator: "  ")
                tlog("\(contacts.count) пальц.: \(s)")
            }
            if verbose {
                h.onRaw = { _, rid, bytes in
                    tlog("raw #\(rid): " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
                }
            }
        }
        h.start()
        running = true
        tlog(inject ? "▶︎ Запущено" : "▶︎ Режим наблюдения (ничего не эмулирую)")
    }

    func stop() {
        guard running else { return }
        debouncer?.reset()
        debouncer = nil
        typer?.reset()
        typer = nil
        micTouches?.reset()
        micTouches = nil
        engine?.handle([:], time: ProcessInfo.processInfo.systemUptime) // release any held button
        watchdog?.cancel()
        watchdog = nil
        hid?.stop()
        hid = nil
        engine = nil
        mapper = nil
        running = false
        fingers(0)
        tlog("■ Остановлено")
    }

    func restart() {
        stop()
        start()
    }

    private func fingers(_ n: Int) {
        if n != lastCount {
            lastCount = n
            onFingers?(n)
        }
    }
}

/// Synthetic-event self tests, fired at the current cursor position.
enum Tester {
    static let names: [(String, String)] = [
        ("magnify", "Зум (щипок)"), ("rotate", "Поворот"), ("scroll", "Прокрутка с инерцией"),
        ("swipe-left", "Свайп: следующий стол"), ("swipe-right", "Свайп: предыдущий стол"),
        ("swipe-up", "Свайп вверх: Mission Control"), ("swipe-down", "Свайп вниз: App Exposé"),
        ("missionControl", "Действие: Mission Control"), ("showDesktop", "Действие: Рабочий стол"),
        ("spaceRight", "Действие: ⌃→"), ("lookup", "Действие: Найти (⌃⌘D)"),
    ]

    private static var momentum: Momentum?

    static func run(_ name: String, config: Config, delay: Double = 3, completion: (() -> Void)? = nil) {
        let synth = EventSynth()
        let actions = Actions(synth: synth)
        tlog("Тест «\(name)» через \(Int(delay)) с — наведи курсор на нужное окно")
        let q = DispatchQueue.main
        q.asyncAfter(deadline: .now() + delay) {
            let p = CGEvent(source: nil)?.location ?? .zero
            var steps: [(Double, () -> Void)] = []
            func seq(_ n: Int, dt: Double, _ f: @escaping (Int) -> Void) {
                for k in 0..<n { steps.append((Double(k) * dt, { f(k) })) }
            }
            switch name {
            case "scroll":
                synth.scroll(dx: 0, dy: 0, scrollPhase: 128)
                seq(30, dt: 0.01) { k in synth.scroll(dx: 0, dy: -8, scrollPhase: k == 0 ? 1 : 2) }
                steps.append((0.31, {
                    synth.scroll(dx: 0, dy: 0, scrollPhase: 4)
                    momentum = Momentum(synth: synth)
                    momentum?.start(vx: 0, vy: -1500, friction: config.momentumFriction)
                }))
            case "magnify":
                synth.magnify(.began, 0, at: p)
                seq(25, dt: 0.016) { _ in synth.magnify(.changed, 0.03, at: p) }
                steps.append((0.45, { synth.magnify(.ended, 0, at: p) }))
            case "rotate":
                synth.rotate(.began, 0, at: p)
                seq(30, dt: 0.016) { _ in synth.rotate(.changed, 3, at: p) }
                steps.append((0.5, { synth.rotate(.ended, 0, at: p) }))
            case "swipe-left", "swipe-right", "swipe-up", "swipe-down":
                let horizontal = name == "swipe-left" || name == "swipe-right"
                let sign: Double = (name == "swipe-left" || name == "swipe-up") ? 1 : -1
                let kind: DockSwipeKind = horizontal ? .horizontal : .vertical
                var off = 0.0
                synth.dockSwipe(kind, .began, offset: 0)
                seq(25, dt: 0.012) { _ in off += 0.03 * sign; synth.dockSwipe(kind, .changed, offset: off) }
                steps.append((0.32, { synth.dockSwipe(kind, .ended, offset: off, exitSpeed: 2.5 * sign) }))
            default:
                actions.run(name, at: p)
            }
            for (t, f) in steps { q.asyncAfter(deadline: .now() + t, execute: f) }
            q.asyncAfter(deadline: .now() + 2) {
                tlog("Тест «\(name)» отправлен. Если ничего не произошло — этот вид событий не работает в твоей версии macOS.")
                completion?()
            }
        }
    }
}
