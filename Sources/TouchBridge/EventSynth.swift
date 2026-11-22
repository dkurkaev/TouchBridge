import AppKit
import CoreGraphics
import Foundation

/// IOHIDEventPhaseBits
enum Phase: Int64 {
    case began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
}

/// Private CGEvent fields (reverse-engineered, used by Mac Mouse Fix and others).
private func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
private let fType = field(55)          // event type
private let fGestureSubtype = field(110)
private let fMagnification = field(113)
private let fRotation = field(114)
private let fGesturePhase = field(132)
private let fDockPhase = field(134)
private let fDockOffset = field(124)
private let fDockOffsetFloatBits = field(135)
private let fDockMotion = field(123)
private let fDockMotion2 = field(165)
private let fDockInverted = field(136)
private let fDockExitSpeed = field(129)
private let fDockExitSpeed2 = field(130)
private let fMagic41 = field(41)

private let kGestureType: Int64 = 29       // NSEventTypeGesture
private let kDockControlType: Int64 = 30   // NSEventTypeMagnify slot, used for dock swipes
private let kSubtypeRotate: Int64 = 5      // kIOHIDEventTypeRotation
private let kSubtypeZoom: Int64 = 8        // kIOHIDEventTypeZoom
private let kSubtypeDockSwipe: Int64 = 23  // kIOHIDEventTypeDockSwipe

enum DockSwipeKind: Int64 { case horizontal = 1, vertical = 2, pinch = 3 }

final class EventSynth {
    let src = CGEventSource(stateID: .hidSystemState)
    var dryRun = false
    private var scrollRemX = 0.0
    private var scrollRemY = 0.0

    private func post(_ e: CGEvent?, _ tap: CGEventTapLocation = .cghidEventTap) {
        guard !dryRun, let e else { return }
        e.post(tap: tap)
    }

    // MARK: Mouse

    func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 1) {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: clickState)
        post(e)
    }

    func move(to p: CGPoint) { mouse(.mouseMoved, at: p) }

    func click(at p: CGPoint, button: CGMouseButton = .left, count: Int64 = 1) {
        let pair: (CGEventType, CGEventType)
        switch button {
        case .right: pair = (.rightMouseDown, .rightMouseUp)
        case .center: pair = (.otherMouseDown, .otherMouseUp)
        default: pair = (.leftMouseDown, .leftMouseUp)
        }
        mouse(pair.0, at: p, button: button, clickState: count)
        mouse(pair.1, at: p, button: button, clickState: count)
    }

    // MARK: Scrolling (continuous, with phases → smooth scrolling, rubber-banding, swipe-back in browsers)

    /// scrollPhase: 0 none, 1 began, 2 changed, 4 ended, 8 cancelled, 128 mayBegin
    /// momentumPhase: 0 none, 1 begin, 2 continue, 3 end
    func scroll(dx: Double, dy: Double, scrollPhase: Int64, momentumPhase: Int64 = 0) {
        let tx = dx + scrollRemX, ty = dy + scrollRemY
        let ix = tx.rounded(.towardZero), iy = ty.rounded(.towardZero)
        scrollRemX = tx - ix
        scrollRemY = ty - iy
        if scrollPhase == 1 || momentumPhase == 1 { scrollRemX = 0; scrollRemY = 0 }
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        post(e)
    }

    // MARK: Gestures (private)

    func magnify(_ phase: Phase, _ amount: Double, at p: CGPoint) {
        guard let e = CGEvent(source: nil) else { return }
        e.setIntegerValueField(fType, value: kGestureType)
        e.setIntegerValueField(fGestureSubtype, value: kSubtypeZoom)
        e.setIntegerValueField(fGesturePhase, value: phase.rawValue)
        e.setDoubleValueField(fMagnification, value: amount)
        e.location = p
        post(e, .cgSessionEventTap)
    }

    /// degrees, positive = counter-clockwise
    func rotate(_ phase: Phase, _ degrees: Double, at p: CGPoint) {
        guard let e = CGEvent(source: nil) else { return }
        e.setIntegerValueField(fType, value: kGestureType)
        e.setIntegerValueField(fGestureSubtype, value: kSubtypeRotate)
        e.setIntegerValueField(fGesturePhase, value: phase.rawValue)
        e.setDoubleValueField(fRotation, value: degrees)
        e.location = p
        post(e, .cgSessionEventTap)
    }

    /// Live Spaces / Mission Control swipe. `offset` is cumulative (≈1.0 = one full space).
    func dockSwipe(_ kind: DockSwipeKind, _ phase: Phase, offset: Double, exitSpeed: Double = 0) {
        guard let e29 = CGEvent(source: nil), let e30 = CGEvent(source: nil) else { return }
        e29.setIntegerValueField(fType, value: kGestureType)
        e29.setIntegerValueField(fMagic41, value: 33231)

        e30.setIntegerValueField(fType, value: kDockControlType)
        e30.setIntegerValueField(fGestureSubtype, value: kSubtypeDockSwipe)
        e30.setIntegerValueField(fGesturePhase, value: phase.rawValue)
        e30.setIntegerValueField(fDockPhase, value: phase.rawValue)
        e30.setDoubleValueField(fDockOffset, value: offset)
        let bits = Float(offset).bitPattern
        e30.setIntegerValueField(fDockOffsetFloatBits, value: Int64(bits))
        e30.setIntegerValueField(fMagic41, value: 33231)
        e30.setIntegerValueField(fDockMotion, value: kind.rawValue)
        e30.setIntegerValueField(fDockMotion2, value: kind.rawValue)
        e30.setIntegerValueField(fDockInverted, value: 0)
        if phase == .ended || phase == .cancelled {
            e30.setDoubleValueField(fDockExitSpeed, value: exitSpeed)
            e30.setDoubleValueField(fDockExitSpeed2, value: exitSpeed)
        }
        post(e30, .cgSessionEventTap)
        post(e29, .cgSessionEventTap)
    }

    // MARK: Keyboard

    /// `pid`: deliver straight to that app (works even if another app has keyboard focus).
    func key(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t? = nil) {
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        var f = flags
        if (123...126).contains(code) { f.insert(.maskSecondaryFn); f.insert(.maskNumericPad) }
        down?.flags = f
        up?.flags = f
        if let pid {
            guard !dryRun else { return }
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            post(down)
            post(up)
        }
    }
}

