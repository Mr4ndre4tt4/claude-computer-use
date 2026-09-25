import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
    /// Longest edge sent to the model; larger images get downscaled by the client anyway.
    static let maxEdge: CGFloat = 1568

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures the app window closest to `target` (screen points). Works for occluded windows.
    private static var cachedContent: (SCShareableContent, Date)?

    /// Window list lookups are the slow part of a capture; the live view may reuse a recent one.
    private static func shareableContent(maxAge: TimeInterval) async throws -> SCShareableContent {
        if maxAge > 0, let (content, time) = cachedContent, Date().timeIntervalSince(time) < maxAge { return content }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        cachedContent = (content, Date())
        return content
    }

    static func window(pid: pid_t, near target: CGRect, maxEdge: CGFloat = Capture.maxEdge, cacheAge: TimeInterval = 0) async throws -> (CGImage, CGRect) {
        let content = try await shareableContent(maxAge: cacheAge)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20
        }
        guard let window = candidates.min(by: { distance($0.frame, target) < distance($1.frame, target) }) else {
            throw ToolError("no capturable window (minimized or hidden?)")
        }
        // Preferred: composite every on-screen window of the app (sheets, popovers, open menus are
        // separate windows) cropped to the target window; other apps' windows are left out.
        if window.isOnScreen,
           let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }),
           display.frame.contains(window.frame) {
            let appWindows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
            let filter = SCContentFilter(display: display, including: appWindows)
            let config = SCStreamConfiguration()
            let scale = min(CGFloat(filter.pointPixelScale), maxEdge / max(window.frame.width, window.frame.height))
            config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = max(1, Int((window.frame.width * scale).rounded()))
            config.height = max(1, Int((window.frame.height * scale).rounded()))
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                return (image, window.frame)
            }
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(CGFloat(filter.pointPixelScale), maxEdge / max(window.frame.width, window.frame.height))
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, window.frame)
    }

    /// Captures a whole display (0 = main display).
    static func display(index: Int) async throws -> (CGImage, CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.sorted { a, b in
            if a.displayID == CGMainDisplayID() { return true }
            if b.displayID == CGMainDisplayID() { return false }
            return a.frame.minX < b.frame.minX
        }
        guard displays.indices.contains(index) else {
            throw ToolError("display \(index) not found (\(displays.count) display(s) available)")
        }
        let display = displays[index]
        // Keep our own overlay out of the picture.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        let frame = CGDisplayBounds(display.displayID)
        let scale = min(CGFloat(filter.pointPixelScale), maxEdge / max(frame.width, frame.height))
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, frame)
    }

    static func jpeg(_ image: CGImage, quality: CGFloat = 0.85) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Keeps a copy on disk so the user (or Claude via Read) can inspect it later.
    static func save(_ data: Data, label: String) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-computer-use", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = label.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "screen" : safe)-\(stamp).jpg")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

enum Displays {
    static func contains(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return true }
        return ids.contains { CGDisplayBounds($0).contains(point) }
    }
}
