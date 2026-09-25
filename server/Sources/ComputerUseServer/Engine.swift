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
        for (pid, stale) in sessions where stale.app.isTerminated {
            stale.stopObserving()
            sessions[pid] = nil
        }
        let running = try await Apps.resolve(app, launch: launch)
        guard Sharing.shared.allows(pid: running.processIdentifier) else {
            throw ToolError("\(running.localizedName ?? app) is outside the shared windows. \(Sharing.shared.describe())\nAsk the user to share it (share_window) or clear the share.")
        }
        if let existing = sessions[running.processIdentifier] {
            guard await waitUntilResponsive(existing) else { throw notResponding(existing) }
            return existing
        }
        let session = Session(app: running)
        sessions[running.processIdentifier] = session
        // Chromium/Electron only build their web accessibility tree when asked.
        if session.appElement.set("AXManualAccessibility", kCFBooleanTrue) == .success, session.needsFocusForKeys {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return session
    }

    /// Apps are often briefly busy right after an action (creating a document, opening a panel);
    /// keep probing for a while before calling them hung, longer when we just acted on them.
    private func waitUntilResponsive(_ session: Session) async -> Bool {
        if session.isResponsive { return true }
        let patience: Double = Date().timeIntervalSince(lastAction) < 15 ? 10 : 4
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if session.isResponsive { return true }
        }
        return false
    }

    private func notResponding(_ session: Session) -> ToolError {
        ToolError("\(session.name) is not responding (busy or hung). Wait a moment and retry; if it stays stuck, tell the user rather than force-quitting it.")
    }

    private func element(_ session: Session, _ index: Int) throws -> AXUIElement {
        guard let el = session.elements[index] else {
            throw ToolError("Unknown element_index \(index) for \(session.name). Call get_app_state to refresh the tree.")
        }
        return el
    }

    private func markAction() { lastAction = Date() }

    /// Waits until the app has stopped changing after the last action: at least a short reaction
    /// window, then 250 ms without accessibility notifications (capped). Returns immediately when
    /// nothing was done recently.
    private func settle(_ session: Session, cap: Double = 3) async {
        let sinceAction = Date().timeIntervalSince(lastAction)
        guard sinceAction < 5 else { return }
        let reaction = session.observing ? 0.2 : 0.6
        if sinceAction < reaction {
            try? await Task.sleep(nanoseconds: UInt64((reaction - sinceAction) * 1_000_000_000))
        }
        guard session.observing else { return }
        let deadline = Date().addingTimeInterval(cap)
        while Date() < deadline, Date().timeIntervalSince(session.lastChange) < 0.25 {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// Anything that takes focus or the pointer first waits for a pause in the user's own input,
    /// so it never lands in the middle of their typing, a click or a drag. If they keep going,
    /// the action is postponed (error) rather than interrupting them.
    private func waitForUserPause(_ what: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Safety.userIdleSeconds() < 1.2 {
            guard Date() < deadline else {
                throw ToolError("The user has been typing or using the mouse continuously, so \(what) was postponed to avoid interrupting them. Retry in a moment, or use a background route (element_index actions, select_menu, set_value, paste).")
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// Brings the app (and the window we last looked at) to the front before synthetic input.
    private func activate(_ session: Session) async throws {
        if !session.isFrontmost { try await waitForUserPause("bringing \(session.name) forward") }
        let wasFrontmost = session.isFrontmost
        if !wasFrontmost {
            session.appElement.set("AXFrontmost", kCFBooleanTrue)
            if !session.isFrontmost { session.app.activate() }
            let deadline = Date().addingTimeInterval(1.5)
            while !session.isFrontmost && Date() < deadline { try? await Task.sleep(nanoseconds: 25_000_000) }
        }
        if let window = session.window {
            window.perform("AXRaise")
            window.set("AXMain", kCFBooleanTrue)
        }
        // Freshly activated apps (Office especially) drop keys until their key window settles.
        try? await Task.sleep(nanoseconds: wasFrontmost ? 80_000_000 : 250_000_000)
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

    func getAppState(app: String, disableDiff: Bool, screenshot: Bool?, window: String?, includeOffscreen: Bool) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        await settle(session)

        func refreshWindow() {
            session.window = session.pickWindow(window)
            session.windowFrame = session.window?.frame
        }
        func read() -> Collected {
            session.collect(expandAll: false, maxNodes: 1500, maxVisit: 10_000, pruneOffscreen: !includeOffscreen)
        }
        let previousWindow = session.window
        refreshWindow()
        var collected = read()
        if collected.unresponsive && collected.nodes.isEmpty { throw notResponding(session) }

        // Without notifications, confirm stability by comparing two reads; either way keep waiting
        // (up to 5 s) while the app shows a loading indicator.
        let needsCheck = !session.observing && Date().timeIntervalSince(lastAction) < 5
        if needsCheck || collected.busy {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if session.observing {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await settle(session, cap: 1)
                } else {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
                refreshWindow()
                let next = read()
                let stable = next.signature == collected.signature
                collected = next
                if (stable || session.observing) && !collected.busy { break }
            }
        }

        // Coordinates come from the window frame and the same scale a capture would use, so the
        // tree can be rendered (and diffed) before deciding whether a screenshot is worth sending.
        session.origin = session.windowFrame?.origin ?? .zero
        session.scale = session.windowFrame.map(Session.imageScale) ?? 1

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

        var footer: [String] = []
        if collected.hiddenOffscreen > 0 {
            footer.append("… \(collected.hiddenOffscreen) container(s) outside the visible area were skipped (scroll, find_elements, or include_offscreen: true).")
        }
        if cut { footer.append("… tree truncated. Use find_elements to search, or scroll.") }
        let full = "Elements ([index] role \"title\" … {state} actions=[…] @(x,y,w,h)):\n" + fullTree.joined(separator: "\n")
            + (footer.isEmpty ? "" : "\n" + footer.joined(separator: "\n"))

        var body = full
        var unchanged = false
        if !disableDiff, let baseline = session.baseline {
            switch TreeDiff.compute(baseline: baseline, lines: lines, order: order) {
            case .unchanged:
                unchanged = true
                body = "No UI changes since the previous get_app_state."
            case .full:
                body = full
            case .changes(let changes):
                body = "Diff since previous state (+ added, ~ changed, - removed). Unchanged elements are omitted and keep their indices:\n"
                    + changes.joined(separator: "\n")
            }
        }
        session.baseline = lines

        // Screenshot policy: explicit true/false wins; by default skip it when nothing changed
        // and the same window was already shown.
        let sameWindow = previousWindow.map { prev in session.window.map { CFEqual(prev, $0) } ?? false } ?? false
        let wantImage = screenshot ?? !(unchanged && sameWindow && session.hasShownScreenshot)
        var notes: [String] = []
        var image: CGImage?
        if wantImage {
            if !Capture.hasPermission {
                notes.append("No screenshot: Screen Recording permission is missing (see check_permissions).")
            } else if let frame = session.windowFrame {
                do {
                    let (captured, capturedFrame) = try await Capture.window(pid: session.pid, near: frame)
                    image = captured
                    session.origin = capturedFrame.origin
                    session.scale = CGFloat(captured.width) / max(1, capturedFrame.width)
                    session.hasShownScreenshot = true
                } catch {
                    notes.append("Screenshot failed: \(error). Try the screenshot tool or activate the app.")
                }
            } else {
                notes.append("The app has no window, so there is no screenshot. Its menu bar is still listed.")
            }
        } else if screenshot == nil {
            notes.append("Screenshot omitted because nothing changed (pass screenshot: true to force).")
        }

        var header: [String] = []
        header.append("App: \(session.name) (\(session.app.bundleIdentifier ?? "?"), pid \(session.pid))\(session.isFrontmost ? " — frontmost" : " — in background")")
        if let win = session.window {
            let title = Walker.nonEmptyTitle(win.str("AXTitle")) ?? win.str("AXDescription") ?? win.str("AXSubrole") ?? ""
            let count = session.windows.count
            header.append("Window: \(Session.quote(title))\(count > 1 ? " (1 of \(count) windows; pass window=<index or title> to switch)" : "")")
            if let modal = session.modalAlert, !CFEqual(modal, win) {
                let message = Session.texts(in: modal).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
                header.append("⚠ A modal alert has keyboard focus and blocks input to this window: \(Session.quote(message, max: 200)). Dismiss it first (get_app_state without window= shows it).")
            }
        }
        var jpegData: Data?
        if let image {
            let data = Capture.jpeg(image)
            jpegData = data
            let path = Capture.save(data, label: session.name)
            header.append("Screenshot: \(image.width)x\(image.height) px\(path.map { ", saved at \($0)" } ?? ""). x/y arguments and @(x,y,w,h) frames use these pixels, origin = window top-left.")
        } else {
            header.append("Coordinates: pixels of this window's screenshot space (origin = window top-left).")
        }
        if let focusedIndex { header.append("Focused element: [\(focusedIndex)]") }
        if collected.busy { header.append("Note: the app still shows a loading indicator.") }
        if collected.unresponsive { header.append("Note: the app stopped answering mid-read; the tree may be partial.") }
        if registered.count < 8, (session.windowFrame?.width ?? 0) > 300 {
            header.append("Tip: very little accessibility here (canvas/custom UI?). read_screen_text gives OCR text with clickable coordinates.")
        }
        header += notes

        Overlay.shared.report(session, "Looking at " + Session.quote(session.window?.str("AXTitle") ?? session.name, max: 40), at: nil)
        if let image { Overlay.shared.show(image: image) }

        var content: [Content] = [.text(header.joined(separator: "\n") + "\n\n" + body)]
        if let jpegData { content.append(.image(jpegData, mime: "image/jpeg")) }
        return content
    }

    func findElements(app: String, query: String, role: String?, limit: Int) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        await settle(session)
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
        // Build folders and backups leave many copies of one bundle id; list it once (the running
        // or most recently used copy, thanks to the sort order) and say how many others exist.
        var apps: [AppInfo] = []
        var copies: [String: Int] = [:]
        for app in Apps.list(runningOnly: runningOnly) {
            if copies[app.id] != nil { copies[app.id]! += 1 } else { copies[app.id] = 0; apps.append(app) }
        }
        let lines = apps.prefix(limit).map { app -> String in
            var line = "\(app.name) — \(app.id)"
            if let extra = copies[app.id], extra > 0 { line += " (+\(extra) other cop\(extra == 1 ? "y" : "ies"))" }
            if app.running { line += " [running]" }
            if let date = app.lastUsed { line += " last used \(formatter.string(from: date))" }
            if let count = app.useCount { line += " (\(count) uses)" }
            return line
        }
        return [.text("\(apps.count) apps (running first, then most recently used):\n" + lines.joined(separator: "\n"))]
    }

    // MARK: Actions

    /// True once the app reported a UI change after `since` (nil when notifications are unavailable).
    private func changed(_ session: Session, since: Date, within: Double = 0.45) async -> Bool? {
        guard session.observing else { return nil }
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if session.lastChange > since { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return session.lastChange > since
    }

    /// Pointer input strategy. Background first: events are posted straight to the app's process
    /// (the user's cursor and focus stay put) and success is confirmed through the app's own
    /// change notifications. Apps that ignore background pointer events (Chromium, Electron,
    /// SwiftUI…) get a brief borrow instead: app forward, real pointer, cursor put back, focus
    /// returned to the user's app.
    /// A real pointer event lands on whatever window is on top at that point, so refuse unless it
    /// belongs to the target (another app's window or panel may be covering it).
    private func checkPointerTarget(_ session: Session, _ point: CGPoint?) throws {
        guard session.isFrontmost else {
            throw ToolError("Could not bring \(session.name) to the front; the real pointer event was not sent.")
        }
        if let point, let owner = Safety.ownerAt(point), owner.pid != session.pid {
            throw ToolError("\(owner.name) has a window covering that point, so the click was not sent (it would hit \(owner.name), not \(session.name)). Move or close that window, or use an element_index action.")
        }
    }

    private func pointer(_ session: Session, foreground: Bool, restoreCursor: Bool = true, at point: CGPoint?,
                         background: (pid_t) -> Void, real: () -> Void) async throws -> String {
        func refuseIfCovered() throws {
            if let point, let cover = Safety.floatingCover(at: point, excluding: session.pid) {
                throw ToolError("\(cover) has a floating window over that point, so the real pointer was not used and \(session.name) was not brought forward. Try an element_index action, or ask the user to move that window.")
            }
        }
        if foreground {
            try refuseIfCovered()
            try await activate(session)
            try checkPointerTarget(session, point)
            real()
            return " (foreground)"
        }
        let start = Date()
        background(session.pid)
        if await changed(session, since: start) != false { return " (background)" }
        if !session.needsFocusForKeys {
            // Don't escalate on our own: a real click activates the app and moves the user's
            // pointer. Often nothing changed simply because the target is inert (a label).
            return " (background; no UI change was detected. If the click should have done something, retry with foreground: true, which briefly takes the pointer and focus)"
        }
        // Chromium/Electron/Firefox: the background attempt showed no effect; borrow the pointer.
        try refuseIfCovered()
        let previous = userFrontmost(excluding: session)
        let cursor = CGEvent(source: nil)?.location
        try await activate(session)
        do { try checkPointerTarget(session, point) } catch {
            await giveFocusBack(to: previous, from: session)
            throw error
        }
        real()
        try? await Task.sleep(nanoseconds: 120_000_000)
        if restoreCursor, let cursor {
            CGWarpMouseCursorPosition(cursor)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        await giveFocusBack(to: previous, from: session)
        return restoreCursor
            ? " (background had no effect; focus and pointer borrowed briefly, then restored)"
            : " (focus borrowed; pointer left in place so the hover stays open)"
    }

    /// The app the user is working in, captured before an action so focus can be handed back.
    private func userFrontmost(excluding session: Session) -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != session.pid,
              front.processIdentifier != getpid() else { return nil }
        return front
    }

    /// Hands focus back to the user's app if the target grabbed it. Checks now and again shortly
    /// after (apps often activate themselves a beat later), without delaying the tool result.
    private func giveFocusBack(to app: NSRunningApplication?, from session: Session) async {
        guard let app, !app.isTerminated else { return }
        func restoreIfNeeded() {
            guard session.isFrontmost, !app.isTerminated else { return }
            AXUIElementCreateApplication(app.processIdentifier).set("AXFrontmost", kCFBooleanTrue)
            if !app.isActive { app.activate() }
        }
        restoreIfNeeded()
        Task { @MainActor in
            for delay: UInt64 in [150_000_000, 350_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                restoreIfNeeded()
            }
        }
    }

    /// Keys go to the app's key window, which is not always the window the agent is working in
    /// (activating Excel makes the workbook key even while the VBA editor is open, so text meant
    /// for the editor lands in cells). Move focus to the working window, or refuse.
    private func ensureKeyWindow(_ session: Session, weActivated: Bool = false) throws {
        guard let target = session.window, session.windows.count > 1,
              let key = session.keyWindow, !CFEqual(key, target) else { return }
        // The user is working in this app: moving its focused window would pull it out from under them.
        if !weActivated, session.isFrontmost, session.modalAlert == nil {
            let keyTitle = Walker.nonEmptyTitle(key.str("AXTitle")) ?? "another window"
            throw ToolError("The user is working in \"\(keyTitle)\" of \(session.name) right now, and keys only reach its focused window. Nothing was sent, to avoid switching windows under them. Wait until they switch to another app, use background routes (set_value, element_index clicks, paste), or ask the user.")
        }
        target.set("AXMain", kCFBooleanTrue)
        target.set("AXFocused", kCFBooleanTrue)
        if let now = session.keyWindow, !CFEqual(now, target) {
            let message = Session.texts(in: now).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            let keyTitle = Walker.nonEmptyTitle(now.str("AXTitle")) ?? (message.isEmpty ? "another window" : "alert: " + String(message.prefix(120)))
            let targetTitle = target.str("AXTitle") ?? "the working window"
            throw ToolError("Keys would go to \"\(keyTitle)\", not \"\(targetTitle)\" (the window you are working in), so nothing was sent. Click inside \"\(targetTitle)\" first, or call get_app_state with window=\"\(keyTitle)\" if that is the intended target.")
        }
    }

    /// Runs keyboard input on the plugin's virtual keyboard: keys are posted to the target process
    /// only, never into the shared HID stream, so they cannot reach another app or mix with the
    /// user's typing. Apps that only accept keys while active get a brief focus borrow (~0.2 s),
    /// taken only during a pause in the user's own input.
    private func withKeyboard(_ session: Session, foreground: Bool, needsKeyWindow: Bool = false, _ body: (pid_t) -> Void) async throws -> String {
        let needsKeyWindow = needsKeyWindow && !session.shortcutsWorkInBackground
        let previous = userFrontmost(excluding: session)
        try ensureKeyWindow(session)
        // The user is in this very window: our keys would interleave with theirs, so wait for a pause.
        if session.isFrontmost && !foreground { try await waitForUserPause("typing into \(session.name), which the user is using") }
        if foreground {
            try await activate(session)
            try ensureKeyWindow(session, weActivated: true)
            body(session.pid)
            return session.isFrontmost ? " (foreground)" : " (could not bring the app forward; sent in background)"
        }
        func borrow() async throws -> String {
            try await waitForUserPause("the brief focus switch needed to type into \(session.name)")
            session.appElement.set("AXFrontmost", kCFBooleanTrue)
            if let window = session.window {
                window.perform("AXRaise")
                window.set("AXMain", kCFBooleanTrue)
            }
            if !session.isFrontmost { session.app.activate() }
            let deadline = Date().addingTimeInterval(0.5)
            while !session.isFrontmost && Date() < deadline { try? await Task.sleep(nanoseconds: 15_000_000) }
            // Frontmost is reported before the key window accepts input; keys sent right away get lost.
            try? await Task.sleep(nanoseconds: 150_000_000)
            let front = session.isFrontmost
            do { try ensureKeyWindow(session, weActivated: true) } catch {
                await giveFocusBack(to: previous, from: session)
                throw error
            }
            body(session.pid)
            try? await Task.sleep(nanoseconds: 100_000_000)
            await giveFocusBack(to: previous, from: session)
            return front ? " (focus borrowed ~0.2s, then returned)" : " (could not take focus; sent in background)"
        }
        if needsKeyWindow && !session.isFrontmost { return try await borrow() }
        if session.needsFocusForKeys && !session.isFrontmost {
            // Current Chromium/Electron builds take pid-posted keys in the background. Verify on the
            // focused text field and only borrow focus (and resend) when nothing arrived.
            let field = session.appElement.element("AXFocusedUIElement")
            let before = field?.str("AXValue")
            let start = Date()
            body(session.pid)
            try? await Task.sleep(nanoseconds: 120_000_000)
            let noticed = await changed(session, since: start)
            if let before, field?.str("AXValue") == before, noticed != true {
                return try await borrow() + " — background keys had no effect"
            }
            return " (background)"
        }
        body(session.pid)
        await giveFocusBack(to: previous, from: session)
        return " (background)"
    }

    func click(app: String, index: Int?, x: Double?, y: Double?, text: String?, button: MouseButtonKind, count: Int, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        let previous = foreground ? nil : userFrontmost(excluding: session)
        defer { markAction() }
        var index = index
        var x = x
        var y = y
        var found = ""
        if index == nil, x == nil, let text, !text.isEmpty {
            let target = try await locate(session, text: text)
            index = target.index
            if let point = target.point {
                x = Double((point.x - session.origin.x) * session.scale)
                y = Double((point.y - session.origin.y) * session.scale)
            }
            found = " [found via \(target.how)]"
        }
        let result = try await clickInner(session, index: index, x: x, y: y, button: button, count: count, foreground: foreground) + found
        await giveFocusBack(to: previous, from: session)
        return result
    }

    private func clickInner(_ session: Session, index: Int?, x: Double?, y: Double?, button: MouseButtonKind, count: Int, foreground: Bool) async throws -> String {
        var point: CGPoint
        var label: String
        var targetRect: CGRect?
        if let index {
            let el = try element(session, index)
            let actions = el.actionNames
            let name = session.info[index]?.label.map { Session.quote($0, max: 40) } ?? "[\(index)]"
            if !foreground, count == 1, button == .left, actions.contains("AXPress"), el.perform("AXPress") == .success {
                Overlay.shared.report(session, "Pressed \(name)", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) }, rect: el.frame)
                return "Pressed [\(index)]."
            }
            if !foreground, count == 1, button == .right, actions.contains("AXShowMenu"), el.perform("AXShowMenu") == .success {
                Overlay.shared.report(session, "Opened menu of \(name)", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) }, rect: el.frame)
                return "Opened the context menu of [\(index)]."
            }
            guard let center = await center(session, index, el) else {
                throw ToolError("Element [\(index)] has no on-screen frame. Try perform_secondary_action or x/y.")
            }
            point = center
            targetRect = el.frame
            label = "Clicked \(name)"
            if !foreground, count == 1, button == .left, ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(session.info[index]?.role ?? ""),
               el.set("AXFocused", kCFBooleanTrue) == .success, el.bool("AXFocused") == true {
                Overlay.shared.report(session, "Focused \(name)", at: point, rect: targetRect)
                return "Focused [\(index)] (background, no mouse movement)."
            }
        } else {
            guard let x, let y else { throw ToolError("Provide element_index, or both x and y.") }
            point = session.toScreen(x: x, y: y)
            guard Displays.contains(point) else { throw ToolError("(\(x), \(y)) maps outside every display. Refresh get_app_state.") }
            label = "Clicked at (\(Int(x)), \(Int(y)))"
        }
        Overlay.shared.report(session, label, at: point, rect: targetRect)
        if !foreground, let how = accessibilityClick(session, at: point, button: button, count: count) {
            return "\(label) — \(how)."
        }
        let how = try await pointer(session, foreground: foreground, at: point,
                                background: { Input.backgroundClick(pid: $0, at: point, button: button, count: count) },
                                real: { Input.click(at: point, button: button, count: count) })
        return "\(label) (\(button.rawValue) ×\(count))\(how)."
    }

    /// Background click without synthetic mouse events: hit-test the point and drive the element
    /// through accessibility. Returns nil when nothing suitable is there.
    private func accessibilityClick(_ session: Session, at point: CGPoint, button: MouseButtonKind, count: Int) -> String? {
        guard count == 1 else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(session.appElement, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        for _ in 0..<8 {
            let role = current.str("AXRole") ?? ""
            if ["AXWindow", "AXWebArea", "AXScrollArea", "AXApplication", "AXSplitGroup"].contains(role) { return nil }
            // Anonymous wrappers (web divs, images, text runs) often expose Press but aren't the
            // control the user sees; keep walking up to the real button/link/menu.
            let anonymous = ["AXGroup", "AXGenericElement", "AXImage", "AXStaticText", "AXUnknown"].contains(role)
                && current.str("AXTitle")?.isEmpty != false && current.str("AXDescription")?.isEmpty != false
            if anonymous {
                guard let parent = current.element("AXParent") else { return nil }
                current = parent
                continue
            }
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

    func hover(app: String, index: Int?, x: Double?, y: Double?, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        var point: CGPoint
        var rect: CGRect?
        if let index {
            let el = try element(session, index)
            guard let center = await center(session, index, el) else { throw ToolError("Element [\(index)] has no on-screen frame.") }
            point = center
            rect = el.frame
        } else if let x, let y {
            point = session.toScreen(x: x, y: y)
        } else {
            throw ToolError("Provide element_index, or both x and y.")
        }
        Overlay.shared.report(session, "Hovering", at: point, rect: rect)
        let how = try await pointer(session, foreground: foreground, restoreCursor: false, at: point,
                                background: { Input.backgroundHover(pid: $0, at: point) },
                                real: { Input.move(to: point) })
        return "Hovered at screen point (\(Int(point.x)), \(Int(point.y)))\(how)."
    }

    func drag(app: String, from: (Double, Double), to: (Double, Double), foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        let start = session.toScreen(x: from.0, y: from.1)
        let end = session.toScreen(x: to.0, y: to.1)
        Overlay.shared.report(session, "Dragging", at: end)
        let how = try await pointer(session, foreground: foreground, at: start,
                                background: { Input.backgroundDrag(pid: $0, from: start, to: end) },
                                real: { Input.drag(from: start, to: end) })
        return "Dragged from (\(Int(from.0)), \(Int(from.1))) to (\(Int(to.0)), \(Int(to.1)))\(how)."
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
        // Excel grid: the first background key of each entry is spent opening the cell editor.
        if session.isExcel, let focused = session.appElement.element("AXFocusedUIElement"),
           focused.str("AXRole") == "AXLayoutArea" {
            return try await typeExcelCells(session, text: text, foreground: foreground)
        }
        // Browsers, Electron and Office fake settable text: Excel's formula bar accepts
        // AXSelectedText but never commits it to the cell.
        if !foreground, !session.fakesTextInsertion, let focused = session.appElement.element("AXFocusedUIElement"),
           focused.isSettable("AXSelectedText"), !isInWebContent(focused) {
            // Native text views: insert at the caret through accessibility. Newlines/tabs are still keys.
            var segment = ""
            @MainActor func flush() {
                if !segment.isEmpty { focused.set("AXSelectedText", segment as CFString) }
                segment = ""
            }
            for char in text {
                if char == "\n" || char == "\r\n" || char == "\r" || char == "\t" {
                    flush()
                    let key = KeyStroke(code: char == "\t" ? 48 : 36)
                    _ = try await withKeyboard(session, foreground: false) { Input.press(key, to: $0) }
                } else {
                    segment.append(char)
                }
            }
            flush()
            return "Inserted \(text.count) character(s) into the focused field (background)."
        }
        let how = try await withKeyboard(session, foreground: foreground) { Input.typeText(text, to: $0) }
        return "Typed \(text.count) character(s)\(how)."
    }

    /// Excel grid entry, row by row. Excel's own Return after a run of Tabs jumps back to wherever
    /// it thinks the run began (not reset by Name Box navigation), so each new row is reached
    /// explicitly through the Name Box: same column as the starting cell, next row.
    private func typeExcelCells(_ session: Session, text: String, foreground: Bool) async throws -> String {
        func nameBox() -> AXUIElement? {
            guard let window = session.window else { return nil }
            func search(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
                guard depth < 4 else { return nil }
                for child in el.elements("AXChildren") {
                    if child.str("AXIdentifier") == "NameBox" { return child }
                    if let found = search(child, depth + 1) { return found }
                }
                return nil
            }
            return search(window, 0)
        }
        // "N2" → ("N", 2); ranges and names ("A1:B3", "Total") can't anchor rows.
        var anchor: (column: String, row: Int)?
        if let box = nameBox(), let ref = box.str("AXValue"),
           let match = ref.range(of: #"^\$?([A-Za-z]{1,3})\$?([0-9]+)$"#, options: .regularExpression), match == ref.startIndex..<ref.endIndex {
            let letters = ref.filter(\.isLetter)
            if let row = Int(ref.filter(\.isNumber)) { anchor = (letters.uppercased(), row) }
        }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var how = ""
        for (i, row) in rows.enumerated() {
            let isLast = i == rows.count - 1
            if !row.isEmpty {
                how = try await withKeyboard(session, foreground: foreground) { Input.typeCells(row, to: $0) }
            }
            if isLast { break }
            if let anchor, let box = nameBox() {
                // Commit the open entry without moving, then jump to the next row's first cell.
                if !row.isEmpty {
                    _ = try await withKeyboard(session, foreground: foreground) { Input.press(KeyStroke(code: 36), to: $0) }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                box.set("AXFocused", kCFBooleanTrue)
                box.set("AXValue", "\(anchor.column)\(anchor.row + i + 1)" as CFString)
                // AXConfirm doesn't navigate; a Return in the focused Name Box does.
                Input.press(KeyStroke(code: 36), to: session.pid)
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let grid = session.appElement.element("AXFocusedUIElement"), grid.str("AXRole") != "AXLayoutArea",
                   let layout = session.window?.elements("AXChildren").first(where: { $0.str("AXRole") == "AXLayoutArea" }) {
                    layout.set("AXFocused", kCFBooleanTrue)
                }
            } else {
                how = try await withKeyboard(session, foreground: foreground) { Input.press(KeyStroke(code: 36), to: $0) }
                Input.pause(0.1)
            }
        }
        let note = anchor.map { " starting at \($0.column)\($0.row), one row per line" } ?? ""
        return "Typed \(text.count) character(s) into cells\(note) (F2 + select-all per entry, so each replaces its cell)\(how)."
    }

    /// Text of the app's current modal alert or sheet, if any (used to spot alerts an action raised).
    func modalSignature(app: String) async -> String? {
        guard let session = try? await self.session(app, launch: false) else { return nil }
        return session.modalAlert.map { Session.texts(in: $0).joined(separator: " ") }
    }

    /// A note for the tool result when the action just raised an alert (compile errors, circular
    /// references, "save changes?"): later input would be blocked until it is dismissed.
    func newAlertNote(app: String, before: String?) async -> String {
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let now = await modalSignature(app: app), now != before else { return "" }
        let message = now.replacingOccurrences(of: "\n", with: " ")
        return "\n⚠ An alert is now open and blocks input: \(Session.quote(message, max: 200)). Read it with get_app_state and dismiss it before continuing."
    }

    func pressKey(app: String, key: String, foreground: Bool) async throws -> String {
        let stroke = try Input.parse(key)
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        Overlay.shared.report(session, "Pressed \(key)", at: nil)
        // Menu shortcuts (Cmd/Ctrl+…) act on the key window, which only an active app has.
        let isShortcut = stroke.modifiers.contains { $0.flag == .maskCommand || $0.flag == .maskControl }
        // Select All in a text field: set the selection through accessibility (works in the
        // background everywhere, including Chromium where posted Cmd+A is ignored).
        if !foreground, stroke.code == 0, stroke.modifiers.map(\.flag) == [.maskCommand],
           let field = session.appElement.element("AXFocusedUIElement"), field.isSettable("AXSelectedTextRange"),
           let text = field.str("AXValue") {
            var range = CFRange(location: 0, length: text.utf16.count)
            if let value = AXValueCreate(.cfRange, &range), field.set("AXSelectedTextRange", value) == .success {
                return "Pressed \(key): selected all text of the focused field through accessibility (background, no focus change)."
            }
        }
        // Most shortcuts are a menu item's key equivalent: pressing the item through accessibility
        // runs the same command with no focus switch at all.
        if isShortcut, !foreground, !session.shortcutsWorkInBackground, !session.isFrontmost,
           let item = menuItem(matching: stroke, in: session), await pressMenuItem(item, in: session) {
            return "Pressed \(key) through its menu item \(Session.quote(item.str("AXTitle") ?? "?")) (background, no focus change)."
        }
        let how = try await withKeyboard(session, foreground: foreground, needsKeyWindow: isShortcut) { Input.press(stroke, to: $0) }
        return "Pressed \(key)\(how)."
    }

    /// An enabled plain "Paste" button in the working window's toolbars (not a ribbon menu button).
    private func pasteButton(_ session: Session) -> AXUIElement? {
        guard let window = session.window else { return nil }
        func search(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 4 else { return nil }
            for child in el.elements("AXChildren") {
                let role = child.str("AXRole")
                if role == "AXButton", ["Paste", "Colar"].contains(child.str("AXTitle") ?? ""), child.bool("AXEnabled") != false { return child }
                if role == "AXToolbar" || role == "AXGroup", let found = search(child, depth + 1) { return found }
            }
            return nil
        }
        return search(window, 0)
    }

    func paste(app: String, text: String, format: String, foreground: Bool) async throws -> String {
        let session = try await self.session(app, launch: false)
        defer { markAction() }
        Overlay.shared.report(session, "Pasting \(text.count) characters", at: nil)
        // Plain text into a native field: insert directly, leaving the clipboard alone.
        if !foreground, !session.fakesTextInsertion, format.lowercased() == "text" || format.isEmpty,
           let focused = session.appElement.element("AXFocusedUIElement"),
           focused.isSettable("AXSelectedText"), !isInWebContent(focused),
           focused.set("AXSelectedText", text as CFString) == .success {
            return "Inserted \(text.count) character(s) into the focused field (background, clipboard untouched)."
        }
        let saved = Clipboard.save()
        try Clipboard.put(text, format: format)
        // Some windows only honor Cmd+V while active (legacy editors such as Excel's VBA editor),
        // but offer a Paste toolbar button that can be pressed in the background.
        if !foreground, let button = pasteButton(session), button.perform("AXPress") == .success {
            try? await Task.sleep(nanoseconds: 600_000_000)
            Clipboard.restore(saved)
            return "Pasted \(text.count) character(s) as \(format) with the window's Paste button (background); clipboard restored."
        }
        let stroke = try Input.parse("super+v")
        let how: String
        do {
            how = try await withKeyboard(session, foreground: foreground, needsKeyWindow: true) { Input.press(stroke, to: $0) }
        } catch {
            Clipboard.restore(saved)
            throw error
        }
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
        if !foreground, let area = scrollArea(session, index: index, point: point),
           let done = scrollViaBar(area, direction: direction.lowercased(), pages: pages) {
            return done
        }
        let how = try await pointer(session, foreground: foreground, at: point,
                                background: { Input.backgroundScroll(pid: $0, at: point, dx: dx, dy: dy) },
                                real: { Input.scroll(at: point, dx: dx, dy: dy) })
        return "Scrolled \(direction) \(pages) page(s)\(how)."
    }

    /// The scroll area an element or point belongs to.
    private func scrollArea(_ session: Session, index: Int?, point: CGPoint) -> AXUIElement? {
        var current: AXUIElement?
        if let index { current = session.elements[index] }
        if current == nil {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(session.appElement, Float(point.x), Float(point.y), &hit) == .success { current = hit }
        }
        for _ in 0..<12 {
            guard let el = current else { return nil }
            if el.str("AXRole") == "AXScrollArea" { return el }
            current = el.element("AXParent")
        }
        return nil
    }

    /// Scrolls by setting the scroll bar's position through accessibility: works in the
    /// background, moves nothing on screen but the content, and is exact. Nil when unsupported.
    private func scrollViaBar(_ area: AXUIElement, direction: String, pages: Double) -> String? {
        let vertical = ["down", "d", "up", "u"].contains(direction)
        let forward = ["down", "d", "right", "r"].contains(direction)
        guard let bar = area.element(vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"), bar.isSettable("AXValue"),
              let current = (bar.raw("AXValue") as? NSNumber)?.doubleValue,
              let visible = area.frame, let content = area.elements("AXContents").first?.frame else { return nil }
        let span = vertical ? content.height - visible.height : content.width - visible.width
        guard span > 1 else { return "Nothing to scroll: all the content already fits (background)." }
        let step = Double((vertical ? visible.height : visible.width) * 0.8 / span) * pages
        let target = min(1, max(0, current + (forward ? step : -step)))
        if abs(target - current) < 0.0001 {
            return "Already at the \(forward ? (vertical ? "bottom" : "right edge") : (vertical ? "top" : "left edge")); nothing scrolled."
        }
        guard bar.set("AXValue", NSNumber(value: target)) == .success else { return nil }
        let position = Int((target * 100).rounded())
        return "Scrolled \(direction) \(pages) page(s) via the scroll bar (background), now at \(position)%."
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
                // Text views may accept the write and then restore their own content; check a beat later.
                try? await Task.sleep(nanoseconds: 80_000_000)
                let readBack = el.str("AXValue")
                if (readBack == nil && !value.isEmpty) || (readBack ?? "") == value || Double(readBack ?? "") == Double(value) {
                    Overlay.shared.report(session, "Set value of [\(index)]", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) }, rect: el.frame)
                    return "Set the value of [\(index)]."
                }
            }
        }
        // Text fields: select the whole content and replace it through accessibility (no keys at all).
        if !session.fakesTextInsertion, el.isSettable("AXSelectedTextRange"), el.isSettable("AXSelectedText") {
            let length = (el.str("AXValue") ?? "").utf16.count
            var range = CFRange(location: 0, length: length)
            if let axRange = AXValueCreate(.cfRange, &range), el.set("AXSelectedTextRange", axRange) == .success,
               el.set("AXSelectedText", value as CFString) == .success {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if (el.str("AXValue") ?? "") == value {
                    return "Set the value of [\(index)] (replaced its text through accessibility)."
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
        Overlay.shared.report(session, "\(AX.displayAction(match)) on [\(index)]", at: el.frame.map { CGPoint(x: $0.midX, y: $0.midY) }, rect: el.frame)
        return "Performed \(AX.displayAction(match)) on [\(index)]."
    }


    // MARK: Finding things by text

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureWindow(_ session: Session) {
        if session.window == nil || session.windowFrame == nil {
            session.window = session.pickWindow(nil)
            session.windowFrame = session.window?.frame
            session.origin = session.windowFrame?.origin ?? .zero
            session.scale = session.windowFrame.map(Session.imageScale) ?? 1
        }
    }

    /// Finds the on-screen control whose visible text matches: accessibility first (exact label,
    /// then partial, preferring enabled and clickable elements), OCR as the fallback.
    /// True when `needle` occurs in `haystack` as whole words (bounded by non-alphanumerics).
    nonisolated static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !(haystack[haystack.index(before: range.lowerBound)].isLetter || haystack[haystack.index(before: range.lowerBound)].isNumber)
            let afterOK = range.upperBound == haystack.endIndex
                || !(haystack[range.upperBound].isLetter || haystack[range.upperBound].isNumber)
            if beforeOK && afterOK { return true }
            searchRange = haystack.index(after: range.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private func locate(_ session: Session, text: String) async throws -> (index: Int?, point: CGPoint?, how: String) {
        ensureWindow(session)
        let needle = Engine.fold(text)
        let collected = session.collect(expandAll: false, maxNodes: 4000, maxVisit: 20_000, pruneOffscreen: true)
        // "OK" must not match "Workbook area": short queries need a whole-word match, and big
        // containers only count on an exact label.
        let containers: Set<String> = ["AXLayoutArea", "AXScrollArea", "AXGroup", "AXWindow", "AXSplitGroup", "AXWebArea", "AXTable", "AXOutline", "AXList"]
        func score(_ node: NodeInfo) -> Int? {
            let labels = [node.title, node.desc, node.value, node.placeholder].compactMap { $0 }.map(Engine.fold)
            var points: Int
            if labels.contains(needle) { points = 100 }
            else if containers.contains(node.role) { return nil }
            else if labels.contains(where: { Engine.containsWord($0, needle) }) { points = 60 }
            else if needle.count >= 4, labels.contains(where: { $0.contains(needle) }) { points = 30 }
            else { return nil }
            if Session.obviousPress.contains(node.role) || node.actions.contains("AXPress") { points += 20 }
            if node.enabled == false { points -= 50 }
            if node.role == "AXStaticText" { points -= 5 }
            return points
        }
        let ranked = collected.nodes.compactMap { node in score(node).map { (node, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                let areaA = (a.0.frame?.width ?? .greatestFiniteMagnitude) * (a.0.frame?.height ?? 1)
                let areaB = (b.0.frame?.width ?? .greatestFiniteMagnitude) * (b.0.frame?.height ?? 1)
                return areaA < areaB
            }
        if let best = ranked.first {
            let registered = session.register([best.0], replace: false)
            if let index = registered.first?.0 { return (index, nil, "accessibility [\(index)]") }
        }
        let lines = try await ocrLines(session)
        let exact = lines.first { Engine.fold($0.text) == needle }
        let partial = lines.first(where: { Engine.containsWord(Engine.fold($0.text), needle) })
            ?? (needle.count >= 4 ? lines.first(where: { Engine.fold($0.text).contains(needle) }) : nil)
        guard let hit = exact ?? partial else {
            throw ToolError("No visible element or text matching \(Session.quote(text)) in \(session.name). Try get_app_state or read_screen_text.")
        }
        // For a partial OCR hit, aim at the matching words inside the line.
        var rect = hit.screenRect
        if exact == nil, let range = Engine.fold(hit.text).range(of: needle) {
            let folded = Engine.fold(hit.text)
            let startRatio = CGFloat(folded.distance(from: folded.startIndex, to: range.lowerBound)) / CGFloat(max(folded.count, 1))
            let lengthRatio = CGFloat(needle.count) / CGFloat(max(folded.count, 1))
            rect = CGRect(x: rect.minX + rect.width * startRatio, y: rect.minY, width: rect.width * lengthRatio, height: rect.height)
        }
        return (nil, CGPoint(x: rect.midX, y: rect.midY), "OCR")
    }

    private struct ScreenLine {
        let text: String
        let screenRect: CGRect
        let confidence: Float
    }

    /// OCR of the app's window at high resolution, mapped to screen points.
    private func ocrLines(_ session: Session) async throws -> [ScreenLine] {
        guard Capture.hasPermission else { throw ToolError("OCR needs Screen Recording permission (see check_permissions).") }
        ensureWindow(session)
        guard let frame = session.windowFrame else { throw ToolError("\(session.name) has no window to read.") }
        let (image, captured) = try await Capture.window(pid: session.pid, near: frame, maxEdge: 3200)
        let ratio = CGFloat(image.width) / max(1, captured.width)
        return try await OCR.recognize(image).map { line in
            ScreenLine(text: line.text,
                       screenRect: CGRect(x: captured.minX + line.rect.minX / ratio, y: captured.minY + line.rect.minY / ratio,
                                          width: line.rect.width / ratio, height: line.rect.height / ratio),
                       confidence: line.confidence)
        }
    }

    func readScreenText(app: String, query: String?, window: String?) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        await settle(session)
        session.window = session.pickWindow(window)
        session.windowFrame = session.window?.frame
        session.origin = session.windowFrame?.origin ?? .zero
        session.scale = session.windowFrame.map(Session.imageScale) ?? 1
        Overlay.shared.report(session, "Reading text on screen", at: nil)
        var lines = try await ocrLines(session)
        if let query, !query.isEmpty {
            let needle = Engine.fold(query)
            lines = lines.filter { Engine.fold($0.text).contains(needle) }
        }
        if lines.isEmpty { return [.text("No text\(query.map { " matching \(Session.quote($0))" } ?? "") recognized in \(session.name).")] }
        let rendered = lines.prefix(400).map { line -> String in
            let r = session.toImage(line.screenRect)
            let conf = line.confidence < 0.5 ? " (low confidence)" : ""
            return "\(Session.quote(line.text, max: 200)) @(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))\(conf)"
        }
        return [.text("OCR of \(session.name) (\(lines.count) line(s), reading order). @(x,y,w,h) use the same pixels as get_app_state, so click x/y at a line's center works:\n" + rendered.joined(separator: "\n"))]
    }

    // MARK: Waiting and reading

    func waitFor(app: String, query: String, role: String?, gone: Bool, timeout: Double) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        let needle = Engine.fold(query)
        let roleNeedle = role.map(Engine.fold)
        let deadline = Date().addingTimeInterval(timeout)
        let start = Date()
        while true {
            ensureWindow(session)
            session.window = session.pickWindow(nil)
            session.windowFrame = session.window?.frame
            let collected = session.collect(expandAll: false, maxNodes: 5000, maxVisit: 25_000)
            let matches = collected.nodes.filter { node in
                if let roleNeedle, !Engine.fold(Session.roleName(node.role, node.subrole)).contains(roleNeedle) { return false }
                return Engine.fold(node.searchText).contains(needle)
            }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            if gone && matches.isEmpty {
                return [.text("\(Session.quote(query)) is gone from \(session.name) after \(elapsed)s.")]
            }
            if !gone, !matches.isEmpty {
                let registered = session.register(Array(matches.prefix(10)), replace: false)
                return [.text("Found after \(elapsed)s:\n" + registered.map { session.render($0.1, index: $0.0) }.joined(separator: "\n"))]
            }
            if Date() >= deadline {
                throw ToolError("Timed out after \(Int(timeout))s waiting for \(Session.quote(query)) to \(gone ? "disappear" : "appear") in \(session.name).")
            }
            // Re-check as soon as the app reports a change (or every 0.5 s).
            let mark = Date()
            while Date() < deadline && Date().timeIntervalSince(mark) < 0.5 && session.lastChange <= mark {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func readText(app: String, index: Int?, maxChars: Int) async throws -> [Content] {
        let session = try await self.session(app, launch: true)
        await settle(session)
        ensureWindow(session)
        let root: AXUIElement
        if let index { root = try element(session, index) } else {
            guard let window = session.pickWindow(nil) else { throw ToolError("\(session.name) has no window.") }
            root = window
        }
        let rootRole = root.str("AXRole") ?? ""
        if ["AXTextArea", "AXTextField", "AXStaticText", "AXComboBox", "AXSearchField"].contains(rootRole),
           let value = root.str("AXValue"), !value.isEmpty {
            return [.text(clip(value, maxChars))]
        }
        // Walk the subtree gathering visible text in document order, breaking lines on layout.
        var output = ""
        var lastFrame: CGRect?
        var visited = 0
        var lastPiece = ""
        func walk(_ el: AXUIElement, level: Int) {
            guard visited < 60_000, level < 120, output.count < maxChars + 200 else { return }
            visited += 1
            guard let v = el.multi(["AXRole", "AXValue", "AXTitle", "AXChildren", "AXPosition", "AXSize"]) else { return }
            let role = AX.string(v[0]) ?? ""
            if Session.skipRoles.contains(role) { return }
            var piece: String?
            switch role {
            case "AXStaticText": piece = AX.string(v[1]) ?? AX.string(v[2])
            case "AXTextField", "AXTextArea", "AXSearchField": piece = AX.string(v[1]).map { "[\($0)]" }
            case "AXImage": piece = nil
            default: piece = nil
            }
            if let text = piece?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != lastPiece {
                var frame: CGRect?
                if let p = AX.point(v[4]), let s = AX.size(v[5]) { frame = CGRect(origin: p, size: s) }
                if !output.isEmpty {
                    if let frame, let last = lastFrame, frame.minY < last.maxY - 2 && frame.minY >= last.minY - 2 {
                        output += " "
                    } else {
                        output += "\n"
                    }
                }
                output += text
                lastPiece = text
                lastFrame = frame ?? lastFrame
            }
            for child in AX.elements(v[3]) { walk(child, level: level + 1) }
        }
        walk(root, level: 0)
        if output.isEmpty {
            return [.text("No accessible text under that element. For canvas/custom UIs use read_screen_text (OCR).")]
        }
        return [.text(clip(output, maxChars))]
    }

    private func clip(_ text: String, _ maxChars: Int) -> String {
        text.count <= maxChars ? text : String(text.prefix(maxChars)) + "\n…(\(text.count - maxChars) more characters; raise max_chars or read a narrower element)"
    }

    // MARK: Menus, windows, opening things

    func selectMenu(app: String, path: String) async throws -> String {
        let session = try await self.session(app, launch: true)
        defer { markAction() }
        let parts = path.components(separatedBy: CharacterSet(charactersIn: ">→")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ToolError("path looks like \"File > Save As…\".") }
        guard let menuBar = session.appElement.element("AXMenuBar") else { throw ToolError("\(session.name) has no menu bar.") }

        func pick(_ items: [AXUIElement], _ name: String) -> AXUIElement? {
            let needle = Engine.fold(name).replacingOccurrences(of: "...", with: "…")
            let titled = items.map { ($0, Engine.fold($0.str("AXTitle") ?? "").replacingOccurrences(of: "...", with: "…")) }
            if let exact = titled.first(where: { $0.1 == needle }) { return exact.0 }
            let partial = titled.filter { !$0.1.isEmpty && $0.1.hasPrefix(needle) }
            return partial.count == 1 ? partial[0].0 : titled.first(where: { $0.1.contains(needle) })?.0
        }
        var current: AXUIElement = menuBar
        var trail: [String] = []
        for (i, name) in parts.enumerated() {
            var items = current.elements("AXChildren")
            // Menu bar items and submenu items hold an AXMenu whose children are the entries.
            if i > 0, let menu = items.first(where: { $0.str("AXRole") == "AXMenu" }) { items = menu.elements("AXChildren") }
            guard let next = pick(items, name) else {
                let available = items.compactMap { $0.str("AXTitle") }.filter { !$0.isEmpty }.prefix(30).joined(separator: ", ")
                throw ToolError("No menu item \(Session.quote(name)) under \(trail.isEmpty ? "the menu bar" : trail.joined(separator: " > ")). Available: \(available)")
            }
            trail.append(next.str("AXTitle") ?? name)
            current = next
        }
        Overlay.shared.report(session, "Menu " + trail.joined(separator: " › "), at: nil)
        if current.bool("AXEnabled") != false, await pressMenuItem(current, in: session) {
            return "Chose \(trail.joined(separator: " > ")) (background)."
        }
        // Window commands are disabled while the app is inactive, and menus only re-validate when
        // opened. Borrow focus, press anyway, and fall back to the item's own keyboard shortcut.
        let previous = userFrontmost(excluding: session)
        try await activate(session)
        try? await Task.sleep(nanoseconds: 120_000_000)
        var how = "focus borrowed briefly, then returned"
        var status = current.perform("AXPress")
        if status != .success, let stroke = shortcut(of: current) {
            Input.press(stroke, to: session.pid)
            status = .success
            how = "via its keyboard shortcut; focus borrowed briefly, then returned"
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await giveFocusBack(to: previous, from: session)
        guard status == .success else { throw ToolError("\(trail.joined(separator: " > ")) is unavailable right now (AXError \(status.rawValue)).") }
        return "Chose \(trail.joined(separator: " > ")) (\(how))."
    }

    /// Presses a menu item through accessibility. Chromium/Electron menu bars report success for
    /// presses that do nothing while the app is inactive, so there it only counts when the app
    /// visibly reacted.
    private func pressMenuItem(_ item: AXUIElement, in session: Session) async -> Bool {
        let start = Date()
        guard item.perform("AXPress") == .success else { return false }
        guard session.needsFocusForKeys else { return true }
        return await changed(session, since: start, within: 0.8) == true
    }

    /// The enabled menu item whose key equivalent is `stroke` (Apple menu excluded: its shortcuts
    /// are system-wide, like Force Quit).
    private func menuItem(matching stroke: KeyStroke, in session: Session) -> AXUIElement? {
        func signature(_ s: KeyStroke) -> String {
            "\(s.code ?? 0):" + s.modifiers.map { String($0.flag.rawValue) }.sorted().joined(separator: ",")
        }
        let wanted = signature(stroke)
        func search(_ menu: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard depth < 4 else { return nil }
            for item in menu.elements("AXChildren") {
                if let equivalent = shortcut(of: item), signature(equivalent) == wanted, item.bool("AXEnabled") != false {
                    return item
                }
                if let submenu = item.elements("AXChildren").first(where: { $0.str("AXRole") == "AXMenu" }),
                   let found = search(submenu, depth + 1) {
                    return found
                }
            }
            return nil
        }
        guard let menuBar = session.appElement.element("AXMenuBar") else { return nil }
        for barItem in menuBar.elements("AXChildren").dropFirst() {
            if let menu = barItem.elements("AXChildren").first(where: { $0.str("AXRole") == "AXMenu" }),
               let found = search(menu, 0) {
                return found
            }
        }
        return nil
    }

    /// A menu item's key equivalent as a keystroke (AXMenuItemCmdChar + AXMenuItemCmdModifiers).
    private func shortcut(of item: AXUIElement) -> KeyStroke? {
        guard let char = item.str("AXMenuItemCmdChar"), let first = char.lowercased().first, !char.isEmpty else { return nil }
        let bits = (item.raw("AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
        var parts: [String] = []
        if bits & 8 == 0 { parts.append("cmd") }       // 8 = no Command
        if bits & 1 != 0 { parts.append("shift") }
        if bits & 2 != 0 { parts.append("alt") }
        if bits & 4 != 0 { parts.append("ctrl") }
        parts.append(String(first))
        return try? Input.parse(parts.joined(separator: "+"))
    }

    func manageWindow(app: String, action: String, window: String?, x: Double?, y: Double?, width: Double?, height: Double?) async throws -> String {
        let session = try await self.session(app, launch: true)
        defer { markAction() }
        guard let win = session.pickWindow(window) else { throw ToolError("\(session.name) has no window.") }
        let title = Session.quote(win.str("AXTitle") ?? "", max: 50)
        func setPoint(_ p: CGPoint) -> AXError { var p = p; return win.set("AXPosition", AXValueCreate(.cgPoint, &p)!) }
        func setSize(_ s: CGSize) -> AXError { var s = s; return win.set("AXSize", AXValueCreate(.cgSize, &s)!) }
        var status: AXError
        switch action.lowercased() {
        case "move":
            guard let x, let y else { throw ToolError("move needs x and y (screen points, top-left of the main display is 0,0).") }
            status = setPoint(CGPoint(x: x, y: y))
        case "resize":
            guard let width, let height else { throw ToolError("resize needs width and height (points).") }
            status = setSize(CGSize(width: width, height: height))
        case "move_resize", "frame":
            guard let x, let y, let width, let height else { throw ToolError("frame needs x, y, width and height.") }
            status = setPoint(CGPoint(x: x, y: y))
            if status == .success { status = setSize(CGSize(width: width, height: height)) }
        case "minimize": status = win.set("AXMinimized", kCFBooleanTrue)
        case "restore", "unminimize": status = win.set("AXMinimized", kCFBooleanFalse)
        case "fullscreen": status = win.set("AXFullScreen", kCFBooleanTrue)
        case "exit_fullscreen": status = win.set("AXFullScreen", kCFBooleanFalse)
        case "raise": status = win.perform("AXRaise")
        case "close":
            guard let close = win.element("AXCloseButton") else { throw ToolError("This window has no close button.") }
            status = close.perform("AXPress")
        default:
            throw ToolError("action must be move, resize, frame, minimize, restore, fullscreen, exit_fullscreen, raise or close.")
        }
        guard status == .success else { throw ToolError("\(action) was refused for window \(title) (AXError \(status.rawValue)).") }
        let frame = win.frame.map { " Now at (\(Int($0.minX)), \(Int($0.minY))) size \(Int($0.width))x\(Int($0.height)) pt." } ?? ""
        return "\(action) done for \(title).\(frame)"
    }

    func open(target: String, app: String?) async throws -> String {
        let expanded = (target as NSString).expandingTildeInPath
        let url: URL
        if let parsed = URL(string: target), let scheme = parsed.scheme, scheme.count > 1 {
            url = parsed
        } else {
            guard FileManager.default.fileExists(atPath: expanded) else { throw ToolError("No such file: \(expanded)") }
            url = URL(fileURLWithPath: expanded)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let opened: NSRunningApplication
        if let app {
            guard let appURL = Apps.findRunning(app)?.bundleURL ?? Apps.findInstalled(app) else {
                throw ToolError("App '\(app)' not found. Use list_apps.")
            }
            opened = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            opened = try await NSWorkspace.shared.open(url, configuration: config)
        }
        markAction()
        return "Opened \(url.isFileURL ? url.path : url.absoluteString) in \(opened.localizedName ?? "its app") (in the background). Next: get_app_state app=\"\(opened.bundleIdentifier ?? opened.localizedName ?? "")\"."
    }

    func screenshot(app: String?, display: Int, window: String?, index: Int?, region: [Double]?) async throws -> [Content] {
        guard Capture.hasPermission else {
            throw ToolError("Screen Recording permission is missing for \"\(Permissions.responsibleAppName)\". Run check_permissions.")
        }
        if let app, index != nil || region != nil {
            // Zoomed crop of one element or region, captured at full resolution for small text.
            let session = try await self.session(app, launch: true)
            ensureWindow(session)
            var target: CGRect
            if let index {
                let el = try element(session, index)
                guard let frame = el.frame ?? session.info[index]?.frame else { throw ToolError("[\(index)] has no frame.") }
                target = frame
            } else if let region, region.count == 4 {
                let a = session.toScreen(x: region[0], y: region[1])
                target = CGRect(x: a.x, y: a.y, width: CGFloat(region[2]) / session.scale, height: CGFloat(region[3]) / session.scale)
            } else {
                throw ToolError("region must be [x, y, width, height] in screenshot pixels.")
            }
            guard let frame = session.windowFrame else { throw ToolError("\(session.name) has no window.") }
            let (image, captured) = try await Capture.window(pid: session.pid, near: frame, maxEdge: 6000)
            let ratio = CGFloat(image.width) / max(1, captured.width)
            let crop = CGRect(x: (target.minX - captured.minX) * ratio, y: (target.minY - captured.minY) * ratio,
                              width: target.width * ratio, height: target.height * ratio).insetBy(dx: -8 * ratio, dy: -8 * ratio)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !crop.isNull, crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop.integral) else {
                throw ToolError("That area is outside the window.")
            }
            let data = Capture.jpeg(Capture.fit(cropped, maxEdge: Capture.maxEdge), quality: 0.9)
            return [.text("Zoomed view (\(cropped.width)x\(cropped.height) source px). View only — use get_app_state coordinates for clicks."),
                    .image(data, mime: "image/jpeg")]
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
