import AppKit
import CoreGraphics
import Foundation

private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }

private func angleDiff(_ a: Double, _ b: Double) -> Double {
    var d = a - b
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return d
}

private struct Metrics {
    var c = CGPoint.zero
    var spread = 0.0
    var angle = 0.0
    var count = 0
}

/// Inertial scrolling after the fingers leave the screen.
final class Momentum {
    private let synth: EventSynth
    private var timer: DispatchSourceTimer?
    private var vx = 0.0, vy = 0.0
    private var first = true

    init(synth: EventSynth) { self.synth = synth }

    var running: Bool { timer != nil }

    func start(vx: Double, vy: Double, friction: Double) {
        cancel()
        self.vx = vx
        self.vy = vy
        first = true
        let dt = 1.0 / 120.0
        let decay = pow(max(min(friction, 0.99), 0.0001), dt)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: dt)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.synth.scroll(dx: self.vx * dt, dy: self.vy * dt, scrollPhase: 0, momentumPhase: self.first ? 1 : 2)
            self.first = false
            self.vx *= decay
            self.vy *= decay
            if hypot(self.vx, self.vy) < 12 { self.cancel() }
        }
        timer = t
        t.resume()
    }

    func cancel() {
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        synth.scroll(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)
    }
}

final class GestureEngine {
    private enum Mode { case idle, pending, pointer, multi, ignoring }
    private enum Kind { case undecided, scroll, transform, dockSwipe(DockSwipeKind), drag, done }

    private let cfg: Config
    private let synth: EventSynth
    private let actions: Actions
    private let mapper: ScreenMapper
    private let momentum: Momentum
    var verbose = false

    private var mode = Mode.idle
    private var gen = 0
    private var current: [Int: CGPoint] = [:]
    private var startPoints: [Int: CGPoint] = [:]
    private var startTime: TimeInterval = 0
    private var maxFingers = 0
    private var maxTravel = 0.0

    // pointer
    private var primaryID = 0
    private var pointerStart = CGPoint.zero
    private var pointerLast = CGPoint.zero
    private var dragging = false
    private var dragClickState: Int64 = 1
    private var lastClickTime: TimeInterval = 0
    private var lastClickPos = CGPoint.zero
    private var clickCount: Int64 = 0

    // multi-finger
    private var kind = Kind.undecided
    private var tracked: [Int] = []
    private var base = Metrics()
    private var prev = Metrics()
    private var prevTime: TimeInterval = 0
    private var vx = 0.0, vy = 0.0
    private var magActive = false, rotActive = false
    private var swipeOffset = 0.0, swipeVelocity = 0.0
    private var tapCentroid = CGPoint.zero
    private var lastUndecided = Metrics()
    private var multiStart: TimeInterval = 0
    private var firstTouchID: Int?
    // press and hold / press and tap
    private var holdArmed = false
    private var holdPoint = CGPoint.zero
    private var secondTap: (id: Int, time: TimeInterval)?
    /// Visual hint under the finger when a press-and-hold registers (nil in tests / CLI).
    var feedback: TouchFeedback?
    /// Double-tap seeking on browser videos (nil = off).
    var video: VideoTaps?
    /// Lets our own UI claim a two-finger tap: returns the finger that is on it (nil = none).
    var tapTargetResolver: (([CGPoint]) -> CGPoint?)?

    /// Where a two-finger tap clicks (right-click). Fingers rarely land at exactly the same moment,
    /// so "the first one" is nearly random. Rules: a finger on our own button wins; a finger that
    /// clearly landed first (press, then tap) is the target; otherwise the index finger — the left
    /// of the two for a right hand (`dominantHand`).
    private func twoFingerTarget() -> CGPoint {
        let pts = Array(startPoints.values)
        if let r = tapTargetResolver?(pts) { return r }
        if let f = firstTouchID, let p = startPoints[f], multiStart - startTime >= cfg.pressAndTapGap { return p }
        guard let left = pts.min(by: { $0.x < $1.x }), let right = pts.max(by: { $0.x < $1.x }) else { return tapCentroid }
        return cfg.dominantHand == "left" ? right : left
    }
    private var basePoints: [Int: CGPoint] = [:]
    private var baseTime: TimeInterval = 0

    /// The user's trackpad settings; nil when `useSystemGestures` is off (then config actions apply).
    let system: SystemGestures?

