import Cocoa

/// Guards for "real" input (HID keyboard, real mouse), which lands on whatever app is actually
/// in front or under the pointer, not necessarily the target. NSWorkspace's frontmost app is only
/// refreshed by the run loop and can be stale, so these ask the window server directly.
enum Safety {
    private static func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func isForeign(_ w: [String: Any]) -> Bool {
        guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != getpid() else { return false }
        if (w[kCGWindowAlpha as String] as? Double ?? 1) <= 0.01 { return false }
        if (w[kCGWindowOwnerName as String] as? String) == "Window Server" { return false }
        return true
    }

    /// Owner of the frontmost normal window (layer 0), ignoring this process's overlay.
    static func frontPid() -> pid_t? {
        for w in windows() where isForeign(w) && (w[kCGWindowLayer as String] as? Int) == 0 {
            return w[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    /// Owner of the topmost window containing a screen point (any layer: menus, panels, Dock…).
    static func ownerAt(_ point: CGPoint) -> (pid: pid_t, name: String)? {
        for w in windows() where isForeign(w) {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point) else { continue }
            // The Dock keeps transparent full-screen windows (Mission Control, Launchpad) that
            // never take clicks; only its bar itself counts.
            if (w[kCGWindowOwnerName as String] as? String) == "Dock",
               let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
               bounds.width * bounds.height > screen.frame.width * screen.frame.height * 0.5 { continue }
            return (w[kCGWindowOwnerPID as String] as! pid_t, w[kCGWindowOwnerName as String] as? String ?? "?")
        }
        return nil
    }

    /// Seconds since the user's last real keyboard or mouse input. The plugin's own keys are
    /// posted to processes, not the HID stream, so they don't count.
    static func userIdleSeconds() -> Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .mouseMoved, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// Frame (top-left origin) of the frontmost normal window: the one the user is working in.
    static func frontWindowFrame() -> CGRect? {
        for w in windows() where isForeign(w) && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
        return nil
    }
}
