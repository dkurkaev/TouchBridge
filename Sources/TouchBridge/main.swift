import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

let usageText = """
TouchBridge — трекпад-жесты для USB сенсорных мониторов в macOS

Без аргументов запускается как приложение в строке меню.
Командная строка (для отладки):
  touchbridge list                 сенсорные устройства, их дескрипторы и дисплеи
  touchbridge monitor [--seize]    показать касания (ничего не эмулирует)
  touchbridge run [-v]             работать в терминале
  touchbridge test <имя>           проверить синтез событий под курсором через 3 с
  touchbridge init-config          записать конфиг по умолчанию
  touchbridge keyboard             показать/скрыть экранную клавиатуру
  touchbridge ax-probe             как браузеры показывают видео через Accessibility (диагностика)
  (keyboard и ax-probe нужно запускать через open -n TouchBridge.app --args …, чтобы работали разрешения приложения)
  --config <путь>, -v/--verbose
"""

var cliArgs = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }
var cliVerbose = false
var cliConfigPath = Config.defaultPath
var cliSeize = false
var positional: [String] = []
do {
    var i = 0
    while i < cliArgs.count {
        switch cliArgs[i] {
        case "-v", "--verbose": cliVerbose = true
        case "--seize": cliSeize = true
        case "--config":
            i += 1
            if i < cliArgs.count { cliConfigPath = (cliArgs[i] as NSString).expandingTildeInPath }
        case "-h", "--help", "help": print(usageText); exit(0)
        default: positional.append(cliArgs[i])
        }
        i += 1
    }
}

let app = NSApplication.shared
setvbuf(stdout, nil, _IOLBF, 0)

func listDevices() {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 0x0D] as CFDictionary)
    let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
    if devices.isEmpty { print("Не найдено HID-устройств класса Digitizer. Подключён ли USB-кабель сенсора?") }
    for d in devices.sorted(by: { registryID($0) < registryID($1) }) {
        print("\n=== \(deviceName(d))")
        let manuf: String = hidProp(d, kIOHIDManufacturerKey) ?? "?"
        let transport: String = hidProp(d, kIOHIDTransportKey) ?? "?"
        let loc: Int = hidProp(d, kIOHIDLocationIDKey) ?? 0
        print("    производитель: \(manuf), транспорт: \(transport), LocationID: 0x\(String(loc, radix: 16))")
        if let pairs: [[String: Int]] = hidProp(d, kIOHIDDeviceUsagePairsKey) {
            let s = pairs.map { String(format: "%02lX:%02lX", $0[kIOHIDDeviceUsagePageKey] ?? 0, $0[kIOHIDDeviceUsageKey] ?? 0) }
            print("    коллекции (page:usage): \(s.joined(separator: ", "))   (0D:04 = Touch Screen)")
        }
        guard let data: Data = hidProp(d, kIOHIDReportDescriptorKey) else { print("    нет дескриптора"); continue }
        let desc = HIDDescriptor(data: data)
        let layout = TouchLayout(desc)
        for (rid, r) in layout.reports.sorted(by: { $0.key < $1.key }) {
            let xr = r.slots.compactMap { $0.x }.first.map { "X \($0.logicalMin)…\($0.logicalMax)" } ?? ""
            let yr = r.slots.compactMap { $0.y }.first.map { "Y \($0.logicalMin)…\($0.logicalMax)" } ?? ""
            print("    отчёт #\(rid): слотов пальцев: \(r.slots.count), Contact Count: \(r.contactCount != nil ? "есть" : "нет"), \(xr), \(yr)")
        }
        if desc.featureFields.contains(where: { $0.usage == Usage.contactCountMax }) {
            print("    есть feature «Contact Count Maximum»")
        }
        if desc.featureFields.contains(where: { $0.usage == Usage.inputMode }) {
            print("    есть feature «Input Mode» (переключатель mouse/multi-touch)")
        }
        if cliVerbose { print("    дескриптор: " + data.map { String(format: "%02x", $0) }.joined(separator: " ")) }
    }
    print("\nДисплеи:")
    for d in allDisplays() {
        print("    id \(d.id)  «\(d.name)»  \(d.builtin ? "встроенный" : "внешний")  \(Int(d.bounds.width))×\(Int(d.bounds.height)) pt @ (\(Int(d.bounds.minX)),\(Int(d.bounds.minY)))")
    }
}

