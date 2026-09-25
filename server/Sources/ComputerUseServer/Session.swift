import AppKit
import ApplicationServices

struct NodeInfo {
    let el: AXUIElement
    let depth: Int
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let desc: String?
    let placeholder: String?
    let identifier: String?
    let url: String?
    let enabled: Bool?
    let selected: Bool?
    let expanded: Bool?
    let focused: Bool
    let collapsed: Bool
    let offscreen: Bool
    let frame: CGRect?
    let actions: [String]

    var label: String? { title ?? desc ?? value ?? placeholder }

    var searchText: String {
        [Session.roleName(role, subrole), title, desc, value, placeholder, identifier, url]
            .compactMap { $0 }.joined(separator: " ")
    }
}

struct Collected {
    var nodes: [NodeInfo] = []
    /// Containers skipped because they were entirely outside the visible area.
    var hiddenOffscreen = 0
    var unresponsive = false
    var truncated = false
    var busy = false
    var signature = 0
}

/// Per-app state: stable element indices, last rendered tree (for diffs) and the
/// mapping between screenshot pixels and screen points.
@MainActor
final class Session {
    let app: NSRunningApplication
    let pid: pid_t
    let appElement: AXUIElement

    var indexOf: [ElementKey: Int] = [:]
    var elements: [Int: AXUIElement] = [:]
    var info: [Int: NodeInfo] = [:]
    var baseline: [Int: String]?
    var nextIndex = 1
    var hasShownScreenshot = false

    var window: AXUIElement?
    var windowFrame: CGRect?
    /// Screen point that maps to pixel (0,0) of the latest screenshot.
    var origin: CGPoint = .zero
    /// Screenshot pixels per screen point.
    var scale: CGFloat = 1

    /// Last time the app reported a UI change through accessibility notifications.
    var lastChange = Date.distantPast
    private(set) var observing = false
    private var observer: AXObserver?

