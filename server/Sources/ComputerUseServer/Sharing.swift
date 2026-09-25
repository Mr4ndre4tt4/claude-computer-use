import AppKit
import ScreenCaptureKit

/// "Share window": the user picks windows with the system sharing picker (the same UI as
/// screen sharing in a video call). Once anything is shared, only those windows' apps can be
/// read or controlled until the share is cleared.
@MainActor
final class Sharing: NSObject, SCContentSharingPickerObserver {
    static let shared = Sharing()

    struct SharedWindow {
        let pid: pid_t
        let windowID: CGWindowID
        let app: String
        let title: String
    }

    private(set) var windows: [SharedWindow] = []
    private var continuation: CheckedContinuation<SCContentFilter?, Never>?

    var isLocked: Bool { !windows.isEmpty }

    func allows(pid: pid_t) -> Bool { !isLocked || windows.contains { $0.pid == pid } }

    /// Current on-screen frame of the shared window of `pid`, if any.
    func sharedFrame(for pid: pid_t) -> CGRect? {
        guard let shared = windows.first(where: { $0.pid == pid }),
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], shared.windowID) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    func clear() { windows.removeAll() }

    func describe() -> String {
        guard isLocked else { return "No window is shared: any app can be controlled." }
        return "Shared (only these can be controlled):\n" + windows.map { "- \($0.app): \(Session.quote($0.title))" }.joined(separator: "\n")
    }

    /// Shows the picker and waits for the user's choice.
    func pick(timeout: Double) async throws -> SharedWindow {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.excludedBundleIDs = []
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        defer {
            picker.isActive = false
            picker.remove(self)
        }
        picker.present(using: .window)

        let filter: SCContentFilter? = await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(nil)
            }
        }
        guard let filter else { throw ToolError("No window was shared (picker cancelled or timed out).") }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        var window: SCWindow?
        if #available(macOS 15.2, *) {
            window = filter.includedWindows.first
        }
        if window == nil {
            // Older systems: match the filter's rectangle against known windows.
            let rect = filter.contentRect
            window = content.windows
                .filter { $0.windowLayer == 0 && abs($0.frame.width - rect.width) < 2 && abs($0.frame.height - rect.height) < 2 }
                .first
        }
        guard let window, let app = window.owningApplication else {
            throw ToolError("Could not identify the shared window.")
        }
        let shared = SharedWindow(pid: app.processID, windowID: window.windowID,
                                  app: app.applicationName, title: window.title ?? "")
        windows.removeAll { $0.windowID == shared.windowID }
        windows.append(shared)
        return shared
    }

    private func finish(_ filter: SCContentFilter?) {
        continuation?.resume(returning: filter)
        continuation = nil
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.finish(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
