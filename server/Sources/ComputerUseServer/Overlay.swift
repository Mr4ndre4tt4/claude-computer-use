import AppKit
import QuartzCore

/// Floating live view of what Claude is doing: the controlled window as a card (recent apps
/// stacked behind it), a ghost cursor that glides to each target, the target element outlined,
/// and a caption pill with the app and current action.
///
/// Non-intrusive by design: never takes focus, lets clicks through, fades while the pointer is
/// over it, moves to another corner when it would cover the controlled window, and is excluded
/// from every screenshot. Disable with COMPUTER_USE_HUD=0.
@MainActor
final class Overlay {
    static let shared = Overlay()

    private let enabled = ProcessInfo.processInfo.environment["COMPUTER_USE_HUD"] != "0"

    // Geometry
    private let maxCardWidth: CGFloat = 300
    private let pad: CGFloat = 22            // room for shadows
    private let stackStep: CGFloat = 10      // how much each back card peeks out
    private let pillHeight: CGFloat = 40
    private let pillOverlap: CGFloat = 14
    private let cornerRadius: CGFloat = 12

    // Views and layers
    private var panel: NSPanel?
    private let root = NSView()
    private let stage = CALayer()
    private let mainCard = Card()
    private let backCards = [Card(), Card()]
    private let marks = CALayer()
    private let cursor = CALayer()
    private let highlight = CAShapeLayer()
    private let pill = NSVisualEffectView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let actionField = NSTextField(labelWithString: "")
    private let liveDot = CALayer()

    // State
    private var targetPID: pid_t = 0
    private var targetFrame: CGRect = .zero
    private var cardSize: CGSize = .zero
    private var cursorPoint: CGPoint?
    private var recent: [(pid: pid_t, image: CGImage)] = []
    private var currentImage: CGImage?
    private var lastActivity = Date.distantPast
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    private var capturing = false
    private var visible = false
    private var dimmed = false

    // MARK: API

    /// Called by every action and by get_app_state. `rect` outlines the target element.
    func report(_ session: Session, _ action: String, at point: CGPoint?, rect: CGRect? = nil) {
        guard enabled else { return }
        ensurePanel()
        if session.pid != targetPID {
            if let currentImage, targetPID != 0 {
                recent.removeAll { $0.pid == targetPID || $0.pid == session.pid }
                recent.insert((targetPID, currentImage), at: 0)
                recent = Array(recent.prefix(backCards.count))
            }
            recent.removeAll { $0.pid == session.pid }
            currentImage = nil
            mainCard.image.contents = nil
            cursorPoint = nil
        }
        targetPID = session.pid
        if let frame = session.windowFrame ?? session.pickWindow(nil)?.frame { targetFrame = frame }
        lastActivity = Date()

        iconView.image = session.app.icon
        titleField.stringValue = session.name
        setAction(action)
        layout()
        show()
        if let point { moveCursor(to: point, outline: rect) }
        refresh()
    }

    /// Reuses a screenshot that was already captured.
    func show(image: CGImage) {
        guard enabled, panel != nil else { return }
        currentImage = image
        mainCard.image.contents = image      // implicit crossfade
    }

    // MARK: Setup

    private final class Card {
        let container = CALayer()
        let image = CALayer()

        init() {
            container.shadowColor = NSColor.black.cgColor
            container.shadowOpacity = 0.32
            container.shadowRadius = 12
            container.shadowOffset = CGSize(width: 0, height: 6)
            image.masksToBounds = true
            image.contentsGravity = .resizeAspectFill
            image.borderWidth = 0.5
            image.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            image.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
            container.addSublayer(image)
        }

        func place(_ frame: CGRect, radius: CGFloat) {
            container.frame = frame
            image.frame = container.bounds
            image.cornerRadius = radius
            container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0
        panel.contentView = root

        root.wantsLayer = true
        root.layer?.addSublayer(stage)
        stage.isGeometryFlipped = true   // y grows downwards, like screen coordinates

        for card in backCards.reversed() { stage.addSublayer(card.container) }
        stage.addSublayer(mainCard.container)

        marks.masksToBounds = true
        mainCard.image.addSublayer(marks)

        highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        highlight.strokeColor = NSColor.controlAccentColor.cgColor
        highlight.lineWidth = 1.5
        highlight.opacity = 0
        marks.addSublayer(highlight)

        if let arrow = NSCursor.arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cursor.contents = arrow
        }
        cursor.bounds = CGRect(x: 0, y: 0, width: 13, height: 20)
        cursor.anchorPoint = CGPoint(x: 0.2, y: 0.12)
        cursor.shadowColor = NSColor.black.cgColor
        cursor.shadowOpacity = 0.35
        cursor.shadowRadius = 2
        cursor.shadowOffset = CGSize(width: 0, height: 1)
        cursor.opacity = 0
        marks.addSublayer(cursor)

