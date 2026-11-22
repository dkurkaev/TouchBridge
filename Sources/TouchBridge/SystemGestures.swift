import Foundation

/// The user's own trackpad gesture settings (System Settings → Trackpad / Dock), so that the
/// touchscreen does exactly what their trackpad does. Read on every (re)start of the bridge.
struct SystemGestures {
    enum Horizontal: String { case off = "выкл", pages = "страницы", spaces = "рабочие столы" }

    var threeVertical = true          // swipe up: Mission Control, down: App Exposé
    var fourVertical = true
    var threeHorizontal = Horizontal.spaces
    var fourHorizontal = Horizontal.spaces
    var threeFingerTap = false        // Look up
    var threeFingerDrag = false
    var fourPinch = true              // pinch: Launchpad, spread: Show Desktop
    var fivePinch = true
    var pinchZoom = true
    var rotate = true
    var missionControl = true
    var appExpose = false
    var launchpad = true
    var showDesktop = true

    static func read() -> SystemGestures {
        func int(_ key: String) -> Int? {
            // Built-in trackpad first, then the Magic Trackpad domain.
            for d in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
                if let v = CFPreferencesCopyAppValue(key as CFString, d as CFString) as? Int { return v }
            }
            return nil
        }
        func dock(_ key: String, _ def: Bool) -> Bool {
            (CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? Bool) ?? def
        }
        func horizontal(_ v: Int?) -> Horizontal {
            switch v {
            case 0?: return .off
            case 1?: return .pages
            default: return .spaces
            }
        }
        var s = SystemGestures()
        s.threeVertical = (int("TrackpadThreeFingerVertSwipeGesture") ?? 2) != 0
        s.fourVertical = (int("TrackpadFourFingerVertSwipeGesture") ?? 2) != 0
        s.threeHorizontal = horizontal(int("TrackpadThreeFingerHorizSwipeGesture"))
        s.fourHorizontal = horizontal(int("TrackpadFourFingerHorizSwipeGesture"))
        s.threeFingerTap = (int("TrackpadThreeFingerTapGesture") ?? 0) != 0
        s.threeFingerDrag = (int("TrackpadThreeFingerDrag") ?? 0) != 0
        s.fourPinch = (int("TrackpadFourFingerPinchGesture") ?? 2) != 0
        s.fivePinch = (int("TrackpadFiveFingerPinchGesture") ?? 2) != 0
        s.pinchZoom = (int("TrackpadPinch") ?? 1) != 0
        s.rotate = (int("TrackpadRotate") ?? 1) != 0
        s.missionControl = dock("showMissionControlGestureEnabled", true)
        s.appExpose = dock("showAppExposeGestureEnabled", false)
        s.launchpad = dock("showLaunchpadGestureEnabled", true)
        s.showDesktop = dock("showDesktopGestureEnabled", true)
        return s
    }

    func verticalEnabled(fingers n: Int) -> Bool { n == 3 ? threeVertical : fourVertical }
    func horizontal(fingers n: Int) -> Horizontal { n == 3 ? threeHorizontal : fourHorizontal }
    func pinchEnabled(fingers n: Int) -> Bool { n == 4 ? fourPinch : fivePinch }

    var summary: String {
        func on(_ b: Bool) -> String { b ? "вкл" : "выкл" }
        return "Жесты из настроек трекпада: 3 пальца ↑↓ \(on(threeVertical)), ←→ \(threeHorizontal.rawValue); "
            + "4 пальца ↑↓ \(on(fourVertical)), ←→ \(fourHorizontal.rawValue); "
            + "Mission Control \(on(missionControl)), App Exposé \(on(appExpose)); "
            + "тап 3 пальцами (Найти) \(on(threeFingerTap)); перетаскивание 3 пальцами \(on(threeFingerDrag)); "
            + "щипок 4/5 пальцев \(on(fourPinch))/\(on(fivePinch)); зум \(on(pinchZoom)), поворот \(on(rotate))"
    }
}