    init(config: Config, synth: EventSynth, mapper: ScreenMapper) {
        cfg = config
        self.synth = synth
        self.mapper = mapper
        actions = Actions(synth: synth)
        momentum = Momentum(synth: synth)
        system = config.useSystemGestures ? SystemGestures.read() : nil
    }

    private var threeFingerDrag: Bool { system?.threeFingerDrag ?? cfg.threeFingerDrag }

    var hasContacts: Bool { !current.isEmpty }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func debug(_ s: @autoclosure () -> String) { if verbose { tlog(s()) } }

    // MARK: - Entry point

    func handle(_ points: [Int: CGPoint], time: TimeInterval) {
        if verbose && points.count != current.count {
            let ids = points.keys.sorted().map(String.init).joined(separator: ",")
            tlog("пальцев: \(current.count) → \(points.count) [id \(ids)]  режим: \(mode)")
        }
        current = points
        if points.isEmpty { allUp(time); return }

        switch mode {
        case .idle:
            momentum.cancel()
            mode = .pending
            startTime = time
            startPoints = points
            maxFingers = points.count
            maxTravel = 0
            firstTouchID = points.count == 1 ? points.first?.key : nil
            holdArmed = false
            secondTap = nil
            if points.count >= 2 { enterMulti(time) } else { scheduleDecision() }

        case .pending:
            for (id, p) in points where startPoints[id] == nil { startPoints[id] = p }
            maxFingers = max(maxFingers, points.count)
            if points.count >= 2 { enterMulti(time); return }
            if let f = points.first, let s = startPoints[f.key], dist(f.value, s) > cfg.dragSlop {
                enterPointer(time)
                pointerUpdate(time)
            }

        case .pointer: pointerUpdate(time)
        case .multi: multiUpdate(time)
        case .ignoring: break
        }
    }