        pill.material = .popover
        pill.blendingMode = .behindWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pillHeight / 2
        pill.layer?.masksToBounds = true
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.separatorColor.cgColor
        root.addSubview(pill)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        actionField.font = .systemFont(ofSize: 11)
        actionField.textColor = .secondaryLabelColor
        actionField.lineBreakMode = .byTruncatingTail
        for view in [iconView, titleField, actionField] { pill.addSubview(view) }

        pill.layer?.addSublayer(liveDot)
        liveDot.backgroundColor = NSColor.systemGreen.cgColor
        liveDot.cornerRadius = 3.5
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.3
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        liveDot.add(breathe, forKey: "breathe")

        self.panel = panel
    }

    // MARK: Layout

    private func layout() {
        guard let panel else { return }
        let aspect = targetFrame.width > 0 ? targetFrame.height / targetFrame.width : 0.62
        let cardHeight = min(max(maxCardWidth * aspect, 120), 230)
        let cardWidth = min(maxCardWidth, max(cardHeight / max(aspect, 0.01), 150))
        cardSize = CGSize(width: cardWidth, height: cardHeight)

        let stacked = recent.count
        let width = max(cardWidth, 240) + pad * 2
        let mainTop = pad + CGFloat(stacked) * stackStep
        let height = mainTop + cardHeight - pillOverlap + pillHeight + pad

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        stage.frame = CGRect(x: 0, y: 0, width: width, height: height)

        for (i, card) in backCards.enumerated() {
            guard i < stacked else {
                card.container.opacity = 0
                continue
            }
            // Farther cards are smaller and dimmer, peeking out above the main card.
            let depth = CGFloat(stacked - i)
            let scale = 1 - depth * 0.07
            let frame = CGRect(x: (width - cardWidth * scale) / 2, y: mainTop - depth * stackStep,
                               width: cardWidth * scale, height: cardHeight * scale)
            card.place(frame, radius: cornerRadius)
            card.image.contents = recent[i].image
            card.container.opacity = Float(0.9 - depth * 0.25)
        }
        mainCard.place(CGRect(x: (width - cardWidth) / 2, y: mainTop, width: cardWidth, height: cardHeight), radius: cornerRadius)
        marks.frame = mainCard.image.bounds
        CATransaction.commit()

        let pillWidth = min(width - pad * 2 + 8, max(cardWidth - 16, 230))
        pill.frame = NSRect(x: (width - pillWidth) / 2, y: pad, width: pillWidth, height: pillHeight)
        iconView.frame = NSRect(x: 9, y: 8, width: 24, height: 24)
        titleField.frame = NSRect(x: 40, y: 20, width: pillWidth - 64, height: 15)
        actionField.frame = NSRect(x: 40, y: 5, width: pillWidth - 52, height: 14)
        liveDot.frame = CGRect(x: pillWidth - 18, y: pillHeight - 17, width: 7, height: 7)

        let size = NSSize(width: width, height: height)
        let origin = bestOrigin(for: size)
        let newFrame = NSRect(origin: origin, size: size)
        if visible, panel.frame.size == size, panel.frame.origin != origin {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    /// Bottom-right by default; another corner when that one would cover the user's own window
    /// (weighted most) or the controlled window.
    private func bestOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 6
        let candidates = [
            NSPoint(x: area.maxX - size.width - inset, y: area.minY + inset),
            NSPoint(x: area.minX + inset, y: area.minY + inset),
            NSPoint(x: area.maxX - size.width - inset, y: area.maxY - size.height - inset),
            NSPoint(x: area.minX + inset, y: area.maxY - size.height - inset),
        ]
        guard let primary = NSScreen.screens.first?.frame else { return candidates[0] }
        func flipped(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height) }
        let target = targetFrame.width > 0 ? flipped(targetFrame) : nil
        let userWindow = Safety.frontWindowFrame().map(flipped)
        func overlap(_ origin: NSPoint, _ other: NSRect?) -> CGFloat {
            guard let other else { return 0 }
            let r = NSRect(origin: origin, size: size).intersection(other)
            return r.isNull ? 0 : r.width * r.height
        }
        func cost(_ origin: NSPoint) -> CGFloat { overlap(origin, userWindow) * 3 + overlap(origin, target) }
        return candidates.min { cost($0) < cost($1) - 1 } ?? candidates[0]
    }

