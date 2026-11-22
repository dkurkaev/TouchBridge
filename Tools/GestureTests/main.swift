// Real-time gesture tests: touch frames are played through ContactDebouncer, the touch routers and
// GestureEngine with a dry-run EventSynth (nothing is posted to the system); the log is checked.
// Run: Tools/run-gesture-tests.sh
import AppKit
import Foundation
import CoreGraphics

var events: [String] = []
func tlog(_ s: String) { events.append(s) }
func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
typealias Frames = [(Double, [Int: CGPoint])]
let dt = 0.008
func seq(_ n: Int, from t0: Double, _ f: (Int) -> [Int: CGPoint]) -> Frames { (0..<n).map { (t0 + Double($0) * dt, f($0)) } }

var queue: [() -> Void] = []
var failed = 0
func next() { if queue.isEmpty { print(failed == 0 ? "ВСЕ ТЕСТЫ ПРОШЛИ" : "ПРОВАЛЕНО: \(failed)"); exit(failed == 0 ? 0 : 1) } else { queue.removeFirst()() } }
var keep: [AnyObject] = []
final class FakeMic: MicTarget {
    // microphone 1800…1876 × 900…976, language pill 1800…1876 × 982…1010, an open list 1650…1790 × 900…940
    func part(at p: CGPoint) -> MicPart? {
        if CGRect(x: 1800, y: 900, width: 76, height: 76).contains(p) { return .main }
        if CGRect(x: 1800, y: 982, width: 76, height: 28).contains(p) { return .language }
        if CGRect(x: 1882, y: 982, width: 30, height: 28).contains(p) { return .close }
        if CGRect(x: 1650, y: 900, width: 140, height: 40).contains(p) { return .option("ru_RU") }
        return nil
    }
    func activate(_ part: MicPart) { tlog("mic: \(part)") }
    func touchedElsewhere() { tlog("mic: elsewhere") }
    func beginDrag() { tlog("mic: beginDrag") }
    func drag(dx: CGFloat, dy: CGFloat) {}
    func endDrag() { tlog("mic: endDrag") }
    func showMenu(event: NSEvent?) { tlog("mic: menu") }
}

/// Plays frames in real time through debouncer + engine (both use real timers), then checks the log.
func test(_ name: String, _ frames: Frames, expect: [String], forbid: [String] = [], video: Bool = false, counts: [String: Int] = [:], typing: Bool = false, mic: Bool = false) {
    queue.append {
        events = []
        let cfg = Config()
        let synth = EventSynth(); synth.dryRun = true
        let e = GestureEngine(config: cfg, synth: synth, mapper: ScreenMapper(config: cfg))
        e.verbose = true
        let deb = ContactDebouncer(grace: cfg.liftGrace, multiGrace: cfg.liftGraceMulti, maxJump: cfg.rematchDistance)
        let ty = typing ? KeyTyper(synth: synth) : nil
        ty?.verbose = true
        ty?.zoneOverride = { CGRect(x: 400, y: 400, width: 400, height: 250) }
        let mt = MicTouches()
        let fake = FakeMic()
        if mic { mt.button = fake; e.tapTargetResolver = { pts in mt.preferredPoint(pts) } }
        deb.onFrame = { pts, t in
            let m = mt.route(pts, time: t)
            e.handle(ty?.route(m, time: t) ?? m, time: t)
        }
        keep.append(fake)
        keep = [e, deb, synth, fake]
        if let ty { keep.append(ty) }
        if video {
            let vt = VideoTaps(config: cfg, synth: synth)
            vt.verbose = true
            // A YouTube video over the whole screen except the bottom strip (y > 1000 = not a video).
            vt.targetOverride = { p in p.y > 1000 ? nil
                : VideoTaps.Target(frame: CGRect(x: 0, y: 0, width: 1920, height: 1000), pid: 1, back: "j", forward: "l", host: "youtube.com") }
            e.video = vt
            keep.append(vt)
        }
        let t0 = ProcessInfo.processInfo.systemUptime
        for (t, p) in frames {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { deb.feed(p, time: t0 + t) }
        }
        let end = (frames.last?.0 ?? 0) + 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            let g = events.filter { !$0.hasPrefix("пальцев") && !$0.hasPrefix("multi") && !$0.hasPrefix("Сенсор") }
            let countsOK = counts.allSatisfy { k, n in g.filter { $0.hasPrefix(k) }.count == n }
            let ok = countsOK && expect.allSatisfy { x in g.contains { $0.hasPrefix(x) } } && !forbid.contains { x in g.contains { $0.hasPrefix(x) } }
            if !ok { failed += 1 }
            print("\(ok ? "✅" : "❌") \(name): \(g)")
            next()
        }
    }
}

