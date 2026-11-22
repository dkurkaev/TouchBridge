import CoreGraphics
import Foundation

/// Turns the controller's raw contacts into stable finger tracks.
///
/// Cheap touch controllers (this ILITEK panel included) misbehave in two ways:
/// 1. They drop a contact for 1–10 scans (20–90 ms), mostly while it moves, then report it again.
///    To the gesture engine that looks like a lift — scrolls break, false taps fire.
/// 2. When several contacts drop out together, the controller may hand the finger IDs back in a
///    different order, so two fingers seem to swap places (a fake 180° rotation).
///
/// A vanished finger is therefore kept alive for `grace` seconds, moving along with the fingers
/// that are still reported. Contacts that (re)appear during such a gap are matched to the missing
/// fingers by position, not by ID, and the match is re-solved on every frame until all fingers
/// are back — the first finger to return alone is often ambiguous.
final class ContactDebouncer {
    var onFrame: (([Int: CGPoint], TimeInterval) -> Void)?
    /// track, gap length in seconds — for the verbose log.
    var onGapBridged: ((Int, TimeInterval) -> Void)?
    /// Controller renumbered fingers after a dropout — for the verbose log.
    var onRenumbered: ((String) -> Void)?

    private struct Track {
        var pos: CGPoint
        var anchor: CGPoint             // where it vanished, moved along with the remaining fingers
        var missingSince: TimeInterval?
        var grace: TimeInterval = 0     // chosen when it vanished: longer while several fingers are down
        var lastDev: Int
        var bridged = false
        var vel = CGVector.zero         // pt/s, smoothed
        var lastTime: TimeInterval = 0
    }

    private let grace: TimeInterval
    private let multiGrace: TimeInterval
    private let maxJump: Double
    private let loneSlop: Double
    private var tracks: [Int: Track] = [:]
    private var episode: Set<Int> = []      // tracks that vanished recently: their device IDs are not trusted
    private var devTrack: [Int: Int] = [:]  // device contact ID → track, as of the last frame
    private var nextID = 0
    private var timer: DispatchSourceTimer?

    /// `grace` for a lone finger (short, so quick double taps stay separate), `multiGrace` when
    /// several fingers are down (dropouts of a moving pair last up to ~140 ms).
    /// `loneSlop`: a lone finger counts as "returned" only this close (pt) to where it vanished,
    /// plus how far its own motion would have carried it — so quick taps on neighbouring keys stay separate.
    init(grace: TimeInterval, multiGrace: TimeInterval, maxJump: Double, loneSlop: Double = 30) {
        self.grace = grace
        self.multiGrace = max(multiGrace, grace)
        self.maxJump = maxJump
        self.loneSlop = loneSlop
    }

    func feed(_ pts: [Int: CGPoint], time: TimeInterval) {
        guard grace > 0 else { onFrame?(pts, time); return }

        // 1. Contacts that continue without a gap keep their track.
        var newDevTrack: [Int: Int] = [:]
        var present = Set<Int>()
        var rest: [(dev: Int, p: CGPoint)] = []
        var dx = 0.0, dy = 0.0, n = 0.0
        for (dev, p) in pts.sorted(by: { $0.key < $1.key }) {
            if let t = devTrack[dev], !episode.contains(t), let tr = tracks[t], !present.contains(t) {
                dx += Double(p.x - tr.pos.x)
                dy += Double(p.y - tr.pos.y)
                n += 1
                let dt = time - tr.lastTime
                if dt > 0.0005 && dt < 0.1 {
                    tracks[t]!.vel = CGVector(dx: tr.vel.dx * 0.5 + (p.x - tr.pos.x) / dt * 0.5,
                                              dy: tr.vel.dy * 0.5 + (p.y - tr.pos.y) / dt * 0.5)
                }
                tracks[t]!.lastTime = time
                tracks[t]!.pos = p
                present.insert(t)
                newDevTrack[dev] = t
            } else {
                rest.append((dev, p))
            }
        }
        if n > 0 { dx /= n; dy /= n }

        // A lone finger (nothing else on the screen) is matched strictly: a touch somewhere else
        // within the grace period is the next tap, not this finger coming back.
        let lone = tracks.count == 1 && present.isEmpty

        // 2. Fingers that just vanished start a gap episode.
        let g = tracks.count >= 2 ? multiGrace : grace
        for (t, tr) in tracks where !episode.contains(t) && !present.contains(t) {
            episode.insert(t)
            tracks[t]!.anchor = tr.pos
            tracks[t]!.missingSince = time
            tracks[t]!.grace = g
        }
        for t in episode {
            tracks[t]!.anchor.x += dx
            tracks[t]!.anchor.y += dy
        }

        // 3. Everything else is matched to the episode's fingers by position.
        let cand = episode.sorted()
        var anchors = cand.map { tracks[$0]!.anchor }
        var allowed = [Double](repeating: maxJump, count: cand.count)
        if lone {
            for (j, t) in cand.enumerated() {
                let tr = tracks[t]!
                let gap = time - (tr.missingSince ?? time)
                anchors[j].x += max(-150, min(150, tr.vel.dx * gap))   // carried on by its own motion
                anchors[j].y += max(-150, min(150, tr.vel.dy * gap))
                allowed[j] = min(maxJump, loneSlop + Double(hypot(tr.vel.dx, tr.vel.dy)) * gap * 0.5)
            }
        }
        let match = Self.assign(rest.map(\.p), anchors, allowed: allowed)
        var matched = Set<Int>()
        if lone, let t = cand.first, !match.contains(where: { $0 != nil }), !rest.isEmpty {
            // The lone finger really lifted: deliver its lift before the new touch starts.
            tracks[t] = nil
            episode.remove(t)
            emit(time)
        }
        for (i, u) in rest.enumerated() {
            if let j = match[i] {
                let t = cand[j]
                matched.insert(t)
                if let since = tracks[t]!.missingSince, !tracks[t]!.bridged {
                    tracks[t]!.bridged = true
                    onGapBridged?(t, time - since)
                }
                if tracks[t]!.lastDev != u.dev {
                    onRenumbered?("контроллер перенумеровал пальцы: id\(u.dev) — это палец \(t) (был id\(tracks[t]!.lastDev))")
                }
                tracks[t]!.missingSince = nil
                tracks[t]!.pos = u.p
                tracks[t]!.lastDev = u.dev
                tracks[t]!.lastTime = time
                newDevTrack[u.dev] = t
            } else {
                let t = nextID
                nextID += 1
                tracks[t] = Track(pos: u.p, anchor: u.p, lastDev: u.dev, lastTime: time)
                newDevTrack[u.dev] = t
            }
        }
        for t in cand where !matched.contains(t) && tracks[t] != nil {
            if tracks[t]!.missingSince == nil {
                tracks[t]!.missingSince = time
                tracks[t]!.grace = g
            }
            tracks[t]!.pos = tracks[t]!.anchor
        }
        devTrack = newDevTrack

        expire(at: time)
        emit(time)
        updateTimer()
    }

