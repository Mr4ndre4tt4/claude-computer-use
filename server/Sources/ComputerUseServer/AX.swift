import AppKit
import ApplicationServices

/// Hashable wrapper so AXUIElements can key dictionaries (CFEqual/CFHash identity).
struct ElementKey: Hashable {
    let el: AXUIElement
    init(_ el: AXUIElement) { self.el = el }
    static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.el, b.el) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(el)) }
}

enum AX {
    static func string(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() { return value as? String }
        if type == CFAttributedStringGetTypeID() { return (value as? NSAttributedString)?.string }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "1" : "0" }
        if type == CFNumberGetTypeID() {
            guard let number = value as? NSNumber else { return nil }
            let double = number.doubleValue
            if double == double.rounded() && abs(double) < 1e15 { return String(Int64(double)) }
            return String(format: "%.4g", double)
        }
        if type == CFURLGetTypeID() { return (value as? URL)?.absoluteString }
        return nil
    }

    static func bool(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        if type == CFNumberGetTypeID() { return (value as? NSNumber)?.boolValue }
        return nil
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AnyObject] else { return [] }
        return array.compactMap { element($0) }
    }

    /// "AXPress" -> "Press"; custom actions ("Name:Reply\nTarget:...") -> "Reply".
    static func displayAction(_ raw: String) -> String {
        if raw.hasPrefix("Name:") {
            let rest = raw.dropFirst(5)
            return String(rest.split(separator: "\n", maxSplits: 1).first ?? Substring(rest))
        }
        return raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
    }

    static func normalizeAction(_ name: String) -> String {
        var n = name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        if n.hasPrefix("ax") { n.removeFirst(2) }
        return n
    }
}

extension AXUIElement {
    func raw(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    func str(_ name: String) -> String? { AX.string(raw(name)) }
    func bool(_ name: String) -> Bool? { AX.bool(raw(name)) }
    func element(_ name: String) -> AXUIElement? { AX.element(raw(name)) }
    func elements(_ name: String) -> [AXUIElement] { AX.elements(raw(name)) }

    var frame: CGRect? {
        guard let origin = AX.point(raw("AXPosition")), let size = AX.size(raw("AXSize")) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    @discardableResult
    func perform(_ action: String) -> AXError { AXUIElementPerformAction(self, action as CFString) }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError { AXUIElementSetAttributeValue(self, name as CFString, value) }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    /// Fetches many attributes in one IPC round trip; missing ones come back nil.
    /// Returns nil when the app does not answer (hung or busy), so callers can stop early.
    func multi(_ names: [String]) -> [CFTypeRef?]? {
        var out: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        if status == .cannotComplete { return nil }
        guard status == .success, let values = out as? [AnyObject], values.count == names.count else {
            return names.map { raw($0) }
        }
        return values.map { $0 as CFTypeRef }
    }
}
