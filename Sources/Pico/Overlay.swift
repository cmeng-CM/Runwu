import AppKit
import SwiftUI

/// Maps the persisted theme choice to concrete colors used by the overlay.
/// 全卡覆盖的透明拖拽层：手动逐事件驱动窗口移动（setFrameOrigin，无系统
/// 边界栏），四向都允许推出屏幕外——卡片拖到哪儿就停在哪儿。头部按钮区
/// 与底边缩放把手在 hitTest 里穿透给下层 SwiftUI 控件；滚轮显式转发给
/// 正文滚动区（否则事件会死在本层）；悬停经 NSTrackingArea 上报，用于
/// 悬停暂停自动隐藏与钉住按钮的浮现。
private struct WindowDragCatcherRepresentable: NSViewRepresentable {
    var onHoverChange: (Bool) -> Void
    /// 仅视觉的初始同步：视图挂窗/重建时光标若已在卡内，直接点亮 cardHovered
    /// （否则按钮要等一次真实的 mouseEntered 才浮现——卡片弹在光标底下或
    /// 钉住切换重建视图时，用户手没动就永远看不到钉住键）。不碰协调器：
    /// 自动隐藏的看门狗不依赖悬停事件。
    var onInitialHoverSync: ((Bool) -> Void)?
    var excludesHandle: Bool
    /// 钉住按钮当前是否可见（悬停或已钉住）：可见时头部命中区让位三键
    var pinChipVisible: Bool

    func makeNSView(context: Context) -> WindowDragCatcherView {
        let view = WindowDragCatcherView()
        view.onHoverChange = onHoverChange
        view.onInitialHoverSync = onInitialHoverSync
        view.excludesHandle = excludesHandle
        view.pinChipVisible = pinChipVisible
        return view
    }

    func updateNSView(_ nsView: WindowDragCatcherView, context: Context) {
        nsView.onHoverChange = onHoverChange
        nsView.onInitialHoverSync = onInitialHoverSync
        nsView.excludesHandle = excludesHandle
        nsView.pinChipVisible = pinChipVisible
    }
}

final class WindowDragCatcherView: NSView {
    var onHoverChange: (Bool) -> Void = { _ in }
    var onInitialHoverSync: ((Bool) -> Void)?
    var excludesHandle = false
    var pinChipVisible = false
    private var startMouse: CGPoint?
    private var startOrigin: CGPoint?
    private var scrollTarget: NSScrollView?
    private var trackingArea: NSTrackingArea?

