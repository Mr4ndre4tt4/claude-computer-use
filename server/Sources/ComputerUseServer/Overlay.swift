import AppKit
import QuartzCore

/// Small floating "what Claude is doing" card: live thumbnail of the controlled window, the app,
/// the current action and a pulse where the last click landed. It never takes focus, lets clicks
/// pass through and is excluded from every screenshot we take. Disable with COMPUTER_USE_HUD=0.
@MainActor
final class Overlay {
    static let shared = Overlay()

    private let enabled = ProcessInfo.processInfo.environment["COMPUTER_USE_HUD"] != "0"
    private let width: CGFloat = 340
    private let margin: CGFloat = 12
    private let headerHeight: CGFloat = 50

    private var panel: NSPanel?
    private let effect = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let actionField = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let markerView = NSView()
    private let liveDot = NSView()

    private var targetPID: pid_t = 0
    private var targetFrame: CGRect = .zero
    private var lastPoint: CGPoint?
    private var lastActivity = Date.distantPast
    private var timer: Timer?
    private var capturing = false
    private var visible = false

    /// Called by every action and by get_app_state.
    func report(_ session: Session, _ action: String, at point: CGPoint?) {
        guard enabled else { return }
        targetPID = session.pid
        if let frame = session.windowFrame ?? session.pickWindow(nil)?.frame { targetFrame = frame }
        lastPoint = point
        lastActivity = Date()
        ensurePanel()
        iconView.image = session.app.icon
        titleField.stringValue = "Claude · \(session.name)"
        actionField.stringValue = action
        layout()
        show()
        if let point { pulse(at: point) }
        refresh()
    }

    /// Reuses a screenshot we already captured instead of taking another one.
    func show(image: CGImage) {
        guard enabled, panel != nil else { return }
        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        panel.contentView = effect

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        actionField.font = .systemFont(ofSize: 11.5)
        actionField.textColor = .secondaryLabelColor
        actionField.lineBreakMode = .byTruncatingTail

        liveDot.wantsLayer = true
        liveDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        liveDot.layer?.cornerRadius = 4

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 9
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        markerView.wantsLayer = true

        for view in [iconView, titleField, actionField, liveDot, imageView, markerView] { effect.addSubview(view) }
        self.panel = panel
    }

    private func layout() {
        guard let panel else { return }
        let aspect = targetFrame.width > 0 ? targetFrame.height / targetFrame.width : 0.62
        let maxImageWidth = width - margin * 2
        let imageHeight = min(max(maxImageWidth * aspect, 110), 280)
        // Tall windows get a narrower, centered thumbnail instead of letterboxing.
        let imageWidth = min(maxImageWidth, imageHeight / max(aspect, 0.01))
        let height = imageHeight + headerHeight + margin

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visibleFrame.maxX - width - 16, y: visibleFrame.minY + 16, width: width, height: height), display: true)

        iconView.frame = NSRect(x: margin, y: height - 38, width: 26, height: 26)
        titleField.frame = NSRect(x: margin + 34, y: height - 26, width: width - margin * 2 - 50, height: 16)
        actionField.frame = NSRect(x: margin + 34, y: height - 42, width: width - margin * 2 - 34, height: 15)
        liveDot.frame = NSRect(x: width - margin - 8, y: height - 22, width: 8, height: 8)
        imageView.frame = NSRect(x: (width - imageWidth) / 2, y: margin, width: imageWidth, height: imageHeight)
        markerView.frame = imageView.frame
    }

    private func show() {
        guard let panel else { return }
        if !visible {
            visible = true
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func hide() {
        guard let panel, visible else { return }
        visible = false
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in if !self.visible { panel.orderOut(nil) } }
        })
    }

    private func tick() {
        if Date().timeIntervalSince(lastActivity) > 15 {
            hide()
        } else {
            refresh()
        }
    }

    /// Live thumbnail of the controlled window (captured by pid, so occluding windows don't show).
    private func refresh() {
        guard !capturing, targetPID != 0, targetFrame.width > 0, Capture.hasPermission else { return }
        capturing = true
        let pid = targetPID
        let frame = targetFrame
        Task { @MainActor in
            defer { self.capturing = false }
            if let (image, _) = try? await Capture.window(pid: pid, near: frame, maxEdge: 700) {
                self.show(image: image)
            }
        }
    }

    private func pulse(at screenPoint: CGPoint) {
        guard let layer = markerView.layer, targetFrame.width > 0, targetFrame.height > 0 else { return }
        let rx = (screenPoint.x - targetFrame.minX) / targetFrame.width
        let ry = (screenPoint.y - targetFrame.minY) / targetFrame.height
        guard (0...1).contains(rx), (0...1).contains(ry) else { return }
        let point = CGPoint(x: rx * markerView.bounds.width, y: (1 - ry) * markerView.bounds.height)

        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let size: CGFloat = 16
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
        ring.position = point
        ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2
        layer.addSublayer(ring)

        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -3.5, y: -3.5, width: 7, height: 7), transform: nil)
        dot.position = point
        dot.fillColor = NSColor.controlAccentColor.cgColor
        layer.addSublayer(dot)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.repeatCount = 2
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "pulse")

        let dotFade = CABasicAnimation(keyPath: "opacity")
        dotFade.fromValue = 1
        dotFade.toValue = 0
        dotFade.beginTime = CACurrentMediaTime() + 2.5
        dotFade.duration = 0.5
        dotFade.isRemovedOnCompletion = false
        dotFade.fillMode = .forwards
        dot.add(dotFade, forKey: "fade")
    }
}
