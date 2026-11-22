import Foundation
import IOKit
import IOKit.hid

/// One finger, normalized 0...1 in the touch sensor's coordinate space.
struct Contact {
    let id: Int
    let x: Double
    let y: Double
}

func hidProp<T>(_ d: IOHIDDevice, _ key: String) -> T? {
    IOHIDDeviceGetProperty(d, key as CFString) as? T
}

func registryID(_ d: IOHIDDevice) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &id)
    return id
}

func deviceName(_ d: IOHIDDevice) -> String {
    let product: String = hidProp(d, kIOHIDProductKey) ?? "?"
    let vid: Int = hidProp(d, kIOHIDVendorIDKey) ?? 0
    let pid: Int = hidProp(d, kIOHIDProductIDKey) ?? 0
    return String(format: "%@ [%04lX:%04lX]", product, vid, pid)
}

/// Assembles complete frames, including "hybrid mode" where one frame is split across several reports.
final class FrameAssembler {
    let layout: TouchLayout
    private var pending: [(active: Bool, c: Contact)] = []
    private var expected = 0

    init(layout: TouchLayout) { self.layout = layout }

    /// Returns active contacts when a frame is complete, nil otherwise.
    func feed(reportID: UInt8, bytes: UnsafeBufferPointer<UInt8>, usesReportIDs: Bool) -> [Contact]? {
        guard let rep = layout.reports[reportID] else { return nil }
        let base = (usesReportIDs && bytes.count > 0 && bytes[0] == reportID) ? 8 : 0

        var slots: [(active: Bool, c: Contact)] = []
        for (i, s) in rep.slots.enumerated() {
            guard let fx = s.x, let fy = s.y else { continue }
            let tip = s.tip.map { $0.read(bytes, baseBit: base) != 0 } ?? true
            let id = s.contactID.map { Int($0.read(bytes, baseBit: base)) } ?? i
            let c = Contact(id: id, x: fx.normalized(fx.read(bytes, baseBit: base)),
                            y: fy.normalized(fy.read(bytes, baseBit: base)))
            slots.append((tip, c))
        }

        guard let ccField = rep.contactCount else {
            return Self.dedupe(slots.filter { $0.active }.map { $0.c })
        }
        let count = Int(ccField.read(bytes, baseBit: base))
        // Whole frame fits into one report (the common case, e.g. ILITEK with 10 slots):
        // don't rely on active contacts being packed into the first `count` slots.
        if expected == 0 && count <= slots.count {
            let active = slots.filter { $0.active }.map { $0.c }
            return Self.dedupe(Array(active.prefix(max(count, 0))))
        }
        if count > 0 {
            pending = []
            expected = count
        } else if expected == 0 {
            // Stand-alone report without a contact count (e.g. "all lifted").
            return Self.dedupe(slots.filter { $0.active }.map { $0.c })
        }
        let take = max(0, min(slots.count, expected - pending.count))
        pending.append(contentsOf: slots.prefix(take))
        if pending.count >= expected {
            let frame = pending.filter { $0.active }.map { $0.c }
            pending = []
            expected = 0
            return Self.dedupe(frame)
        }
        return nil
    }

    /// Compact decoding of one report for the verbose log. `sig` changes whenever the set of
    /// touching slots or the contact count changes.
    func describe(reportID: UInt8, bytes: UnsafeBufferPointer<UInt8>, usesReportIDs: Bool) -> (sig: String, text: String)? {
        guard let rep = layout.reports[reportID] else { return nil }
        let base = (usesReportIDs && bytes.count > 0 && bytes[0] == reportID) ? 8 : 0
        let cc = rep.contactCount.map { String($0.read(bytes, baseBit: base)) } ?? "-"
        let st = rep.scanTime.map { String($0.read(bytes, baseBit: base)) } ?? "-"
        var parts: [String] = []
        var sig: [String] = []
        for (i, s) in rep.slots.enumerated() {
            guard let fx = s.x, let fy = s.y else { continue }
            let tip = s.tip.map { $0.read(bytes, baseBit: base) != 0 } ?? true
            let id = s.contactID.map { Int($0.read(bytes, baseBit: base)) } ?? i
            let x = fx.read(bytes, baseBit: base), y = fy.read(bytes, baseBit: base)
            if !tip && x == 0 && y == 0 && id == 0 { continue }
            parts.append("s\(i):id\(id)\(tip ? "↓" : "↑")(\(x),\(y))")
            if tip { sig.append("\(i):\(id)") }
        }
        return ("cc\(cc) " + sig.joined(separator: " "),
                "cc=\(cc) scan=\(st) " + (parts.isEmpty ? "(пусто)" : parts.joined(separator: " ")))
    }

