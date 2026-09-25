import AppKit
import CoreServices

struct AppInfo {
    let id: String
    let name: String
    let path: String?
    let running: Bool
    let lastUsed: Date?
    let useCount: Int?
}

@MainActor
enum Apps {
    static let searchDirs: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications",
    ]

    static func installedURLs() -> [URL] {
        var urls: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        let fm = FileManager.default
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    urls.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fm.contentsOfDirectory(atPath: url.path) {
                    // One level of nesting, e.g. /Applications/Microsoft Office/*.app
                    urls += nested.filter { $0.hasSuffix(".app") }.map { url.appendingPathComponent($0) }
                }
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func displayName(_ url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func list(runningOnly: Bool) -> [AppInfo] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var byPath: [String: NSRunningApplication] = [:]
        for app in running {
            if let path = app.bundleURL?.standardizedFileURL.path { byPath[path] = app }
        }

        var result: [AppInfo] = []
        var covered = Set<String>()
        if !runningOnly {
            for url in installedURLs() {
                let path = url.standardizedFileURL.path
                let bundle = Bundle(url: url)
                guard let id = bundle?.bundleIdentifier else { continue }
                var lastUsed: Date?
                var useCount: Int?
                if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
                    lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                    useCount = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
                }
                result.append(AppInfo(id: id, name: displayName(url), path: path, running: byPath[path] != nil,
                                      lastUsed: lastUsed, useCount: useCount))
                covered.insert(path)
            }
        }
        for app in running {
            let path = app.bundleURL?.standardizedFileURL.path
            if let path, covered.contains(path) { continue }
            result.append(AppInfo(id: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                                  name: app.localizedName ?? "?", path: path, running: true,
                                  lastUsed: nil, useCount: nil))
        }
        return result.sorted { a, b in
            if a.running != b.running { return a.running }
            return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
        }
    }

    static func findRunning(_ query: String) -> NSRunningApplication? {
        let q = query.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
        if q.hasPrefix("pid:"), let pid = pid_t(q.dropFirst(4)) {
            return apps.first { $0.processIdentifier == pid }
        }
        if let app = apps.first(where: { $0.bundleIdentifier?.lowercased() == q }) { return app }
        if let app = apps.first(where: { $0.localizedName?.lowercased() == q }) { return app }
        if let app = apps.first(where: {
            $0.bundleURL?.path.lowercased() == q || $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == q
        }) { return app }
        let partial = apps.filter { $0.activationPolicy == .regular && ($0.localizedName?.lowercased().contains(q) ?? false) }
        return partial.count == 1 ? partial[0] : nil
    }

    static func findInstalled(_ query: String) -> URL? {
        if query.hasSuffix(".app"), FileManager.default.fileExists(atPath: query) { return URL(fileURLWithPath: query) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) { return url }
        let q = query.lowercased()
        let urls = installedURLs()
        if let url = urls.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == q }) { return url }
        if let url = urls.first(where: { displayName($0).lowercased() == q }) { return url }
        let partial = urls.filter { displayName($0).lowercased().contains(q) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Resolves a running app, launching it in the background if needed.
    static func resolve(_ query: String, launch: Bool) async throws -> NSRunningApplication {
        if let app = findRunning(query) { return app }
        guard launch else {
            throw ToolError("'\(query)' is not running. Call get_app_state first (it launches apps).")
        }
        guard let url = findInstalled(query) else {
            throw ToolError("App '\(query)' not found. Use list_apps to see names and bundle ids.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<40 {
            if !element.elements("AXWindows").isEmpty { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return app
    }
}