// Real data from your log: both fingers drop out and come back with swapped IDs.
let caseA: Frames = [
    (0.000, [0: P(1026.3, 579.9)]),
    (0.031, [0: P(1026.3, 579.9)]),
    (0.032, [0: P(1026.3, 579.9), 1: P(957.5, 561.6)]),
    (0.042, [1: P(957.5, 561.6)]),
    (0.054, [1: P(957.5, 561.6)]),
    (0.087, [1: P(957.5, 561.6)]),
    (0.087, [:]),
    (0.100, [0: P(956.9, 525.6)]),
    (0.134, [0: P(956.9, 525.6)]),
    (0.135, [0: P(956.9, 525.6), 1: P(1006.7, 520.5)]),
    (0.156, [0: P(956.9, 525.6), 1: P(1006.7, 520.5)]),
    (0.157, [0: P(956.9, 524.8)]),
    (0.165, [0: P(956.9, 523.5)]),
    (0.187, [0: P(956.9, 521.4)]),
    (0.187, [0: P(956.5, 517.7), 1: P(1004.7, 486.9)]),
    (0.262, [0: P(952.9, 465.7), 1: P(1004.7, 483.2)]),
    (0.262, [1: P(1004.7, 479.7)]),
    (0.275, [1: P(1004.5, 474.2)]),
    (0.297, [1: P(1004.3, 466.8)]),
    (0.297, [0: P(952.9, 392.6), 1: P(1004.1, 457.3)]),
    (0.339, [0: P(952.9, 392.6), 1: P(1003.5, 424.2)]),
    (0.340, [1: P(1003.5, 412.8)]),
    (0.354, [1: P(1003.1, 401.8)]),
    (0.362, [:]),
]
let caseB: Frames = [
    (0.000, [0: P(912.3, 644.7)]),
    (0.014, [0: P(912.3, 644.7), 1: P(859.6, 640.7)]),
    (0.061, [0: P(912.3, 644.7), 1: P(859.6, 640.7)]),
    (0.061, [0: P(912.3, 644.7)]),
    (0.074, [:]),
    (0.106, [0: P(895.3, 611.7)]),
    (0.148, [0: P(895.3, 611.7)]),
    (0.148, [0: P(895.3, 611.2), 1: P(928.5, 581.6)]),
    (0.190, [0: P(894.7, 605.0), 1: P(928.5, 581.6)]),
    (0.190, [0: P(893.7, 599.6)]),
    (0.203, [0: P(892.3, 591.4)]),
    (0.226, [0: P(891.1, 581.0)]),
    (0.226, [0: P(889.9, 568.2), 1: P(935.3, 492.4)]),
    (0.300, [0: P(887.1, 471.3), 1: P(935.9, 488.2)]),
    (0.300, [0: P(887.7, 456.0)]),
    (0.313, [0: P(890.1, 441.5)]),
    (0.384, [0: P(925.3, 359.2)]),
    (0.384, [:]),
]
test("лог 00:36:20.9 — перенумерация, прокрутка", caseA + [(caseA.last!.0 + 0.1, [:])], expect: ["scroll"], forbid: ["rotate", "pinch"])
test("лог 00:36:22.5 — перенумерация, прокрутка", caseB + [(caseB.last!.0 + 0.1, [:])], expect: ["scroll"], forbid: ["rotate", "pinch"])

// Earlier log cases: leading finger + dropout.
var f: Frames = seq(2, from: 0) { _ in [0: P(1013, 1309), 1: P(1068, 1305)] }
f += seq(4, from: 0.016) { _ in [0: P(1013, 1309)] }
f += seq(6, from: 0.048) { k in [0: P(1013, 1307), 1: P(1064, 1245 - Double(k) * 8)] }
f += seq(30, from: 0.096) { k in [0: P(1013, 1300 - Double(k) * 15), 1: P(1064, 1197 - Double(k) * 15)] }
test("ведущий палец + пропуск", f + [(0.4, [:])], expect: ["scroll"], forbid: ["rotate"])

test("обычная прокрутка", seq(30, from: 0) { k in [0: P(500, 500 + Double(k) * 6), 1: P(560, 500 + Double(k) * 6)] } + [(0.3, [:])],
     expect: ["scroll"])