    init(app: NSRunningApplication) {
        self.app = app
        pid = app.processIdentifier
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.5)
        startObserving()
    }

    /// Subscribes to the app's UI-change notifications so waits end as soon as the UI is quiet,
    /// instead of sleeping for a fixed time.
    private func startObserving() {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let session = Unmanaged<Session>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { session.lastChange = Date() }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            "AXValueChanged", "AXUIElementDestroyed", "AXCreated", "AXFocusedUIElementChanged",
            "AXLayoutChanged", "AXTitleChanged", "AXSelectedChildrenChanged", "AXSelectedTextChanged",
            "AXWindowCreated", "AXFocusedWindowChanged", "AXMainWindowChanged", "AXMenuOpened", "AXMenuClosed",
            "AXRowCountChanged", "AXSheetCreated", "AXLoadComplete", "AXElementBusyChanged",
        ]
        var registered = 0
        for name in notifications where AXObserverAddNotification(created, appElement, name as CFString, refcon) == .success {
            registered += 1
        }
        guard registered > 0 else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observing = true
    }

    /// Detaches the notification observer (called when the app quits).
    func stopObserving() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        observing = false
    }

    var name: String { app.localizedName ?? "pid \(pid)" }

    /// Quick liveness probe so a hung app fails in about a second instead of timing out per element.
    var isResponsive: Bool {
        let probe = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(probe, 1)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(probe, "AXRole" as CFString, &value) != .cannotComplete
    }

    /// Chromium/Electron (and Firefox) drop keyboard events delivered to an inactive app, so for
    /// them keystrokes briefly borrow focus. AppKit apps accept them fully in the background.
    lazy var needsFocusForKeys: Bool = {
        let known: Set<String> = [
            "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
            "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
            "org.mozilla.firefox", "app.zen-browser.zen",
        ]
        if let id = app.bundleIdentifier, known.contains(id) { return true }
        guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let items = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return items.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chromium Embedded") || $0.contains("Chrome Framework") }
    }()
    var isExcel: Bool { app.bundleIdentifier == "com.microsoft.Excel" }
    /// Office takes Cmd/Ctrl shortcuts posted to its pid while in the background (verified in
    /// Excel), so it never needs the focus borrow that other apps need for menu shortcuts.
    var shortcutsWorkInBackground: Bool { (app.bundleIdentifier ?? "").hasPrefix("com.microsoft.") }

    /// The window that owns keyboard focus (walking up from a focused sheet or panel). App-modal
    /// alerts are often missing from AXWindows; they are returned as they are.
    var keyWindow: AXUIElement? {
        let all = windows
        guard let focused = appElement.element("AXFocusedWindow") else { return nil }
        var current: AXUIElement? = focused
        for _ in 0..<4 {
            guard let el = current else { break }
            if all.contains(where: { CFEqual($0, el) }) { return el }
            current = el.element("AXParent")
        }
        return focused
    }

    /// A focused alert or dialog that blocks input to the app's other windows.
    var modalAlert: AXUIElement? {
        guard let focused = appElement.element("AXFocusedWindow") else { return nil }
        let subrole = focused.str("AXSubrole") ?? ""
        let isModal = subrole == "AXDialog" || subrole == "AXSystemDialog" || focused.str("AXDescription") == "alert"
            || focused.str("AXRole") == "AXSheet" || (focused.bool("AXModal") ?? false)
        return isModal ? focused : nil
    }

    /// The visible text of a small window (alert message), for warnings.
    static func texts(in el: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        var out: [String] = []
        if el.str("AXRole") == "AXStaticText", let v = el.str("AXValue") ?? el.str("AXTitle"), !v.isEmpty { out.append(v) }
        for child in el.elements("AXChildren") { out += texts(in: child, depth: depth + 1) }
        return out
    }
    /// Apps whose focused fields claim a settable AXSelectedText that never really lands.
    var fakesTextInsertion: Bool { needsFocusForKeys || (app.bundleIdentifier ?? "").hasPrefix("com.microsoft.") }
    /// Asks the window server (not NSWorkspace, which can be stale off the run loop).
    var isFrontmost: Bool {
        if let front = Safety.frontPid() { return front == pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: Windows

    var windows: [AXUIElement] { appElement.elements("AXWindows") }

    func pickWindow(_ selector: String?) -> AXUIElement? {
        let all = windows
        if let selector, !selector.isEmpty {
            if let index = Int(selector) {
                if let el = elements[index], all.contains(where: { CFEqual($0, el) }) { return el }
                if all.indices.contains(index) { return all[index] }
            }
            // Exact title first, then prefix, then substring: "Book1" must not pick "Microsoft Visual Basic - Book1".
            let q = selector.lowercased()
            let titled = all.map { ($0, ($0.str("AXTitle") ?? "").lowercased()) }
            if let match = titled.first(where: { $0.1 == q }) ?? titled.first(where: { $0.1.hasPrefix(q) })
                ?? titled.first(where: { $0.1.contains(q) }) {
                return match.0
            }
        }
        // A focused alert/dialog blocks everything else, so it wins even when not in AXWindows.
        if selector == nil || selector?.isEmpty == true, let modal = modalAlert {
            // A sheet lives inside its document window: pick that window so the sheet is shown in it.
            var current: AXUIElement? = modal
            for _ in 0..<4 {
                guard let el = current else { break }
                if all.contains(where: { CFEqual($0, el) }) { return el }
                current = el.element("AXParent")
            }
            return modal
        }
        // A shared window wins by default.
        if let shared = Sharing.shared.sharedFrame(for: pid),
           let match = all.min(by: { distance($0.frame, shared) < distance($1.frame, shared) }),
           distance(match.frame, shared) < 40 {
            return match
        }
        // A focused sheet/dialog is not in AXWindows; walk up to the window that owns it.
        for candidate in [appElement.element("AXFocusedWindow"), appElement.element("AXMainWindow")] {
            var current = candidate
            for _ in 0..<4 {
                guard let el = current else { break }
                if all.contains(where: { CFEqual($0, el) }) { return el }
                current = el.element("AXParent")
            }
        }
        return all.first
    }

    /// Pixels per point used for screenshots of `frame`; applied even without a screenshot so
    /// coordinates never change meaning between calls.
    static func imageScale(for frame: CGRect) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var backing: CGFloat = 2
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 1, &displayID, &count) == .success, count > 0,
           let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 {
            backing = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        }
        return min(backing, Capture.maxEdge / max(frame.width, frame.height, 1))
    }

    private func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    func toScreen(x: Double, y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) / scale, y: origin.y + CGFloat(y) / scale)
    }

    func toImage(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    // MARK: Tree collection

    static let attributeNames = [
        "AXRole", "AXSubrole", "AXTitle", "AXValue", "AXDescription", "AXPlaceholderValue",
        "AXEnabled", "AXSelected", "AXPosition", "AXSize", "AXChildren", "AXIdentifier",
        "AXExpanded", "AXURL",
    ]

    static let printRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXDrawer", "AXDialog", "AXPopover", "AXMenuBar", "AXMenu", "AXMenuBarItem",
        "AXMenuItem", "AXMenuButton", "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXSearchField", "AXComboBox", "AXPopUpButton", "AXSlider", "AXIncrementor", "AXStepper", "AXLink",
        "AXDisclosureTriangle", "AXTabGroup", "AXToolbar", "AXTable", "AXOutline", "AXList", "AXRow",
        "AXScrollArea", "AXWebArea", "AXColorWell", "AXDateField", "AXTimeField", "AXSwitch",
        "AXLevelIndicator", "AXProgressIndicator", "AXBusyIndicator", "AXBrowser", "AXRadioGroup",
        "AXSegmentedControl", "AXDockItem",
    ]

    /// Decorative / structural roles that are never useful targets.
    static let skipRoles: Set<String> = [
        "AXColumn", "AXScrollBar", "AXSplitter", "AXValueIndicator", "AXGrowArea", "AXMatte", "AXRuler",
        "AXRulerMarker", "AXLayoutItem",
    ]

    static let noiseActions: Set<String> = ["AXScrollToVisible", "AXShowMenu", "AXShowDefaultUI", "AXShowAlternateUI"]

    func collect(expandAll: Bool, maxNodes: Int, maxVisit: Int, pruneOffscreen: Bool = false) -> Collected {
        let walker = Walker(
            maxNodes: maxNodes, maxVisit: maxVisit, expandAll: expandAll, pruneOffscreen: pruneOffscreen,
            focused: appElement.element("AXFocusedUIElement").map(ElementKey.init),
            chosen: window.map(ElementKey.init), windowFrame: windowFrame,
            focusedWindow: appElement.element("AXFocusedWindow").map(ElementKey.init)
        )
        var roots = appElement.elements("AXChildren")
        if roots.isEmpty {
            roots = windows
            if let menuBar = appElement.element("AXMenuBar") { roots.append(menuBar) }
        }
        // Windows first, menu bars last.
        let ranked = roots.map { el -> (AXUIElement, Int) in
            let role = el.str("AXRole") ?? ""
            return (el, role.contains("MenuBar") ? 2 : (role == "AXWindow" ? 0 : 1))
        }.sorted { $0.1 < $1.1 }
        for (root, _) in ranked {
            walker.visit(root, depth: 0, parentLabel: nil, level: 0, clip: nil)
            if walker.truncated || walker.unresponsive { break }
        }
        return Collected(nodes: walker.nodes, hiddenOffscreen: walker.hiddenOffscreen, unresponsive: walker.unresponsive,
                         truncated: walker.truncated, busy: walker.busy,
                         signature: walker.hasher.finalize())
    }

    // MARK: Registry

    /// Assigns stable indices: an element keeps its number for as long as it exists.
    @discardableResult
    func register(_ nodes: [NodeInfo], replace: Bool) -> [(Int, NodeInfo)] {
        var newIndexOf: [ElementKey: Int] = replace ? [:] : indexOf
        var newElements: [Int: AXUIElement] = replace ? [:] : elements
        var newInfo: [Int: NodeInfo] = replace ? [:] : info
        var seen = Set<Int>()
        var result: [(Int, NodeInfo)] = []
        for node in nodes {
            let key = ElementKey(node.el)
            let index: Int
            if let existing = indexOf[key] ?? newIndexOf[key] {
                index = existing
            } else {
                index = nextIndex
                nextIndex += 1
            }
            guard seen.insert(index).inserted else { continue }
            newIndexOf[key] = index
            newElements[index] = node.el
            newInfo[index] = node
            result.append((index, node))
        }
        indexOf = newIndexOf
        elements = newElements
        info = newInfo
        return result
    }

    // MARK: Rendering

    nonisolated static func roleName(_ role: String, _ subrole: String?) -> String {
        func clean(_ s: String) -> String {
            let stripped = s.hasPrefix("AX") ? String(s.dropFirst(2)) : s
            return stripped.prefix(1).lowercased() + stripped.dropFirst()
        }
        var name = clean(role)
        if let subrole, !subrole.isEmpty, !["AXStandardWindow", "AXUnknown", "AXContentList"].contains(subrole) {
            name += "(\(clean(subrole)))"
        }
        return name
    }

    nonisolated static func quote(_ s: String, max: Int = 120) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
        if t.count > max { t = String(t.prefix(max)) + "…(+\(s.count - max) chars)" }
        return "\"\(t)\""
    }

    /// Roles where "not expanded" is meaningful (web content reports it on everything).
    static let disclosureRoles: Set<String> = ["AXDisclosureTriangle", "AXRow", "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXDisclosureGroup"]

    static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXMenuItem"]
    static let obviousPress: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXDisclosureTriangle", "AXDockItem", "AXSwitch",
    ]

    func render(_ node: NodeInfo, index: Int) -> String {
        var parts = ["[\(index)]", Session.roleName(node.role, node.subrole)]
        if let title = node.title { parts.append(Session.quote(title)) }
        if let desc = node.desc, desc != node.title { parts.append("desc=" + Session.quote(desc)) }
        var flags: [String] = []
        if let value = node.value, value != node.title, value != node.desc {
            if Session.toggleRoles.contains(node.role), value == "1" || value == "0" {
                if value == "1" { flags.append("checked") } else if node.role != "AXMenuItem" { flags.append("unchecked") }
            } else if node.role == "AXHeading", Int(value) != nil {
                parts[1] = "heading(h\(value))"
            } else {
                parts.append("value=" + Session.quote(value, max: node.role == "AXTextArea" ? 300 : 120))
            }
        }
        if let placeholder = node.placeholder, node.value == nil { parts.append("placeholder=" + Session.quote(placeholder)) }
        if let identifier = node.identifier, identifier.count <= 48, !identifier.hasPrefix("_NS:") {
            parts.append("id=\(identifier)")
        }
        if let url = node.url, node.role == "AXLink" { parts.append("url=" + Session.quote(url, max: 90)) }

        if node.focused { flags.append("focused") }
        if node.enabled == false { flags.append("disabled") }
        if node.selected == true { flags.append("selected") }
        let isMenuChrome = node.role == "AXMenuBar" || node.role == "AXMenuBarItem"
        if let expanded = node.expanded {
            if expanded { flags.append("expanded") } else if Session.disclosureRoles.contains(node.role) { flags.append("closed") }
        }
        if node.offscreen { flags.append("offscreen") }
        if node.collapsed { flags.append("children hidden: pass window=\(index) to expand") }
        if !flags.isEmpty { parts.append("{" + flags.joined(separator: ",") + "}") }

        let shownActions = node.actions
            .filter { !Session.noiseActions.contains($0) && !(Session.obviousPress.contains(node.role) && $0 == "AXPress") }
            .filter { !(isMenuChrome && $0 == "AXCancel") }
            .map(AX.displayAction)
        if !shownActions.isEmpty { parts.append("actions=[" + shownActions.joined(separator: ",") + "]") }

        // Menu bar items move whenever the app gains focus; they are driven by Press/Pick, not coordinates.
        if let frame = node.frame, !node.collapsed, !isMenuChrome, frame.width > 0 || frame.height > 0 {
            let r = toImage(frame)
            parts.append("@(\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded())))")
        }
        return parts.joined(separator: " ")
    }
}

