import AppKit
import ApplicationServices

@MainActor
final class Engine {
    private var sessions: [pid_t: Session] = [:]
    private var lastAction = Date.distantPast

    static let maxTreeChars = 60_000

    // MARK: Sessions

    func session(_ app: String, launch: Bool) async throws -> Session {
        guard AXIsProcessTrusted() else { throw ToolError(Permissions.accessibilityMissing) }
        sessions = sessions.filter { !$0.value.app.isTerminated }
        let running = try await Apps.resolve(app, launch: launch)
        guard Sharing.shared.allows(pid: running.processIdentifier) else {
            throw ToolError("\(running.localizedName ?? app) is outside the shared windows. \(Sharing.shared.describe())\nAsk the user to share it (share_window) or clear the share.")
        }
        if let existing = sessions[running.processIdentifier] { return existing }
        let session = Session(app: running)
        sessions[running.processIdentifier] = session
        // Chromium/Electron only build their web accessibility tree when asked.
        if session.appElement.set("AXManualAccessibility", kCFBooleanTrue) == .success {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return session
    }

    private func element(_ session: Session, _ index: Int) throws -> AXUIElement {
        guard let el = session.elements[index] else {
            throw ToolError("Unknown element_index \(index) for \(session.name). Call get_app_state to refresh the tree.")
        }
        return el
    }

    private func markAction() { lastAction = Date() }

    private func settle() async {
        let elapsed = Date().timeIntervalSince(lastAction)
        if elapsed < 0.6 { try? await Task.sleep(nanoseconds: UInt64((0.6 - elapsed) * 1_000_000_000)) }
    }

    /// Brings the app (and the window we last looked at) to the front before synthetic input.
    private func activate(_ session: Session) async {
        if !session.isFrontmost {
            session.appElement.set("AXFrontmost", kCFBooleanTrue)
            if !session.isFrontmost { session.app.activate() }
            for _ in 0..<30 where !session.isFrontmost {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        if let window = session.window {
            window.perform("AXRaise")
            window.set("AXMain", kCFBooleanTrue)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// Center of an element on screen, scrolling it into view first when needed.
    private func center(_ session: Session, _ index: Int, _ el: AXUIElement) async -> CGPoint? {
        guard var frame = el.frame ?? session.info[index]?.frame, frame.width > 0 || frame.height > 0 else { return nil }
        let outside = !Displays.contains(CGPoint(x: frame.midX, y: frame.midY))
            || (session.windowFrame.map { !$0.intersects(frame) } ?? false)
        if outside {
            el.perform("AXScrollToVisible")
            try? await Task.sleep(nanoseconds: 250_000_000)
            frame = el.frame ?? frame
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: State

    func getAppState(app: String, disableDiff: Bool, screenshot: Bool, window: String?) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        await settle()

        func refreshWindow() {
            session.window = session.pickWindow(window)
            session.windowFrame = session.window?.frame
        }
        refreshWindow()
        var collected = session.collect(expandAll: false, maxNodes: 1500, maxVisit: 10_000)

        // Wait for the UI to settle after recent actions or while something is loading.
        let recent = Date().timeIntervalSince(lastAction) < 5
        if recent || collected.busy {
            let deadline = Date().addingTimeInterval(collected.busy ? 5 : 2.5)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 350_000_000)
                refreshWindow()
                let next = session.collect(expandAll: false, maxNodes: 1500, maxVisit: 10_000)
                let stable = next.signature == collected.signature
                collected = next
                if stable && !collected.busy { break }
            }
        }

        var notes: [String] = []
        var image: CGImage?
        session.origin = session.windowFrame?.origin ?? .zero
        session.scale = session.windowFrame.map(Session.imageScale) ?? 1
        if screenshot {
            if !Capture.hasPermission {
                notes.append("No screenshot: Screen Recording permission is missing (see check_permissions).")
            } else if let frame = session.windowFrame {
                do {
                    let (captured, capturedFrame) = try await Capture.window(pid: session.pid, near: frame)
                    image = captured
                    session.origin = capturedFrame.origin
                    session.scale = CGFloat(captured.width) / max(1, capturedFrame.width)
                } catch {
                    notes.append("Screenshot failed: \(error). Try the screenshot tool or activate the app.")
                }
            } else {
                notes.append("The app has no window, so there is no screenshot. Its menu bar is still listed.")
            }
        }

        let registered = session.register(collected.nodes, replace: true)
        var lines: [Int: String] = [:]
        var order: [Int] = []
        var fullTree: [String] = []
        var chars = 0
        var cut = collected.truncated
        var focusedIndex: Int?
        for (index, node) in registered {
            let text = session.render(node, index: index)
            let line = String(repeating: "  ", count: node.depth) + text
            if chars + line.count > Engine.maxTreeChars {
                cut = true
                break
            }
            chars += line.count + 1
            fullTree.append(line)
            lines[index] = text
            order.append(index)
            if node.focused { focusedIndex = index }
        }

        var header: [String] = []
        header.append("App: \(session.name) (\(session.app.bundleIdentifier ?? "?"), pid \(session.pid))\(session.isFrontmost ? " — frontmost" : " — in background")")
        if let win = session.window {
            let title = win.str("AXTitle") ?? ""
            let count = session.windows.count
            header.append("Window: \(Session.quote(title))\(count > 1 ? " (1 of \(count) windows; pass window=<index or title> to switch)" : "")")
        }
        var screenshotPath: String?
        var jpegData: Data?
        if let image {
            let data = Capture.jpeg(image)
            jpegData = data
            screenshotPath = Capture.save(data, label: session.name)
            header.append("Screenshot: \(image.width)x\(image.height) px\(screenshotPath.map { ", saved at \($0)" } ?? ""). x/y arguments and @(x,y,w,h) frames use these pixels, origin = window top-left.")
        } else {
            header.append("Coordinates: same pixel space a screenshot of this window would use (origin = window top-left).")
        }
        if let focusedIndex { header.append("Focused element: [\(focusedIndex)]") }
        if collected.busy { header.append("Note: the app still shows a loading indicator.") }
        header += notes

        var body: String
        let full = "Elements ([index] role \"title\" … {state} actions=[…] @(x,y,w,h)):\n" + fullTree.joined(separator: "\n")
            + (cut ? "\n… tree truncated. Use find_elements to search, or scroll." : "")
        if !disableDiff, let baseline = session.baseline {
            var changes: [String] = []
            for index in order {
                guard let text = lines[index] else { continue }
                if let old = baseline[index] {
                    if old != text { changes.append("~ " + text) }
                } else {
                    changes.append("+ " + text)
                }
            }
            let removed = baseline.keys.filter { lines[$0] == nil }.sorted().map { "- " + baseline[$0]! }
            let total = changes.count + removed.count
            if total == 0 {
                body = "No UI changes since the previous get_app_state."
            } else if total * 2 > max(lines.count, 1) {
                body = full
            } else {
                body = "Diff since previous state (+ added, ~ changed, - removed). Unchanged elements are omitted and keep their indices:\n"
                    + (changes + removed).joined(separator: "\n")
            }
        } else {
            body = full
        }
        session.baseline = lines

        Overlay.shared.report(session, "Looking at " + Session.quote(session.window?.str("AXTitle") ?? session.name, max: 40), at: nil)
        if let image { Overlay.shared.show(image: image) }

        var content: [Content] = [.text(header.joined(separator: "\n") + "\n\n" + body)]
        if let jpegData { content.append(.image(jpegData, mime: "image/jpeg")) }
        return content
    }

    func findElements(app: String, query: String, role: String?, limit: Int) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        await settle()
        if session.window == nil {
            session.window = session.pickWindow(nil)
            session.windowFrame = session.window?.frame
            session.origin = session.windowFrame?.origin ?? .zero
            session.scale = session.windowFrame.map(Session.imageScale) ?? 1
        }
        let collected = session.collect(expandAll: true, maxNodes: 8000, maxVisit: 30_000)
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let needle = fold(query)
        let roleNeedle = role.map(fold)
        let matches = collected.nodes.filter { node in
            if let roleNeedle, !fold(Session.roleName(node.role, node.subrole)).contains(roleNeedle), !fold(node.role).contains(roleNeedle) {
                return false
            }
            return needle.isEmpty || fold(node.searchText).contains(needle)
        }
        let registered = session.register(Array(matches.prefix(limit)), replace: false)
        if registered.isEmpty {
            return [.text("No elements matching \(Session.quote(query))\(role.map { " with role \($0)" } ?? "") in \(session.name).")]
        }
        var text = "\(registered.count) of \(matches.count) match(es) in \(session.name) (closed menus included; indices usable with other tools):\n"
        text += registered.map { session.render($0.1, index: $0.0) }.joined(separator: "\n")
        return [.text(text)]
    }

    func listApps(runningOnly: Bool, limit: Int) -> [Content] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let apps = Apps.list(runningOnly: runningOnly)
        let lines = apps.prefix(limit).map { app -> String in
            var line = "\(app.name) — \(app.id)"
            if app.running { line += " [running]" }
            if let date = app.lastUsed { line += " last used \(formatter.string(from: date))" }
            if let count = app.useCount { line += " (\(count) uses)" }
            return line
        }
        return [.text("\(apps.count) apps (running first, then most recently used):\n" + lines.joined(separator: "\n"))]
    }

    // MARK: Actions

    /// Delivery strategy: background (default) posts events straight to the app's process —
    /// the real cursor does not move and the app is not brought forward. Foreground activates the
    /// app and uses the global event stream, for the rare app that ignores background events.
    private func deliver(_ session: Session, foreground: Bool) async -> pid_t? {
        if foreground {
            await activate(session)
            return nil
        }
        return session.pid
    }

    /// The app the user is working in, captured before an action so focus can be handed back.
    private func userFrontmost(excluding session: Session) -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != session.pid,
              front.processIdentifier != getpid() else { return nil }
        return front
    }

    private func giveFocusBack(to app: NSRunningApplication?, from session: Session) async {
        guard let app, !app.isTerminated else { return }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard session.isFrontmost else { return }
        AXUIElementCreateApplication(app.processIdentifier).set("AXFrontmost", kCFBooleanTrue)
        if !app.isActive { app.activate() }
    }

    /// Runs keyboard input. Background by default; apps that ignore background keys get a brief
    /// focus borrow (~0.2 s) and the user's app is re-activated right after.
    private func withKeyboard(_ session: Session, foreground: Bool, _ body: (pid_t?) -> Void) async -> String {
        let previous = userFrontmost(excluding: session)
        if foreground {
            await activate(session)
            body(nil)
            return " (foreground)"
        }
        if session.needsFocusForKeys && !session.isFrontmost {
            session.appElement.set("AXFrontmost", kCFBooleanTrue)
            for _ in 0..<20 where !session.isFrontmost { try? await Task.sleep(nanoseconds: 25_000_000) }
            body(session.pid)
            try? await Task.sleep(nanoseconds: 150_000_000)
            await giveFocusBack(to: previous, from: session)
            return " (focus borrowed briefly and returned; mouse untouched)"
        }
        body(session.pid)
        await giveFocusBack(to: previous, from: session)
        return " (background)"
    }

    private func modeNote(_ foreground: Bool) -> String {
        foreground ? " (foreground)" : " (background; if nothing changed, retry with foreground=true)"
    }

    func click(app: String, index: Int?, x: Double?, y: Double?, button: MouseButtonKind, count: Int, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        let previous = foreground ? nil : userFrontmost(excluding: session)
        defer { markAction() }
        let result = try await clickInner(session, index: index, x: x, y: y, button: button, count: count, foreground: foreground)
        await giveFocusBack(to: previous, from: session)
        return result
    }

    private func clickInner(_ session: Session, index: Int?, x: Double?, y: Double?, button: MouseButtonKind, count: Int, foreground: Bool) async throws -> String {
        var point: CGPoint
        var label: String
        if let index {
            let el = try element(session, index)
            let actions = el.actionNames
            let name = session.info[index]?.label.map { Session.quote($0, max: 40) } ?? "[\(index)]"
            if !foreground, count == 1, button == .left, actions.contains("AXPress"), el.perform("AXPress") == .success {
                Overlay.shared.report(session, "Pressed \(name)", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) })
                return "Pressed [\(index)] via accessibility (background, no mouse movement)."
            }
            if !foreground, count == 1, button == .right, actions.contains("AXShowMenu"), el.perform("AXShowMenu") == .success {
                Overlay.shared.report(session, "Opened menu of \(name)", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) })
                return "Opened the context menu of [\(index)]."
            }
            guard let center = await center(session, index, el) else {
                throw ToolError("Element [\(index)] has no on-screen frame. Try perform_secondary_action or x/y.")
            }
            point = center
            label = "Clicked \(name)"
            if !foreground, count == 1, button == .left, ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(session.info[index]?.role ?? ""),
               el.set("AXFocused", kCFBooleanTrue) == .success, el.bool("AXFocused") == true {
                Overlay.shared.report(session, "Focused \(name)", at: point)
                return "Focused [\(index)] (background, no mouse movement)."
            }
        } else {
            guard let x, let y else { throw ToolError("Provide element_index, or both x and y.") }
            point = session.toScreen(x: x, y: y)
            guard Displays.contains(point) else { throw ToolError("(\(x), \(y)) maps outside every display. Refresh get_app_state.") }
            label = "Clicked at (\(Int(x)), \(Int(y)))"
        }
        Overlay.shared.report(session, label, at: point)
        if !foreground, let how = accessibilityClick(session, at: point, button: button, count: count) {
            return "\(label) — \(how) (background, no mouse movement)."
        }
        if let pid = await deliver(session, foreground: foreground) {
            Input.backgroundClick(pid: pid, at: point, button: button, count: count)
        } else {
            Input.click(at: point, button: button, count: count)
        }
        return "\(label) (\(button.rawValue) ×\(count))\(modeNote(foreground))."
    }

    /// Background click without synthetic mouse events: hit-test the point and drive the element
    /// through accessibility. Returns nil when nothing suitable is there.
    private func accessibilityClick(_ session: Session, at point: CGPoint, button: MouseButtonKind, count: Int) -> String? {
        guard count == 1 else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(session.appElement, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        for _ in 0..<6 {
            let role = current.str("AXRole") ?? ""
            if ["AXWindow", "AXWebArea", "AXScrollArea", "AXApplication", "AXGroup", "AXSplitGroup"].contains(role) && role != "AXGroup" { return nil }
            let actions = current.actionNames
            let describe = "\(Session.roleName(role, nil)) \(Session.quote(current.str("AXTitle") ?? current.str("AXDescription") ?? "", max: 30))"
            if button == .right, actions.contains("AXShowMenu"), current.perform("AXShowMenu") == .success {
                return "opened the menu of \(describe)"
            }
            if button == .left {
                if actions.contains("AXPress"), current.perform("AXPress") == .success { return "pressed \(describe)" }
                if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role),
                   current.set("AXFocused", kCFBooleanTrue) == .success { return "focused \(describe)" }
                if ["AXRow", "AXCell", "AXOutlineRow"].contains(role) || current.isSettable("AXSelected") && role == "AXRow",
                   current.set("AXSelected", kCFBooleanTrue) == .success { return "selected \(describe)" }
            }
            guard let parent = current.element("AXParent") else { return nil }
            current = parent
        }
        return nil
    }

    func drag(app: String, from: (Double, Double), to: (Double, Double), foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        let start = session.toScreen(x: from.0, y: from.1)
        let end = session.toScreen(x: to.0, y: to.1)
        Overlay.shared.report(session, "Dragging", at: end)
        if let pid = await deliver(session, foreground: foreground) {
            Input.backgroundDrag(pid: pid, from: start, to: end)
        } else {
            Input.drag(from: start, to: end)
        }
        return "Dragged from (\(Int(from.0)), \(Int(from.1))) to (\(Int(to.0)), \(Int(to.1)))\(modeNote(foreground))."
    }

    /// True when the element lives inside web content, where direct AX text insertion would
    /// bypass the page's input events.
    private func isInWebContent(_ el: AXUIElement) -> Bool {
        var current: AXUIElement? = el
        for _ in 0..<40 {
            guard let node = current else { return false }
            if node.str("AXRole") == "AXWebArea" { return true }
            current = node.element("AXParent")
        }
        return false
    }

    func typeText(app: String, text: String, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        Overlay.shared.report(session, "Typing " + Session.quote(text, max: 40), at: nil)
        if !foreground, let focused = session.appElement.element("AXFocusedUIElement"),
           focused.isSettable("AXSelectedText"), !isInWebContent(focused) {
            // Native text views: insert at the caret through accessibility. Newlines/tabs are still keys.
            var segment = ""
            func flush() {
                if !segment.isEmpty { focused.set("AXSelectedText", segment as CFString) }
                segment = ""
            }
            for char in text {
                if char == "\n" || char == "\r\n" || char == "\r" {
                    flush()
                    Input.press(KeyStroke(code: 36), to: session.pid)
                } else if char == "\t" {
                    flush()
                    Input.press(KeyStroke(code: 48), to: session.pid)
                } else {
                    segment.append(char)
                }
            }
            flush()
            return "Inserted \(text.count) character(s) into the focused field (background)."
        }
        let how = await withKeyboard(session, foreground: foreground) { Input.typeText(text, to: $0) }
        return "Typed \(text.count) character(s)\(how)."
    }

    func pressKey(app: String, key: String, foreground: Bool) async throws -> String {
        let stroke = try Input.parse(key)
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        Overlay.shared.report(session, "Pressed \(key)", at: nil)
        let how = await withKeyboard(session, foreground: foreground) { Input.press(stroke, to: $0) }
        return "Pressed \(key)\(how)."
    }

    func paste(app: String, text: String, format: String, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        Overlay.shared.report(session, "Pasting \(text.count) characters", at: nil)
        let saved = Clipboard.save()
        try Clipboard.put(text, format: format)
        let stroke = try Input.parse("super+v")
        let how = await withKeyboard(session, foreground: foreground) { Input.press(stroke, to: $0) }
        // Give the app time to read the pasteboard before restoring the user's clipboard.
        try? await Task.sleep(nanoseconds: 600_000_000)
        Clipboard.restore(saved)
        return "Pasted \(text.count) character(s) as \(format); clipboard restored\(how)."
    }

    func scroll(app: String, index: Int?, x: Double?, y: Double?, direction: String, pages: Double, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        var point: CGPoint
        var height: CGFloat
        var width: CGFloat
        if let index {
            let el = try element(session, index)
            guard let frame = el.frame ?? session.info[index]?.frame else { throw ToolError("Element [\(index)] has no frame.") }
            let visible = session.windowFrame.map { frame.intersection($0) } ?? frame
            let area = visible.isNull || visible.isEmpty ? frame : visible
            point = CGPoint(x: area.midX, y: area.midY)
            height = area.height
            width = area.width
        } else if let x, let y {
            point = session.toScreen(x: x, y: y)
            height = session.windowFrame?.height ?? 600
            width = session.windowFrame?.width ?? 800
        } else if let frame = session.windowFrame ?? session.pickWindow(nil)?.frame {
            point = CGPoint(x: frame.midX, y: frame.midY)
            height = frame.height
            width = frame.width
        } else {
            throw ToolError("No window to scroll. Pass element_index or x/y.")
        }
        let vertical = Int((max(height, 100) * 0.8 * CGFloat(pages)).rounded())
        let horizontal = Int((max(width, 100) * 0.8 * CGFloat(pages)).rounded())
        let (dx, dy): (Int, Int)
        switch direction.lowercased() {
        case "down", "d": (dx, dy) = (0, -vertical)
        case "up", "u": (dx, dy) = (0, vertical)
        case "left", "l": (dx, dy) = (horizontal, 0)
        case "right", "r": (dx, dy) = (-horizontal, 0)
        default: throw ToolError("direction must be up, down, left or right")
        }
        Overlay.shared.report(session, "Scrolling \(direction)", at: point)
        if let pid = await deliver(session, foreground: foreground) {
            Input.backgroundScroll(pid: pid, at: point, dx: dx, dy: dy)
        } else {
            Input.scroll(at: point, dx: dx, dy: dy)
        }
        return "Scrolled \(direction) \(pages) page(s)\(modeNote(foreground))."
    }

    func selectText(app: String, index: Int, text: String, prefix: String?, suffix: String?, mode: String) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        let el = try element(session, index)
        guard let value = el.str("AXValue") else {
            throw ToolError("Element [\(index)] exposes no text value. Click into it and use press_key (shift+arrows) instead.")
        }
        let haystack = value as NSString
        var searchRange = NSRange(location: 0, length: haystack.length)
        var found: NSRange?
        while searchRange.length > 0 {
            let range = haystack.range(of: text, options: [], range: searchRange)
            if range.location == NSNotFound { break }
            let before = haystack.substring(to: range.location)
            let after = haystack.substring(from: range.location + range.length)
            if (prefix.map { before.hasSuffix($0) } ?? true) && (suffix.map { after.hasPrefix($0) } ?? true) {
                found = range
                break
            }
            let next = range.location + max(range.length, 1)
            searchRange = NSRange(location: next, length: haystack.length - next)
        }
        guard let range = found else { throw ToolError("Text \(Session.quote(text)) not found in [\(index)] with the given prefix/suffix.") }
        var target: CFRange
        switch mode {
        case "cursor_before": target = CFRange(location: range.location, length: 0)
        case "cursor_after": target = CFRange(location: range.location + range.length, length: 0)
        default: target = CFRange(location: range.location, length: range.length)
        }
        el.set("AXFocused", kCFBooleanTrue)
        guard let axRange = AXValueCreate(.cfRange, &target) else { throw ToolError("Could not build text range.") }
        let status = el.set("AXSelectedTextRange", axRange)
        guard status == .success else { throw ToolError("The app refused the selection (AXError \(status.rawValue)).") }
        return mode == "text" ? "Selected \(Session.quote(text)) in [\(index)]." : "Placed the cursor \(mode == "cursor_before" ? "before" : "after") \(Session.quote(text)) in [\(index)]."
    }

    func setValue(app: String, index: Int, value: String) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        let el = try element(session, index)
        let role = el.str("AXRole") ?? ""
        if el.isSettable("AXValue") {
            el.set("AXFocused", kCFBooleanTrue)
            let newValue: CFTypeRef
            if ["AXSlider", "AXIncrementor", "AXLevelIndicator", "AXStepper"].contains(role), let number = Double(value) {
                newValue = NSNumber(value: number)
            } else {
                newValue = value as CFString
            }
            if el.set("AXValue", newValue) == .success {
                let readBack = el.str("AXValue")
                if readBack == nil || readBack == value || Double(readBack ?? "") == Double(value) {
                    Overlay.shared.report(session, "Set value of [\(index)]", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) })
                    return "Set the value of [\(index)]."
                }
            }
        }
        // Fallback: focus, select everything and type like a person (still delivered in background).
        guard let point = await center(session, index, el) else { throw ToolError("[\(index)] is not settable and has no frame to click.") }
        if el.set("AXFocused", kCFBooleanTrue) != .success || el.bool("AXFocused") != true {
            Input.backgroundClick(pid: session.pid, at: point, button: .left, count: 1)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        Input.press(try Input.parse("super+a"), to: session.pid)
        Input.typeText(value, to: session.pid)
        return "[\(index)] was not directly settable, so it was focused, selected and typed into."
    }

    func performSecondaryAction(app: String, index: Int, action: String) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        let el = try element(session, index)
        let available = el.actionNames
        let wanted = AX.normalizeAction(action)
        guard let match = available.first(where: { $0 == action || AX.normalizeAction(AX.displayAction($0)) == wanted }) else {
            let names = available.map(AX.displayAction).joined(separator: ", ")
            throw ToolError("[\(index)] does not expose \(Session.quote(action)). Available: \(names.isEmpty ? "none" : names).")
        }
        let status = el.perform(match)
        guard status == .success else { throw ToolError("\(AX.displayAction(match)) failed (AXError \(status.rawValue)).") }
        Overlay.shared.report(session, "\(AX.displayAction(match)) on [\(index)]", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) })
        return "Performed \(AX.displayAction(match)) on [\(index)]."
    }

    func screenshot(app: String?, display: Int, window: String?) async throws -> [Content] {
        guard Capture.hasPermission else {
            throw ToolError("Screen Recording permission is missing for \"\(Permissions.responsibleAppName)\". Run check_permissions.")
        }
        if let app {
            let session = try await self.session(app, launch: true)
            session.window = session.pickWindow(window)
            session.windowFrame = session.window?.frame
            guard let frame = session.windowFrame else { throw ToolError("\(session.name) has no window.") }
            let (image, captured) = try await Capture.window(pid: session.pid, near: frame)
            session.origin = captured.origin
            session.scale = CGFloat(image.width) / max(1, captured.width)
            let data = Capture.jpeg(image)
            let path = Capture.save(data, label: session.name)
            return [.text("\(session.name) window, \(image.width)x\(image.height) px\(path.map { ", saved at \($0)" } ?? ""). Coordinates in this image work with click/drag/scroll for this app."),
                    .image(data, mime: "image/jpeg")]
        }
        let (image, frame) = try await Capture.display(index: display)
        let data = Capture.jpeg(image)
        let path = Capture.save(data, label: "display-\(display)")
        return [.text("Display \(display) (\(Int(frame.width))x\(Int(frame.height)) pt), image \(image.width)x\(image.height) px\(path.map { ", saved at \($0)" } ?? ""). View only: use get_app_state for clickable coordinates."),
                .image(data, mime: "image/jpeg")]
    }
}
