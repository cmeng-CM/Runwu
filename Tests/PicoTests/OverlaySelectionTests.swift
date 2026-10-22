import AppKit
import XCTest
@testable import Pico

/// 译文区拖选复制：命中区（拖拽层放行）与「只复制选中的那一截」。
/// 合成事件直接走窗口派发，不依赖真实鼠标；选区由 SwiftUI 的文本交互层
/// 自己维护，测试验证边界、选区与复制结果。
@MainActor
final class OverlaySelectionTests: XCTestCase {
    private var coordinator: OverlayCoordinator!
    private var savedPasteboard: String?

    override func setUp() async throws {
        _ = NSApplication.shared
        coordinator = OverlayCoordinator()
        coordinator.textSize = .medium
        coordinator.neverHide = true
        savedPasteboard = NSPasteboard.general.string(forType: .string)
    }

    override func tearDown() async throws {
        coordinator.hide()
        coordinator = nil
        if let savedPasteboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(savedPasteboard, forType: .string)
        }
    }

    // MARK: - 命中区

    private func makeCatcher(bodyTop: CGFloat?, size: NSSize = NSSize(width: 340, height: 140))
        -> WindowDragCatcherView {
        let catcher = WindowDragCatcherView(frame: NSRect(origin: .zero, size: size))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(catcher)
        catcher.selectableBodyTop = bodyTop
        return catcher
    }

    func testTranslationAreaPassesThroughToSwiftUISelection() {
        let catcher = makeCatcher(bodyTop: 66)
        // 卡片顶部往下 66pt 以下 = 译文区：拖拽层放行（返回 nil）。
        XCTAssertNil(catcher.hitTest(NSPoint(x: 100, y: 30)))
        XCTAssertNil(catcher.hitTest(NSPoint(x: 100, y: 8)))
        // 66pt 以上仍是拖拽层，按住才移动窗口。
        XCTAssertTrue(catcher.hitTest(NSPoint(x: 100, y: 120)) === catcher)
        XCTAssertTrue(catcher.hitTest(NSPoint(x: 100, y: 76)) === catcher)
    }

    func testHeaderControlsKeepTheirOwnHitAreas() {
        let catcher = makeCatcher(bodyTop: 66)
        catcher.pinChipVisible = true
        // 右上三键仍让位给 SwiftUI 按钮。
        XCTAssertNil(catcher.hitTest(NSPoint(x: 300, y: 120)))
        // 底边缩放手柄（滚动卡）也让位。
        catcher.excludesHandle = true
        XCTAssertNil(catcher.hitTest(NSPoint(x: 170, y: 10)))
    }

    func testWithoutMeasuredBoundaryTheWholeCardStillDrags() {
        let catcher = makeCatcher(bodyTop: nil)
        XCTAssertTrue(catcher.hitTest(NSPoint(x: 100, y: 30)) === catcher)
    }

    // MARK: - 拖选复制

    /// SwiftUI 的可选中文本层：老系统是 NSTextField（SelectionTextField），
    /// 新系统是 AppKitTextInteractionView；只认这两个，别的控件不参与。
    private func selectionSurface(in view: NSView) -> NSView? {
        var result: NSView?
        func scan(_ v: NSView) {
            guard result == nil else { return }
            let name = String(describing: type(of: v))
            if name.contains("TextInteraction") {
                result = v
            } else if let field = v as? NSTextField, field.isSelectable, !field.isEditable {
                result = v
            }
            for sub in v.subviews { scan(sub) }
        }
        scan(view)
        return result
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in panel: NSPanel) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func drag(from start: NSPoint, to end: NSPoint, in panel: NSPanel) {
        panel.sendEvent(mouse(.leftMouseDown, start, in: panel))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        panel.sendEvent(mouse(.leftMouseDragged, end, in: panel))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        panel.sendEvent(mouse(.leftMouseUp, end, in: panel))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func showingCard(_ translation: String) throws -> (NSView, NSPanel, NSView) {
        coordinator.show(translation, on: NSScreen.main)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let content = try XCTUnwrap(coordinator.panelContentViews.first)
        let panel = try XCTUnwrap(content.window as? NSPanel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let surface = try XCTUnwrap(selectionSurface(in: content), "译文没有生成可拖选的文本层")
        return (content, panel, surface)
    }

    func testDragSelectionCopiesOnlyTheSelectedPart() throws {
        let translation = "The quick brown fox jumps over the lazy dog."
        let (_, panel, surface) = try showingCard(translation)
        let rect = surface.convert(surface.bounds, to: nil)
        XCTAssertGreaterThan(rect.width, 100, "文本层尺寸异常：\(rect)")
        drag(from: NSPoint(x: rect.minX + 2, y: rect.midY),
             to: NSPoint(x: rect.minX + 60, y: rect.midY), in: panel)

        let copied = try XCTUnwrap(coordinator.copySelection(in: panel), "拖选后没有复制到剪贴板")
        XCTAssertTrue(translation.hasPrefix(copied), "复制内容应是选区：\(copied)")
        XCTAssertLessThan(copied.count, translation.count, "只应复制选区，而不是整段")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), copied)
    }

    func testPlainClickWithoutSelectionCopiesNothing() throws {
        let (_, panel, surface) = try showingCard("Nothing selected here.")
        let rect = surface.convert(surface.bounds, to: nil)
        let point = NSPoint(x: rect.minX + 10, y: rect.midY)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("SENTINEL", forType: .string)
        panel.sendEvent(mouse(.leftMouseDown, point, in: panel))
        panel.sendEvent(mouse(.leftMouseUp, point, in: panel))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        XCTAssertNil(coordinator.copySelection(in: panel), "没有选区时不应写剪贴板")
        XCTAssertEqual(pasteboard.string(forType: .string), "SENTINEL", "没有选区时剪贴板不能被清空或改写")
    }


    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    func testSelectableBodyPointUsesFlippedCoordinates() {
        // NSHostingView 是 flipped：y 从顶部往下。y=10 属于标题栏，y=100 是译文区。
        let flipped = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertFalse(OverlayCoordinator.isSelectableBodyPoint(NSPoint(x: 10, y: 10), in: flipped, bodyTop: 60))
        XCTAssertTrue(OverlayCoordinator.isSelectableBodyPoint(NSPoint(x: 10, y: 100), in: flipped, bodyTop: 60))

        // 普通 NSView 从底部往上：y=10 是底部（译文区），y=190 是顶部（标题栏）。
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertTrue(OverlayCoordinator.isSelectableBodyPoint(NSPoint(x: 10, y: 10), in: plain, bodyTop: 60))
        XCTAssertFalse(OverlayCoordinator.isSelectableBodyPoint(NSPoint(x: 10, y: 190), in: plain, bodyTop: 60))
    }

    // MARK: - 边界回传

    func testCardReportsTranslationBoundaryAboveTheText() throws {
        coordinator.show("Hello there.", key: "with-source", on: NSScreen.main, sourceText: "你好")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let top = try XCTUnwrap(coordinator.selectableBodyTops.first, "译文区顶边没有回传")
        let frame = try XCTUnwrap(coordinator.visiblePanelFrames.first)
        // 有原文时：标题栏 + 原文 + 分隔线在大约 60~80pt；必须落在卡片内。
        XCTAssertGreaterThan(top, 45)
        XCTAssertLessThan(top, frame.height - 20)
    }
}
