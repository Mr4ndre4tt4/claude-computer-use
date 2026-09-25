import Foundation

@MainActor
final class Tools {
    private let engine = Engine()

    // MARK: Argument helpers

    private func string(_ a: JSON, _ key: String) -> String? { a[key] as? String }

    private func int(_ a: JSON, _ key: String) -> Int? {
        if let n = a[key] as? NSNumber { return n.intValue }
        if let s = a[key] as? String { return Int(s) }
        return nil
    }

    private func double(_ a: JSON, _ key: String) -> Double? {
        if let n = a[key] as? NSNumber { return n.doubleValue }
        if let s = a[key] as? String { return Double(s) }
        return nil
    }

    private func bool(_ a: JSON, _ key: String) -> Bool? {
        if let n = a[key] as? NSNumber { return n.boolValue }
        if let s = a[key] as? String { return s.lowercased() == "true" }
        return nil
    }

    private func fg(_ a: JSON) -> Bool { bool(a, "foreground") ?? false }

    private func required(_ a: JSON, _ key: String) throws -> String {
        guard let value = string(a, key), !value.isEmpty else { throw ToolError("Missing required argument '\(key)'.") }
        return value
    }

    private func requiredInt(_ a: JSON, _ key: String) throws -> Int {
        guard let value = int(a, key) else { throw ToolError("Missing required integer argument '\(key)'.") }
        return value
    }

    private func requiredDouble(_ a: JSON, _ key: String) throws -> Double {
        guard let value = double(a, key) else { throw ToolError("Missing required number argument '\(key)'.") }
        return value
    }

    // MARK: Calls

    func call(_ name: String, _ args: JSON) async -> JSON {
        do {
            var content = try await dispatch(name, args)
            if bool(args, "then_get_state") == true, name != "get_app_state", let app = string(args, "app") {
                content += try await engine.getAppState(app: app, disableDiff: false, screenshot: nil, window: nil, includeOffscreen: false)
            }
            return ["content": content.map(\.json), "isError": false]
        } catch let error as ToolError {
            return ["content": [Content.text("Error: \(error.message)").json], "isError": true]
        } catch {
            return ["content": [Content.text("Error: \(error.localizedDescription)").json], "isError": true]
        }
    }

