import AppKit
import ApplicationServices
import Darwin

enum Permissions {
    /// macOS attributes TCC permissions to the app that launched us (Claude, Terminal, VS Code...).
    static func responsibleApp() -> String? {
        var pid = getppid()
        var outermost: String?
        for _ in 0..<16 {
            guard pid > 1 else { break }
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") {
                    outermost = String(path[..<range.lowerBound]) + ".app"
                }
            }
            pid = parentPID(of: pid)
        }
        return outermost
    }

    static var responsibleAppName: String {
        guard let path = responsibleApp() else { return "the app running Claude Code (Claude, Terminal, iTerm, VS Code...)" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    static var accessibilityMissing: String {
        """
        Accessibility permission is not granted to "\(responsibleAppName)". \
        Ask the user to open System Settings > Privacy & Security > Accessibility, enable "\(responsibleAppName)" \
        and restart it. check_permissions with prompt=true opens that pane.
        """
    }

    static func report(prompt: Bool) -> String {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            if !AXIsProcessTrusted(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            } else if !CGPreflightScreenCaptureAccess(),
                      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        var lines = [
            "Accessibility (read UI, click, type): \(ax ? "granted" : "NOT granted")",
            "Screen Recording (screenshots): \(screen ? "granted" : "NOT granted")",
            "Permissions belong to: \(responsibleApp() ?? responsibleAppName)",
            "Server binary: \(CommandLine.arguments.first ?? "?")",
        ]
        if !ax || !screen {
            lines.append("To fix: System Settings > Privacy & Security > Accessibility and Screen Recording > enable \"\(responsibleAppName)\", then quit and reopen it. Only the user can do this.")
        }
        return lines.joined(separator: "\n")
    }
}
