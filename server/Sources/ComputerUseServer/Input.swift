import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum MouseButtonKind: String {
    case left, right, middle

    static func parse(_ raw: String?) throws -> MouseButtonKind {
        switch (raw ?? "left").lowercased() {
        case "left", "l": return .left
        case "right", "r": return .right
        case "middle", "m": return .middle
        default: throw ToolError("mouse_button must be left, right or middle")
        }
    }

    var cg: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

struct KeyStroke {
    var modifiers: [(code: CGKeyCode, flag: CGEventFlags)] = []
    var code: CGKeyCode?
}

enum Input {
    static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    static func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

    // MARK: Mouse

    static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, button: MouseButtonKind, count: Int) {
        move(to: point)
        pause(0.05)
        for n in 1...max(1, count) {
            for type in [button.downType, button.upType] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cg) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event.post(tap: .cghidEventTap)
                pause(0.025)
            }
            pause(0.05)
        }
    }

    static func drag(from start: CGPoint, to end: CGPoint) {
        move(to: start)
        pause(0.05)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        pause(0.1)
        let steps = 30
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            pause(0.012)
        }
        pause(0.08)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Pixel-based wheel scrolling. Negative dy scrolls content down (like swiping up).
    static func scroll(at point: CGPoint, dx: Int, dy: Int) {
        move(to: point)
        pause(0.04)
        var remainingX = dx
        var remainingY = dy
        while remainingX != 0 || remainingY != 0 {
            let stepY = max(-80, min(80, remainingY))
            let stepX = max(-80, min(80, remainingX))
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) {
                event.location = point
                event.post(tap: .cghidEventTap)
            }
            remainingY -= stepY
            remainingX -= stepX
            pause(0.012)
        }
    }

    // MARK: Background delivery (no cursor movement, no activation)

    /// Topmost on-screen window of `pid` under `point`, used to route posted mouse events.
    static func windowNumber(pid: pid_t, at point: CGPoint) -> Int64? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point),
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            return number.int64Value
        }
        return nil
    }

    private static func routed(_ event: CGEvent, window: Int64?) -> CGEvent {
        if let window {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: window)
        }
        return event
    }

    static func backgroundClick(pid: pid_t, at point: CGPoint, button: MouseButtonKind, count: Int) {
        let window = windowNumber(pid: pid, at: point)
        for n in 1...max(1, count) {
            for type in [button.downType, button.upType] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button.cg) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                routed(event, window: window).postToPid(pid)
                pause(0.03)
            }
            pause(0.05)
        }
    }

    /// Mouse-over without moving the real cursor (opens submenus, tooltips, hover states).
    static func backgroundHover(pid: pid_t, at point: CGPoint) {
        let window = windowNumber(pid: pid, at: point)
        for offset in [CGPoint(x: -3, y: -2), .zero] {
            let p = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            if let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                routed(event, window: window).postToPid(pid)
            }
            pause(0.03)
        }
    }

    static func backgroundDrag(pid: pid_t, from start: CGPoint, to end: CGPoint) {
        let window = windowNumber(pid: pid, at: start)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) {
            routed(down, window: window).postToPid(pid)
        }
        pause(0.1)
        let steps = 30
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                routed(drag, window: window).postToPid(pid)
            }
            pause(0.012)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            routed(up, window: window).postToPid(pid)
        }
    }

    static func backgroundScroll(pid: pid_t, at point: CGPoint, dx: Int, dy: Int) {
        let window = windowNumber(pid: pid, at: point)
        var remainingX = dx
        var remainingY = dy
        while remainingX != 0 || remainingY != 0 {
            let stepY = max(-80, min(80, remainingY))
            let stepX = max(-80, min(80, remainingX))
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) {
                event.location = point
                routed(event, window: window).postToPid(pid)
            }
            remainingY -= stepY
            remainingX -= stepX
            pause(0.012)
        }
    }

    // MARK: Keyboard

    static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "iso_left_tab": 48, "space": 49,
        "backspace": 51, "delete": 117, "del": 117, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "page_up": 116, "pageup": 116, "prior": 116,
        "page_down": 121, "pagedown": 121, "next": 121, "insert": 114, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86, "kp_5": 87, "kp_6": 88,
        "kp_7": 89, "kp_8": 91, "kp_9": 92, "kp_decimal": 65, "kp_multiply": 67, "kp_add": 69,
        "kp_subtract": 78, "kp_divide": 75, "kp_equal": 81, "clear": 71, "kp_clear": 71,
        "caps_lock": 57, "volume_up": 72, "volume_down": 73, "mute": 74,
    ]

    static let symbolNames: [String: Character] = [
        "minus": "-", "plus": "+", "equal": "=", "comma": ",", "period": ".", "slash": "/",
        "backslash": "\\", "semicolon": ";", "apostrophe": "'", "grave": "`", "bracketleft": "[",
        "bracketright": "]", "quotedbl": "\"", "exclam": "!", "at": "@", "numbersign": "#",
        "dollar": "$", "percent": "%", "asciicircum": "^", "ampersand": "&", "asterisk": "*",
        "parenleft": "(", "parenright": ")", "underscore": "_", "colon": ":", "less": "<",
        "greater": ">", "question": "?", "braceleft": "{", "braceright": "}", "bar": "|",
        "asciitilde": "~",
    ]

    static let modifierNames: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
        "super": (55, .maskCommand), "cmd": (55, .maskCommand), "command": (55, .maskCommand),
        "meta": (55, .maskCommand), "win": (55, .maskCommand), "super_l": (55, .maskCommand),
        "super_r": (54, .maskCommand), "meta_l": (55, .maskCommand),
        "ctrl": (59, .maskControl), "control": (59, .maskControl), "control_l": (59, .maskControl),
        "control_r": (62, .maskControl),
        "alt": (58, .maskAlternate), "option": (58, .maskAlternate), "opt": (58, .maskAlternate),
        "alt_l": (58, .maskAlternate), "alt_r": (61, .maskAlternate),
        "shift": (56, .maskShift), "shift_l": (56, .maskShift), "shift_r": (60, .maskShift),
        "fn": (63, .maskSecondaryFn),
    ]

    private static let keypadCodes: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    private static let usFallback: [Character: (CGKeyCode, Bool)] = {
        let base: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
            "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        ]
        return base.mapValues { ($0, false) }
    }()

    /// Maps characters to key codes for the *current* keyboard layout (ABNT2, US, etc.).
    static func layoutMap() -> [Character: (CGKeyCode, Bool)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return usFallback
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return usFallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        var map: [Character: (CGKeyCode, Bool)] = [:]
        for shifted in [false, true] {
            for code in 0..<128 where !keypadCodes.contains(code) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let modifiers: UInt32 = shifted ? UInt32(shiftKey >> 8) & 0xFF : 0
                // Option bit 0 = kUCKeyTranslateNoDeadKeysMask.
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                            OptionBits(1), &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length == 1,
                      let char = String(utf16CodeUnits: chars, count: length).first,
                      map[char] == nil else { continue }
                map[char] = (CGKeyCode(code), shifted)
            }
        }
        return map.isEmpty ? usFallback : map
    }

    /// Parses xdotool-style specs such as "Return", "super+c", "ctrl+shift+Tab", "KP_0", "cmd+plus".
    static func parse(_ spec: String) throws -> KeyStroke {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ToolError("key is empty") }

        var parts: [String]
        var keyPart: String
        if trimmed == "+" {
            parts = []
            keyPart = "+"
        } else if trimmed.hasSuffix("++") {
            parts = trimmed.dropLast(2).split(separator: "+").map(String.init)
            keyPart = "+"
        } else {
            parts = trimmed.split(separator: "+").map(String.init)
            keyPart = parts.removeLast()
        }

        var stroke = KeyStroke()
        for part in parts {
            guard let modifier = modifierNames[part.lowercased()] else {
                throw ToolError("Unknown modifier '\(part)'. Use super/cmd, ctrl, alt/option, shift or fn.")
            }
            stroke.modifiers.append(modifier)
        }

        let lower = keyPart.lowercased()
        if let modifier = modifierNames[lower] {
            stroke.modifiers.append(modifier)
            return stroke
        }
        if let code = namedKeys[lower] {
            stroke.code = code
            return stroke
        }

        var char: Character
        if let symbol = symbolNames[lower] {
            char = symbol
        } else if keyPart.count == 1, let first = keyPart.first {
            char = first
        } else {
            throw ToolError("Unknown key '\(keyPart)'. Use xdotool names (Return, Tab, Escape, Up, Page_Down, F5, KP_0, ...) or a single character.")
        }

        let map = layoutMap()
        var mapped = map[char]
        if mapped == nil, char.isUppercase, let lowered = String(char).lowercased().first, let base = map[lowered] {
            mapped = (base.0, true)
        }
        if mapped == nil, char.isLowercase, stroke.modifiers.contains(where: { $0.flag == .maskShift }),
           let lowered = String(char).lowercased().first {
            mapped = map[lowered]
        }
        guard let (code, needsShift) = mapped else {
            throw ToolError("'\(char)' is not on the current keyboard layout; use type_text for it.")
        }
        if needsShift && !stroke.modifiers.contains(where: { $0.flag == .maskShift }) {
            stroke.modifiers.append((56, .maskShift))
        }
        stroke.code = code
        return stroke
    }

    /// Posts to `pid` when given (background, no focus change), otherwise to the HID stream.
    private static func post(_ event: CGEvent, to pid: pid_t?) {
        if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
    }

    static func press(_ stroke: KeyStroke, to pid: pid_t? = nil) {
        let src = source
        var flags: CGEventFlags = []
        for modifier in stroke.modifiers {
            flags.insert(modifier.flag)
            if let event = CGEvent(keyboardEventSource: src, virtualKey: modifier.code, keyDown: true) {
                event.flags = flags
                post(event, to: pid)
            }
            pause(0.01)
        }
        if let code = stroke.code {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
                event.flags = flags
                post(event, to: pid)
                pause(0.02)
            }
        }
        for modifier in stroke.modifiers.reversed() {
            flags.remove(modifier.flag)
            if let event = CGEvent(keyboardEventSource: src, virtualKey: modifier.code, keyDown: false) {
                event.flags = flags
                post(event, to: pid)
            }
            pause(0.01)
        }
    }

    /// Types arbitrary Unicode (accents, emoji) independent of keyboard layout.
    /// Newlines press Return and tabs press Tab, exactly like a human typing.
    static func typeText(_ text: String, to pid: pid_t? = nil) {
        let src = source
        for char in text {
            if char == "\n" || char == "\r\n" || char == "\r" {
                press(KeyStroke(code: 36), to: pid)
                continue
            }
            if char == "\t" {
                press(KeyStroke(code: 48), to: pid)
                continue
            }
            let units = Array(String(char).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event, to: pid)
            }
            pause(0.006)
        }
    }
}