    private var didSyncInitialHover = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncInitialHoverOnce()
    }

    /// 视图挂窗/重建时光标若已在卡内，直接点亮 cardHovered（否则钉住键要等
    /// 一次真实的 mouseEntered 才浮现——卡片弹在光标底下、或钉住切换重建
    /// 视图后用户手没动，就永远看不到钉住键）。仅同步视觉状态，不碰协调器：
    /// 自动隐藏不依赖悬停事件（压卡有看门狗，离开有 mouseExited/轮询兜底）。
    /// viewDidMoveToWindow 与 updateTrackingAreas 双钩子：SwiftUI 桥视图的
    /// 挂窗时机不稳，后者在布局完成后必被调用。
    private func syncInitialHoverOnce() {
        guard !didSyncInitialHover, window != nil else { return }
        didSyncInitialHover = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.onInitialHoverSync?(window.frame.contains(NSEvent.mouseLocation))
        }
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse, let startOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        // 无边界栏：跟随光标增量移动，四向都允许推出屏幕外
        window.setFrameOrigin(
            CGPoint(x: startOrigin.x + (now.x - startMouse.x),
                    y: startOrigin.y + (now.y - startMouse.y)))
    }

    override func mouseUp(with event: NSEvent) {
        startMouse = nil
        startOrigin = nil
    }

    // 面板的 isMovableByWindowBackground 会让窗口服务器接管拖拽并在屏幕
    // 顶缘设栏，拖拽改由本层驱动后必须关闭
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 头部按钮区（复制/关闭/钉住）与底边缩放把手穿透给下层控件
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let root = window?.contentView {
            func containsControl(_ view: NSView) -> Bool {
                if let control = view as? OverlayServicePopUpButton, !control.isHidden,
                    control.bounds.contains(control.convert(local, from: self)) { return true }
                return view.subviews.contains(where: containsControl)
            }
            if containsControl(root) { return nil }
        }
        let width = bounds.width, height = bounds.height
        // 三键（钉住/复制/关闭）都在右上：悬停浮现钉住键后让位 104pt，
        // 平时只让位复制/关闭的 70pt
        let chipsWidth: CGFloat = pinChipVisible ? 104 : 70
        if local.x >= width - chipsWidth, local.y >= height - 36 { return nil }
        if excludesHandle,
            local.x >= width / 2 - 40, local.x <= width / 2 + 40,
            local.y <= 26 {
            return nil
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        syncInitialHoverOnce()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange(true)
        DiagnosticLog.write("catcher hover enter")
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange(false)
        DiagnosticLog.write("catcher hover exit")
    }

    override func scrollWheel(with event: NSEvent) {
        if scrollTarget == nil {
            // SwiftUI hoists .overlay views beside the scroll view under
            // the hosting view, so the NSScrollView bridge is a sibling
            // subtree, never an ancestor — search the whole tree.
            var root: NSView? = superview
            while let parent = root?.superview { root = parent }
            var queue: [NSView] = root.map { [$0] } ?? []
            while !queue.isEmpty, scrollTarget == nil {
                let view = queue.removeFirst()
                if let scroll = view as? NSScrollView {
                    scrollTarget = scroll
                } else {
                    queue.append(contentsOf: view.subviews)
                }
            }
        }
        if let scrollTarget {
            scrollTarget.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Maps the persisted theme choice to concrete colors used by the overlay.
extension OverlayTheme {
    var accentColor: Color {
        switch self {
        case .system: return .accentColor
        case .blue: return Color(red: 0.05, green: 0.45, blue: 0.95)
        case .green: return Color(red: 0.10, green: 0.65, blue: 0.35)
        case .purple: return Color(red: 0.55, green: 0.35, blue: 0.90)
        case .orange: return Color(red: 0.95, green: 0.50, blue: 0.15)
        case .pink: return Color(red: 0.90, green: 0.30, blue: 0.55)
        }
    }
}

/// Decides whether a translation card fits on screen or needs to scroll.
/// Pure so the threshold policy is unit-testable.
enum OverlaySizing {
    struct Plan: Equatable {
        let scrolls: Bool
        let textHeightLimit: CGFloat?
        let cardHeight: CGFloat
    }

    /// Width of the longest line when nothing wraps. Together with the card
    /// width clamp (min 340, max 600) this mirrors how SwiftUI sizes the
    /// card, so wrap counts below match the rendered layout.
    static func textWidth(text: String, fontSize: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).width)
    }

    /// Body-text width the card will actually offer: the card is clamped to
    /// 340...600 and pads 16pt leading + 12pt trailing (keep in sync with the
    /// paddings in `TranslationOverlayView.body`).
    static func measuredContentWidth(text: String, fontSize: CGFloat) -> CGFloat {
        let ideal = textWidth(text: text, fontSize: fontSize)
        let card = min(600, max(340, ideal + 28))
        return card - 28
    }

    /// Pulls a frame fully inside `bounds` (used for auto-placed cards so a
    /// fresh card never spawns partially off-screen, whatever the display).
    /// Pure so the clamp math is unit-testable. User-dragged cards are NOT
    /// clamped — 拖到哪儿就停在哪儿，允许故意推出屏幕外。
    static func clampedIntoVisible(_ frame: NSRect, in bounds: NSRect, margin: CGFloat = 8) -> NSRect {
        let x = min(
            max(frame.minX, bounds.minX + margin),
            max(bounds.minX + margin, bounds.maxX - frame.width - margin))
        let y = min(
            max(frame.minY, bounds.minY + margin),
            max(bounds.minY + margin, bounds.maxY - frame.height - margin))
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    /// Exact wrapped text height via TextKit — deterministic regardless of
    /// window state (NSHostingView.fittingSize collapses for scrollable or
    /// unattached content). A few points of drift against SwiftUI's line
    /// layout only matters at the scroll threshold, where either choice is
    /// acceptable.
    static func textHeight(text: String, fontSize: CGFloat, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    static func plan(naturalCardHeight: CGFloat, maxCardHeight: CGFloat, chromeHeight: CGFloat) -> Plan {
        guard naturalCardHeight > maxCardHeight, maxCardHeight > chromeHeight + 60 else {
            return Plan(scrolls: false, textHeightLimit: nil, cardHeight: naturalCardHeight)
        }
        return Plan(
            scrolls: true, textHeightLimit: maxCardHeight - chromeHeight, cardHeight: maxCardHeight)
    }
}

/// A native pull-down participates in AppKit menu tracking without taking focus.
final class OverlayServicePopUpButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class OverlayServiceNativeMenu: NSMenu {
    // AppKit tracks this menu after an action has replaced the old hosting view.
    // Keep its delegate alive until menuDidClose balances the timer suspension.
    var trackingDelegate: NSObject?
}

private struct OverlayServiceMenu: NSViewRepresentable {
    let title: String
    let language: UILanguage
    let selected: TranslationBackend
    let color: Color
    let onSelect: (TranslationBackend) -> Void
    let onTracking: (Bool) -> Void

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: OverlayServiceMenu
        init(_ parent: OverlayServiceMenu) { self.parent = parent }
        @objc func choose(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String,
                let backend = TranslationBackend(rawValue: raw) else { return }
            parent.onSelect(backend)
        }
        func menuWillOpen(_ menu: NSMenu) { parent.onTracking(true) }
        func menuDidClose(_ menu: NSMenu) { parent.onTracking(false) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> OverlayServicePopUpButton {
        let button = OverlayServicePopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        button.controlSize = .mini
        button.setAccessibilityIdentifier("translation-service-menu")
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: OverlayServicePopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = OverlayServiceNativeMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for backend in TranslationBackend.allCases {
            let item = NSMenuItem(title: backend.displayName(for: language),
                action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.target = context.coordinator
            item.representedObject = backend.rawValue
            item.state = selected == backend ? .on : .off
            menu.addItem(item)
        }
        menu.trackingDelegate = context.coordinator
        menu.delegate = context.coordinator
        button.menu = menu
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(color)])
        button.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OverlayServicePopUpButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: min(size.width, proposal.width ?? size.width), height: 22)
    }
}

struct TranslationOverlayView: View {
    let text: String
    let fontSize: CGFloat
    let theme: OverlayTheme
    let surface: OverlaySurfaceEffect
    /// When set, body text scrolls inside this fixed height instead of growing
    /// the card without bound (long clipboard translations).
    let textHeightLimit: CGFloat?
    /// 钉住的卡片不自动隐藏，关闭才消失；状态由协调器持有（跨刷新保留）。
    let contentPinned: Bool
    /// Resize bounds for scrollable cards; the coordinator derives them from
    /// the screen so a dragged-out handle stays on display.
    var minBodyHeight: CGFloat = 90
    var maxBodyHeight: CGFloat = .infinity
    let onClose: () -> Void
    let onCopy: () -> Void
    var headerTitle: String = "润物"
    var serviceLanguage: UILanguage = .chinese
    var selectedService: TranslationBackend = .local
    var onServiceSelected: ((TranslationBackend) -> Void)? = nil
    var onMenuTracking: (Bool) -> Void = { _ in }
    var serviceStatus: String? = nil
    var sourceText: String? = nil
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Live body-height updates while the user drags the bottom handle.
    var onResize: (CGFloat) -> Void = { _ in }
    /// Called when the handle is released so the coordinator can settle the
    /// panel frame (top edge fixed) after SwiftUI has resized the content.
    var onResizeEnd: (CGFloat) -> Void = { _ in }
    /// 钉住/解除钉住当前卡片。
    var onTogglePin: () -> Void = {}

    @State private var closeHovered = false
    @State private var copyHovered = false
    @State private var copied = false
    @State private var pinHovered = false
    @State private var handleHovered = false
    @State private var handlePressed = false
    /// 卡片是否被鼠标悬停：驱动钉住按钮的浮现
    @State private var cardHovered = false
    /// Body height while the handle is being dragged; nil falls back to the
    /// installed limit (also how double-click restores the default).
    @State private var liveLimit: CGFloat?

    private var effectiveLimit: CGFloat? { liveLimit ?? textHeightLimit }

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let onServiceSelected {
                    OverlayServiceMenu(title: headerTitle, language: serviceLanguage,
                        selected: selectedService, color: theme.accentColor,
                        onSelect: onServiceSelected, onTracking: onMenuTracking)
                } else {
                Text(headerTitle)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(theme.accentColor)
                    .lineLimit(1)
                    .accessibilityIdentifier("translation-service-title")
                }
                Spacer(minLength: 8)
                Button(action: onTogglePin) {
                    Image(systemName: contentPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            contentPinned ? Color.primary : (pinHovered ? Color.primary : Color.secondary))
                        .frame(width: 22, height: 22)
                        .background(chipBackground(highlighted: pinHovered))
                }
                .buttonStyle(.plain)
                .opacity(cardHovered || contentPinned ? 1 : 0)
                .onHover { pinHovered = $0 }
                .accessibilityLabel(Text("Pin"))
                Button(action: copyTapped) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            copied ? theme.accentColor : (copyHovered ? Color.primary : Color.secondary))
                        .frame(width: 22, height: 22)
                        .background(chipBackground(highlighted: copyHovered || copied))
                }
                .buttonStyle(.plain)
                .onHover { copyHovered = $0 }
                .accessibilityLabel(Text("Copy"))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(closeHovered ? Color.primary : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(chipBackground(highlighted: closeHovered))
                }
                .buttonStyle(.plain)
                .onHover { closeHovered = $0 }
                .accessibilityLabel(Text("Close"))
            }
            if let serviceStatus {
                Text(serviceStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            textBody
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 13)
        .frame(minWidth: 340, maxWidth: 600)
        .overlay { WindowDragCatcherRepresentable(
            // 悬停事件两个去向缺一不可：cardHovered 只管钉住键浮现，
            // 暂停/恢复自动隐藏必须同步上报协调器（onHoverChange→setHovering）。
            // 拖拽层重构曾丢掉后一条转发，单测全绿而真机卡片照样消失。
            onHoverChange: { hovering in
                cardHovered = hovering
                onHoverChange(hovering)
            },
            onInitialHoverSync: { cardHovered = $0 },
            excludesHandle: textHeightLimit != nil,
            pinChipVisible: cardHovered || contentPinned) }
        .overlay(alignment: .bottom) {
            if textHeightLimit != nil { resizeHandle }
        }
        .background {
            surfaceShape
                .overlay {
                    if theme != .system {
                        shape.fill(theme.accentColor.opacity(0.10))
                    }
                }
                .overlay { shape.stroke(theme.accentColor.opacity(0.35), lineWidth: 1) }
        }
        // The whole card is a move handle; window dragging is driven by the
        // window server via isMovableByWindowBackground (set on the panel), so
        // buttons above still win for plain clicks.
    }

    @ViewBuilder private var textBody: some View {
        let bodyText = VStack(alignment: .leading, spacing: 8) {
            if let sourceText {
                Text(sourceText).font(.system(size: fontSize)).foregroundStyle(.secondary)
                Divider()
            }
            MarkdownCardBodyView(text: text, fontSize: fontSize, accentColor: theme.accentColor)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        if let limit = effectiveLimit {
            ScrollView(.vertical) { bodyText }
                .frame(height: limit)
        } else {
            bodyText
        }
    }

    /// Bottom-edge grabber for scrollable cards: drag to grow/shrink the card
    /// (top edge stays put), double-click to restore the default height.
    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(handleHovered || handlePressed ? 0.75 : 0.35))
            .frame(width: 44, height: 5)
            .padding(.bottom, 3)
            .frame(height: 18)
            .contentShape(Rectangle())
            .onHover { hovering in
                handleHovered = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = liveLimit ?? textHeightLimit ?? 0
                        handlePressed = true
                        let newHeight = min(
                            max(base + value.translation.height, minBodyHeight), maxBodyHeight)
                        if newHeight != liveLimit {
                            liveLimit = newHeight
                            onResize(newHeight)
                        }
                    }
                    .onEnded { _ in
                        handlePressed = false
                        if let liveLimit { onResizeEnd(liveLimit) }
                    }
            )
            .onTapGesture(count: 2) {
                liveLimit = nil
                if let limit = textHeightLimit { onResize(limit) }
            }
    }

    private func chipBackground(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(highlighted ? 0.09 : 0.05))
    }

    @ViewBuilder private var surfaceShape: some View {
        switch surface {
        case .frost: shape.fill(.regularMaterial)
        case .glass: shape.fill(.ultraThinMaterial)
        case .thick: shape.fill(.thickMaterial)
        case .solid: shape.fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func copyTapped() {
        onCopy()
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// 自由浮窗面板：关闭 AppKit 默认的窗口框架约束——默认实现会把窗口
/// 顶边压回菜单栏/屏幕上缘之下，导致「把卡片往顶上抽出去」永远做不到
/// （左右下三向系统本就不设栏）。四向自由全靠这个覆写。
final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

enum OverlayOrigin: Equatable {
    case realtime(InputSessionID)
    case clipboard
    case fixed
}

struct OverlayCardContent: Equatable {
    let source: String?
    let translation: String
}

/// Context of an accepted result, independent of global settings and body
/// presentation. Clipboard cards retain their original input here even when
/// the body displays only the translation. No credentials or model snapshot.
struct OverlayTranslationContext: Equatable, Sendable {
    let sourceText: String
    let sourceLanguage: Language
    let targetLanguage: Language
    let backend: TranslationBackend
}

/// 自动摆位的净空几何：屏内边距、「整张放得下」判定，以及固定槽位卡被
/// 输入框压住时的最小挪位。跟随布局与固定槽位共用同一套边距。
enum OverlayPlacement {
    static let margin: CGFloat = 8
    static let gap: CGFloat = 6
    /// 跟随卡选择输入框上方/下方时，光标贴中线附近的位移不触发翻面：
    /// 两侧差不到这个距离就沿用默认侧，避免光标在中线上下轻移时卡片
    /// 在两三百点开外来回跳。
    static let flipDeadZone: CGFloat = 12

    static func fits(_ frame: NSRect, in bounds: NSRect) -> Bool {
        frame.minX >= bounds.minX + margin && frame.maxX <= bounds.maxX - margin
            && frame.minY >= bounds.minY + margin && frame.maxY <= bounds.maxY - margin
    }

    /// 绕开输入框：上/下/左/右四个方向各试一次贴边落点，钳回屏幕后取位移
    /// 最小的那个（不考虑方向，只算曼哈顿位移，不会为了「先垂直」多绕远）。
    /// 四个方向都放不下就返回 nil，由调用方留在原处。不相交时原样返回——
    /// 位置稳定优先，输入框挪开后自动回到原位。
    static func cleared(_ frame: NSRect, of obstacle: NSRect, in bounds: NSRect) -> NSRect? {
        guard frame.intersects(obstacle) else { return frame }
        let size = frame.size
        func clamped(_ origin: CGPoint) -> NSRect {
            NSRect(
                x: min(max(origin.x, bounds.minX + margin), max(bounds.minX + margin, bounds.maxX - margin - size.width)),
                y: min(max(origin.y, bounds.minY + margin), max(bounds.minY + margin, bounds.maxY - margin - size.height)),
                width: size.width, height: size.height)
        }
        let candidates = [
            clamped(CGPoint(x: frame.minX, y: obstacle.maxY + gap)),
            clamped(CGPoint(x: frame.minX, y: obstacle.minY - gap - size.height)),
            clamped(CGPoint(x: obstacle.maxX + gap, y: frame.minY)),
            clamped(CGPoint(x: obstacle.minX - gap - size.width, y: frame.minY)),
        ].filter { fits($0, in: bounds) && !$0.intersects(obstacle) }
        func distance(_ rect: NSRect) -> CGFloat {
            abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY)
        }
        return candidates.min(by: { distance($0) < distance($1) })
    }

    static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        guard a.intersects(b) else { return 0 }
        let hit = a.intersection(b)
        return hit.width * hit.height
    }
}

/// Placement uses global Cocoa points and the display containing the actual
/// anchor, including negative origins. It never invents an insertion point.
///
/// 跟随卡的第一要求是别压住用户正在看的地方：宿主可能把光标框报在输入行
/// 之外（实测 ZCode 报高一整行），只盯着这个矩形「下方放不下就翻到上方」
/// 的旧规则会把卡片正好落在输入行上——用户看不到自己打的字，也找不到
/// 光标。因此把「输入框 ∪ 光标框」当作整块障碍，按下列顺序取第一个在屏内
/// 放得下的候选：
///   1. 障碍下方 / 上方（先试离光标更近的那侧，中线附近留死区不翻面）：
///      整段输入框留在视野里；
///   2. 光标行左 / 右侧：输入框顶天立地、上下都没位置时从侧面贴近；
///   3. 兜底：没有干净位置时，优先贴光标上下（整屏编辑器这类输入框布满
///      屏幕，贴光标才是用户要的），与贴屏幕上下缘比一比，取压住输入框
///      面积更小的那个。
/// 宿主不报告输入框时障碍就是光标框：先下/上、再光标行左右，光标行始终
/// 不被压住（旧实现只能把卡片钳进屏幕，可能反过来盖住光标）。
struct OverlayFollowingLayout {
    static func frame(size: NSSize, anchor: InputAnchor, screens: [NSRect]) -> NSRect? {
        let candidates = [anchor.caretFrame, anchor.fieldFrame].compactMap { $0 }
        let placement = candidates.compactMap { target -> (NSRect, NSRect)? in
            guard InputScreenLayout.finite(target), target.width >= 0, target.height > 0,
                let screen = screens.first(where: { $0.contains(NSPoint(x: target.midX, y: target.midY)) })
                    ?? screens.first(where: { $0.intersects(target) }),
                screen.width > 16, screen.height > 16 else { return nil }
            return (target, screen)
        }.first
        guard let (target, screen) = placement else { return nil }
        let margin = OverlayPlacement.margin, gap = OverlayPlacement.gap
        let width = min(size.width, screen.width - margin * 2)
        let height = min(size.height, screen.height - margin * 2)
        let x = min(max(target.minX, screen.minX + margin), max(screen.minX + margin, screen.maxX - width - margin))
        func rect(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
        let obstacle = obstacle(anchor: anchor, screen: screen) ?? target
        let below = rect(x, obstacle.minY - gap - height)
        let above = rect(x, obstacle.maxY + gap)
        let caret = valid(anchor.caretFrame, screen: screen)
        // 先试离光标更近的那侧；没有可信光标时先试下方（阅读顺序）
        let preferAbove = caret.map {
            obstacle.maxY - $0.maxY + OverlayPlacement.flipDeadZone < $0.minY - obstacle.minY
        } ?? false
        if let fitted = (preferAbove ? [above, below] : [below, above])
            .first(where: { OverlayPlacement.fits($0, in: screen) }) { return fitted }
        let lineY = min(
            max((caret ?? obstacle).midY - height / 2, screen.minY + margin),
            max(screen.minY + margin, screen.maxY - height - margin))
        if let fitted = [rect(obstacle.maxX + gap, lineY), rect(obstacle.minX - gap - width, lineY)]
            .first(where: { OverlayPlacement.fits($0, in: screen) }) { return fitted }
        var fallbacks: [NSRect] = []
        if let caret {
            fallbacks += [rect(x, caret.maxY + gap), rect(x, caret.minY - gap - height)]
        }
        fallbacks += [rect(x, screen.maxY - margin - height), rect(x, screen.minY + margin)]
        return fallbacks.filter { OverlayPlacement.fits($0, in: screen) }
            .min(by: { OverlayPlacement.overlap($0, obstacle) < OverlayPlacement.overlap($1, obstacle) })
            ?? rect(x, screen.minY + margin)
    }

    /// 障碍区域：输入框矩形并入光标框。宿主把光标框报在输入框之外时，
    /// 只避输入框仍会把卡片落在输入行上，所以两者取并集；任一矩形不可信
    /// （非有限值、零高度、不在本屏）就只用余下的那个。两者都不可信时
    /// 返回 nil，调用方以目标矩形兜底。
    static func obstacle(anchor: InputAnchor, screen: NSRect) -> NSRect? {
        let rects = [anchor.fieldFrame, anchor.caretFrame].compactMap { valid($0, screen: screen) }
        guard var region = rects.first else { return nil }
        for rect in rects.dropFirst() { region = region.union(rect) }
        return region
    }

    private static func valid(_ rect: NSRect?, screen: NSRect) -> NSRect? {
        guard let rect, InputScreenLayout.finite(rect), rect.width >= 0, rect.height > 0,
            screen.intersects(rect) else { return nil }
        return rect
    }
}

@MainActor final class OverlayCoordinator {
    private final class Entry {
        let id: UUID
        let key: String
        let panel: NSPanel
        var text: String
        var sourceText: String?
        var translationContext: OverlayTranslationContext?
        var pendingBackend: TranslationBackend?
        var serviceFailure: String?
        var menuOpen = false
        let origin: OverlayOrigin
        var inputAnchor: InputAnchor?
        var isRealtime: Bool { if case .realtime = origin { return true }; return false }
        var detached: Bool { contentPinned || (isRealtime && isPinned) }
        var textHeightLimit: CGFloat?
        /// Set when the card scrolls: the panel height is a fixed budget
        /// instead of the (collapsed) fitting size of a scroll view.
        var plannedCardHeight: CGFloat?
        /// Actual installed header/status/padding budget, reused during every
        /// drag event and settle without constructing another measurement host.
        var chromeHeight: CGFloat = 0
        weak var screen: NSScreen?
        var avoid: NSRect?
        var slot: OverlayPosition?
        var isPinned = false
        /// 钉住（不自动隐藏，关闭才消失）；与 isPinned（位置保持）语义不同
        var contentPinned = false
        var usesAnchor = false
        var hideTask: Task<Void, Never>?
        /// Lets us detach the didMove observer when the entry goes away.
        var moveObserver: NSObjectProtocol?
        init(id: UUID, key: String, panel: NSPanel, screen: NSScreen?, avoid: NSRect?, text: String,
            sourceText: String?, origin: OverlayOrigin, inputAnchor: InputAnchor?,
            translationContext: OverlayTranslationContext?) {
            self.id = id
            self.key = key
            self.panel = panel
            self.screen = screen
            self.avoid = avoid
            self.text = text
            self.sourceText = sourceText
            self.translationContext = translationContext
            self.origin = origin
            self.inputAnchor = inputAnchor
        }
    }

    /// Debug/diagnostic hook: frames of the panels currently on screen.
    var visiblePanelFrames: [NSRect] { entries.filter { $0.panel.isVisible }.map { $0.panel.frame } }
    /// Debug/diagnostic hook: ids of the entries currently on screen.
    var shownEntryIDs: [UUID] { entries.filter { $0.panel.isVisible }.map(\.id) }
    var cardContents: [OverlayCardContent] { entries.map { OverlayCardContent(source: $0.sourceText, translation: $0.text) } }
    func translationContext(for id: UUID) -> OverlayTranslationContext? {
        entries.first(where: { $0.id == id })?.translationContext
    }
    /// Debug/test hook: content views of the panels currently on screen, so
    /// tests can reach the drag catcher and drive its hover callbacks the way
    /// tracking-area delivery does.
    var panelContentViews: [NSView] { entries.compactMap { $0.panel.contentView } }

    private var entries: [Entry] = []
    /// Top-left corner the next fresh overlay should use. Set when the user
    /// drags a panel; cleared when the configured position changes.
    private var anchor: CGPoint?
    /// True while we move panels ourselves (placement/relayout); didMove
    /// notifications arriving outside these windows are user drags.
    private var isApplyingProgrammaticFrame = false
    var onServiceSelected: ((UUID, TranslationBackend) -> Void)?
    var onEntryRemoved: ((UUID) -> Void)?
    var selectedService: TranslationBackend = .local {
        didSet {
            guard oldValue != selectedService else { return }
            // A global menu checkmark must not remeasure another card's resized body budget.
            for entry in entries {
                (entry.panel.contentView as? NSHostingView<TranslationOverlayView>)?.rootView =
                    makeView(text: entry.text, textHeightLimit: entry.textHeightLimit, id: entry.id)
            }
        }
    }
    var followCaret = true { didSet { if oldValue != followCaret { relayout() } } }
    var uiLanguage: UILanguage = .chinese {
        didSet { if oldValue != uiLanguage { refreshAppearance() } }
    }
    var followingScreenFrames: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }
    var hideAfter: Double = 4
    var neverHide = false
    /// 光标压卡时看门狗的轮询间隔（秒）：压卡期间不倒计时，但 mouseExited
    /// 在视图重建后可能永远不来（取消钉住会重建视图），靠轮询发现离开。
    var cursorWatchInterval: Double = 1
    var textSize: OverlayTextSize = .medium {
        didSet {
            // Re-measure: font size changes both the rendered cards and the
            // scroll threshold computed in installContent.
            guard oldValue != textSize else { return }
            for entry in entries { installContent(for: entry) }
            relayout()
        }
    }
    /// Whole-window transparency applied via panel alpha so slider changes
    /// update live panels without rebuilding views.
    var cardOpacity: Double = 1 {
        didSet {
            let value = CGFloat(min(max(cardOpacity, 0.3), 1))
            entries.forEach { $0.panel.alphaValue = value }
        }
    }
    var theme: OverlayTheme = .system {
        didSet {
            if oldValue != theme { refreshAppearance() }
        }
    }
    var surface: OverlaySurfaceEffect = .frost {
        didSet {
            if oldValue != surface { refreshAppearance() }
        }
    }
    var position: OverlayPosition = .bottomCenter {
        didSet {
            if oldValue != position { anchor = nil }
        }
    }
    var edgeDistance: Double = 48
    var behavior: OverlayBehavior = .stack
    /// Invoked after the overlay's copy button writes text to the pasteboard,
    /// so the owner can resync its clipboard watcher and avoid a feedback loop.
    var onCopyToPasteboard: ((String) -> Void)?
    /// Recreates every panel's content so theme/surface changes apply to
    /// overlays that are already on screen.
    func refreshAppearance() {
        for entry in entries {
            entry.panel.contentView = hostingView(
                text: entry.text, textHeightLimit: entry.textHeightLimit, id: entry.id)
        }
        relayout()
    }

    /// 面板内容一律用「不让 SwiftUI 决定窗口尺寸」的承载方式：默认选项会把
    /// 窗口的内容最小/最大尺寸绑到 SwiftUI 的内在尺寸上，而这份内在尺寸上屏
    /// 后可能塌缩（实测 279 字符译文只报 110 点）——面板被设成实测高度 114
    /// 点后又被最大值夹回 110 点，卡片画出面板之外、压住输入行。只保留
    /// 「可查询内在尺寸」，尺寸一律由 relayout 按实测文本高度决定。
    private func hostingView(text: String, textHeightLimit: CGFloat?, id: UUID)
        -> NSHostingView<TranslationOverlayView> {
        let host = NSHostingView(rootView: makeView(text: text, textHeightLimit: textHeightLimit, id: id))
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }
    func show(_ text: String, on screen: NSScreen?) { show(text, key: UUID().uuidString, on: screen) }
    func show(_ text: String, key: String, on screen: NSScreen?, avoid: NSRect? = nil,
        sourceText: String? = nil, origin: OverlayOrigin = .fixed, inputAnchor: InputAnchor? = nil,
        translationContext: OverlayTranslationContext? = nil) {
        guard !text.isEmpty else {
            if case .realtime = origin { hideRealtime() }
            else { hideFixedUnpinned() }
            return
        }
        if let existing = entries.first(where: { $0.key == key && $0.origin == origin && !$0.detached }) {
            existing.text = text
            existing.sourceText = sourceText
            existing.translationContext = translationContext
            existing.inputAnchor = inputAnchor
            existing.screen = screen ?? existing.screen ?? NSScreen.main
            existing.avoid = avoid
            installContent(for: existing)
            // Restart the auto-hide timer so a refreshed sentence gets the
            // full display duration instead of vanishing on the old schedule.
            scheduleHide(for: existing)
            relayout()
            return
        }
        // replace 模式只顶掉未钉住的卡：钉住的卡只随显式关闭消失
        if case .realtime = origin { hideRealtime() }
        else if behavior == .replace { hideFixedUnpinned() }
        // 数量上限只管未钉住的临时卡（防自动监听/堆叠模式下连续复制糊屏）；
        // 钉住的卡不设上限、永不自动移除——钉住语义=只随显式关闭消失
        let unpinned = entries.filter { !$0.isRealtime && !$0.contentPinned }
        if origin == .clipboard || origin == .fixed, unpinned.count >= 3, let oldest = unpinned.first {
            remove(oldest.id)
        }
        let target = screen ?? NSScreen.main
        let id = UUID()
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 64), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = false
        // 拖拽由卡片上的 WindowDragCatcher 逐事件驱动（setFrameOrigin，无
        // 系统边界栏，四向都允许推出屏幕外），不用窗口服务器背景拖拽
        panel.isMovableByWindowBackground = false
        // 显式关闭「应用失活即隐藏」（NSPanel 默认依赖平台行为）
        panel.hidesOnDeactivate = false
        panel.alphaValue = CGFloat(min(max(cardOpacity, 0.3), 1))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let entry = Entry(id: id, key: key, panel: panel, screen: target, avoid: avoid, text: text,
            sourceText: sourceText, origin: origin, inputAnchor: inputAnchor, translationContext: translationContext)
        entry.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, !self.isApplyingProgrammaticFrame else { return }
                self.pin(id, topLeft: CGPoint(x: panel.frame.minX, y: panel.frame.maxY))
            }
        }
        entries.append(entry)
        installContent(for: entry)
        relayout()
        // Markdown 渲染/文本排版可能需要额外一轮布局才能稳定：
        // 延迟到下一帧二次校准高度，消除弹出后的位置漂移
        DispatchQueue.main.async { [weak self] in
            self?.relayout()
        }
        isApplyingProgrammaticFrame = true
        if !entry.isRealtime || !followCaret { panel.orderFrontRegardless() }
        isApplyingProgrammaticFrame = false
        scheduleHide(for: entry)
    }

    /// Sizes the card for the current text (scrolling when it would exceed the
    /// screen budget) and installs it as the panel's content.
    private func installContent(for entry: Entry) {
        let status = entry.pendingBackend.map { L10n.overlayRetranslating($0, uiLanguage) } ?? entry.serviceFailure
        let chrome: CGFloat
        if entry.translationContext != nil || status != nil {
            let host = NSHostingView(rootView: makeView(text: "", textHeightLimit: 0, id: entry.id))
            measurePanel.contentView = host
            host.layoutSubtreeIfNeeded()
            chrome = host.fittingSize.height
            measurePanel.contentView = nil
        } else { chrome = chromeHeight() }
        entry.chromeHeight = chrome
        let measuredText = entry.sourceText.map { $0 + "\n\n" + entry.text } ?? entry.text
        let naturalText = OverlaySizing.textHeight(
            text: measuredText, fontSize: textSize.points,
            width: OverlaySizing.measuredContentWidth(text: measuredText, fontSize: textSize.points))
        let plan = OverlaySizing.plan(
            naturalCardHeight: naturalText + chrome,
            maxCardHeight: cardHeightLimit(on: entry.screen),
            chromeHeight: chrome)
        entry.textHeightLimit = plan.textHeightLimit
        // 面板高度预算始终记录：非滚动卡也要用，因为 NSHostingView 的
        // fittingSize 在视图上屏后会塌缩（实测 279 字符译文只报 110 点），
        // 面板比内容矮时卡片会画出面板之外、压住输入行。
        entry.plannedCardHeight = plan.cardHeight
        entry.panel.contentView = hostingView(
            text: entry.text, textHeightLimit: entry.textHeightLimit, id: entry.id)
    }

    /// Card height ceiling: roughly 60% of the visible screen so long
    /// translations stay readable instead of spilling past the display edge.
    /// 小屏（13 寸 Air 可视高 ~750pt）按 0.55 阅读区太小，提到 0.6；
    /// 大屏仍受 460 上限约束不受影响。
    private func cardHeightLimit(on screen: NSScreen?) -> CGFloat {
        let visible = screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        return min(460, max(240, visible * 0.6))
    }

    /// Header row + outer padding height, measured once with a zero-height
    /// text area (layout constants, so it never needs invalidation).
    private func chromeHeight() -> CGFloat {
        if let cached = measuredChromeHeight { return cached }
        let host = NSHostingView(
            rootView: TranslationOverlayView(
                text: "Xg", fontSize: 10, theme: theme, surface: surface, textHeightLimit: 0,
                contentPinned: false,
                onClose: {}, onCopy: {}, onHoverChange: { _ in }))
        measurePanel.contentView = host
        host.layoutSubtreeIfNeeded()
        measuredChromeHeight = host.fittingSize.height
        measurePanel.contentView = nil
        return measuredChromeHeight ?? 64
    }
    private var measuredChromeHeight: CGFloat?

    private var measurePanel: NSPanel {
        if let panel = measurePanelStorage { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        measurePanelStorage = panel
        return panel
    }
    private var measurePanelStorage: NSPanel?

    private func makeView(text: String, textHeightLimit: CGFloat?, id: UUID) -> TranslationOverlayView {
        let entry = entries.first(where: { $0.id == id })
        return TranslationOverlayView(
            text: text,
            fontSize: textSize.points,
            theme: theme,
            surface: surface,
            textHeightLimit: textHeightLimit,
            contentPinned: entry?.contentPinned ?? false,
            minBodyHeight: 90,
            maxBodyHeight: max(
                90, (screenForEntry(id)?.visibleFrame.height ?? 900) - 120),
            onClose: { [weak self] in self?.remove(id) },
            onCopy: { [weak self] in
                _ = TranslationClipboard.copy(text)
                self?.onCopyToPasteboard?(text)
            },
            headerTitle: "润物 · " + (entry?.translationContext?.backend.displayName(for: uiLanguage)
                ?? L10n.previewOverlay(uiLanguage)),
            serviceLanguage: uiLanguage,
            selectedService: selectedService,
            onServiceSelected: entry?.translationContext == nil ? nil : { [weak self] backend in
                guard self?.translationContext(for: id) != nil else { return }
                self?.onServiceSelected?(id, backend)
            },
            onMenuTracking: { [weak self] open in self?.setMenuOpen(id, open) },
            serviceStatus: entry?.pendingBackend.map { L10n.overlayRetranslating($0, uiLanguage) } ?? entry?.serviceFailure,
            sourceText: entry?.sourceText,
            onHoverChange: { [weak self] hovering in
                self?.setHovering(id, hovering)
            },
            onResize: { [weak self] bodyHeight in
                self?.recordResize(of: id, to: bodyHeight)
            },
            onResizeEnd: { [weak self] bodyHeight in
                self?.settleResize(of: id, to: bodyHeight)
            },
            onTogglePin: { [weak self] in
                self?.togglePin(of: id)
            })
    }

    private func screenForEntry(_ id: UUID) -> NSScreen? {
        entries.first(where: { $0.id == id })?.screen ?? NSScreen.main
    }

    /// Bottom-edge resize: grows/shrinks the card with the top edge fixed.
    /// While dragging, SwiftUI grows the hosting view and the window along
    /// with it (the cursor's physical screen limit naturally bounds the
    /// drag), so the coordinator only records state; on release
    /// `settleResize` pins the final frame with the top edge fixed and
    /// marks the card user-placed.
    private func recordResize(of id: UUID, to bodyHeight: CGFloat) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let chrome = entry.chromeHeight
        entry.textHeightLimit = bodyHeight
        entry.plannedCardHeight = bodyHeight + chrome
        entry.isPinned = true
    }

    /// Pins the final frame with the top edge fixed. The view already clamps
    /// the drag to sane bounds (the cursor physically cannot leave the screen
    /// mid-drag, so the bottom edge stays reachable); settling with the same
    /// value avoids fighting the hosting view's content sizing.
    func settleResize(of id: UUID, to bodyHeight: CGFloat) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let chrome = entry.chromeHeight
        let clamped = min(max(bodyHeight, 90), 4000)
        entry.textHeightLimit = clamped
        entry.plannedCardHeight = clamped + chrome
        var frame = entry.panel.frame
        frame.origin.y = frame.maxY - (clamped + chrome)
        frame.size.height = clamped + chrome
        isApplyingProgrammaticFrame = true
        entry.panel.setFrame(frame, display: true)
        isApplyingProgrammaticFrame = false
    }

    /// 钉住/解除钉住：钉住的卡片不参与自动隐藏，关闭时才消失。
    /// 切换后重建内容视图，让钉住图标的状态立即反映（否则视图停留在
    /// 创建时的快照，点击无视觉反馈）。
    func togglePin(of id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.contentPinned.toggle()
        if entry.contentPinned {
            // A live card becomes history when pinned. Unpinning restores its
            // timer, but must not attach that historical card to current input.
            if entry.isRealtime { entry.isPinned = true }
            entry.hideTask?.cancel()
            DiagnosticLog.write("overlay pinned id=\(id.uuidString.prefix(6))")
        } else {
            scheduleHide(for: entry)
            DiagnosticLog.write("overlay unpinned id=\(id.uuidString.prefix(6))")
        }
        installContent(for: entry)
    }

    /// Pauses auto-hide while the cursor rests on the card so long
    /// translations can be read (and scrolled) at leisure.
    func setHovering(_ id: UUID, _ hovering: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if hovering {
            entry.hideTask?.cancel()
        } else {
            scheduleHide(for: entry)
        }
    }

    /// Remembers a user-dragged panel and adopts its position as the spot for
    /// future overlays, so moving one out of the way keeps later ones clear.
    private func pin(_ id: UUID, topLeft: CGPoint) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.isPinned = true
        if !entry.isRealtime { anchor = topLeft }
    }

    /// 判定光标是否压在卡片上（scheduleHide 的豁免条件）；测试可注入固定值。
    var cursorOverCard: (NSRect) -> Bool = { frame in frame.contains(NSEvent.mouseLocation) }

    private func scheduleHide(for entry: Entry) {
        // 钉住的卡片不参与自动隐藏，关闭时才消失
        guard !entry.contentPinned, !entry.menuOpen, entry.pendingBackend == nil else { return }
        entry.hideTask?.cancel()
        guard !neverHide else { return }
        // 光标正压在卡片上时不倒计时（悬停豁免：卡片可能就弹在光标位置，
        // 此时没有 mouseEntered 事件）。但不能干等 mouseExited——取消钉住
        // 会重建视图、旧 tracking 区注销，离开事件可能永远不来（2026-09-20
        // 用户报「取消钉住后一直挂着」）。起看门狗轮询，光标一离开转正常
        // 倒计时；事件链路正常时 setHovering(false) 会先到并重置本任务。
        if cursorOverCard(entry.panel.frame) {
            DiagnosticLog.write("auto-hide deferred: cursor over card, watchdog watching")
            entry.hideTask = Task { [weak self, weak entry] in
                while let self, let entry, !Task.isCancelled,
                      self.cursorOverCard(entry.panel.frame) {
                    try? await Task.sleep(for: .seconds(self.cursorWatchInterval))
                }
                guard let entry, !Task.isCancelled else { return }
                self?.scheduleHide(for: entry)
            }
            return
        }
        let seconds = hideAfter
        entry.hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.remove(entry.id)
        }
    }
    func hide() { for id in entries.map(\.id) { remove(id) } }
    func hideUnpinned(except preservedID: UUID? = nil) {
        for id in entries.filter({ !$0.contentPinned && $0.id != preservedID }).map(\.id) { remove(id) }
    }

    func setMenuOpen(_ id: UUID, _ open: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.menuOpen = open
        if open { entry.hideTask?.cancel() } else { scheduleHide(for: entry) }
    }
    func isMenuOpen(_ id: UUID) -> Bool { entries.first(where: { $0.id == id })?.menuOpen ?? false }
    func pendingService(for id: UUID) -> TranslationBackend? {
        entries.first(where: { $0.id == id })?.pendingBackend
    }
    func serviceFailure(for id: UUID) -> String? { entries.first(where: { $0.id == id })?.serviceFailure }
    func beginRetranslation(_ id: UUID, backend: TranslationBackend) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.hideTask?.cancel()
        entry.pendingBackend = backend
        entry.serviceFailure = nil
        resizeRetranslation(entry)
    }
    private func resizeRetranslation(_ entry: Entry) {
        let top = entry.panel.frame.maxY, x = entry.panel.frame.minX
        installContent(for: entry)
        if entry.detached, let view = entry.panel.contentView {
            var size = view.fittingSize
            size.height = max(size.height, entry.plannedCardHeight ?? 0)
            entry.panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        } else { relayout() }
    }
    func finishRetranslation(_ id: UUID, result: String? = nil,
        context: OverlayTranslationContext? = nil, failure: String? = nil) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.pendingBackend = nil
        entry.serviceFailure = failure
        if let result, let context { entry.text = result; entry.translationContext = context }
        resizeRetranslation(entry)
        scheduleHide(for: entry)
    }

    private func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.hideTask?.cancel()
        if let observer = entry.moveObserver { NotificationCenter.default.removeObserver(observer) }
        entry.panel.orderOut(nil)
        onEntryRemoved?(id)
        // Relayout each remaining panel on its own screen so closing one
        // overlay on a secondary display does not move the others to the main
        // screen.
        relayout()
    }
    func showRealtime(source: String, translation: String, key: String, session: InputSessionID,
        anchor: InputAnchor?, translationContext: OverlayTranslationContext? = nil) {
        show(translation, key: key, on: screen(containing: anchor), avoid: anchor?.fieldFrame, sourceText: source,
            origin: .realtime(session), inputAnchor: anchor, translationContext: translationContext)
    }
    func updateAnchor(_ anchor: InputAnchor, session: InputSessionID) {
        for entry in entries where entry.origin == .realtime(session) && !entry.detached {
            entry.inputAnchor = anchor
            // 固定模式（跟随关闭）靠 avoid 避让输入框；输入框随窗口/换行移动后
            // 这里必须同步，否则卡片会照旧槽位压住已经挪过来的输入框。
            entry.avoid = anchor.fieldFrame
            entry.screen = screen(containing: anchor) ?? entry.screen
        }
        relayout()
    }
    func hideRealtime(except preservedID: UUID? = nil) {
        for id in entries.filter({ $0.isRealtime && !$0.detached && $0.id != preservedID }).map(\.id) { remove(id) }
    }
    private func hideFixedUnpinned() {
        for id in entries.filter({ !$0.isRealtime && !$0.contentPinned }).map(\.id) { remove(id) }
    }
    private func screen(containing anchor: InputAnchor?) -> NSScreen? {
        guard let rect = anchor?.caretFrame ?? anchor?.fieldFrame else { return nil }
        return NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
    }
    private func relayout() {
        isApplyingProgrammaticFrame = true
        defer { isApplyingProgrammaticFrame = false }
        var stackIndex = 0
        var autoPlaced: [(entry: Entry, frame: NSRect)] = []
        for entry in entries {
            if entry.contentPinned { continue }
            entry.panel.contentView?.layoutSubtreeIfNeeded()
            let fitting = entry.panel.contentView?.fittingSize ?? entry.panel.frame.size
            // 高度取「实测渲染」与「文本量预估」的较大值：fittingSize 会塌缩
            // （上屏后常见的只报头部高度），沿用塌缩值会让卡片画出面板之外。
            let size = NSSize(width: fitting.width,
                height: max(fitting.height, entry.plannedCardHeight ?? 0))
            if entry.isPinned {
                if entry.isRealtime { continue }
                let old = entry.panel.frame
                entry.panel.setFrame(NSRect(x: old.minX, y: old.maxY - size.height,
                    width: size.width, height: size.height), display: true)
                continue
            }
            if entry.isRealtime && followCaret {
                if let anchor = entry.inputAnchor,
                    let frame = OverlayFollowingLayout.frame(size: size, anchor: anchor, screens: followingScreenFrames()) {
                    // 落点日志：只有坐标与「是否压住输入框」，用来在宿主报偏几何时
                    // 直接看出卡片落到了哪里（仅在落点变化时记，不刷屏）。
                    if entry.panel.frame != frame {
                        DiagnosticLog.write(
                            "follow card frame=\(AccessibilityMonitor.coordinates(frame))"
                                + " covers_field=\(anchor.fieldFrame.map { frame.intersects($0) }.map(String.init) ?? "unknown")"
                                + " covers_caret=\(anchor.caretFrame.map { frame.intersects($0) }.map(String.init) ?? "unknown")")
                    }
                    entry.panel.setFrame(frame, display: true)
                    if !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
                } else { entry.panel.orderOut(nil) }
                continue
            }
            if let anchor, entry.usesAnchor || (entry.slot == nil && stackIndex == 0) {
                entry.usesAnchor = true
                entry.panel.setFrame(Self.anchoredFrame(size: size, topLeft: anchor, on: entry.screen), display: true)
                if entry.isRealtime && !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
                stackIndex += 1
                continue
            }
            autoPlaced.append((entry, slotFrame(for: entry, size: size, stackIndex: stackIndex)))
            stackIndex += 1
        }
        // 自动摆位的固定卡按显示器成组落地：组内任一成员被当前输入框压住时
        // 整组同向挪开并保持堆叠间距。各自挪位会让后面的卡压住前面的卡。
        for (entry, frame) in autoPlaced {
            entry.panel.setFrame(groupedFrame(frame, of: entry, group: autoPlaced), display: true)
            if entry.isRealtime && !entry.panel.isVisible { entry.panel.orderFrontRegardless() }
        }
    }

    /// 固定卡的配置槽位落点（含堆叠偏移）；输入框避让在整组一步做。
    private func slotFrame(for entry: Entry, size: NSSize, stackIndex: Int) -> NSRect {
        let slot = entry.slot ?? position
        entry.slot = slot
        return position(for: size, on: entry.screen, slot: slot, stackIndex: stackIndex)
    }

    /// 同屏自动卡作为一组让开输入框：组内确实有成员被压住时，整组按同一
    /// 增量挪开（只比整组包围盒与输入框相交就动会平白挪卡：两卡之间的空隙
    /// 也能和包围盒相交），输入框移开后整组自动回到配置槽位。组里没有输入
    /// 框信息的卡片（剪贴板卡）随组一起走，否则会被挪开的实时卡反压住。
    private func groupedFrame(_ frame: NSRect, of entry: Entry,
        group: [(entry: Entry, frame: NSRect)]) -> NSRect {
        let bounds = entry.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let members = group.filter { $0.entry.screen === entry.screen }
        guard var union = members.first?.frame else { return frame }
        var obstacle: NSRect?
        for member in members.dropFirst() { union = union.union(member.frame) }
        for member in members {
            guard let avoid = member.entry.avoid, avoid != .zero, avoid.intersects(bounds) else { continue }
            obstacle = obstacle.map { $0.union(avoid) } ?? avoid
        }
        guard let obstacle, members.contains(where: { $0.frame.intersects(obstacle) }),
            let cleared = OverlayPlacement.cleared(union, of: obstacle, in: bounds) else { return frame }
        return NSRect(x: frame.minX + (cleared.minX - union.minX), y: frame.minY + (cleared.minY - union.minY),
            width: frame.width, height: frame.height)
    }

    private static func anchoredFrame(size: NSSize, topLeft: CGPoint, on screen: NSScreen?) -> NSRect {
        let bounds = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 8
        let x = min(max(topLeft.x, bounds.minX + margin), max(bounds.minX + margin, bounds.maxX - size.width - margin))
        let y = min(
            max(topLeft.y - size.height, bounds.minY + margin),
            max(bounds.minY + margin, bounds.maxY - size.height - margin))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
    private func position(for size: NSSize, on screen: NSScreen?, slot: OverlayPosition, stackIndex: Int) -> NSRect {
        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let distance = CGFloat(max(0, edgeDistance))
        let offset = CGFloat(stackIndex) * (size.height + 10)
        switch slot {
        case .topRight:
            return NSRect(
                x: frame.maxX - size.width - distance, y: frame.maxY - size.height - distance - offset,
                width: size.width, height: size.height)
        case .bottomRight:
            return NSRect(
                x: frame.maxX - size.width - distance, y: frame.minY + distance + offset, width: size.width,
                height: size.height)
        case .bottomCenter:
            return NSRect(
                x: frame.midX - size.width / 2, y: frame.minY + distance + offset, width: size.width,
                height: size.height)
        }
    }
}
