import AppKit
import QuartzCore

/// The cursor the user watches QuickAsk work with: a small pointer drawn just above the
/// controlled window, gliding to each action and pulsing on clicks. It never takes focus or
/// mouse events, and window screenshots capture only the target window, so it never appears
/// in what the model sees. The user's own cursor is not moved.
final class AgentCursor {
    private var panel: NSPanel?
    private var view: CursorView?
    private var hide: DispatchWorkItem?
    private static let size = CGSize(width: 40, height: 40)
    /// Where the arrow's tip sits in the view (non-flipped).
    private static let tip = CGPoint(x: 6, y: 34)

    /// Glides to `point` (global screen coordinates, top-left origin) above `window`.
    func move(to point: CGPoint, above window: UInt32, click: Bool = false) {
        DispatchQueue.main.async { [self] in
            let panel = panel ?? makePanel()
            let height = NSScreen.screens.first?.frame.height ?? 0
            let origin = CGPoint(x: point.x - Self.tip.x, y: height - point.y - Self.tip.y)
            let frame = CGRect(origin: origin, size: Self.size)
            if panel.isVisible && panel.alphaValue > 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                    panel.animator().alphaValue = 1
                }
            } else { panel.setFrame(frame, display: true); panel.alphaValue = 1 }
            if window != 0 { panel.order(.above, relativeTo: Int(window)) } else { panel.orderFrontRegardless() }
            if click { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.view?.pulse() } }
            scheduleHide()
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in hide?.cancel(); panel?.orderOut(nil) }
    }

    private func scheduleHide() {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = CursorView(frame: CGRect(origin: .zero, size: Self.size), tip: Self.tip)
        panel.contentView = view
        self.panel = panel; self.view = view
        return panel
    }
}

private final class CursorView: NSView {
    private let tip: CGPoint
    private let ring = CAShapeLayer()

    init(frame: CGRect, tip: CGPoint) {
        self.tip = tip
        super.init(frame: frame)
        wantsLayer = true
        ring.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        ring.position = tip
        ring.fillColor = nil
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2.5
        ring.opacity = 0
        layer?.addSublayer(ring)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The macOS arrow's proportions, tip at `tip`.
        let path = NSBezierPath()
        let t = tip
        path.move(to: t)
        path.line(to: CGPoint(x: t.x, y: t.y - 22))
        path.line(to: CGPoint(x: t.x + 5.5, y: t.y - 17))
        path.line(to: CGPoint(x: t.x + 9, y: t.y - 25))
        path.line(to: CGPoint(x: t.x + 12.5, y: t.y - 23.5))
        path.line(to: CGPoint(x: t.x + 9, y: t.y - 15.5))
        path.line(to: CGPoint(x: t.x + 16, y: t.y - 15.5))
        path.close()
        path.lineJoinStyle = .round
        NSColor.controlAccentColor.setFill(); path.fill()
        NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
    }

    func pulse() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3; scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]; group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
    }
}