    private static func dedupe(_ cs: [Contact]) -> [Contact] {
        var seen = Set<Int>()
        return cs.enumerated().map { i, c in
            if seen.insert(c.id).inserted { return c }
            return Contact(id: c.id + 1000 * (i + 1), x: c.x, y: c.y)
        }
    }
}

final class DeviceContext {
    let device: IOHIDDevice
    let descriptor: HIDDescriptor
    let layout: TouchLayout
    let assembler: FrameAssembler
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int
    weak var owner: TouchHID?
    var siblings: [IOHIDDevice] = []

    init(device: IOHIDDevice, descriptor: HIDDescriptor) {
        self.device = device
        self.descriptor = descriptor
        self.layout = TouchLayout(descriptor)
        self.assembler = FrameAssembler(layout: layout)
        let maxIn: Int = hidProp(device, kIOHIDMaxInputReportSizeKey) ?? 256
        bufferSize = max(maxIn, 64)
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit { buffer.deallocate() }

    private var gotFirstReport = false
    private var sawContacts = false
    /// The sibling "mouse" interface is seized only once the digitizer has proven it sends touches,
    /// otherwise a controller that is still in mouse mode would leave the screen completely dead.
    var siblingSeizePending = false
    /// Verbose: log decoded raw reports whenever the touching slots / contact count change.
    var debugRaw = false
    private var lastSig = ""
    private var lastText = ""
    private var lastLogged = true

    func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        let bytes = UnsafeBufferPointer(start: report, count: length)
        if !gotFirstReport {
            gotFirstReport = true
            tlog("Первый мультитач-отчёт от дигитайзера (#\(reportID), \(length) байт): "
                 + bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        owner?.rawReport(self, reportID: UInt8(truncatingIfNeeded: reportID), bytes: bytes)
        if debugRaw, let d = assembler.describe(reportID: UInt8(truncatingIfNeeded: reportID), bytes: bytes,
                                                usesReportIDs: descriptor.usesReportIDs) {
            if d.sig != lastSig {
                if !lastLogged && !lastText.isEmpty { tlog("    raw … \(lastText)") }
                tlog("    raw → \(d.text)")
                lastLogged = true
            } else {
                lastLogged = false
            }
            lastSig = d.sig
            lastText = d.text
        }
        if let frame = assembler.feed(reportID: UInt8(truncatingIfNeeded: reportID), bytes: bytes,
                                      usesReportIDs: descriptor.usesReportIDs) {
            if !frame.isEmpty && !sawContacts {
                sawContacts = true
                tlog("Дигитайзер передаёт касания: \(frame.count) пальц.")
            }
            if siblingSeizePending && sawContacts && frame.isEmpty {
                siblingSeizePending = false
                owner?.seizeSiblings(of: self)
            }
            owner?.onFrame?(frame)
        }
    }
}

final class TouchHID {
    var onFrame: (([Contact]) -> Void)?
    var onRaw: ((DeviceContext, UInt8, UnsafeBufferPointer<UInt8>) -> Void)?
    private let cfg: Config
    private let seize: Bool
    private let manager: IOHIDManager
    private var contexts: [UInt64: DeviceContext] = [:]
    let verbose: Bool

    init(config: Config, seize: Bool, verbose: Bool) {
        cfg = config
        self.seize = seize
        self.verbose = verbose
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    static func matching(_ cfg: Config) -> [String: Any] {
        var m: [String: Any] = [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x04]
        if let v = cfg.vendorID { m[kIOHIDVendorIDKey] = v }
        if let p = cfg.productID { m[kIOHIDProductIDKey] = p }
        return m
    }

    var connectedNames: [String] { contexts.values.map { deviceName($0.device) } }
    private var retired: [DeviceContext] = []

    func stop() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        for dc in contexts.values {
            for s in dc.siblings { IOHIDDeviceClose(s, IOOptionBits(kIOHIDOptionsTypeNone)) }
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        retired.append(contentsOf: contexts.values) // keep buffers alive
        contexts.removeAll()
        tlog("Сенсор отпущен — macOS снова управляет им сама")
    }

    func rawReport(_ dc: DeviceContext, reportID: UInt8, bytes: UnsafeBufferPointer<UInt8>) {
        onRaw?(dc, reportID, bytes)
    }

    func start() {
        IOHIDManagerSetDeviceMatching(manager, Self.matching(cfg) as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<TouchHID>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<TouchHID>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, ctx)
        // commonModes: keep reading the sensor while a menu or modal panel runs its own event loop —
        // with defaultMode touches froze (and could not close the menu) whenever a menu was open.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        var r = IOHIDManagerOpen(manager, IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess && seize {
            tlog("⚠️  Не удалось захватить устройство эксклюзивно (\(hex(r))). macOS тоже будет получать касания как мышь.")
            r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if r != kIOReturnSuccess {
            tlog("❌ IOHIDManagerOpen: \(hex(r)). Проверь разрешение «Мониторинг ввода» (Input Monitoring).")
        }
        tlog("Жду сенсорный экран…")
    }

    private func added(_ device: IOHIDDevice) {
        let rid = registryID(device)
        guard contexts[rid] == nil else { return }
        guard let data: Data = hidProp(device, kIOHIDReportDescriptorKey) else {
            tlog("⚠️  \(deviceName(device)): нет ReportDescriptor, пропускаю")
            return
        }
        let desc = HIDDescriptor(data: data)
        let dc = DeviceContext(device: device, descriptor: desc)
        guard !dc.layout.reports.isEmpty else {
            tlog("⚠️  \(deviceName(device)): не нашёл в дескрипторе X/Y касаний, пропускаю")
            return
        }
        dc.owner = self
        dc.debugRaw = verbose
        contexts[rid] = dc
        let slots = dc.layout.reports.values.map { $0.slots.count }.reduce(0, +)
        tlog("✅ Подключен: \(deviceName(device)), слотов пальцев в отчётах: \(slots)")

        IOHIDDeviceRegisterInputReportCallback(device, dc.buffer, dc.bufferSize, { ctx, _, _, _, reportID, report, length in
            Unmanaged<DeviceContext>.fromOpaque(ctx!).takeUnretainedValue()
                .handle(reportID: reportID, report: report, length: length)
        }, Unmanaged.passUnretained(dc).toOpaque())

        if cfg.featureHandshake { featureHandshake(dc) }
        if cfg.setInputMode { setInputMode(dc) }
        if seize && cfg.seizeSiblings {
            dc.siblingSeizePending = true
            tlog("Интерфейс-мышь контроллера пока оставляю macOS — захвачу после первых мультитач-касаний")
        }
    }

    /// Windows and Linux (hid-multitouch: "Retrieve the Win8 blob once to enable some devices") read
    /// these feature reports right after enumeration. Many Win8-certified controllers stay in
    /// single-pointer mouse mode until that happens — which is what macOS gets by default.
    private func featureHandshake(_ dc: DeviceContext) {
        let d = dc.descriptor
        let wanted: Set<UInt32> = [Usage.contactCountMax, Usage.win8Blob]
        let rids = Set(d.featureFields.filter { wanted.contains($0.usage) }.map { $0.reportID }).sorted()
        for rid in rids {
            let bits = d.featureReportBits[rid] ?? 0
            let len = max((bits + 7) / 8 + (d.usesReportIDs ? 1 : 0), 2)
            var buf = [UInt8](repeating: 0, count: len)
            if d.usesReportIDs { buf[0] = rid }
            var l = CFIndex(len)
            let r = IOHIDDeviceGetReport(dc.device, kIOHIDReportTypeFeature, CFIndex(rid), &buf, &l)
            guard r == kIOReturnSuccess else {
                tlog("⚠️  Не удалось прочитать feature-отчёт #\(rid) (\(hex(r)))")
                continue
            }
            var info = ""
            if let f = d.featureFields.first(where: { $0.reportID == rid && $0.usage == Usage.contactCountMax }) {
                info = ", Contact Count Maximum = \(buf.withUnsafeBufferPointer { f.read($0, baseBit: d.usesReportIDs ? 8 : 0) })"
            }
            tlog("Прочитал feature-отчёт #\(rid) (\(l) байт)\(info) — включение мультитача, как в Windows/Linux")
        }
    }

    private func removed(_ device: IOHIDDevice) {
        let rid = registryID(device)
        guard let dc = contexts.removeValue(forKey: rid) else { return }
        for s in dc.siblings { IOHIDDeviceClose(s, IOOptionBits(kIOHIDOptionsTypeNone)) }
        tlog("Отключен: \(deviceName(device))")
        onFrame?([])
    }

    /// Windows-style "Input Mode" feature: 0 = mouse, 1 = single input, 2 = multi-input (touch).
    private func setInputMode(_ dc: DeviceContext) {
        let d = dc.descriptor
        guard let f = d.featureFields.first(where: { $0.usage == Usage.inputMode }) else { return }
        let rid = f.reportID
        let bits = d.featureReportBits[rid] ?? 0
        let hasID = d.usesReportIDs
        let len = (bits + 7) / 8 + (hasID ? 1 : 0)
        var buf = [UInt8](repeating: 0, count: len)
        if hasID { buf[0] = rid }
        var l = CFIndex(len)
        let gr = IOHIDDeviceGetReport(dc.device, kIOHIDReportTypeFeature, CFIndex(rid), &buf, &l)
        if gr != kIOReturnSuccess {
            buf = [UInt8](repeating: 0, count: len)
            if hasID { buf[0] = rid }
        }
        let base = hasID ? 8 : 0
        let current = buf.withUnsafeBufferPointer { f.read($0, baseBit: base) }
        if gr == kIOReturnSuccess && current == 2 {
            if verbose { tlog("Input Mode уже = 2 (multi-touch)") }
            return
        }
        f.write(2, into: &buf, baseBit: base)
        for idx in d.featureFields where idx.reportID == rid && idx.usage == Usage.deviceIndex {
            idx.write(0, into: &buf, baseBit: base)
        }
        let sr = IOHIDDeviceSetReport(dc.device, kIOHIDReportTypeFeature, CFIndex(rid), buf, len)
        tlog(sr == kIOReturnSuccess ? "Переключил Input Mode → multi-touch (было \(current))"
                                   : "⚠️  Не удалось выставить Input Mode (\(hex(sr)))")
    }

    /// Composite touch boards often also expose a separate "mouse" interface. Seize it so macOS
    /// doesn't move the cursor / click on its own while we are handling touches.
    func seizeSiblings(of dc: DeviceContext) {
        guard let vid: Int = hidProp(dc.device, kIOHIDVendorIDKey),
              let pid: Int = hidProp(dc.device, kIOHIDProductIDKey) else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return }
        let me = registryID(dc.device)
        let myLocation: Int? = hidProp(dc.device, kIOHIDLocationIDKey)
        for s in set where registryID(s) != me && contexts[registryID(s)] == nil {
            let loc: Int? = hidProp(s, kIOHIDLocationIDKey)
            if let a = myLocation, let b = loc, a != b { continue }
            let r = IOHIDDeviceOpen(s, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if r == kIOReturnSuccess {
                dc.siblings.append(s)
                let pu: Int = hidProp(s, kIOHIDPrimaryUsagePageKey) ?? 0
                let u: Int = hidProp(s, kIOHIDPrimaryUsageKey) ?? 0
                tlog("  + захвачен соседний интерфейс (usage \(String(pu, radix: 16)):\(String(u, radix: 16)))")
            }
        }
    }
}

func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }
