import Foundation

/// Full 32-bit usage: (usagePage << 16) | usageID
enum Usage {
    static let genericDesktopX: UInt32 = 0x0001_0030
    static let genericDesktopY: UInt32 = 0x0001_0031
    static let touchScreen: UInt32 = 0x000D_0004
    static let deviceConfiguration: UInt32 = 0x000D_000E
    static let finger: UInt32 = 0x000D_0022
    static let tipSwitch: UInt32 = 0x000D_0042
    static let confidence: UInt32 = 0x000D_0047
    static let contactID: UInt32 = 0x000D_0051
    static let inputMode: UInt32 = 0x000D_0052
    static let deviceIndex: UInt32 = 0x000D_0053
    static let contactCount: UInt32 = 0x000D_0054
    static let contactCountMax: UInt32 = 0x000D_0055
    static let scanTime: UInt32 = 0x000D_0056
    /// Vendor feature with the Windows 8 touch certification (THQA) blob.
    static let win8Blob: UInt32 = 0xFF00_00C5
}

struct HIDField {
    let reportID: UInt8
    let bitOffset: Int      // offset inside the report payload (after the report-ID byte)
    let bitSize: Int
    let usage: UInt32
    let logicalMin: Int64
    let logicalMax: Int64
    let isConstant: Bool
    let isVariable: Bool
    let fingerIndex: Int?   // index of the enclosing "Finger" logical collection
    let topCollection: UInt32

    func read(_ r: UnsafeBufferPointer<UInt8>, baseBit: Int) -> Int64 {
        let size = min(bitSize, 63)
        guard size > 0 else { return 0 }
        let start = baseBit + bitOffset
        var v: UInt64 = 0
        for b in 0..<size {
            let bit = start + b
            let byte = bit >> 3
            if byte >= r.count { break }
            if (r[byte] >> UInt8(bit & 7)) & 1 == 1 { v |= (1 as UInt64) << UInt64(b) }
        }
        if logicalMin < 0, (v >> UInt64(size - 1)) & 1 == 1 {
            return Int64(bitPattern: v | (~(0 as UInt64) << UInt64(size)))
        }
        return Int64(bitPattern: v)
    }

    func write(_ value: Int64, into buf: inout [UInt8], baseBit: Int) {
        let v = UInt64(bitPattern: value)
        for b in 0..<min(bitSize, 64) {
            let bit = baseBit + bitOffset + b
            let byte = bit >> 3
            if byte >= buf.count { break }
            let mask = UInt8(1 << (bit & 7))
            if (v >> UInt64(b)) & 1 == 1 { buf[byte] |= mask } else { buf[byte] &= ~mask }
        }
    }

    /// Normalized 0...1 position for X/Y fields.
    func normalized(_ raw: Int64) -> Double {
        let span = Double(logicalMax - logicalMin)
        guard span > 0 else { return 0 }
        return min(max(Double(raw - logicalMin) / span, 0), 1)
    }
}

/// Minimal HID report descriptor parser (enough for Windows-compatible touch screens).
struct HIDDescriptor {
    var inputFields: [HIDField] = []
    var featureFields: [HIDField] = []
    var usesReportIDs = false
    var inputReportBits: [UInt8: Int] = [:]
    var featureReportBits: [UInt8: Int] = [:]
    var topCollections: [UInt32] = []