/// Depth-first walk that flattens anonymous containers so the output stays compact.
@MainActor
final class Walker {
    var nodes: [NodeInfo] = []
    var visited = 0
    var truncated = false
    var busy = false
    var unresponsive = false
    var hiddenOffscreen = 0
    var hasher = Hasher()

    let maxNodes: Int
    let maxVisit: Int
    let expandAll: Bool
    let pruneOffscreen: Bool
    let focused: ElementKey?
    let chosen: ElementKey?
    let windowFrame: CGRect?
    let focusedWindow: ElementKey?

    init(maxNodes: Int, maxVisit: Int, expandAll: Bool, pruneOffscreen: Bool, focused: ElementKey?, chosen: ElementKey?, windowFrame: CGRect?, focusedWindow: ElementKey? = nil) {
        self.focusedWindow = focusedWindow
        self.maxNodes = maxNodes
        self.maxVisit = maxVisit
        self.expandAll = expandAll
        self.pruneOffscreen = pruneOffscreen
        self.focused = focused
        self.chosen = chosen
        self.windowFrame = windowFrame
    }

    static func nonEmptyTitle(_ s: String?) -> String? { nonEmpty(s) }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : s
    }

    /// `clip` is the visible area inherited from the enclosing window and scroll areas.
    func visit(_ el: AXUIElement, depth: Int, parentLabel: String?, level: Int, clip: CGRect?) {
        if nodes.count >= maxNodes || visited >= maxVisit {
            truncated = true
            return
        }
        if level > 80 { return }
        visited += 1

        guard let v = el.multi(Session.attributeNames) else {
            unresponsive = true
            truncated = true
            return
        }
        let role = AX.string(v[0]) ?? "AXUnknown"
        if Session.skipRoles.contains(role) { return }
        let subrole = AX.string(v[1])
        let title = Walker.nonEmpty(AX.string(v[2]))
        let value = Walker.nonEmpty(AX.string(v[3]))
        let desc = Walker.nonEmpty(AX.string(v[4]))
        let placeholder = Walker.nonEmpty(AX.string(v[5]))
        let enabled = AX.bool(v[6])
        let selected = AX.bool(v[7])
        var frame: CGRect?
        if let position = AX.point(v[8]), let size = AX.size(v[9]) { frame = CGRect(origin: position, size: size) }
        var children = AX.elements(v[10])
        let identifier = Walker.nonEmpty(AX.string(v[11]))
        let expanded = AX.bool(v[12])
        let url = Walker.nonEmpty(AX.string(v[13]))

        let key = ElementKey(el)
        let actions = el.actionNames
        let meaningfulActions = actions.filter { !Session.noiseActions.contains($0) }
        let label = title ?? desc ?? value ?? placeholder

        var printable = Session.printRoles.contains(role) || label != nil || !meaningfulActions.isEmpty
        if role == "AXStaticText", let label, label == parentLabel { printable = false }
        if role == "AXImage", label == nil, meaningfulActions.isEmpty { printable = false }

        let isWindowLike = role == "AXWindow"
        // Only floating panels (inspectors, palettes) stay expanded next to the chosen window; some
        // apps (iWork) report document windows as AXDialog, so don't rely on AXStandardWindow.
        let collapsed = isWindowLike && !expandAll && chosen != nil && key != chosen && key != focusedWindow
            && !["AXFloatingWindow", "AXSystemFloatingWindow", "AXDialog", "AXSystemDialog"].contains(subrole ?? "")

        // Visibility is judged against the element's own window (not just the captured one) and
        // any scroll area around it, so floating panels and scrolled-away content are handled right.
        var offscreen = false
        if let clip, let frame, !isWindowLike, !role.hasPrefix("AXMenu"), frame.width > 0, frame.height > 0 {
            offscreen = !frame.intersects(clip)
        }
        if offscreen && pruneOffscreen {
            hiddenOffscreen += 1
            return
        }
        var childClip = clip
        if let frame, frame.width > 0, frame.height > 0 {
            if isWindowLike || role == "AXSheet" || role == "AXDrawer" {
                childClip = frame
            } else if role == "AXScrollArea" || role == "AXWebArea" {
                childClip = clip.map { $0.intersection(frame) } ?? frame
                if childClip?.isNull == true { childClip = frame }
            }
        }

        if role == "AXBusyIndicator" && !offscreen { busy = true }
        if role == "AXProgressIndicator" && value == nil && !offscreen { busy = true }
        if role == "AXWebArea", el.bool("AXElementBusy") == true { busy = true }

        var childDepth = depth
        var childParentLabel = parentLabel
        if printable {
            nodes.append(NodeInfo(
                el: el, depth: depth, role: role, subrole: subrole, title: title, value: value, desc: desc,
                placeholder: placeholder, identifier: identifier, url: url, enabled: enabled, selected: selected,
                expanded: expanded, focused: focused == key, collapsed: collapsed, offscreen: offscreen,
                frame: frame, actions: actions
            ))
            hasher.combine(role)
            hasher.combine(label)
            hasher.combine(value)
            hasher.combine(selected)
            if let frame, !role.hasPrefix("AXMenuBar") { hasher.combine(Int(frame.minX)); hasher.combine(Int(frame.minY)); hasher.combine(Int(frame.width)) }
            childDepth = depth + 1
            childParentLabel = label
        }

        if collapsed { return }
        switch role {
        case "AXMenuBarItem", "AXMenuItem":
            // Closed menus stay folded unless we are searching.
            if selected != true && !expandAll { return }
        case "AXTable", "AXOutline":
            let visibleRows = el.elements("AXVisibleRows")
            if !visibleRows.isEmpty && visibleRows.count < children.count {
                children = (el.element("AXHeader").map { [$0] } ?? []) + visibleRows
            }
        default:
            break
        }
        for child in children {
            visit(child, depth: childDepth, parentLabel: childParentLabel, level: level + 1, clip: childClip)
            if truncated { return }
        }
    }
}