/// Named actions usable in the config.
final class Actions {
    let synth: EventSynth
    init(synth: EventSynth) { self.synth = synth }

    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Int32
    private static let coreDock: CoreDockSendNotificationFn? = {
        _ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(sym, to: CoreDockSendNotificationFn.self)
    }()

    private func dock(_ name: String) -> Bool {
        guard let f = Self.coreDock else { return false }
        _ = f(name as CFString, 0)
        return true
    }

    static let known = ["none", "hold (только longPressAction)", "click", "rightClick", "middleClick", "doubleClick", "missionControl", "appExpose",
                        "showDesktop", "launchpad", "spaceLeft", "spaceRight", "lookup", "keyboard", "keys:<combo>", "open:<path>"]

    func run(_ action: String, at p: CGPoint) {
        guard !synth.dryRun else { return }
        switch action {
        case "none", "": return
        case "click": synth.click(at: p)
        case "doubleClick": synth.click(at: p, count: 1); synth.click(at: p, count: 2)
        case "rightClick": synth.click(at: p, button: .right)
        case "middleClick": synth.click(at: p, button: .center)
        case "missionControl": if !dock("com.apple.expose.awake") { synth.key(126, flags: .maskControl) }
        case "appExpose": if !dock("com.apple.expose.front.awake") { synth.key(125, flags: .maskControl) }
        case "showDesktop": if !dock("com.apple.showdesktop.awake") { synth.key(103) }
        case "launchpad":
            let candidates = ["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"]
            if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                _ = dock("com.apple.launchpad.toggle")
            }
        case "keyboard": DispatchQueue.global(qos: .userInitiated).async { OnScreenKeyboard.toggle() }
        case "spaceLeft": synth.key(123, flags: .maskControl)
        case "spaceRight": synth.key(124, flags: .maskControl)
        case "lookup":
            synth.move(to: p)
            synth.key(2, flags: [.maskControl, .maskCommand]) // ⌃⌘D
        default:
            if action.hasPrefix("keys:") {
                if let (code, flags) = Self.parseCombo(String(action.dropFirst(5))) { synth.key(code, flags: flags) }
                else { tlog("⚠️  Не понял сочетание клавиш: \(action)") }
            } else if action.hasPrefix("open:") {
                NSWorkspace.shared.open(URL(fileURLWithPath: String(action.dropFirst(5))))
            } else {
                tlog("⚠️  Неизвестное действие: \(action)")
            }
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "home": 115, "end": 119, "pageup": 116,
        "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// "ctrl+cmd+d", "cmd+shift+]", "f11"
    static func parseCombo(_ s: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for raw in s.lowercased().split(separator: "+") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            switch t {
            case "ctrl", "control": flags.insert(.maskControl)
            case "cmd", "command": flags.insert(.maskCommand)
            case "opt", "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: code = keyCodes[t]
            }
        }
        guard let c = code else { return nil }
        return (c, flags)
    }
}
