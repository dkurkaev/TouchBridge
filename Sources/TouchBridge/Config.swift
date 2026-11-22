import Foundation

/// All distances are in screen points, times in seconds.
struct Config: Codable {
    // --- Device & screen ---
    var vendorID: Int? = nil              // limit to a specific touch controller (see `touchbridge list`)
    var productID: Int? = nil
    var displayName: String? = nil        // substring of the display name; default: the only external display
    var displayID: UInt32? = nil
    var swapXY = false                    // for portrait / rotated mounting
    var invertX = false
    var invertY = false
    var seize = true                      // take the touchscreen away from macOS' own mouse emulation
    var seizeSiblings = true
    var setInputMode = true               // switch the controller to multi-touch "Input Mode" if it has one
    var featureHandshake = true           // read Contact Count Max / Win8 blob features like Windows does
    var staleTouchTimeout = 1.5           // lift all fingers if the device goes silent (0 = off)
    var rematchLoneSlop = 30.0            // …but a lone finger only this close (+ its own motion): quick taps on neighbouring keys stay separate
    var rematchDistance = 250.0           // a finger returning after a dropout may land this far (pt) from where it vanished
    var liftGrace = 0.09                 // a finger that vanishes for less than this is treated as still down (0 = off);
                                          // ILITEK dropouts of a lone finger measured at 21–81 ms
    var liftGraceMulti = 0.14             // the same while several fingers are down: pairs drop out for up to ~136 ms

    // --- One finger: direct pointing ---
    var multiFingerWait = 0.12            // wait for more fingers before treating a touch as a pointer
    var lateSecondFingerWindow = 0.25     // a 2nd finger within this time still turns it into a 2-finger gesture
    var dragDelay = 0.15                  // don't start a 1-finger drag earlier than this (unless moved > dragFastDistance)
    var dragFastDistance = 40.0
    var tapSlop = 12.0
    var dragSlop = 8.0
    var tapMaxDuration = 0.35
    var doubleTapDistance = 30.0
    var longPressDelay = 0.6
    var longPressAction = "hold"          // "hold" = press-and-hold (see holdReleaseAction); or any action, see README
    var holdReleaseAction = "rightClick"  // hold, then lift without moving (moving drags instead);
                                          // "hold" = old behaviour: the left button goes down when the hold registers
    var holdFeedback = true               // show a ring under the finger when the hold registers

    // --- On-screen keyboard ---
    var keyboardTypingMode = true         // fingers on the Accessibility Keyboard type: each one a press of its own, no gestures

    // --- Videos in the browser ---
    var videoDoubleTapSeek = true         // double tap on the left / right of a video seeks back / forward
    var videoDoubleTapWindow = 0.35       // the first tap on a video waits this long for a second one
    var videoSeekChainWindow = 0.7        // further taps within this time keep seeking
    var videoSeekKeys = ["youtube.com": "j,l", "default": "left,right"] // the player's own seek shortcuts per site

    // --- Two fingers ---
    var scrollThreshold = 10.0
    var scrollSpeed = 1.0
    var momentum = true
    var momentumMinVelocity = 250.0       // pt/s
    var momentumFriction = 0.05           // fraction of velocity left after 1 s
    var pinchThreshold = 18.0             // change of average finger distance before zoom starts
    var pinchSpeed = 1.0
    var rotateThresholdDegrees = 14.0
    var rotateArcThreshold = 20.0         // …and each finger must travel this far around the centre (pt)
    var twoFingerDecisionDelay = 0.15     // if only one of two fingers moves, wait this long for the other one
    var twoFingerTap = "rightClick"
    var dominantHand = "right"            // a simultaneous two-finger tap clicks under the index finger: left of the two for "right"
    var pressAndTapGap = 0.08             // a finger that landed this much earlier than the other is the target (press, then tap)

    // --- Three / four fingers ---
    var useSystemGestures = true          // take 3/4/5-finger gestures and 3-finger tap/drag from System Settings → Trackpad;
                                          // the swipe*/pinchIn/pinchOut/threeFinger* keys below apply only when false
    var threeFingerDrag = false           // like the macOS accessibility option; swipes then use 4 fingers
    var threeFingerTap = "lookup"
    var fourFingerTap = "none"
    var swipeMode = "live"                // "live" = real Spaces / Mission Control animation, "discrete" = actions below
    var swipeThreshold = 25.0
    var discreteSwipeDistance = 80.0
    var dockSwipeGain = 1.6
    var dockSwipeInvertX = false
    var dockSwipeInvertY = false
    var swipeLeft = "spaceRight"          // fingers move left
    var swipeRight = "spaceLeft"
    var swipeUp = "missionControl"
    var swipeDown = "appExpose"
    var fourFingerPinchThreshold = 60.0
    var pinchIn = "launchpad"             // 4+ fingers pinch together
    var pinchOut = "showDesktop"          // 4+ fingers spread apart

    static var defaultPath: String {
        NSHomeDirectory() + "/.config/touchbridge/config.json"
    }

    static func load(path: String) -> Config {
        let defaults = Config()
        guard let data = FileManager.default.contents(atPath: path) else { return defaults }
        do {
            guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return defaults }
            let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any] ?? [:]
            let merged = base.merging(user) { _, new in new }
            let cfg = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
            let unknown = Set(user.keys).subtracting(Set(base.keys))
                .subtracting(["vendorID", "productID", "displayName", "displayID"])
            if !unknown.isEmpty { tlog("⚠️  Неизвестные ключи в конфиге: \(unknown.sorted().joined(separator: ", "))") }
            tlog("Конфиг: \(path)")
            return cfg
        } catch {
            tlog("⚠️  Ошибка в конфиге \(path): \(error). Использую значения по умолчанию.")
            return defaults
        }
    }

    static func writeDefaults(to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(Config())
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