    init(data: Data) {
        let bytes = [UInt8](data)

        struct Globals {
            var usagePage: UInt32 = 0
            var logMin: Int64 = 0
            var logMax: Int64 = 0
            var logMaxUnsigned: UInt32 = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        struct LocalUsage { let value: UInt32; let hasPage: Bool }

        var g = Globals()
        var stack: [Globals] = []
        var usages: [LocalUsage] = []
        var usageMin: LocalUsage?
        var usageMax: LocalUsage?
        var collections: [(usage: UInt32, finger: Int?)] = []
        var fingerCounter = 0
        var topCollection: UInt32 = 0
        var outputBits: [UInt8: Int] = [:]

        func resolve(_ u: LocalUsage) -> UInt32 { u.hasPage ? u.value : (g.usagePage << 16) | (u.value & 0xFFFF) }

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { // long item
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            var size = Int(prefix & 0x3)
            if size == 3 { size = 4 }
            let type = (prefix >> 2) & 0x3
            let tag = prefix >> 4
            guard i + size < bytes.count else { break }
            var uval: UInt32 = 0
            for k in 0..<size { uval |= UInt32(bytes[i + 1 + k]) << (8 * UInt32(k)) }
            let sval: Int64
            switch size {
            case 1: sval = Int64(Int8(truncatingIfNeeded: uval))
            case 2: sval = Int64(Int16(truncatingIfNeeded: uval))
            case 4: sval = Int64(Int32(truncatingIfNeeded: uval))
            default: sval = 0
            }
            i += 1 + size

            switch type {
            case 0: // Main
                switch tag {
                case 0xA: // Collection
                    let u = usages.first.map(resolve) ?? 0
                    if collections.isEmpty { topCollection = u; topCollections.append(u) }
                    var finger = collections.last?.finger
                    if u == Usage.finger { finger = fingerCounter; fingerCounter += 1 }
                    collections.append((u, finger))
                case 0xC: // End collection
                    if !collections.isEmpty { collections.removeLast() }
                case 0x8, 0x9, 0xB: // Input, Output, Feature
                    if g.reportID != 0 { usesReportIDs = true }
                    let isConst = uval & 0x1 != 0
                    let isVar = uval & 0x2 != 0
                    let logMax = (g.logMax < g.logMin && g.logMin >= 0) ? Int64(g.logMaxUnsigned) : g.logMax
                    let resolved = usages.map(resolve)
                    let uMin = usageMin.map(resolve)
                    let uMax = usageMax.map(resolve)
                    var pos: Int
                    switch tag {
                    case 0x8: pos = inputReportBits[g.reportID] ?? 0
                    case 0xB: pos = featureReportBits[g.reportID] ?? 0
                    default: pos = outputBits[g.reportID] ?? 0
                    }
                    for n in 0..<max(g.reportCount, 0) {
                        var usage: UInt32 = 0
                        if !resolved.isEmpty {
                            usage = isVar ? resolved[min(n, resolved.count - 1)] : resolved[0]
                        } else if let a = uMin, let b = uMax {
                            usage = isVar ? min(a + UInt32(n), b) : a
                        }
                        let f = HIDField(reportID: g.reportID, bitOffset: pos, bitSize: g.reportSize, usage: usage,
                                         logicalMin: g.logMin, logicalMax: logMax, isConstant: isConst,
                                         isVariable: isVar, fingerIndex: collections.last?.finger,
                                         topCollection: topCollection)
                        if tag == 0x8, !isConst { inputFields.append(f) }
                        if tag == 0xB, !isConst { featureFields.append(f) }
                        pos += g.reportSize
                    }
                    switch tag {
                    case 0x8: inputReportBits[g.reportID] = pos
                    case 0xB: featureReportBits[g.reportID] = pos
                    default: outputBits[g.reportID] = pos
                    }
                default: break
                }
                usages = []; usageMin = nil; usageMax = nil
            case 1: // Global
                switch tag {
                case 0x0: g.usagePage = uval
                case 0x1: g.logMin = sval
                case 0x2: g.logMax = sval; g.logMaxUnsigned = uval
                case 0x7: g.reportSize = Int(uval)
                case 0x8: g.reportID = UInt8(truncatingIfNeeded: uval)
                case 0x9: g.reportCount = Int(uval)
                case 0xA: stack.append(g)
                case 0xB: if let s = stack.popLast() { g = s }
                default: break
                }
            case 2: // Local
                let lu = LocalUsage(value: uval, hasPage: size == 4)
                switch tag {
                case 0x0: usages.append(lu)
                case 0x1: usageMin = lu
                case 0x2: usageMax = lu
                default: break
                }
            default: break
            }
        }
    }
}

/// Touch-specific view on the descriptor: which bits hold which finger's data.
struct TouchLayout {
    struct Slot {
        var tip: HIDField?
        var contactID: HIDField?
        var x: HIDField?
        var y: HIDField?
    }
    struct Report {
        var slots: [Slot] = []
        var contactCount: HIDField?
        var scanTime: HIDField?
    }
    var reports: [UInt8: Report] = [:]

    init(_ d: HIDDescriptor) {
        let touchFields = d.inputFields.filter { $0.topCollection == Usage.touchScreen }
        let byReport = Dictionary(grouping: touchFields, by: { $0.reportID })
        for (rid, fields) in byReport {
            var rep = Report()
            rep.contactCount = fields.first { $0.usage == Usage.contactCount && $0.fingerIndex == nil }
            rep.scanTime = fields.first { $0.usage == Usage.scanTime && $0.fingerIndex == nil }
            let fingerIdx = Set(fields.compactMap { $0.fingerIndex }).sorted()
            func slot(_ fs: [HIDField]) -> Slot {
                Slot(tip: fs.first { $0.usage == Usage.tipSwitch },
                     contactID: fs.first { $0.usage == Usage.contactID },
                     x: fs.first { $0.usage == Usage.genericDesktopX },
                     y: fs.first { $0.usage == Usage.genericDesktopY })
            }
            for idx in fingerIdx {
                let s = slot(fields.filter { $0.fingerIndex == idx })
                if s.x != nil, s.y != nil { rep.slots.append(s) }
            }
            if rep.slots.isEmpty { // single-touch layout without Finger collections
                let s = slot(fields)
                if s.x != nil, s.y != nil { rep.slots.append(s) }
            }
            if !rep.slots.isEmpty { reports[rid] = rep }
        }
    }

    var maxSlotsPerReport: Int { reports.values.map { $0.slots.count }.max() ?? 0 }
}
