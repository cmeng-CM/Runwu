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

    /// 「像输入框」的高度上限（屏高比例）：超过这个高度的矩形更像整窗/整页
    /// 容器——祖先兜底跳过它，跟随避让也不把它当障碍（整屏编辑器宿主把整个
    /// 编辑器报成一个输入框，当障碍会把卡片挤到屏幕边，贴不到光标）。
    static let fieldHeightLimitFraction: CGFloat = 0.6
    static func withinFieldHeight(_ rect: NSRect, on screen: NSRect) -> Bool {
        rect.height <= screen.height * fieldHeightLimitFraction
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
    /// 携带错误的 parameterized 读取：锚窗读取要按 D-13 区分「宿主不支持」与「读失败」。
    /// 默认值让既有构造点保持原样（该读取视为宿主不支持）。
    var parameterizedResult: (AXUIElement, String, CFTypeRef) -> AXAttributeResult = { _, _, _ in
        .unavailable(.attributeUnsupported)
    }
    var pid: (AXUIElement) -> pid_t?
    var secureInputActive: () -> Bool
    var enableAccessibility: (AXUIElement) -> Void
    var hitTest: (NSPoint) -> AXUIElement?
    var beginRead: () -> Void = {}
    var writeAttribute: (AXUIElement, String, CFTypeRef) -> AXError = { element, key, value in
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return AXUIElementSetAttributeValue(element, key as CFString, value)
    }

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
        result.parameterizedResult = { element, key, parameter in
            guard now() < deadline else { return .budgetExhausted }
            return original.parameterizedResult(element, key, parameter)
        }
        result.hitTest = { point in
            guard now() < deadline else { return nil }
            return original.hitTest(point)
        }
        result.writeAttribute = { element, key, value in
            guard now() < deadline else { return .cannotComplete }
            return original.writeAttribute(element, key, value)
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
            parameterizedResult: { element, key, parameter in
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                var result: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(element, key as CFString, parameter, &result)
                if error == .success, let result { return .value(result) }
                return .unavailable(error == .success ? .failure : error)
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

/// Chromium contenteditable（实测 Obsidian）里 `AXSelectedTextRange` 的偏移按宿主
/// 自身文本计数，而 `AXValue` 在每个块边界多出换行并保留标记字符——两套坐标系。
/// 直接按偏移索引 `AXValue` 会把当前句取到光标上方。这里用宿主锚窗做内容锚定，
/// 把偏移换回 `AXValue` 的 UTF-16 索引；找不到或候选倒退（违反漂移方向）返回 nil，
/// 由调用方按不可信采样处理（不出卡）。两套坐标系对空白与零宽标记的表示法不同
/// （实测宿主 `ZWSP+\t` ↔ `AXValue` 换行），逐字锚在真实宿主里经常找不到，故逐字
/// 失败后按去空白归一化再做一次定位（D-07，实义字符不放宽）。全部单位是 UTF-16 单元。
enum CaretOffsetMapping {
    /// 锚窗长度：足以在重复行常见的文档里定位，又不依赖宿主内部改写规则。
    static let windowLength = 24
    /// 少于 8 个 UTF-16 单元无法辨识（短句重复多），不做映射。
    static let minimumAnchorLength = 8
    /// 归一化去除的字符：系统空白/换行（空格、制表、换行等）加两种零宽字符
    /// （ZWSP U+200B、ZWNBSP/BOM U+FEFF）——实测宿主用它们表示块边界。
    static let strippedCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{200B}\u{FEFF}")
        return set
    }()

    /// 两段式定位：先逐字匹配（原行为）；逐字找不到时容忍空白/标记的形态差异，
    /// 走 `mappedIndexIgnoringWhitespace`。方向守卫（`mapped >= hostOffset`）不变。
    static func mappedIndex(anchor: String, hostOffset: Int, in text: NSString) -> Int? {
        guard hostOffset >= minimumAnchorLength, anchor.utf16.count >= minimumAnchorLength else { return nil }
        let start = max(0, hostOffset - windowLength)
        guard start <= text.length else { return nil }
        let found = text.range(of: anchor, options: [], range: NSRange(location: start, length: text.length - start))
        guard found.location != NSNotFound else {
            return mappedIndexIgnoringWhitespace(anchor: anchor, hostOffset: hostOffset, in: text)
        }
        // 命中长度取实际命中：`range(of:)` 默认按规范等价匹配，锚与文本的归一化
        // 形式不同（NFC/NFD）时命中长度不等于锚自身的 UTF-16 长度。
        let mapped = found.location + found.length
        // 漂移方向单调（AXValue 相对宿主只多不少）：候选落到宿主偏移之前即拒绝。
        guard mapped >= hostOffset else { return nil }
        return mapped
    }

    /// 逐字找不到时的归一化兜底（D-07）：`text` 与锚同法去除空白/零宽字符，在归一化
    /// 串里从「归一化后的 s 位置」（`s = max(0, hostOffset - 24)`）起找首个命中，
    /// 命中区间末端经「归一化索引 → 原文索引」表还原为 `AXValue` 的 UTF-16 索引。
    /// 实义锚尾取最后命中单元后的插入边界，不跨过随后的空白；锚尾为去除字符时
    /// 沿用下一保留单元/文末哨兵，不推断空白块归属。
    /// 归一化锚不足 8 个非空白单元不匹配（短锚不可辨识，fail-closed）；候选仍须
    /// `mapped >= hostOffset`（方向前提的操作化，不依赖单调性假设）。
    static func mappedIndexIgnoringWhitespace(anchor: String, hostOffset: Int, in text: NSString) -> Int? {
        let anchorText = anchor as NSString
        let (normalizedAnchor, _) = whitespaceNormalized(anchorText)
        guard normalizedAnchor.length >= minimumAnchorLength else { return nil }
        let (normalizedText, originals) = whitespaceNormalized(text)
        let start = max(0, hostOffset - windowLength)
        guard start <= text.length, let normalizedStart = originals.firstIndex(where: { $0 >= start }),
            normalizedStart <= normalizedText.length else { return nil }
        let found = normalizedText.range(of: normalizedAnchor as String, options: [],
            range: NSRange(location: normalizedStart, length: normalizedText.length - normalizedStart))
        guard found.location != NSNotFound else { return nil }
        let hitEnd = found.location + found.length
        guard hitEnd < originals.count else { return nil }
        let mapped = isStripped(anchorText.character(at: anchorText.length - 1))
            ? originals[hitEnd] : originals[hitEnd - 1] + 1
        guard mapped >= hostOffset else { return nil }
        return mapped
    }

    /// 单个 UTF-16 单元是否属于归一化去除集合（空白/零宽标记）。
    static func isStripped(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return strippedCharacters.contains(scalar)
    }

    /// 单个 UTF-16 单元的字符串是否属于同一去除集合——甄别两侧（宿主后一位字符与
    /// `AXValue[mapped]`）共用这个判断，空白/标记的形态差异不构成「不一致」的证据。
    static func isStripped(_ character: String) -> Bool {
        guard character.utf16.count == 1, let unit = character.utf16.first else { return false }
        return isStripped(unit)
    }

    /// 去除空白/零宽字符，返回归一化串与「归一化索引 → 原文索引」表（升序）。
    /// 表比归一化串长 1：末尾哨兵（原文长度）供锚尾去除字符的旧边界策略使用。
    static func whitespaceNormalized(_ text: NSString) -> (normalized: NSString, originals: [Int]) {
        var kept: [unichar] = []
        var originals: [Int] = []
        kept.reserveCapacity(text.length)
        originals.reserveCapacity(text.length + 1)
        for index in 0..<text.length {
            let unit = text.character(at: index)
            if isStripped(unit) { continue }
            kept.append(unit)
            originals.append(index)
        }
        originals.append(text.length)
        return (NSString(characters: kept, length: kept.count), originals)
    }
}

@MainActor
struct AXFieldReader {
    let access: AXFieldAccess
    struct Geometry {
        let anchor: InputAnchor
        let selectedRange: NSRange?
        // nil is an unreadable composition state, never an implicit commit.
        let isComposing: Bool?
        /// 宿主在 `[r - 24, r)` 的文本（Chromium contenteditable 的两套坐标系，
        /// 见 `CaretOffsetMapping`）。nil 表示宿主不提供该读取或短锚（沿用报告偏移）。
        let hostAnchor: String?
        /// 宿主在光标后一位的字符：映射后的局部甄别材料。读不到、或读到的字符属于
        /// 归一化去除集合（空白/零宽形态，见 `CaretOffsetMapping.strippedCharacters`）
        /// 时为 nil——不可比即跳过甄别（D-07）。
        let postCaretCharacter: String?
        /// 锚窗读取失败（显式错误/预算耗尽/读回空）：宿主偏移不可信，不出卡。
        let anchorReadFailed: Bool
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

    /// Unsupported optional native metadata retains compatibility; explicit
    /// false, malformed values and real AX errors never fall back to the role.
    private func optionalBoolean(_ element: AXUIElement, _ key: String) -> (valid: Bool, value: Bool?) {
        let result = access.readAttribute(element, key)
        guard result.permitsOptionalMetadata else { return (false, nil) }
        guard let value = result.value else { return (true, nil) }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else { return (false, nil) }
        return (true, boolean)
    }

    private enum EditingQualification { case editor, container, rejected }
    private func editingQualification(_ element: AXUIElement) -> EditingQualification {
        let enabled = optionalBoolean(element, kAXEnabledAttribute as String)
        guard enabled.valid, enabled.value != false else { return .rejected }
        let editable = optionalBoolean(element, "AXEditable")
        guard editable.valid, editable.value != false else { return .rejected }
        if editable.value == true { return .editor }
        guard let role = access.attribute(element, kAXRoleAttribute as String) as? String else { return .rejected }
        return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
            ? .editor : .container
    }
    func editable(_ element: AXUIElement) -> Bool { editingQualification(element) == .editor }

    func eligible(_ element: AXUIElement, pid: pid_t, requiresExplicitFocus: Bool = false) -> Bool {
        guard safe(element, pid: pid) else { return false }
        let focus = optionalBoolean(element, kAXFocusedAttribute as String)
        guard focus.valid, focus.value != false,
            !requiresExplicitFocus || focus.value == true else { return false }
        return editable(element)
    }

    func resolve(_ element: AXUIElement, pid: pid_t, depth: Int = 5,
        requiresExplicitFocus: Bool = false) -> AXUIElement? {
        var remaining = 32
        func visit(_ candidate: AXUIElement, depth: Int, isRoot: Bool) -> AXUIElement? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            guard safe(candidate, pid: pid) else { return nil }
            let focus = optionalBoolean(candidate, kAXFocusedAttribute as String)
            guard focus.valid else { return nil }
            // Only the authoritative root's explicit denial vetoes its tree.
            // A safe layout wrapper need not itself hold keyboard focus.
            if isRoot, !requiresExplicitFocus, focus.value == false { return nil }
            let editing = editingQualification(candidate)
            guard editing != .rejected else { return nil }
            let hasFocus = focus.value != false && ((!requiresExplicitFocus && isRoot) || focus.value == true)
            if hasFocus, editing == .editor { return candidate }
            guard depth > 0,
                let children = access.attribute(candidate, kAXChildrenAttribute as String) as? [AXUIElement] else { return nil }
            for child in children {
                if let resolved = visit(child, depth: depth - 1, isRoot: false) { return resolved }
            }
            return nil
        }
        return visit(element, depth: depth, isRoot: true)
    }

    func geometry(_ element: AXUIElement, pid: pid_t, bundleID: String?, excluded: Set<String>,
        layout: InputScreenLayout, requiresExplicitFocus: Bool = false) -> Geometry? {
        guard !excluded.contains(bundleID ?? ""),
            eligible(element, pid: pid, requiresExplicitFocus: requiresExplicitFocus) else { return nil }
        let selected = range(access.attribute(element, kAXSelectedTextRangeAttribute as String))
        let marked = access.readAttribute(element, "AXTextInputMarkedRange")
        let composing: Bool? = marked.permitsOptionalMetadata
            ? (range(marked.value).map { $0.length > 0 } ?? false) : nil
        // 输入框矩形：焦点元素自己报不出时向上找（Chromium contenteditable 常见）。
        // 光标先按无输入框校验算一次，兜底定位要用它的横向位置。
        var field = layout.fieldRect(elementFrame(element))
        let caret = caretFrame(element, selected: selected, field: field, layout: layout)
        if field == nil, let caretX = caret?.midX {
            field = enclosingFieldFrame(element, caretX: caretX, layout: layout)
        }
        let window = anchorWindow(element, selected: selected)
        return Geometry(anchor: InputAnchor(caretFrame: caret, fieldFrame: field),
            selectedRange: selected, isComposing: composing,
            hostAnchor: window.hostAnchor, postCaretCharacter: window.postCaretCharacter,
            anchorReadFailed: window.failed)
    }

    private struct AnchorWindow {
        let hostAnchor: String?
        let postCaretCharacter: String?
        let failed: Bool
    }

    /// 锚窗读取（`AXSelectedTextRange` 与 `AXValue` 两套坐标系时的映射原料）：
    /// 读宿主在 `[max(0, r - 24), r)` 的文本，再读光标后一位字符供局部甄别。
    /// 分档沿用 D-13——宿主不支持该读取或短锚（r < 8）按「不支持」处理（nil，沿用
    /// 报告偏移）；显式错误、预算耗尽、读回空按不可信采样（fail-closed，不翻错行）。
    private func anchorWindow(_ element: AXUIElement, selected: NSRange?) -> AnchorWindow {
        let none = AnchorWindow(hostAnchor: nil, postCaretCharacter: nil, failed: false)
        guard let selected, selected.location >= CaretOffsetMapping.minimumAnchorLength else { return none }
        let caret = selected.location
        let start = max(0, caret - CaretOffsetMapping.windowLength)
        guard let parameter = rangeValue(NSRange(location: start, length: caret - start)) else { return none }
        switch access.parameterizedResult(element, kAXStringForRangeParameterizedAttribute as String, parameter) {
        case .budgetExhausted:
            return AnchorWindow(hostAnchor: nil, postCaretCharacter: nil, failed: true)
        case .unavailable(let error):
            guard error != .attributeUnsupported, error != .noValue else { return none }
            return AnchorWindow(hostAnchor: nil, postCaretCharacter: nil, failed: true)
        case .value(let raw):
            guard let hostAnchor = raw as? String else {
                return AnchorWindow(hostAnchor: nil, postCaretCharacter: nil, failed: true)
            }
            // 实测 Obsidian 偶发大范围读取返回空：空读（r ≥ 8 > 0）不是「宿主不支持」。
            guard !hostAnchor.isEmpty else {
                return AnchorWindow(hostAnchor: nil, postCaretCharacter: nil, failed: true)
            }
            guard hostAnchor.utf16.count >= CaretOffsetMapping.minimumAnchorLength else { return none }
            return AnchorWindow(hostAnchor: hostAnchor,
                postCaretCharacter: postCaretCharacter(element, caret: caret), failed: false)
        }
    }

    /// 光标后一位字符（局部甄别用）。读不到（越界/不支持/错误）就当不可比，
    /// 不因此关闭采样——D-06 只在可读时要求与 `AXValue[mapped]` 一致；读到的
    /// 字符是空白/零宽形态（实测宿主用 `ZWSP+\t` 表示块边界）同样不可比：
    /// 两套坐标系对空白的表示法不同，形态差异不构成「不一致」的证据（D-07）。
    private func postCaretCharacter(_ element: AXUIElement, caret: Int) -> String? {
        guard let parameter = rangeValue(NSRange(location: caret, length: 1)),
            case .value(let raw) = access.parameterizedResult(
                element, kAXStringForRangeParameterizedAttribute as String, parameter),
            let value = raw as? String, value.utf16.count == 1,
            let unit = value.utf16.first, !CaretOffsetMapping.isStripped(unit) else { return nil }
        return value
    }

    /// 输入框矩形兜底：向上找最近的「像输入框」的祖先——矩形有效、与本屏相交、
    /// 横向盖住光标，且高度不接近整屏（整窗/整页容器当障碍会让卡片无处可躲）。
    /// 焦点元素在 Chromium contenteditable 里常是深层文本节点，自己不带矩形，
    /// 但它上面的容器就是可见输入框。
    func enclosingFieldFrame(_ element: AXUIElement, caretX: CGFloat, layout: InputScreenLayout) -> NSRect? {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current, let parent = access.attribute(node, kAXParentAttribute as String),
                CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            let candidate = parent as! AXUIElement
            current = candidate
            guard let rect = layout.fieldRect(elementFrame(candidate)),
                let screen = layout.frames.first(where: { $0.intersects(rect) }),
                InputScreenLayout.withinFieldHeight(rect, on: screen),
                rect.insetBy(dx: -2, dy: 0).contains(NSPoint(x: caretX, y: rect.midY)) else { continue }
            return rect
        }
        return nil
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