    private func scheduleDecision() {
        gen += 1
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.multiFingerWait) { [weak self] in
            guard let self, self.gen == g, self.mode == .pending, self.current.count == 1 else { return }
            self.enterPointer(self.now())
        }
    }

    // MARK: - One finger

    private func enterPointer(_ time: TimeInterval) {
        guard let f = current.first else { return }
        let id = f.key, p = f.value
        mode = .pointer
        primaryID = id
        pointerStart = startPoints[id] ?? p
        pointerLast = p
        dragging = false
        synth.move(to: pointerStart)
        debug("pointer")

        gen += 1
        let g = gen
        let delay = max(0, cfg.longPressDelay - (time - startTime))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.gen == g, self.mode == .pointer, !self.dragging else { return }
            if self.cfg.longPressAction == "hold" {
                if self.cfg.holdReleaseAction == "hold" {
                    // Legacy: the button goes down right away and stays down until the finger lifts.
                    self.dragging = true
                    self.dragClickState = 1
                    self.synth.mouse(.leftMouseDown, at: self.pointerLast, clickState: 1)
                    self.debug("hold → кнопка зажата")
                    return
                }
                // Touchscreen-style press and hold (Windows, iPad): moving now drags with the left
                // button, lifting without moving fires holdReleaseAction (right-click) under the finger.
                self.video?.flush()
                self.holdArmed = true
                self.holdPoint = self.pointerLast
                self.feedback?.showHold(at: self.holdPoint)
                self.debug("hold → сдвиг = перетаскивание, отпускание = \(self.cfg.holdReleaseAction)")
                return
            }
            self.debug("long press → \(self.cfg.longPressAction)")
            self.mode = .ignoring
            self.actions.run(self.cfg.longPressAction, at: self.pointerStart)
        }
    }

    private func nextClickState(at p: CGPoint, _ time: TimeInterval) -> Int64 {
        if time - lastClickTime < NSEvent.doubleClickInterval && dist(p, lastClickPos) < cfg.doubleTapDistance {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = time
        lastClickPos = p
        return clickCount
    }

    private func pointerUpdate(_ time: TimeInterval) {
        if current.count >= 2 && !dragging && !holdArmed && time - startTime < cfg.lateSecondFingerWindow {
            maxFingers = max(maxFingers, current.count)
            for (id, p) in current where startPoints[id] == nil { startPoints[id] = p }
            enterMulti(time)
            return
        }
        guard let p = current[primaryID] else {
            // primary finger lifted while another one stays: finish and ignore the rest
            pointerEnd(time)
            mode = .ignoring
            return
        }

        // Press and tap: this finger rests on the target, another finger taps next to it →
        // right-click exactly under the resting finger.
        if secondTap == nil, let other = current.keys.first(where: { $0 != primaryID }) {
            secondTap = (other, time)
        }
        if let st = secondTap, current[st.id] == nil {
            secondTap = nil
            if !dragging && time - st.time < cfg.tapMaxDuration {
                gen += 1 // cancel long press
                holdArmed = false
                feedback?.hide()
                debug("нажатие + тап вторым пальцем → \(cfg.twoFingerTap) @\(Int(p.x)),\(Int(p.y))")
                actions.run(cfg.twoFingerTap, at: p)
                mode = .ignoring
                return
            }
        }

        if holdArmed {
            if dist(p, holdPoint) > cfg.dragSlop {
                holdArmed = false
                feedback?.hide()
                dragging = true
                dragClickState = 1
                synth.mouse(.leftMouseDown, at: holdPoint, clickState: 1)
                synth.mouse(.leftMouseDragged, at: p, clickState: 1)
                debug("hold → перетаскивание")
            }
            pointerLast = p
            return
        }
        if !dragging {
            let d = dist(p, pointerStart)
            if d > cfg.dragSlop && (time - startTime > cfg.dragDelay || d > cfg.dragFastDistance) {
                video?.flush()
                dragging = true
                gen += 1 // cancel long press
                dragClickState = nextClickState(at: pointerStart, time)
                synth.mouse(.leftMouseDown, at: pointerStart, clickState: dragClickState)
                synth.mouse(.leftMouseDragged, at: p, clickState: dragClickState)
                debug("drag")
            }
        } else {
            synth.mouse(.leftMouseDragged, at: p, clickState: dragClickState)
        }
        pointerLast = p
    }

    private func pointerEnd(_ time: TimeInterval) {
        feedback?.hide()
        if holdArmed {
            holdArmed = false
            debug("hold → отпускание → \(cfg.holdReleaseAction) @\(Int(holdPoint.x)),\(Int(holdPoint.y))")
            actions.run(cfg.holdReleaseAction, at: holdPoint)
            return
        }
        if dragging {
            synth.mouse(.leftMouseUp, at: pointerLast, clickState: dragClickState)
        } else {
            tap(at: pointerStart, time)
        }
    }

    private func tap(at p: CGPoint, _ time: TimeInterval) {
        // Over a browser video a tap may be the first half of a seek double tap.
        if let v = video, v.handleTap(at: p, time: time, click: { [weak self] in
            guard let self else { return }
            self.click(at: p, self.now())
        }) { return }
        click(at: p, time)
    }

    private func click(at p: CGPoint, _ time: TimeInterval) {
        let cs = nextClickState(at: p, time)
        synth.mouse(.leftMouseDown, at: p, clickState: cs)
        synth.mouse(.leftMouseUp, at: p, clickState: cs)
        debug("tap ×\(cs) @\(Int(p.x)),\(Int(p.y))")
    }

    // MARK: - Several fingers

    private func metrics(_ ids: [Int]) -> Metrics? {
        let pts = ids.compactMap { current[$0] }
        guard pts.count == ids.count, !pts.isEmpty else { return nil }
        var m = Metrics()
        m.count = pts.count
        m.c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                      y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        m.spread = pts.map { dist($0, m.c) }.reduce(0, +) / Double(pts.count)
        if pts.count >= 2 {
            m.angle = Double(atan2(pts[1].y - pts[0].y, pts[1].x - pts[0].x))
        }
        return m
    }

    private func rebase(_ time: TimeInterval) {
        tracked = current.keys.sorted()
        if let m = metrics(tracked) { base = m; prev = m; lastUndecided = m }
        basePoints = current
        baseTime = time
        prevTime = time
        vx = 0; vy = 0
    }

    /// Two fingers: classify by how each finger moved since the gesture started.
    /// People rarely start both fingers at once — the leading finger alone looks like a rotation
    /// or pinch around the resting one — so with only one finger moving we wait a moment for the other.
    private func decideTwoFinger(_ m: Metrics, travel: Double, _ time: TimeInterval) {
        guard tracked.count == 2,
              let a0 = basePoints[tracked[0]], let a1 = basePoints[tracked[1]],
              let p0 = current[tracked[0]], let p1 = current[tracked[1]] else { return }
        let d0 = (x: Double(p0.x - a0.x), y: Double(p0.y - a0.y))
        let d1 = (x: Double(p1.x - a1.x), y: Double(p1.y - a1.y))
        let m0 = hypot(d0.x, d0.y), m1 = hypot(d1.x, d1.y)
        guard max(m0, m1) > cfg.scrollThreshold else { return }

        let spreadChange = abs(m.spread - base.spread)
        let angle = abs(angleDiff(m.angle, base.angle))
        let arc = angle * max(m.spread, base.spread)       // distance each finger travelled around the centre
        let canPinch = (system?.pinchZoom ?? true) && spreadChange > cfg.pinchThreshold && spreadChange >= arc
        let canRotate = (system?.rotate ?? true) && arc > cfg.rotateArcThreshold
            && angle > cfg.rotateThresholdDegrees * .pi / 180 && arc > spreadChange

        if min(m0, m1) > cfg.scrollThreshold * 0.5 {
            let cos = (d0.x * d1.x + d0.y * d1.y) / (m0 * m1)
            if cos > 0.3 { startScroll(m, time) }             // both fingers go the same way
            else if canPinch { startTransform(m, time, magnify: true) }
            else if canRotate { startTransform(m, time, magnify: false) }
            return
        }
        // Only one finger moves so far.
        guard time - baseTime >= cfg.twoFingerDecisionDelay else { return }
        if canPinch { startTransform(m, time, magnify: true) }
        else if canRotate { startTransform(m, time, magnify: false) }
        else if travel > cfg.scrollThreshold { startScroll(m, time) }
    }

    private func enterMulti(_ time: TimeInterval) {
        gen += 1
        mode = .multi
        kind = .undecided
        maxFingers = max(maxFingers, current.count)
        video?.flush()
        rebase(time)
        multiStart = time
        holdArmed = false
        feedback?.hide()
        // A two-finger tap right-clicks under the finger that touched first (put it on the target,
        // tap with the second) — the midpoint between two fingertips is too coarse for macOS UI.
        tapCentroid = firstTouchID.flatMap { current[$0] } ?? base.c
        synth.move(to: tapCentroid)
        debug("multi \(current.count)")
    }

    private var swipeFingerCounts: Set<Int> { threeFingerDrag ? [4, 5] : [3, 4, 5] }

    /// 3–4 finger swipe according to System Settings → Trackpad. Horizontal "spaces" stays live
    /// (follows the fingers); everything else fires the system action once the swipe is long enough.
    private func systemSwipe(_ s: SystemGestures, fingers n: Int, dx: Double, dy: Double,
                             travel: Double, _ m: Metrics, _ time: TimeInterval) {
        let horizontal = abs(dx) > abs(dy)
        func fire(_ a: String) {
            guard travel > cfg.discreteSwipeDistance else { return }
            debug("swipe \(n) → \(a)")
            actions.run(a, at: m.c)
            kind = .done
        }
        if horizontal {
            switch s.horizontal(fingers: n) {
            case .spaces:
                if cfg.swipeMode == "live" { startDockSwipe(.horizontal, m, time) }
                else { fire(dx < 0 ? "spaceRight" : "spaceLeft") }
            case .pages:
                fire(dx < 0 ? "keys:cmd+]" : "keys:cmd+[")   // like the trackpad: fingers right = back
            case .off:
                debug("swipe ←→ \(n) пальцами выключен в настройках трекпада")
                kind = .done
            }
        } else if s.verticalEnabled(fingers: n) {
            fire(dy < 0 ? (s.missionControl ? "missionControl" : "none")
                        : (s.appExpose ? "appExpose" : "none"))
        } else {
            debug("swipe ↑↓ \(n) пальцами выключен в настройках трекпада")
            kind = .done
        }
    }

    private func multiUpdate(_ time: TimeInterval) {
        maxFingers = max(maxFingers, current.count)

        if case .undecided = kind {
            let now = Set(current.keys), was = Set(tracked)
            if now != was {
                if now.isSubset(of: was) {
                    // A finger lifted before the gesture was decided: that's the end of a tap / short
                    // flick (fingers never lift at exactly the same moment) or of press-and-tap.
                    finishGesture(time)
                    kind = .done
                    mode = .ignoring
                    return
                }
                rebase(time)
                return
            }
            guard let m = metrics(tracked) else { return }
            lastUndecided = m
            let travel = dist(m.c, base.c)
            maxTravel = max(maxTravel, travel)
            let n = tracked.count
            if n < 2 { return }

            if n == 2 {
                decideTwoFinger(m, travel: travel, time)
                return
            }

            if n >= 4 && abs(m.spread - base.spread) > cfg.fourFingerPinchThreshold {
                let closing = m.spread < base.spread
                var a = closing ? cfg.pinchIn : cfg.pinchOut
                if let s = system {
                    a = !s.pinchEnabled(fingers: n) ? "none"
                        : closing ? (s.launchpad ? "launchpad" : "none") : (s.showDesktop ? "showDesktop" : "none")
                }
                debug("pinch \(n) → \(a)")
                actions.run(a, at: m.c)
                kind = .done
                return
            }
            if n == 3 && threeFingerDrag && travel > cfg.scrollThreshold {
                kind = .drag
                synth.mouse(.leftMouseDown, at: base.c)
                synth.mouse(.leftMouseDragged, at: m.c)
                prev = m
                debug("3-finger drag")
                return
            }
            if swipeFingerCounts.contains(n) && travel > cfg.swipeThreshold {
                let dx = Double(m.c.x - base.c.x), dy = Double(m.c.y - base.c.y)
                let horizontal = abs(dx) > abs(dy)
                if let s = system {
                    systemSwipe(s, fingers: n, dx: dx, dy: dy, travel: travel, m, time)
                } else if cfg.swipeMode == "live" {
                    startDockSwipe(horizontal ? .horizontal : .vertical, m, time)
                } else if travel > cfg.discreteSwipeDistance {
                    let a = horizontal ? (dx < 0 ? cfg.swipeLeft : cfg.swipeRight)
                                       : (dy < 0 ? cfg.swipeUp : cfg.swipeDown)
                    debug("swipe → \(a)")
                    actions.run(a, at: m.c)
                    kind = .done
                }
            }
            return
        }

        // A tracked finger lifted → finish the gesture, ignore the remaining fingers.
        guard let m = metrics(tracked) else {
            finishGesture(time)
            kind = .done
            mode = .ignoring
            return
        }
        let dt = max(time - prevTime, 0.001)

        switch kind {
        case .scroll:
            let dx = Double(m.c.x - prev.c.x) * cfg.scrollSpeed
            let dy = Double(m.c.y - prev.c.y) * cfg.scrollSpeed
            synth.scroll(dx: dx, dy: dy, scrollPhase: 2)
            let a = 0.35
            vx = vx * (1 - a) + dx / dt * a
            vy = vy * (1 - a) + dy / dt * a

        case .transform:
            let turned = abs(angleDiff(m.angle, base.angle))
            if !rotActive && turned > cfg.rotateThresholdDegrees * .pi / 180
                && turned * max(m.spread, base.spread) > cfg.rotateArcThreshold {
                rotActive = true
                synth.rotate(.began, 0, at: m.c)
            }
            if !magActive && abs(m.spread - base.spread) > cfg.pinchThreshold {
                magActive = true
                synth.magnify(.began, 0, at: m.c)
            }
            if magActive && prev.spread > 1 {
                synth.magnify(.changed, (m.spread / prev.spread - 1) * cfg.pinchSpeed, at: m.c)
            }
            if rotActive {
                synth.rotate(.changed, -angleDiff(m.angle, prev.angle) * 180 / .pi, at: m.c)
            }

        case .dockSwipe(let k):
            let b = mapper.bounds
            var d: Double
            if k == .horizontal {
                d = -Double(m.c.x - prev.c.x) / Double(b.width)
                if cfg.dockSwipeInvertX { d = -d }
            } else {
                d = -Double(m.c.y - prev.c.y) / Double(b.height)
                if cfg.dockSwipeInvertY { d = -d }
            }
            d *= cfg.dockSwipeGain
            swipeOffset += d
            swipeVelocity = swipeVelocity * 0.6 + (d / dt) * 0.4
            synth.dockSwipe(k, .changed, offset: swipeOffset)

        case .drag:
            synth.mouse(.leftMouseDragged, at: m.c)

        case .undecided, .done:
            break
        }
        prev = m
        prevTime = time
    }

    private func startScroll(_ m: Metrics, _ time: TimeInterval) {
        kind = .scroll
        debug("scroll")
        let dx = Double(m.c.x - base.c.x) * cfg.scrollSpeed
        let dy = Double(m.c.y - base.c.y) * cfg.scrollSpeed
        synth.scroll(dx: 0, dy: 0, scrollPhase: 128) // mayBegin
        synth.scroll(dx: dx, dy: dy, scrollPhase: 1)
        prev = m
        prevTime = time
    }

    private func startTransform(_ m: Metrics, _ time: TimeInterval, magnify: Bool) {
        kind = .transform
        magActive = magnify
        rotActive = !magnify
        debug(magnify ? "pinch" : "rotate")
        if magActive {
            synth.magnify(.began, 0, at: m.c)
            if base.spread > 1 { synth.magnify(.changed, (m.spread / base.spread - 1) * cfg.pinchSpeed, at: m.c) }
        }
        if rotActive {
            synth.rotate(.began, 0, at: m.c)
            synth.rotate(.changed, -angleDiff(m.angle, base.angle) * 180 / .pi, at: m.c)
        }
        prev = m
        prevTime = time
    }

    private func startDockSwipe(_ k: DockSwipeKind, _ m: Metrics, _ time: TimeInterval) {
        kind = .dockSwipe(k)
        debug("dock swipe \(k)")
        swipeOffset = 0
        swipeVelocity = 0
        synth.dockSwipe(k, .began, offset: 0)
        prev = base
        prevTime = time
        multiUpdate(time) // apply the distance travelled so far
    }

    private func finishGesture(_ time: TimeInterval) {
        switch kind {
        case .scroll:
            synth.scroll(dx: 0, dy: 0, scrollPhase: 4)
            let stale = time - prevTime > 0.08 + cfg.liftGrace // lifts arrive `liftGrace` late
            if cfg.momentum && !stale && hypot(vx, vy) > cfg.momentumMinVelocity {
                momentum.start(vx: vx, vy: vy, friction: cfg.momentumFriction)
            }
        case .transform:
            if magActive { synth.magnify(.ended, 0, at: prev.c) }
            if rotActive { synth.rotate(.ended, 0, at: prev.c) }
            magActive = false
            rotActive = false
        case .dockSwipe(let k):
            synth.dockSwipe(k, .ended, offset: swipeOffset, exitSpeed: swipeVelocity)
        case .drag:
            synth.mouse(.leftMouseUp, at: prev.c)
        case .undecided:
            // A short 3–4 finger flick up/down that ended before reaching discreteSwipeDistance.
            let n = tracked.count
            if let s = system, n >= 3, swipeFingerCounts.contains(n), s.verticalEnabled(fingers: n) {
                let dx = Double(lastUndecided.c.x - base.c.x), dy = Double(lastUndecided.c.y - base.c.y)
                if abs(dy) > abs(dx) && hypot(dx, dy) > cfg.swipeThreshold {
                    let a = dy < 0 ? (s.missionControl ? "missionControl" : "none") : (s.appExpose ? "appExpose" : "none")
                    debug("swipe \(n) (короткий, на отпускании) → \(a)")
                    actions.run(a, at: lastUndecided.c)
                    return
                }
            }
            let duration = time - multiStart // the first finger may have rested before the others came
            if duration < cfg.tapMaxDuration && maxTravel < cfg.tapSlop * 1.5 {
                let a: String
                switch maxFingers {
                case 2: a = cfg.twoFingerTap
                case 3: a = system.map { $0.threeFingerTap ? "lookup" : "none" } ?? cfg.threeFingerTap
                case 4...: a = cfg.fourFingerTap
                default: a = "none"
                }
                let at = maxFingers == 2 ? twoFingerTarget() : tapCentroid
                debug("\(maxFingers)-finger tap → \(a) @\(Int(at.x)),\(Int(at.y))")
                actions.run(a, at: at)
            }
        case .done:
            break
        }
    }

    // MARK: - All fingers lifted

    private func allUp(_ time: TimeInterval) {
        switch mode {
        case .pending:
            if maxFingers == 1, let p = startPoints.values.first {
                tap(at: p, time)
            }
        case .pointer:
            pointerEnd(time)
        case .multi:
            finishGesture(time)
        case .idle, .ignoring:
            break
        }
        mode = .idle
        kind = .undecided
        gen += 1
        tracked = []
        startPoints = [:]
        holdArmed = false
        secondTap = nil
        feedback?.hide()
    }
}
