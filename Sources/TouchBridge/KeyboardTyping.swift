import AppKit
import CoreGraphics

/// Typing mode for the macOS on-screen keyboard (Accessibility Keyboard, process "AssistiveControl").
///
/// The keyboard is the system one; it only sees mouse events. Fingers that touch down inside its
/// panel bypass the gesture engine: no two-finger gestures, no press-and-hold right-click, no waiting
/// for a second finger. Each finger is a press of its own — the button goes down when the finger
/// lands and comes up when it lifts (so holding Delete repeats and the panel can still be dragged by
/// its title bar). There is only one mouse button, so when the next finger lands before the previous
/// one has lifted (fast typing), the previous key is released first — the presses stay in order.
final class KeyTyper {
    var verbose = false
    /// Tests replace the window lookup with this.
    var zoneOverride: (() -> CGRect?)?

    private let synth: EventSynth
    private let dragSlop: CGFloat
    private var mine = Set<Int>()                 // tracks that started on the keyboard
    private var known = Set<Int>()                // all tracks seen in the previous frame
    private var active: (id: Int, down: CGPoint, last: CGPoint, dragging: Bool)?
    private var zoneCache: (rect: CGRect?, time: TimeInterval)?

    init(synth: EventSynth, dragSlop: CGFloat = 15) {
        self.synth = synth
        self.dragSlop = dragSlop
    }

    private func debug(_ s: @autoclosure () -> String) { if verbose { tlog(s()) } }

    /// The keyboard panel on screen (global CG coordinates), cached briefly — looked up on touch-down only.
    private func zone(_ time: TimeInterval) -> CGRect? {
        if let o = zoneOverride { return o() }
        if let c = zoneCache, time - c.time < 0.25 { return c.rect }
        let rect = Self.keyboardFrame()
        zoneCache = (rect, time)
        return rect
    }

    static func keyboardFrame() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "AssistiveControl" {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (w[kCGWindowLayer as String] as? Int ?? 0) < 1000 else { continue } // skip full-screen overlays
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 150 && r.width < 2000 && r.height > 80 { return r }
        }
        return nil
    }

    /// Takes the keyboard's fingers out of the frame and types with them; returns the rest for the gesture engine.
    func route(_ pts: [Int: CGPoint], time: TimeInterval) -> [Int: CGPoint] {
        // Lifts first, so a new press never overtakes the release of the previous key.
        for id in known where pts[id] == nil {
            known.remove(id)
            if mine.remove(id) != nil { release(id) }
        }
        for (id, p) in pts.sorted(by: { $0.key < $1.key }) {
            if known.insert(id).inserted, let z = zone(time), z.contains(p) {
                mine.insert(id)
                press(id, p)
            } else if mine.contains(id) {
                move(id, p)
            }
        }
        return mine.isEmpty ? pts : pts.filter { !mine.contains($0.key) }
    }

    var hasContacts: Bool { !mine.isEmpty }

    func reset() {
        if let a = active { synth.mouse(.leftMouseUp, at: a.dragging ? a.last : a.down) }
        active = nil
        mine = []
        known = []
    }

    private func press(_ id: Int, _ p: CGPoint) {
        if let a = active {
            synth.mouse(.leftMouseUp, at: a.dragging ? a.last : a.down)
            debug("клавиатура: ↑ досрочно (следующая клавиша уже нажата)")
        }
        active = (id, p, p, false)
        synth.mouse(.leftMouseDown, at: p, clickState: 1)
        debug("клавиатура: ↓ @\(Int(p.x)),\(Int(p.y))")
    }

    private func move(_ id: Int, _ p: CGPoint) {
        guard var a = active, a.id == id else { return }
        // Small slides stay on the key; only a deliberate move drags (the panel by its title bar, a slider…).
        if !a.dragging && hypot(p.x - a.down.x, p.y - a.down.y) > dragSlop {
            a.dragging = true
            debug("клавиатура: перетаскивание")
        }
        if a.dragging { synth.mouse(.leftMouseDragged, at: p, clickState: 1) }
        a.last = p
        active = a
    }

    private func release(_ id: Int) {
        guard let a = active, a.id == id else { return } // already released by a faster finger
        synth.mouse(.leftMouseUp, at: a.dragging ? a.last : a.down, clickState: 1)
        active = nil
        debug("клавиатура: ↑")
    }
}