var cliBridge: Bridge?
var appDelegate: AppDelegate?
var sigtermSource: DispatchSourceSignal?

func cliCheckPermissions() {
    if !Permissions.inputMonitoring {
        Permissions.requestInputMonitoring()
        tlog("⚠️  Нужно разрешение «Мониторинг ввода» для Терминала. После выдачи перезапусти Терминал.")
    }
    if !Permissions.accessibility {
        Permissions.requestAccessibility()
        tlog("⚠️  Нужно разрешение «Универсальный доступ» для Терминала. После выдачи перезапусти Терминал.")
    }
}

switch positional.first {
case nil:
    app.setActivationPolicy(.accessory)
    let d = AppDelegate()
    appDelegate = d
    app.delegate = d
    // `pkill TouchBridge` (the build script) → quit properly: release the touchscreen, stop helpers.
    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler { NSApp.terminate(nil) }
    termSource.resume()
    sigtermSource = termSource
case "list":
    listDevices()
    exit(0)
case "init-config":
    do {
        if FileManager.default.fileExists(atPath: cliConfigPath) {
            print("Уже существует: \(cliConfigPath)")
        } else {
            try Config.writeDefaults(to: cliConfigPath)
            print("Записан: \(cliConfigPath)")
        }
    } catch { print("Ошибка: \(error)") }
    exit(0)
case "monitor":
    app.setActivationPolicy(.prohibited)
    let b = Bridge(configPath: cliConfigPath)
    b.verbose = cliVerbose
    cliBridge = b
    if !Permissions.inputMonitoring { cliCheckPermissions() }
    b.start(inject: false, seize: cliSeize)
case "run":
    app.setActivationPolicy(.prohibited)
    cliCheckPermissions()
    let b = Bridge(configPath: cliConfigPath)
    b.verbose = cliVerbose
    cliBridge = b
    if Permissions.all {
        b.start()
    } else {
        tlog("❌ Не запускаю: без обоих разрешений сенсор перестал бы работать совсем.")
        exit(1)
    }
case "keyboard":
    // Diagnostics: toggle the on-screen keyboard from a separate instance
    // (`open -n TouchBridge.app --args keyboard`), then report the floating windows on screen.
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let r = OnScreenKeyboard.toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let floating = list.compactMap { w -> String? in
                let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                let layer = w[kCGWindowLayer as String] as? Int ?? 0
                guard layer > 0, layer != 25, (b["Height"] ?? 0) > 100 else { return nil }
                return "\(w[kCGWindowOwnerName as String] ?? "?") \(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0)) слой \(layer)"
            }
            tlog("keyboard: результат \(r), плавающие окна: \(floating)")
            exit(0)
        }
    }
case "ax-dictation":
    // Diagnostics: which running apps have "Start Dictation…" in their menus (nothing is pressed).
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            let el = AXUIElementCreateApplication(a.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.5)
            guard let barRef = AX.attr(el, kAXMenuBarAttribute) else { tlog("ax-dictation: \(a.localizedName ?? "?"): нет меню"); continue }
            var found: [String] = []
            for top in AX.children(barRef as! AXUIElement) {
                for menu in AX.children(top) {
                    for item in AX.children(menu) {
                        let t = AX.string(item, kAXTitleAttribute) ?? ""
                        let id = AX.string(item, "AXIdentifier") ?? ""
                        if t.localizedCaseInsensitiveContains("dictation") || t.localizedCaseInsensitiveContains("диктовк") || id.contains("ictation") {
                            found.append("«\(AX.string(top, kAXTitleAttribute) ?? "")» → «\(t)» id=\(id)")
                        }
                    }
                }
            }
            tlog("ax-dictation: \(a.localizedName ?? "?") [\(a.bundleIdentifier ?? "")]: " + (found.isEmpty ? "нет пункта диктовки" : found.joined(separator: "; ")))
        }
        let t0 = ProcessInfo.processInfo.systemUptime
        let f = Dictation.findItem()
        tlog("ax-dictation: активное приложение «\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")»: "
             + (f.map { "пункт «\($0.2)» найден" } ?? "пункт не найден") + " за \(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)) мс")
        exit(0)
    }