test("поворот", seq(30, from: 0) { k in
    let a = Double(k) * (40.0 / 29) * .pi / 180
    return [0: P(800 - 125 * cos(a), 500 - 125 * sin(a)), 1: P(800 + 125 * cos(a), 500 + 125 * sin(a))]
} + [(0.3, [:])], expect: ["rotate"])
test("щипок", seq(30, from: 0) { k in [0: P(700 - Double(k) * 4, 500), 1: P(800 + Double(k) * 4, 500)] } + [(0.3, [:])], expect: ["pinch"])

// One finger.
test("тап", seq(8, from: 0) { _ in [0: P(500, 500)] } + [(0.07, [:])], expect: ["tap ×1"], forbid: ["hold", "drag"])
test("быстрое перетаскивание", seq(40, from: 0) { k in [0: P(500 + Double(k) * 5, 500)] } + [(0.35, [:])], expect: ["drag"], forbid: ["hold"])
test("удержание → перетаскивание",
     seq(90, from: 0) { _ in [0: P(500, 500)] } + seq(40, from: 0.72) { k in [0: P(500 + Double(k) * 5, 500)] } + [(1.1, [:])],
     expect: ["pointer", "hold → сдвиг", "hold → перетаскивание"], forbid: ["drag", "hold → отпускание", "tap"])
test("удержание → отпускание = правый клик под пальцем",
     seq(100, from: 0) { _ in [0: P(500, 500)] } + [(0.82, [:])],
     expect: ["hold → отпускание → rightClick @500,500"], forbid: ["tap", "drag", "перетаскивание"])
test("нажатие + тап вторым пальцем (поздно, через 0.4 с)",
     seq(50, from: 0) { _ in [0: P(500, 500)] } + seq(10, from: 0.4) { _ in [0: P(500, 500), 1: P(545, 520)] }
     + seq(25, from: 0.48) { _ in [0: P(500, 500)] } + [(0.7, [:])],
     expect: ["нажатие + тап вторым пальцем → rightClick @500,500"], forbid: ["tap ×", "hold → отпускание"])
test("нажатие + тап вторым пальцем (быстро, через 0.1 с)",
     seq(12, from: 0) { _ in [0: P(500, 500)] } + seq(10, from: 0.1) { _ in [0: P(500, 500), 1: P(545, 520)] }
     + seq(20, from: 0.18) { _ in [0: P(500, 500)] } + [(0.36, [:])],
     expect: ["2-finger tap → rightClick @500,500"], forbid: ["tap ×"])
test("тап двумя пальцами одновременно → под указательным (левым)",
     seq(10, from: 0) { _ in [0: P(550, 500), 1: P(500, 500)] } + [(0.08, [:])], expect: ["2-finger tap → rightClick @500,500"])
test("нажать и тапнуть: первым лёг правый палец → под ним",
     seq(13, from: 0) { _ in [0: P(650, 500)] } + seq(8, from: 0.1) { _ in [0: P(650, 500), 1: P(600, 500)] } + [(0.17, [:])],
     expect: ["2-finger tap → rightClick @650,500"])
test("тап двумя пальцами, первый чуть раньше → под первым",
     seq(3, from: 0) { _ in [0: P(500, 500)] } + seq(10, from: 0.024) { _ in [0: P(500, 500), 1: P(550, 500)] } + [(0.11, [:])],
     expect: ["2-finger tap → rightClick @500,500"])

// Three fingers (your System Settings).
func three(_ n: Int, _ vx: Double, _ vy: Double) -> Frames {
    seq(n, from: 0) { k in let o = Double(k); return [0: P(600 + vx * o, 500 + vy * o), 1: P(660 + vx * o, 490 + vy * o), 2: P(720 + vx * o, 505 + vy * o)] }
}
test("3 пальца вверх", three(30, 0, -8) + [(0.3, [:])], expect: ["swipe 3 → missionControl"])
test("3 пальца вниз", three(30, 0, 8) + [(0.3, [:])], expect: ["swipe 3 → appExpose"])
test("3 пальца вниз, короткий (40 px)", three(10, 0, 4) + [(0.09, [:])], expect: ["swipe 3 (короткий, на отпускании) → appExpose"])
test("3 пальца вниз, короткий, пальцы уходят по очереди",
     three(10, 0, 4) + seq(6, from: 0.08) { _ in [0: P(600, 536), 1: P(660, 526)] } + seq(4, from: 0.128) { _ in [0: P(600, 536)] } + [(0.16, [:])],
     expect: ["swipe 3 (короткий, на отпускании) → appExpose"])
