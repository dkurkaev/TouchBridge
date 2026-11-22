import AppKit
import ApplicationServices

/// Small helpers over the Accessibility C API.
enum AX {
    static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }

    static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    static func parent(_ e: AXUIElement) -> AXUIElement? {
        guard let p = attr(e, kAXParentAttribute) else { return nil }
        return (p as! AXUIElement)
    }

    /// Frame in global CoreGraphics coordinates (top-left origin).
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func pid(_ e: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(e, &p)
        return p
    }

    static func element(at p: CGPoint, timeout: Float = 0.15) -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)
        var el: AXUIElement?
        return AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success ? el : nil
    }

    static func describe(_ e: AXUIElement) -> String {
        let role = string(e, kAXRoleAttribute) ?? "?"
        let sub = string(e, kAXSubroleAttribute).map { "/\($0)" } ?? ""
        let desc = string(e, kAXRoleDescriptionAttribute).map { " «\($0)»" } ?? ""
        let title = (string(e, kAXTitleAttribute) ?? string(e, kAXDescriptionAttribute)).map { " t=\"\($0.prefix(40))\"" } ?? ""
        let cls = (attr(e, "AXDOMClassList") as? [String]).map { " .\($0.prefix(4).joined(separator: "."))" } ?? ""
        let f = frame(e).map { " [\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))]" } ?? ""
        return role + sub + desc + title + cls + f
    }
}