case "render-dictation":
    let dir = URL(fileURLWithPath: positional.count > 1 ? positional[1] : NSTemporaryDirectory())
    DictationPreview.render(to: dir)
    print("PNG: \(dir.path)")
    exit(0)
case "ax-probe":
    // Diagnostics: how browsers expose <video> through Accessibility, and what a tap on it hits.
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let browsers = NSWorkspace.shared.runningApplications.filter {
            ["com.apple.Safari", "com.google.Chrome"].contains($0.bundleIdentifier ?? "")
        }
        for b in browsers {
            let appEl = AXUIElementCreateApplication(b.processIdentifier)
            if b.bundleIdentifier == "com.google.Chrome" {
                AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                usleep(500_000)
            }
            let wins = (AX.attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            tlog("ax-probe: \(b.localizedName ?? "?"): окон \(wins.count)")
            for w in wins {
                tlog("ax-probe:   окно «\(AX.string(w, kAXTitleAttribute) ?? "")» \(AX.frame(w).map { "\($0)" } ?? "")")
                var queue: [(AXUIElement, Int)] = [(w, 0)]
                var seen = 0
                var videos: [AXUIElement] = []
                while !queue.isEmpty && seen < 6000 {
                    let (e, d) = queue.removeFirst()
                    seen += 1
                    let role = AX.string(e, kAXRoleAttribute) ?? ""
                    let sub = AX.string(e, kAXSubroleAttribute) ?? ""
                    let desc = (AX.string(e, kAXRoleDescriptionAttribute) ?? "").lowercased()
                    if role == "AXWebArea" { tlog("ax-probe:     веб-область url=\((AX.attr(e, "AXURL") as? URL)?.absoluteString ?? "?")") }
                    if desc.contains("video") || desc.contains("видео") || sub.lowercased().contains("video") || role.lowercased().contains("video") {
                        videos.append(e)
                        tlog("ax-probe:     ВИДЕО (глубина \(d)): \(AX.describe(e))")
                    }
                    if d < 40 { queue += AX.children(e).map { ($0, d + 1) } }
                }
                tlog("ax-probe:     просмотрено узлов: \(seen)")
                for v in videos.prefix(2) {
                    guard let f = AX.frame(v), f.width > 50 else { continue }
                    let vt = VideoTaps(config: Config.load(path: cliConfigPath), synth: EventSynth())
                    for x in [0.2, 0.5, 0.8] {
                        let pt = CGPoint(x: f.minX + f.width * x, y: f.midY)
                        let t0 = ProcessInfo.processInfo.systemUptime
                        let t = vt.videoTarget(at: pt)
                        let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
                        tlog("ax-probe:     videoTarget(\(Int(pt.x)),\(Int(pt.y))) за \(ms) мс → " + (t.map { "сайт \($0.host), клавиши \($0.back)/\($0.forward), рамка \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "nil"))
                    }
                    for (name, pt) in [("центр", CGPoint(x: f.midX, y: f.midY)), ("слева", CGPoint(x: f.minX + f.width * 0.15, y: f.midY)),
                                       ("справа", CGPoint(x: f.maxX - f.width * 0.15, y: f.midY))] {
                        guard var e = AX.element(at: pt, timeout: 0.5) else { tlog("ax-probe:     попадание \(name): ничего"); continue }
                        var chain: [String] = []
                        for _ in 0..<8 {
                            chain.append(AX.describe(e))
                            guard let p = AX.parent(e) else { break }
                            e = p
                        }
                        tlog("ax-probe:     попадание \(name) \(Int(pt.x)),\(Int(pt.y)):\n        " + chain.joined(separator: "\n        ↑ "))
                    }
                }
            }
        }
        exit(0)
    }
case "test":
    app.setActivationPolicy(.prohibited)
    guard positional.count >= 2 else { print(usageText); exit(1) }
    cliCheckPermissions()
    Tester.run(positional[1], config: Config.load(path: cliConfigPath)) { exit(0) }
default:
    print(usageText)
    exit(1)
}

signal(SIGINT) { _ in
    cliBridge?.stop()
    exit(0)
}
app.run()
