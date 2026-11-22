import AppKit
import ApplicationServices

/// The macOS on-screen keyboard (Accessibility Keyboard, "Keyboard Viewer").
///
/// macOS has no public call for it, and toggling it from another process via TextInputMenuUI or
/// Text Input Sources only flips a flag without showing anything. So we do exactly what a person
/// does: press "Show Keyboard Viewer" in the Input menu (the keyboard-layout icon in the menu bar)
/// through the Accessibility API. The item is found by its identifier (`toggle`), not by its
/// localized title. Needs the Input menu to be shown in the menu bar
/// (System Settings → Keyboard → Text Input → "Show Input menu in menu bar").
enum OnScreenKeyboard {
    enum Result { case shown, hidden, noInputMenu, failed }

    private static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Whether the keyboard panel is on screen (a window of the AssistiveControl process).
    static var isVisible: Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "AssistiveControl"
                && ((w[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) < 2000
        }
    }

    /// Opens the Input menu, presses the keyboard viewer item and reports the new state.
    @discardableResult
    static func toggle() -> Result {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextInputMenuAgent").first,
              let barRef = attr(AXUIElementCreateApplication(agent.processIdentifier), "AXExtrasMenuBar") else {
            tlog("⚠️  Экранная клавиатура: нет меню ввода в строке меню. Включи «Показывать меню ввода в строке меню» "
                 + "(Системные настройки → Клавиатура → Ввод текста).")
            return .noInputMenu
        }
        let bar = barRef as! AXUIElement
        for extra in children(bar) {
            // Pressing a menu extra blocks until its menu closes; a short timeout lets us continue while it is open.
            AXUIElementSetMessagingTimeout(extra, 0.3)
            AXUIElementPerformAction(extra, kAXPressAction as CFString)
            var item: AXUIElement?
            var menus: [AXUIElement] = []
            for _ in 0..<10 where item == nil { // the menu may take a moment to appear
                usleep(30_000)
                menus = children(extra)
                item = menus.flatMap(children).first { el in
                    let id = attr(el, "AXIdentifier") as? String
                    let title = (attr(el, kAXTitleAttribute) as? String ?? "").lowercased()
                    return id == "toggle" || title.contains("keyboard viewer") || title.contains("панель «клавиатура»")
                }
            }
            guard let it = item else {
                for m in menus { AXUIElementPerformAction(m, kAXCancelAction as CFString) }
                continue
            }
            let title = (attr(it, kAXTitleAttribute) as? String ?? "").lowercased()
            let wasShown = title.hasPrefix("hide") || title.hasPrefix("скрыть")
            AXUIElementSetMessagingTimeout(it, 0.5)
            let r = AXUIElementPerformAction(it, kAXPressAction as CFString)
            guard r == .success || r == .cannotComplete else {
                tlog("⚠️  Экранная клавиатура: не удалось нажать пункт меню ввода (\(r.rawValue))")
                for m in menus { AXUIElementPerformAction(m, kAXCancelAction as CFString) }
                return .failed
            }
            let now: Result = wasShown ? .hidden : .shown
            tlog(now == .shown ? "Экранная клавиатура показана" : "Экранная клавиатура скрыта")
            return now
        }
        tlog("⚠️  Экранная клавиатура: в меню ввода нет пункта «Показать панель Клавиатура»")
        return .failed
    }
}