    // MARK: Show / hide

    private func show() {
        guard let panel else { return }
        if !visible {
            visible = true
            dimmed = false
            panel.orderFrontRegardless()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.92
            spring.toValue = 1
            spring.damping = 14
            spring.stiffness = 180
            spring.duration = spring.settlingDuration
            stage.add(spring, forKey: "appear")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 1
            }
        }
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        if hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateHover() }
            }
        }
    }

    private func hide() {
        guard let panel, visible else { return }
        visible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if !self.visible {
                    panel.orderOut(nil)
                    self.recent.removeAll()
                }
            }
        })
    }

    /// Fades away while the pointer is over the card so it never hides what the user wants to see.
    private func updateHover() {
        guard let panel, visible else { return }
        let over = panel.frame.insetBy(dx: pad - 6, dy: pad - 6).contains(NSEvent.mouseLocation)
        guard over != dimmed else { return }
        dimmed = over
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = over ? 0.12 : 1
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastActivity) > 15 { hide() } else { refresh() }
    }

    private func refresh() {
        guard !capturing, targetPID != 0, targetFrame.width > 0, Capture.hasPermission else { return }
        capturing = true
        let pid = targetPID
        let frame = targetFrame
        Task { @MainActor in
            defer { self.capturing = false }
            if let (image, _) = try? await Capture.window(pid: pid, near: frame, maxEdge: 640, cacheAge: 2),
               pid == self.targetPID {
                self.show(image: image)
            }
        }
    }

    // MARK: Caption, cursor, highlight

    private func setAction(_ text: String) {
        guard actionField.stringValue != text else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        actionField.wantsLayer = true
        actionField.layer?.add(fade, forKey: "text")
        actionField.stringValue = text
    }

    private func toCard(_ p: CGPoint) -> CGPoint? {
        guard targetFrame.width > 0, targetFrame.height > 0 else { return nil }
        let rx = (p.x - targetFrame.minX) / targetFrame.width
        let ry = (p.y - targetFrame.minY) / targetFrame.height
        guard (-0.02...1.02).contains(rx), (-0.02...1.02).contains(ry) else { return nil }
        return CGPoint(x: rx * cardSize.width, y: ry * cardSize.height)
    }

    /// Glides the ghost cursor to the target, outlines the element and pulses on arrival.
    private func moveCursor(to screenPoint: CGPoint, outline: CGRect?) {
        guard let point = toCard(screenPoint) else { return }
        let start = cursorPoint ?? CGPoint(x: cardSize.width * 0.5, y: cardSize.height * 0.9)
        cursorPoint = point

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursor.position = point
        cursor.opacity = 1
        CATransaction.commit()
        let glide = CABasicAnimation(keyPath: "position")
        glide.fromValue = NSValue(point: start)
        glide.toValue = NSValue(point: point)
        glide.duration = 0.38
        glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        cursor.add(glide, forKey: "glide")

        if let outline, let a = toCard(outline.origin), let b = toCard(CGPoint(x: outline.maxX, y: outline.maxY)) {
            let rect = CGRect(x: a.x, y: a.y, width: max(b.x - a.x, 6), height: max(b.y - a.y, 6)).insetBy(dx: -2, dy: -2)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            highlight.opacity = 0
            CATransaction.commit()
            let show = CAKeyframeAnimation(keyPath: "opacity")
            show.values = [0, 1, 1, 0]
            show.keyTimes = [0, 0.12, 0.8, 1]
            show.duration = 2.4
            highlight.add(show, forKey: "flash")
        }

        let ring = CAShapeLayer()
        let size: CGFloat = 18
        ring.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
        ring.position = point
        ring.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        marks.insertSublayer(ring, below: cursor)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.beginTime = CACurrentMediaTime() + 0.34
        pulse.duration = 0.7
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(pulse, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { ring.removeFromSuperlayer() }
    }
}