    private func dispatch(_ name: String, _ a: JSON) async throws -> [Content] {
        switch name {
        case "list_apps":
            return engine.listApps(runningOnly: bool(a, "running_only") ?? false, limit: int(a, "limit") ?? 150)

        case "get_app_state":
            return try await engine.getAppState(
                app: try required(a, "app"),
                disableDiff: bool(a, "disable_diff") ?? bool(a, "disableDiff") ?? false,
                screenshot: bool(a, "screenshot"),
                window: string(a, "window") ?? int(a, "window").map(String.init),
                includeOffscreen: bool(a, "include_offscreen") ?? false
            )

        case "find_elements":
            return try await engine.findElements(
                app: try required(a, "app"), query: string(a, "query") ?? "",
                role: string(a, "role"), limit: max(1, min(int(a, "limit") ?? 40, 300))
            )

        case "click":
            let count = max(1, min(int(a, "click_count") ?? 1, 3))
            let appName = try required(a, "app")
            let before = await engine.modalSignature(app: appName)
            let result = try await engine.click(
                app: appName, index: int(a, "element_index"), x: double(a, "x"), y: double(a, "y"),
                text: string(a, "text"), button: try MouseButtonKind.parse(string(a, "mouse_button")), count: count, foreground: fg(a)
            )
            return [.text(result + (await engine.newAlertNote(app: appName, before: before)))]

        case "hover":
            return [.text(try await engine.hover(
                app: try required(a, "app"), index: int(a, "element_index"), x: double(a, "x"), y: double(a, "y"), foreground: fg(a)
            ))]

        case "drag":
            return [.text(try await engine.drag(
                app: try required(a, "app"),
                from: (try requiredDouble(a, "from_x"), try requiredDouble(a, "from_y")),
                to: (try requiredDouble(a, "to_x"), try requiredDouble(a, "to_y")), foreground: fg(a)
            ))]

        case "type_text":
            guard let text = string(a, "text") else { throw ToolError("Missing required argument 'text'.") }
            let appName = try required(a, "app")
            let before = await engine.modalSignature(app: appName)
            let result = try await engine.typeText(app: appName, text: text, foreground: fg(a))
            return [.text(result + (await engine.newAlertNote(app: appName, before: before)))]

        case "press_key":
            let appName = try required(a, "app")
            let before = await engine.modalSignature(app: appName)
            let result = try await engine.pressKey(app: appName, key: try required(a, "key"), foreground: fg(a))
            return [.text(result + (await engine.newAlertNote(app: appName, before: before)))]

        case "paste":
            guard let text = string(a, "text") else { throw ToolError("Missing required argument 'text'.") }
            let appName = try required(a, "app")
            let before = await engine.modalSignature(app: appName)
            let result = try await engine.paste(app: appName, text: text, format: string(a, "format") ?? "text", foreground: fg(a))
            return [.text(result + (await engine.newAlertNote(app: appName, before: before)))]

        case "scroll":
            return [.text(try await engine.scroll(
                app: try required(a, "app"), index: int(a, "element_index"), x: double(a, "x"), y: double(a, "y"),
                direction: try required(a, "direction"), pages: max(0.1, min(double(a, "pages") ?? 1, 20)), foreground: fg(a)
            ))]

        case "select_text":
            return [.text(try await engine.selectText(
                app: try required(a, "app"), index: try requiredInt(a, "element_index"), text: try required(a, "text"),
                prefix: string(a, "prefix"), suffix: string(a, "suffix"), mode: string(a, "selection_type") ?? "text"
            ))]

        case "set_value":
            guard let value = string(a, "value") else { throw ToolError("Missing required argument 'value'.") }
            return [.text(try await engine.setValue(app: try required(a, "app"), index: try requiredInt(a, "element_index"), value: value))]

        case "perform_secondary_action":
            return [.text(try await engine.performSecondaryAction(
                app: try required(a, "app"), index: try requiredInt(a, "element_index"), action: try required(a, "action")
            ))]

        case "screenshot":
            return try await engine.screenshot(app: string(a, "app"), display: int(a, "display") ?? 0,
                                               window: string(a, "window") ?? int(a, "window").map(String.init),
                                               index: int(a, "element_index"),
                                               region: (a["region"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue })

        case "read_screen_text":
            return try await engine.readScreenText(app: try required(a, "app"), query: string(a, "query"),
                                                   window: string(a, "window") ?? int(a, "window").map(String.init))

        case "wait_for":
            return try await engine.waitFor(app: try required(a, "app"), query: try required(a, "query"), role: string(a, "role"),
                                            gone: bool(a, "gone") ?? false, timeout: max(0.5, min(double(a, "timeout") ?? 10, 60)))

        case "read_text":
            return try await engine.readText(app: try required(a, "app"), index: int(a, "element_index"),
                                             maxChars: max(500, min(int(a, "max_chars") ?? 20_000, 100_000)))

        case "select_menu":
            return [.text(try await engine.selectMenu(app: try required(a, "app"), path: try required(a, "path")))]

        case "window":
            return [.text(try await engine.manageWindow(
                app: try required(a, "app"), action: try required(a, "action"),
                window: string(a, "window") ?? int(a, "window").map(String.init),
                x: double(a, "x"), y: double(a, "y"), width: double(a, "width"), height: double(a, "height")
            ))]

        case "open":
            return [.text(try await engine.open(target: try required(a, "target"), app: string(a, "app")))]

        case "wait":
            let seconds = max(0, min(double(a, "seconds") ?? 1, 30))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return [.text("Waited \(seconds)s.")]

        case "share_window":
            switch (string(a, "action") ?? "pick").lowercased() {
            case "list":
                return [.text(Sharing.shared.describe())]
            case "clear":
                Sharing.shared.clear()
                return [.text("Share cleared. " + Sharing.shared.describe())]
            default:
                let shared = try await Sharing.shared.pick(timeout: max(5, min(double(a, "timeout") ?? 90, 300)))
                return [.text("User shared \(shared.app): \(Session.quote(shared.title)). \(Sharing.shared.describe())\nUse app=\"\(shared.app)\" with the other tools.")]
            }

        case "check_permissions":
            return [.text(Permissions.report(prompt: bool(a, "prompt") ?? false))]

        case "batch":
            guard let steps = a["actions"] as? [JSON], !steps.isEmpty else {
                throw ToolError("'actions' must be a non-empty array of {tool, args}.")
            }
            var output: [Content] = []
            var log: [String] = []
            for (i, step) in steps.enumerated() {
                let tool = step["tool"] as? String ?? step["name"] as? String ?? ""
                var args = step["args"] as? JSON ?? step["arguments"] as? JSON ?? [:]
                if args["app"] == nil, let app = a["app"] { args["app"] = app }
                guard tool != "batch" else { throw ToolError("batch cannot be nested.") }
                do {
                    let result = try await dispatch(tool, args)
                    for item in result {
                        if case .text(let t) = item { log.append("\(i + 1). \(tool): \(t)") } else { output.append(item) }
                    }
                } catch let error as ToolError {
                    log.append("\(i + 1). \(tool): FAILED — \(error.message)")
                    log.append("Stopped; \(steps.count - i - 1) remaining step(s) skipped.")
                    throw ToolError(log.joined(separator: "\n"))
                }
            }
            return [.text(log.joined(separator: "\n"))] + output

        default:
            throw ToolError("Unknown tool '\(name)'.")
        }
    }

    // MARK: Definitions

    private func prop(_ type: String, _ description: String, _ extra: JSON = [:]) -> JSON {
        var p: JSON = ["type": type, "description": description]
        for (k, v) in extra { p[k] = v }
        return p
    }

    private static let inputTools: Set<String> = ["click", "hover", "drag", "type_text", "press_key", "paste", "scroll"]

    private func tool(_ name: String, _ description: String, _ properties: JSON, _ required: [String], action: Bool = false) -> JSON {
        var props = properties
        if Tools.inputTools.contains(name) {
            props["foreground"] = prop("boolean", "Default false: input goes to the app in the background (user's cursor and focus untouched). Set true only if a background attempt visibly had no effect; it brings the app forward (keys still go only to that app through the plugin's own virtual keyboard; clicks use the real pointer and are refused if another window covers the point).")
        }
        if action {
            props["then_get_state"] = prop("boolean", "Return the refreshed app state (diff + screenshot) right after the action, saving a get_app_state round trip.")
        }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    private var app: JSON {
        prop("string", "Target app: display name (\"Google Chrome\"), bundle id (\"com.google.Chrome\") or .app path.")
    }

    private var elementIndex: JSON {
        prop("integer", "Element index from the latest get_app_state/find_elements output for this app.")
    }

    var definitions: [JSON] {
        [
            tool("get_app_state", """
                Read an app's UI: accessibility tree with numbered elements plus a screenshot of its window. \
                Launches the app in the background if needed. The first call returns the full tree; later calls return only \
                what changed (indices are stable for elements that still exist). Call it after actions before deciding the \
                next step. Waits automatically for the UI to settle and for loading indicators.
                """, [
                    "app": app,
                    "disable_diff": prop("boolean", "Return the full tree instead of a diff."),
                    "screenshot": prop("boolean", "Default: automatic (sent unless nothing changed since the last one). true forces it, false skips it."),
                    "include_offscreen": prop("boolean", "Also list content scrolled out of view (skipped by default to save time and tokens)."),
                    "window": prop("string", "Which window to capture/expand: element index of a window, position in the window list, or part of its title. Default: focused window."),
                ], ["app"]),

            tool("find_elements", """
                Search an app's whole accessibility tree (including closed menus, other windows and parts truncated from \
                get_app_state) by text, accent/case-insensitive. Returns matching elements with usable indices.
                """, [
                    "app": app,
                    "query": prop("string", "Text to look for in role, title, value, description, placeholder, identifier or URL. Empty = match all."),
                    "role": prop("string", "Optional role filter, e.g. button, textField, link, menuItem, row."),
                    "limit": prop("integer", "Max results (default 40)."),
                ], ["app"]),

            tool("click", """
                Click an element or a point. With element_index a single left click uses the accessibility Press action \
                when available (works in background, no mouse movement); otherwise the app is brought forward and a real \
                mouse click is sent at the element's center. x/y are pixels in the latest screenshot of this app.
                """, [
                    "app": app, "element_index": elementIndex,
                    "text": prop("string", "Click the control showing this text: accessibility match first, OCR fallback. Saves a lookup round trip."),
                    "x": prop("number", "X in screenshot pixels (use when there is no suitable element)."),
                    "y": prop("number", "Y in screenshot pixels."),
                    "mouse_button": prop("string", "left (default), right or middle.", ["enum": ["left", "right", "middle", "l", "r", "m"]]),
                    "click_count": prop("integer", "1 (default), 2 for double click, 3 for triple click."),
                ], ["app"], action: true),

            tool("hover", "Move the pointer over an element or point without clicking — opens hover submenus, tooltips and hover-only controls. Background by default (the user's real cursor stays put).", [
                "app": app, "element_index": elementIndex,
                "x": prop("number", "X in screenshot pixels."), "y": prop("number", "Y in screenshot pixels."),
            ], ["app"], action: true),

            tool("drag", "Drag with the left mouse button between two points given in screenshot pixels.", [
                "app": app,
                "from_x": prop("number", "Start X."), "from_y": prop("number", "Start Y."),
                "to_x": prop("number", "End X."), "to_y": prop("number", "End Y."),
            ], ["app", "from_x", "from_y", "to_x", "to_y"], action: true),

            tool("type_text", """
                Type text into the focused control of the app (brought to front first). Any Unicode works (accents, emoji). \
                A \\n presses Return and \\t presses Tab, which may submit forms or send messages — use paste for multi-line text.
                """, [
                    "app": app, "text": prop("string", "Text to type."),
                ], ["app", "text"], action: true),

            tool("press_key", """
                Press a key or shortcut in the app, xdotool syntax: "Return", "Tab", "Escape", "BackSpace", "Delete", "Up", \
                "Page_Down", "Home", "F5", "KP_0", "space", "super+c" (Cmd+C), "super+shift+t", "ctrl+Tab", "alt+Left". \
                super/cmd = Command, alt/option = Option. Letters map through the current keyboard layout.
                """, [
                    "app": app, "key": prop("string", "Key or combination."),
                ], ["app", "key"], action: true),

            tool("paste", """
                Paste content into the focused control via the clipboard, then restore the user's clipboard. \
                Best for long, multi-line or formatted text. format md/html pastes rich text where supported.
                """, [
                    "app": app, "text": prop("string", "Content to paste."),
                    "format": prop("string", "text, md or html.", ["enum": ["text", "md", "html"]]),
                ], ["app", "text", "format"], action: true),

            tool("scroll", "Scroll inside an element, at a point, or at the window center. One page ≈ 80% of the area's height/width.", [
                "app": app, "element_index": elementIndex,
                "x": prop("number", "X in screenshot pixels."), "y": prop("number", "Y in screenshot pixels."),
                "direction": prop("string", "up, down, left or right.", ["enum": ["up", "down", "left", "right", "u", "d", "l", "r"]]),
                "pages": prop("number", "How many pages (default 1, fractions allowed)."),
            ], ["app", "direction"], action: true),

            tool("select_text", "Select text (or place the caret before/after it) inside an editable element, without the mouse.", [
                "app": app, "element_index": elementIndex,
                "text": prop("string", "Exact text to find."),
                "prefix": prop("string", "Text that must come right before the match (to disambiguate)."),
                "suffix": prop("string", "Text that must come right after the match."),
                "selection_type": prop("string", "text (default), cursor_before or cursor_after.", ["enum": ["text", "cursor_before", "cursor_after"]]),
            ], ["app", "element_index", "text"], action: true),

            tool("set_value", """
                Replace the value of a text field, search field, slider, etc. Uses the accessibility value directly (works in \
                background); if the control refuses, it focuses it, selects all and types.
                """, [
                    "app": app, "element_index": elementIndex, "value": prop("string", "New value."),
                ], ["app", "element_index", "value"], action: true),

            tool("perform_secondary_action", """
                Invoke an accessibility action exposed by an element other than a plain click, e.g. ShowMenu, Increment, \
                Decrement, Confirm, Cancel, Pick, Raise, or a custom action listed in actions=[…]. Do not guess names.
                """, [
                    "app": app, "element_index": elementIndex,
                    "action": prop("string", "Action name as listed (\"ShowMenu\", \"Show Menu\" and \"AXShowMenu\" all work)."),
                ], ["app", "element_index", "action"], action: true),

            tool("list_apps", "List installed and running apps with bundle ids, running state, last-used date and use count.", [
                "running_only": prop("boolean", "Only running apps."),
                "limit": prop("integer", "Max rows (default 150)."),
            ], []),

            tool("screenshot", """
                Screenshot without reading the tree: an app window (coordinates then usable for click/drag/scroll) or a \
                whole display (view only). Useful for canvas-heavy apps with poor accessibility.
                """, [
                    "app": prop("string", "App whose window to capture. Omit to capture a display."),
                    "window": prop("string", "Window selector, as in get_app_state."),
                    "element_index": prop("integer", "Zoom into this element (full-resolution crop, good for small text)."),
                    "region": prop("array", "Zoom into [x, y, width, height] in screenshot pixels.", ["items": ["type": "number"]]),
                    "display": prop("integer", "Display index when no app is given (0 = main)."),
                ], []),

            tool("read_screen_text", """
                OCR the app's window on-device (Vision framework, pt-BR + en). Returns text lines in reading order with \
                @(x,y,w,h) in the same pixels as get_app_state, so their centers are clickable. For canvases, games, \
                remote desktops, images and any UI with poor accessibility.
                """, [
                    "app": app, "query": prop("string", "Only return lines containing this text."),
                    "window": prop("string", "Window selector, as in get_app_state."),
                ], ["app"]),

            tool("wait_for", """
                Wait until an element whose text/role matches appears (or disappears with gone=true), reacting to the \
                app's change notifications. Use for loads, dialogs, buttons becoming available.
                """, [
                    "app": app, "query": prop("string", "Text to match (like find_elements)."),
                    "role": prop("string", "Optional role filter."),
                    "gone": prop("boolean", "Wait for it to disappear instead."),
                    "timeout": prop("number", "Seconds (default 10, max 60)."),
                ], ["app", "query"]),

            tool("read_text", """
                Full text of an element or the whole window — documents, emails, web pages, text areas — without the \
                tree's truncation. Lines follow the on-screen layout.
                """, [
                    "app": app, "element_index": prop("integer", "Element to read (default: the current window)."),
                    "max_chars": prop("integer", "Limit (default 20000)."),
                ], ["app"]),

            tool("select_menu", """
                Choose a menu-bar command by path, e.g. "File > Export As…" or "View > Zoom In". Works in the background \
                when the item is available; window-specific commands borrow focus for a moment.
                """, [
                    "app": app, "path": prop("string", "Menu path separated by >."),
                ], ["app", "path"]),

            tool("window", "Move, resize, minimize, restore, fullscreen, raise (without activating) or close an app window. Coordinates are screen points.", [
                "app": app,
                "action": prop("string", "move, resize, frame, minimize, restore, fullscreen, exit_fullscreen, raise or close.",
                               ["enum": ["move", "resize", "frame", "minimize", "restore", "fullscreen", "exit_fullscreen", "raise", "close"]]),
                "window": prop("string", "Window selector, as in get_app_state."),
                "x": prop("number", "Left, screen points."), "y": prop("number", "Top, screen points."),
                "width": prop("number", "Width, points."), "height": prop("number", "Height, points."),
            ], ["app", "action"]),

            tool("open", "Open a file, folder or URL — optionally with a specific app — without bringing it forward.", [
                "target": prop("string", "Path (~ allowed) or URL."),
                "app": prop("string", "App to open it with (default: the system default)."),
            ], ["target"]),

            tool("wait", "Pause for a number of seconds (max 30), e.g. while something loads.", [
                "seconds": prop("number", "Seconds to wait."),
            ], ["seconds"]),

            tool("batch", """
                Run several tools in sequence in one call (stops at the first error). Each step is {"tool": name, "args": {...}}; \
                a top-level app is used for steps that omit it. Example: set_value, press_key Return, then get_app_state.
                """, [
                    "app": prop("string", "Default app for steps that do not set one."),
                    "actions": prop("array", "Steps to run.", ["items": [
                        "type": "object",
                        "properties": ["tool": ["type": "string"], "args": ["type": "object"]],
                        "required": ["tool"],
                    ]]),
                ], ["actions"]),

            tool("share_window", """
                Let the user choose which window Claude may use, via the macOS window-sharing picker. Once any window \
                is shared, only apps with shared windows can be read or controlled (scope lock) until action=clear. \
                pick waits for the user's choice; list shows the current share.
                """, [
                    "action": prop("string", "pick (default), list or clear.", ["enum": ["pick", "list", "clear"]]),
                    "timeout": prop("number", "Seconds to wait for the user to pick (default 90)."),
                ], []),

            tool("check_permissions", """
                Report whether Accessibility and Screen Recording are granted and which app they must be granted to. \
                prompt=true shows the system prompts and opens the right System Settings pane for the user.
                """, [
                    "prompt": prop("boolean", "Ask macOS to prompt and open System Settings."),
                ], []),
        ]
    }
}