test("тап двумя пальцами, отпускание по очереди",
     seq(10, from: 0) { _ in [0: P(500, 500), 1: P(550, 500)] } + seq(5, from: 0.08) { _ in [1: P(550, 500)] } + [(0.12, [:])],
     expect: ["2-finger tap → rightClick"])
test("3 пальца влево", three(30, -8, 0) + [(0.3, [:])], expect: ["dock swipe horizontal"])


// Typing on the on-screen keyboard: the controller reuses id 0 for every new touch.
func keyTaps(_ pts: [CGPoint], gap: Double) -> Frames {
    var f: Frames = []; var t = 0.0
    for p in pts { f += seq(8, from: t) { _ in [0: p] }; t += 0.056; f.append((t, [:])); t += gap }
    return f + [(t + 0.4, [:])]
}
test("набор: соседние клавиши, паузы 40 мс", keyTaps([P(500, 500), P(545, 500), P(590, 505)], gap: 0.04),
     expect: ["tap ×1 @500,500", "tap ×1 @545,500", "tap ×1 @590,505"], forbid: ["drag", "2-finger", "multi"])
test("набор: соседние клавиши, паузы 20 мс", keyTaps([P(500, 500), P(540, 500), P(500, 545)], gap: 0.02),
     expect: ["tap ×1 @500,500", "tap ×1 @540,500", "tap ×1 @500,545"], forbid: ["drag", "2-finger", "multi"])
test("набор: одна клавиша дважды (пауза 120 мс)", keyTaps([P(500, 500), P(502, 501)], gap: 0.12),
     expect: ["tap ×1 @500,500", "tap ×2 @502,501"], forbid: ["drag"])
test("тап со сбоем контроллера 50 мс в середине",
     seq(5, from: 0) { _ in [0: P(500, 500)] } + seq(6, from: 0.04) { _ in [:] } + seq(6, from: 0.09) { _ in [0: P(501, 500)] } + [(0.4, [:])],
     expect: ["tap ×1 @500,500"], forbid: ["tap ×2", "drag"], counts: ["tap ×": 1])
test("быстрое перетаскивание со сбоем 60 мс",
     seq(25, from: 0) { k in [0: P(300 + Double(k) * 8, 500)] } + seq(7, from: 0.2) { _ in [:] }
     + seq(25, from: 0.256) { k in [0: P(300 + 32 * 8 + Double(k) * 8, 500)] } + [(0.6, [:])],
     expect: ["drag"], forbid: ["tap ×"], counts: ["drag": 1, "pointer": 1])


// On-screen keyboard typing mode (keyboard panel = 400…800 × 400…650).
test("клавиатура: быстрый набор 3 клавиш (паузы 30 мс)", keyTaps([P(500, 500), P(545, 500), P(590, 505)], gap: 0.03),
     expect: ["клавиатура: ↓ @500,500", "клавиатура: ↓ @545,500", "клавиатура: ↓ @590,505"],
     forbid: ["tap ×", "multi", "drag", "pointer"], counts: ["клавиатура: ↓": 3, "клавиатура: ↑": 3], typing: true)
test("клавиатура: следующая клавиша раньше, чем отпущена предыдущая",
     seq(12, from: 0) { _ in [0: P(500, 500)] } + seq(6, from: 0.096) { _ in [0: P(500, 500), 1: P(620, 520)] }
     + seq(10, from: 0.144) { _ in [1: P(620, 520)] } + [(0.4, [:])],
     expect: ["клавиатура: ↓ @500,500", "клавиатура: ↑ досрочно", "клавиатура: ↓ @620,520"],
     forbid: ["multi", "2-finger", "tap ×", "нажатие + тап"], counts: ["клавиатура: ↓": 2, "клавиатура: ↑": 2], typing: true)
test("клавиатура: долгое удержание клавиши — без правого клика",
     seq(120, from: 0) { _ in [0: P(500, 500)] } + [(1.0, [:])],
     expect: ["клавиатура: ↓ @500,500", "клавиатура: ↑"], forbid: ["hold", "rightClick", "tap ×"], typing: true)
test("клавиатура: перетаскивание панели",
     seq(30, from: 0) { k in [0: P(450 + Double(k) * 4, 410)] } + [(0.3, [:])],
     expect: ["клавиатура: ↓ @450,410", "клавиатура: перетаскивание"], forbid: ["drag", "pointer"], typing: true)
