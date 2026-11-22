import AppKit
import CoreGraphics

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let builtin: Bool
    let bounds: CGRect
}

func allDisplays() -> [DisplayInfo] {
    NSScreen.screens.compactMap { s in
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(n.uint32Value)
        return DisplayInfo(id: id, name: s.localizedName, builtin: CGDisplayIsBuiltin(id) != 0,
                           bounds: CGDisplayBounds(id))
    }
}

/// Maps normalized touch coordinates to global screen points (top-left origin, like CGEvent).
final class ScreenMapper {
    private let cfg: Config
    private(set) var display: DisplayInfo?

    init(config: Config) {
        cfg = config
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let ds = allDisplays()
        let old = display?.id
        if let id = cfg.displayID, let d = ds.first(where: { $0.id == id }) {
            display = d
        } else if let name = cfg.displayName?.lowercased(),
                  let d = ds.first(where: { $0.name.lowercased().contains(name) }) {
            display = d
        } else {
            let external = ds.filter { !$0.builtin }
            if external.count > 1 {
                tlog("⚠️  Несколько внешних дисплеев — беру «\(external[0].name)». Укажи displayName в конфиге.")
            }
            display = external.first ?? ds.first
        }
        if let d = display, d.id != old {
            tlog("Сенсор привязан к дисплею «\(d.name)» (id \(d.id)), \(Int(d.bounds.width))×\(Int(d.bounds.height)) pt")
        }
    }

    var bounds: CGRect {
        guard let d = display else { return CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        return CGDisplayBounds(d.id)
    }

    func map(_ c: Contact) -> CGPoint {
        var x = c.x, y = c.y
        if cfg.swapXY { swap(&x, &y) }
        if cfg.invertX { x = 1 - x }
        if cfg.invertY { y = 1 - y }
        let b = bounds
        return CGPoint(x: b.minX + x * (b.width - 1), y: b.minY + y * (b.height - 1))
    }
}