    func reset() {
        tracks = [:]
        episode = []
        devTrack = [:]
        nextID = 0
        timer?.cancel()
        timer = nil
    }

    private func emit(_ time: TimeInterval) {
        onFrame?(tracks.mapValues(\.pos), time)
    }

    /// Releases fingers that stayed away longer than `grace`; ends the episode once nobody is missing.
    @discardableResult
    private func expire(at t: TimeInterval) -> Bool {
        var changed = false
        for id in episode {
            if let tr = tracks[id], let since = tr.missingSince, t - since >= tr.grace {
                tracks[id] = nil
                episode.remove(id)
                changed = true
            }
        }
        if !episode.contains(where: { tracks[$0]?.missingSince != nil }) {
            for id in episode { tracks[id]?.bridged = false }
            episode = []
        }
        if tracks.isEmpty {
            nextID = 0
            devTrack = [:]
        }
        return changed
    }

    /// As many contact↔anchor pairs as possible (each within its anchor's `allowed` distance), then the smallest
    /// total distance. Returns, per contact, the index of its anchor or nil.
    static func assign(_ ps: [CGPoint], _ anchors: [CGPoint], allowed: [Double]) -> [Int?] {
        var best = [Int?](repeating: nil, count: ps.count)
        guard !ps.isEmpty, !anchors.isEmpty else { return best }
        func d(_ i: Int, _ j: Int) -> Double { Double(hypot(ps[i].x - anchors[j].x, ps[i].y - anchors[j].y)) }

        if ps.count > 6 || anchors.count > 6 { // greedy for big hands — never happens in practice
            var pairs: [(Double, Int, Int)] = []
            for i in ps.indices { for j in anchors.indices where d(i, j) <= allowed[j] { pairs.append((d(i, j), i, j)) } }
            var usedJ = Set<Int>()
            for (_, i, j) in pairs.sorted(by: { $0.0 < $1.0 }) where best[i] == nil && !usedJ.contains(j) {
                best[i] = j
                usedJ.insert(j)
            }
            return best
        }
        var bestCount = 0, bestCost = Double.infinity
        var cur = best
        var used = [Bool](repeating: false, count: anchors.count)
        func search(_ i: Int, _ count: Int, _ cost: Double) {
            if i == ps.count {
                if count > bestCount || (count == bestCount && cost < bestCost) {
                    bestCount = count
                    bestCost = cost
                    best = cur
                }
                return
            }
            search(i + 1, count, cost)
            for j in anchors.indices where !used[j] {
                let dist = d(i, j)
                guard dist <= allowed[j] else { continue }
                used[j] = true
                cur[i] = j
                search(i + 1, count + 1, cost + dist)
                used[j] = false
                cur[i] = nil
            }
        }
        search(0, 0, 0)
        return best
    }

    /// While a finger is in its grace period, a timer releases it even if the device goes silent
    /// (it stops sending reports once nothing touches the screen).
    private func updateTimer() {
        let anyMissing = tracks.values.contains { $0.missingSince != nil }
        if !anyMissing {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.expire(at: now) { self.emit(now) }
            self.updateTimer()
        }
        timer = t
        t.resume()
    }
}