test("вне клавиатуры — обычный тап", keyTaps([P(100, 100)], gap: 0.05),
     expect: ["tap ×1 @100,100"], forbid: ["клавиатура"], typing: true)


// Dictation button (fake): fingers on it never become mouse events.
test("кнопка диктовки: тап по микрофону — без клика мышью", keyTaps([P(1838, 938)], gap: 0.05),
     expect: ["mic: main"], forbid: ["tap ×", "pointer", "drag"], mic: true)
test("кнопка диктовки: перетаскивание", seq(30, from: 0) { k in [0: P(1838 - Double(k) * 6, 938)] } + [(0.3, [:])],
     expect: ["mic: beginDrag", "mic: endDrag"], forbid: ["mic: main", "drag", "pointer"], mic: true)
test("кнопка диктовки: удержание — меню", seq(90, from: 0) { _ in [0: P(1838, 938)] } + [(0.75, [:])],
     expect: ["mic: menu"], forbid: ["mic: main", "hold", "rightClick"], mic: true)
test("кнопка диктовки: тап двумя пальцами — меню (второй палец мимо круга)",
     seq(3, from: 0) { _ in [0: P(1838, 938)] } + seq(8, from: 0.024) { _ in [0: P(1838, 938), 1: P(1900, 960)] } + [(0.1, [:])],
     expect: ["2-finger tap → rightClick @1838,938"], forbid: ["mic: main", "tap ×1"], mic: true)
test("кнопка диктовки: тап двумя пальцами одновременно — меню",
     seq(8, from: 0) { _ in [0: P(1838, 938), 1: P(1860, 950)] } + [(0.07, [:])],
     expect: ["2-finger tap → rightClick @1838,938"], forbid: ["mic: main", "tap ×1"], mic: true)
test("кнопка диктовки: первый палец мимо, второй на кнопке — правый клик по кнопке",
     seq(3, from: 0) { _ in [0: P(1760, 950)] } + seq(8, from: 0.024) { _ in [0: P(1760, 950), 1: P(1838, 938)] } + [(0.1, [:])],
     expect: ["2-finger tap → rightClick @1838,938"], forbid: ["mic: main", "tap ×1"], mic: true)
test("кнопка диктовки: крестик", keyTaps([P(1897, 995)], gap: 0.05),
     expect: ["mic: close"], forbid: ["tap ×", "mic: main"], mic: true)
test("язык под кнопкой: тап — список языков", keyTaps([P(1838, 995)], gap: 0.05),
     expect: ["mic: language"], forbid: ["tap ×", "mic: main"], mic: true)
test("список языков: выбор русского", keyTaps([P(1700, 920)], gap: 0.05),
     expect: ["mic: option(\"ru_RU\")"], forbid: ["tap ×"], mic: true)
test("мимо кнопки — список закрывается, тап обычный", keyTaps([P(1500, 930)], gap: 0.05),
     expect: ["mic: elsewhere", "tap ×1 @1500,930"], forbid: ["mic: main", "mic: language"], mic: true)

// Browser video: double-tap seeking.
func taps(_ pts: [CGPoint], every: Double = 0.2) -> Frames {
    var f: Frames = []
    for (i, p) in pts.enumerated() {
        let t0 = Double(i) * every
        f += seq(7, from: t0) { _ in [i: p] } + [(t0 + 0.06, [:])]
    }
    return f + [(Double(pts.count) * every + 0.5, [:])]
}
test("видео: двойной тап справа → вперёд", taps([P(1500, 500), P(1510, 505)]),
     expect: ["видео (youtube.com): двойной тап → вперёд [l]"], forbid: ["tap ×", "назад"], video: true)
test("видео: три тапа слева → назад ×2", taps([P(300, 500), P(310, 505), P(305, 500)]),
     expect: ["видео (youtube.com): двойной тап → назад [j]"], forbid: ["tap ×", "вперёд"], video: true)
test("видео: одиночный тап → обычный клик после ожидания", taps([P(1500, 500)]),
     expect: ["tap ×1"], forbid: ["двойной тап"], video: true)
test("видео: двойной тап в середине → двойной клик", taps([P(960, 500), P(965, 505)]),
     expect: ["видео: двойной тап в середине", "tap ×2"], forbid: ["вперёд", "назад"], video: true)
test("не видео (нижняя полоса): тап сразу", taps([P(960, 1050)]), expect: ["tap ×1"], forbid: ["двойной тап"], video: true)
DispatchQueue.main.async { next() }
RunLoop.main.run()
