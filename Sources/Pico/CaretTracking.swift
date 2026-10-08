import AppKit
import ApplicationServices
import Carbon.HIToolbox

public struct InputAnchor: Equatable, Sendable {
    public let caretFrame: NSRect?
    public let fieldFrame: NSRect?
    public init(caretFrame: NSRect?, fieldFrame: NSRect?) {
        self.caretFrame = caretFrame
        self.fieldFrame = fieldFrame
    }
}

/// The first NSScreen is the primary display, independent of the active screen.
/// AX's desktop origin stays at that display's top even with a monitor above it.
struct InputScreenLayout {
    let frames: [NSRect]
    var primaryTop: CGFloat { frames.first?.maxY ?? 0 }
    func cocoaRect(_ axRect: NSRect) -> NSRect {
        NSRect(x: axRect.minX, y: primaryTop - axRect.maxY, width: axRect.width, height: axRect.height)
    }
    func axPoint(_ cocoaPoint: NSPoint) -> NSPoint {
        NSPoint(x: cocoaPoint.x, y: primaryTop - cocoaPoint.y)
    }
    func fieldRect(_ axRect: NSRect?) -> NSRect? {
        guard let axRect, Self.finite(axRect), axRect.width > 0, axRect.height > 0 else { return nil }
        let rect = cocoaRect(axRect)
        return frames.contains(where: { $0.intersects(rect) }) ? rect : nil
    }
    func caretRect(_ axRect: NSRect?, field: NSRect?) -> NSRect? {
        guard let axRect, Self.finite(axRect), axRect.width >= 0, axRect.width <= 4,
            (4...200).contains(axRect.height) else { return nil }
        var rect = cocoaRect(axRect)
        // A zero-width range is a real insertion caret, not an invalid box.
        rect.size.width = max(rect.width, 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard frames.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(center) }) else { return nil }
        if let field, rect.height > field.height + 4 || !field.insetBy(dx: -4, dy: -4).contains(center) {
            return nil
        }
        return rect
    }
    static func finite(_ rect: NSRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
    }
}

@MainActor
enum AXAttributeResult {
    case value(CFTypeRef)
    case unavailable(AXError)
    case budgetExhausted

    var value: CFTypeRef? {
        if case .value(let value) = self { return value }
        return nil
    }
    var permitsOptionalMetadata: Bool {
        switch self {
        case .value: return true
        case .unavailable(let error): return error == .attributeUnsupported || error == .noValue
        case .budgetExhausted: return false
        }
    }
}

@MainActor
struct AXFieldAccess {
    var readAttribute: (AXUIElement, String) -> AXAttributeResult
    var parameterized: (AXUIElement, String, CFTypeRef) -> CFTypeRef?
    var pid: (AXUIElement) -> pid_t?
    var secureInputActive: () -> Bool
    var enableAccessibility: (AXUIElement) -> Void
    var hitTest: (NSPoint) -> AXUIElement?
    var beginRead: () -> Void = {}

    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        readAttribute(element, key).value
    }

    /// A busy/hung host must not multiply its per-message timeout by the tree
    /// size. Once a sample spends its budget, remaining reads fail closed.
    func bounded(to seconds: TimeInterval = 0.12,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Self {
        var deadline: TimeInterval = 0
        let original = self
        var result = self
        result.beginRead = {
            deadline = now() + seconds
            original.beginRead()
        }
        result.readAttribute = { element, key in
            guard now() < deadline else { return .budgetExhausted }
            return original.readAttribute(element, key)
        }
        result.parameterized = { element, key, parameter in
            guard now() < deadline else { return nil }
            return original.parameterized(element, key, parameter)
        }
        result.hitTest = { point in
            guard now() < deadline else { return nil }
            return original.hitTest(point)
        }
        result.enableAccessibility = { element in
            guard now() < deadline else { return }
            original.enableAccessibility(element)
        }
        return result
    }

    static let messagingTimeout: Float = 0.05
    static var live: Self {
        Self(
            readAttribute: { element, key in
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                var result: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, key as CFString, &result)
                if error == .success, let result { return .value(result) }
                return .unavailable(error == .success ? .failure : error)
            },
            parameterized: { element, key, parameter in
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                var result: CFTypeRef?
                return AXUIElementCopyParameterizedAttributeValue(element, key as CFString, parameter, &result)
                    == .success ? result : nil
            },
            pid: { element in
                var pid: pid_t = 0
                return AXUIElementGetPid(element, &pid) == .success ? pid : nil
            },
            secureInputActive: { IsSecureEventInputEnabled() },
            enableAccessibility: { element in
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            },
            hitTest: { point in
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system, messagingTimeout)
                var element: AXUIElement?
                return AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
                    == .success ? element : nil
            })
    }
}

@MainActor
struct AXFieldReader {
    let access: AXFieldAccess
    struct Geometry {
        let anchor: InputAnchor
        let selectedRange: NSRange?
        let isComposing: Bool
    }

