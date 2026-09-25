import AppKit

// MCP stdio server: stdout carries JSON-RPC only, logs go to stderr.
setvbuf(stderr, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

// Window-server connection for ScreenCaptureKit/CGEvent and the overlay panel; no Dock icon, never activates.
NSApplication.shared.setActivationPolicy(.accessory)

Task { @MainActor in
    await Server.shared.run()
    exit(0)
}

// Run AppKit's loop so the overlay draws and NSWorkspace callbacks are delivered.
NSApplication.shared.run()
