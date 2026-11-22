import AppKit
import QuartzCore

/// A ring under the finger when a press-and-hold registers (like the Windows touch-hold square):
/// lift now for a right-click, move to drag. Click-through, on every Space, above everything.
final class TouchFeedback {
    private var panel: NSPanel?
    private var ring: CAShapeLayer?
    private var generation = 0
    private let size: CGFloat = 56

    /// `p` in global CoreGraphics coordinates (top-left origin), like CGEvent locations.
    func showHold(at p: CGPoint) {
        generation += 1
        let panel = self.panel ?? makePanel()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setFrame(NSRect(x: p.x - size / 2, y: primaryTop - p.y - size / 2, width: size, height: size), display: false)
        if let ring {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 1
            grow.duration = 0.15
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(grow, forKey: "grow")
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        let g = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.generation == g { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let r = CAShapeLayer()
        r.frame = v.bounds
        r.path = CGPath(ellipseIn: v.bounds.insetBy(dx: 4, dy: 4), transform: nil)
        r.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        r.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        r.lineWidth = 3
        v.layer?.addSublayer(r)
        p.contentView = v
        panel = p
        ring = r
        return p
    }
}