    func safe(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard !access.secureInputActive(), access.pid(element) == pid else { return false }
        guard let role = access.readAttribute(element, kAXRoleAttribute as String).value as? String else {
            return false
        }
        let subtype = access.readAttribute(element, kAXSubroleAttribute as String)
        guard subtype.permitsOptionalMetadata else { return false }
        if let value = subtype.value, !(value is String) { return false }
        let subrole = subtype.value as? String ?? ""
        let secureRoles = ["AXSecureTextField", "AXPasswordField"]
        guard !secureRoles.contains(role), !secureRoles.contains(subrole) else { return false }
        let protected = access.readAttribute(element, "AXProtectedContent")
        guard protected.permitsOptionalMetadata else { return false }
        if let value = protected.value, !(value is Bool) { return false }
        guard protected.value as? Bool != true else { return false }
        // Some web fields publish only a password label, without a secure
        // subrole. Read metadata, never the field value, before admitting them.
        let passwordLabels = ["password", "passcode", "passphrase", "密码", "口令"]
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            let metadata = access.readAttribute(element, key as String)
            guard metadata.permitsOptionalMetadata else { return false }
            if let value = metadata.value, !(value is String) { return false }
            if let label = metadata.value as? String,
                passwordLabels.contains(where: { label.lowercased().contains($0) }) { return false }
        }
        return true
    }

    func editable(_ element: AXUIElement) -> Bool {
        let role = access.attribute(element, kAXRoleAttribute as String) as? String ?? ""
        return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
            || access.attribute(element, "AXEditable") as? Bool == true
    }

    func resolve(_ element: AXUIElement, pid: pid_t, depth: Int = 5) -> AXUIElement? {
        var remaining = 32
        func visit(_ candidate: AXUIElement, depth: Int) -> AXUIElement? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            guard safe(candidate, pid: pid) else { return nil }
            if editable(candidate) { return candidate }
            guard depth > 0, let children = access.attribute(candidate, kAXChildrenAttribute as String) as? [AXUIElement]
            else { return nil }
            for child in children {
                if let resolved = visit(child, depth: depth - 1) { return resolved }
            }
            return nil
        }
        return visit(element, depth: depth)
    }

    func geometry(_ element: AXUIElement, pid: pid_t, bundleID: String?, excluded: Set<String>,
        layout: InputScreenLayout) -> Geometry? {
        guard !excluded.contains(bundleID ?? ""), safe(element, pid: pid), editable(element) else { return nil }
        let selected = range(access.attribute(element, kAXSelectedTextRangeAttribute as String))
        let marked = range(access.attribute(element, "AXTextInputMarkedRange"))
        let composing = marked.map { $0.length > 0 } ?? false
        let field = layout.fieldRect(elementFrame(element))
        let caret = caretFrame(element, selected: selected, field: field, layout: layout)
        return Geometry(anchor: InputAnchor(caretFrame: caret, fieldFrame: field),
            selectedRange: selected, isComposing: composing)
    }

    func text(_ element: AXUIElement) -> String? {
        let value = access.attribute(element, kAXValueAttribute as String) as? String
        if let value, !value.isEmpty { return value }
        if let count = access.attribute(element, kAXNumberOfCharactersAttribute as String) as? NSNumber,
            count.intValue > 0, let parameter = rangeValue(NSRange(location: 0, length: count.intValue)),
            let ranged = access.parameterized(element, kAXStringForRangeParameterizedAttribute as String, parameter)
                as? String { return ranged }
        return value
    }

    private func elementFrame(_ element: AXUIElement) -> NSRect? {
        guard let position = access.attribute(element, kAXPositionAttribute as String),
            let size = access.attribute(element, kAXSizeAttribute as String),
            CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
            AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return NSRect(origin: point, size: dimensions)
    }

    private func caretFrame(_ element: AXUIElement, selected: NSRange?, field: NSRect?,
        layout: InputScreenLayout) -> NSRect? {
        if let selected {
            let direct = bounds(element, range: NSRange(location: selected.location, length: 0))
            var native = direct
            if selected.location > 0,
                let previous = bounds(element, range: NSRange(location: selected.location - 1, length: 1)),
                InputScreenLayout.finite(previous), previous.width >= 0, previous.width <= 200,
                (4...200).contains(previous.height) {
                let edge = NSRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height)
                if layout.caretRect(edge, field: field) != nil {
                    if let direct, layout.caretRect(direct, field: field) != nil {
                        if direct.minY < previous.minY || (direct.minY < previous.maxY && direct.maxY > previous.minY) {
                            native = NSRect(x: direct.minX, y: previous.minY, width: direct.width, height: previous.height)
                        }
                    } else { native = edge }
                }
            }
            if let valid = layout.caretRect(native, field: field) { return valid }
            // At the beginning of an empty/new line no preceding glyph exists.
            if let next = bounds(element, range: NSRange(location: selected.location, length: 1)),
                InputScreenLayout.finite(next), next.width >= 0, next.width <= 200 {
                let edge = NSRect(x: next.minX, y: next.minY, width: 1, height: next.height)
                if let valid = layout.caretRect(edge, field: field) { return valid }
            }
        }
        guard let marker = access.attribute(element, "AXSelectedTextMarkerRange"),
            let markerBounds = access.parameterized(element, "AXBoundsForTextMarkerRange", marker)
        else { return nil }
        // Wider marker bounds represent a selection/run, not an insertion caret.
        return layout.caretRect(rect(markerBounds), field: field)
    }

    private func bounds(_ element: AXUIElement, range: NSRange) -> NSRect? {
        guard let parameter = rangeValue(range),
            let value = access.parameterized(element, kAXBoundsForRangeParameterizedAttribute as String, parameter)
        else { return nil }
        return rect(value)
    }
    private func rect(_ value: CFTypeRef) -> NSRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &result) ? result : nil
    }
    private func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0,
            range.location != NSNotFound, range.length >= 0, range.length <= Int.max - range.location else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private func rangeValue(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }
}

struct MonitoredApplication {
    let pid: pid_t
    let bundleID: String?
}
