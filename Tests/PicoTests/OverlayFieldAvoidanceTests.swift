import AppKit
import XCTest
@testable import Pico

/// 浮窗不压输入框：跟随卡按「输入框 ∪ 光标框」整体避让，固定槽位卡在原
/// 槽位内挪开。用户 2026-10-10 实测反馈：翻译框正好盖住输入行，看不到
/// 自己打的字，也找不到光标；输入框靠屏幕上/下缘时固定位置同样会被压住。
@MainActor
final class OverlayFieldAvoidanceTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let composer = NSRect(x: 170, y: 20, width: 980, height: 105)

    // MARK: - 跟随布局（纯函数）

    /// 底部输入框：卡片挂到输入框上缘，整段输入框留在视野里。
    func testFollowingCardHangsAboveABottomComposer() throws {
        let caret = NSRect(x: 500, y: 45, width: 1, height: 20)
        let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: NSSize(width: 590, height: 150),
            anchor: InputAnchor(caretFrame: caret, fieldFrame: composer), screens: [screen]))
        XCTAssertEqual(frame.minY, composer.maxY + 6)
        XCTAssertEqual(frame.minX, caret.minX)
        XCTAssertFalse(frame.intersects(composer))
        XCTAssertTrue(OverlayPlacement.fits(frame, in: screen))
    }

    /// 复现用户场景：宿主把光标框报在输入行之外（ZCode 报高一整行），
    /// 只避光标框的旧规则会把卡片落在输入行上——现在两者取并集，都让开。
    func testFollowingCardClearsTheFieldWhenTheHostReportsTheCaretOutsideIt() throws {
        let caret = NSRect(x: 302, y: composer.maxY + 20, width: 1, height: 20)
        let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: NSSize(width: 590, height: 150),
            anchor: InputAnchor(caretFrame: caret, fieldFrame: composer), screens: [screen]))
        XCTAssertFalse(frame.intersects(composer))
        XCTAssertFalse(frame.intersects(caret))
        XCTAssertGreaterThanOrEqual(frame.minY, caret.maxY + 6)
    }

    /// 回归（用户 2026-10-13 Obsidian 诊断报告，几何归一化到合成屏
    /// (0,0,1920,1080)：x 减 1512、y 加 63；决策 D-30）：Chromium
    /// contenteditable 宿主把整个编辑器报成输入框（799×961，89% 屏高），
    /// 整块当障碍时上下放不下、左右候选落到焦点窗口外的其它窗口上，兜底
    /// 反而贴到屏幕顶缘。高度 ≥ 0.6 屏高的矩形不再当障碍后，宽/窄两种卡
    /// 都应贴光标行上方（maxY == caret.minY - gap）落下。
    func testFollowingCardHugsTheCaretWhenTheFieldFillsTheScreen() throws {
        let display = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let field = NSRect(x: 515, y: 0, width: 799, height: 961)
        let caret = NSRect(x: 552, y: 218, width: 1, height: 22)
        for size in [NSSize(width: 600, height: 135), NSSize(width: 340, height: 114)] {
            let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
                anchor: InputAnchor(caretFrame: caret, fieldFrame: field), screens: [display]))
            XCTAssertEqual(frame.maxY, caret.minY - OverlayPlacement.gap, "卡片应贴光标行上方（卡 \(size)）")
            XCTAssertFalse(frame.intersects(caret), "卡片不得压住光标（卡 \(size)）")
            XCTAssertTrue(display.contains(frame), "卡片应整张落在屏内（卡 \(size)）")
        }
    }

    /// 输入框在屏幕中间时，先试离光标更近的那一侧。
    func testFollowingCardPicksTheSideNearerTheCaret() throws {
        let field = NSRect(x: 300, y: 250, width: 800, height: 300)
        let size = NSSize(width: 400, height: 180)
        let lastLine = NSRect(x: 320, y: 265, width: 1, height: 20)
        let firstLine = NSRect(x: 320, y: 515, width: 1, height: 20)
        let below = try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
            anchor: InputAnchor(caretFrame: lastLine, fieldFrame: field), screens: [screen]))
        XCTAssertEqual(below.maxY, field.minY - 6)
        XCTAssertFalse(below.intersects(field))
        let above = try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
            anchor: InputAnchor(caretFrame: firstLine, fieldFrame: field), screens: [screen]))
        XCTAssertEqual(above.minY, field.maxY + 6)
        XCTAssertFalse(above.intersects(field))
    }

    /// 高度未到整屏级（≤0.6 屏高）的输入框仍是避让障碍；上下都放不下整张
    /// 卡时，贴着光标行从侧面绕开。（高度 ≥0.6 屏高的屏幕级矩形已按 D-30
    /// 不再当障碍，由 testFollowingCardHugsTheCaretWhenTheFieldFillsTheScreen
    /// 覆盖。）
    func testFollowingCardSlidesBesideAFieldThatBlocksBothSides() throws {
        let field = NSRect(x: 400, y: 100, width: 500, height: 500)
        let caret = NSRect(x: 600, y: 420, width: 1, height: 20)
        let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: NSSize(width: 460, height: 300),
            anchor: InputAnchor(caretFrame: caret, fieldFrame: field), screens: [screen]))
        XCTAssertEqual(frame.minX, field.maxX + 6)
        XCTAssertFalse(frame.intersects(field))
        XCTAssertTrue(frame.minY <= caret.midY && caret.midY <= frame.maxY)
        XCTAssertTrue(OverlayPlacement.fits(frame, in: screen))
    }

    /// 没有干净位置时：卡片仍整张在屏内、不压光标行，并挑压住输入框更少的
    /// 那条屏幕边（此处上缘重叠更小）。
    func testFollowingCardKeepsTheScreenAndCaretWhenNothingFitsClear() throws {
        let field = NSRect(x: 100, y: 100, width: 1240, height: 500)
        let caret = NSRect(x: 700, y: 400, width: 1, height: 20)
        let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: NSSize(width: 460, height: 300),
            anchor: InputAnchor(caretFrame: caret, fieldFrame: field), screens: [screen]))
        XCTAssertTrue(OverlayPlacement.fits(frame, in: screen))
        XCTAssertFalse(frame.intersects(caret))
        XCTAssertEqual(frame.maxY, screen.maxY - OverlayPlacement.margin)
        XCTAssertLessThanOrEqual(
            OverlayPlacement.overlap(frame, field),
            OverlayPlacement.overlap(NSRect(x: frame.minX, y: screen.minY + OverlayPlacement.margin,
                width: frame.width, height: frame.height), field))
    }

    /// 另一台显示器上的输入框不影响本屏定位（沿用光标框规则）。
    func testFollowingCardIgnoresAFieldOnAnotherDisplay() throws {
        let other = NSRect(x: -1000, y: 0, width: 1000, height: 800)
        let caret = NSRect(x: 200, y: 400, width: 1, height: 20)
        let field = NSRect(x: -800, y: 100, width: 600, height: 400)
        let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: NSSize(width: 400, height: 180),
            anchor: InputAnchor(caretFrame: caret, fieldFrame: field), screens: [screen, other]))
        XCTAssertEqual(frame.maxY, caret.minY - 6)
        XCTAssertTrue(OverlayPlacement.fits(frame, in: screen))
    }

    /// 副屏（负原点）上按同样规则避让。
    func testFollowingCardClearsTheFieldOnANegativeOriginDisplay() throws {
        let secondary = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        let field = NSRect(x: -1300, y: 20, width: 980, height: 105)
        let caret = NSRect(x: -1000, y: 45, width: 1, height: 20)
        let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: NSSize(width: 590, height: 150),
            anchor: InputAnchor(caretFrame: caret, fieldFrame: field), screens: [screen, secondary]))
        XCTAssertEqual(frame.minY, field.maxY + 6)
        XCTAssertFalse(frame.intersects(field))
        XCTAssertTrue(secondary.contains(frame))
    }

    /// 光标在输入框中线附近轻移不翻面：翻面位移是整块输入框加卡片的高度，
    /// 「离光标更近的一侧」需要拉开半个死区才认。
    func testFollowingCardKeepsItsSideAcrossTheFieldsMidline() throws {
        let field = NSRect(x: 300, y: 250, width: 800, height: 300)
        let size = NSSize(width: 400, height: 180)
        func place(_ caretY: CGFloat) throws -> NSRect {
            try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
                anchor: InputAnchor(caretFrame: NSRect(x: 320, y: caretY, width: 1, height: 20),
                    fieldFrame: field), screens: [screen]))
        }
        // 两侧等距处（光标底 y=390）与死区内的偏移都留在下方
        XCTAssertEqual(try place(385).maxY, field.minY - 6)
        XCTAssertEqual(try place(393).maxY, field.minY - 6)
        // 明显越过中线才翻到上方
        XCTAssertEqual(try place(420).minY, field.maxY + 6)
    }

    /// 固定卡也能从侧面绕开输入框（输入框纵向吃满、上下都放不下时）。
    func testPlacementSlidesSidewaysAroundAnObstacle() throws {
        let bounds = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let obstacle = NSRect(x: 400, y: 100, width: 500, height: 675)
        let frame = NSRect(x: 520, y: 48, width: 400, height: 120)
        let cleared = try XCTUnwrap(OverlayPlacement.cleared(frame, of: obstacle, in: bounds))
        XCTAssertFalse(cleared.intersects(obstacle))
        XCTAssertEqual(cleared.minX, obstacle.maxX + OverlayPlacement.gap)
        XCTAssertEqual(cleared.minY, frame.minY)
    }

    // MARK: - 固定槽位（协调器）

    /// 复现用户场景（跟随关闭 + 底部输入框）：卡片不得压在输入行上，
    /// 输入框挪走后自动回到配置的底部居中位置。
    func testFixedCardShiftsClearOfTheInputBoxAndReturnsWhenItMovesAway() throws {
        let coordinator = makeCoordinator()
        let bounds = try XCTUnwrap(NSScreen.main).visibleFrame
        coordinator.edgeDistance = 48
        coordinator.position = .bottomCenter
        let session = InputSessionID(pid: 1)
        let field = NSRect(x: bounds.midX - 450, y: bounds.minY + 24, width: 900, height: 110)
        let caret = NSRect(x: field.minX + 300, y: field.minY + 40, width: 1, height: 20)
        coordinator.showRealtime(source: "中文。", translation: "English.", key: "live", session: session,
            anchor: InputAnchor(caretFrame: caret, fieldFrame: field))
        coordinator.followCaret = false

        let shifted = try XCTUnwrap(coordinator.visiblePanelFrames.first)
        XCTAssertFalse(shifted.intersects(field), "固定卡必须让开输入框")
        XCTAssertEqual(shifted.minY, field.maxY + OverlayPlacement.gap, accuracy: 1)
        XCTAssertEqual(shifted.midX, bounds.midX, accuracy: 1, "水平仍在配置的底部居中槽位")
        XCTAssertTrue(bounds.contains(shifted))

        coordinator.updateAnchor(InputAnchor(caretFrame: caret, fieldFrame: nil), session: session)
        let restored = try XCTUnwrap(coordinator.visiblePanelFrames.first)
        XCTAssertEqual(restored.minY, bounds.minY + 48, accuracy: 1, "输入框不再挡路时回到配置位置")
    }

    /// 跟随卡的端到端回归：卡片整张避开输入框与光标。
    func testFollowingCardDoesNotCoverTheReportedInputBox() throws {
        let coordinator = makeCoordinator()
        let bounds = try XCTUnwrap(NSScreen.main).visibleFrame
        let field = NSRect(x: bounds.minX + 100, y: bounds.minY + 20, width: bounds.width - 400, height: 105)
        let caret = NSRect(x: bounds.minX + 500, y: field.maxY + 20, width: 1, height: 20)
        coordinator.showRealtime(source: "现在设计的现在设计的。", translation: "Designed now.", key: "live",
            session: InputSessionID(pid: 1), anchor: InputAnchor(caretFrame: caret, fieldFrame: field))
        let frame = try XCTUnwrap(coordinator.visiblePanelFrames.first)
        XCTAssertFalse(frame.intersects(field), "跟随卡不得压住输入框")
        XCTAssertFalse(frame.intersects(caret), "跟随卡不得压住光标")
        XCTAssertTrue(bounds.contains(frame))
    }

    /// 固定卡整组让开输入框：没有锚点的剪贴板卡随组一起走，不会被挪开的
    /// 实时卡反压住（各自挪位就会互相压住）；输入框移开后整组回到槽位。
    func testFixedCardsShiftAsAGroupAndKeepTheirStackOffsets() throws {
        let coordinator = makeCoordinator()
        let bounds = try XCTUnwrap(NSScreen.main).visibleFrame
        coordinator.edgeDistance = 48
        coordinator.position = .bottomCenter
        let session = InputSessionID(pid: 1)
        coordinator.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: nil)
        coordinator.followCaret = false
        coordinator.show("Clipboard", key: "clip", on: NSScreen.main, origin: .clipboard)
        let base = coordinator.visiblePanelFrames
        XCTAssertEqual(base.count, 2)
        XCTAssertGreaterThan(base[1].minY, base[0].minY, "堆叠顺序：后加的卡在上")

        let field = NSRect(x: bounds.midX - 450, y: bounds.minY + 24, width: 900, height: 110)
        coordinator.updateAnchor(
            InputAnchor(caretFrame: NSRect(x: field.minX + 300, y: field.minY + 40, width: 1, height: 20),
                fieldFrame: field), session: session)
        let shifted = coordinator.visiblePanelFrames
        XCTAssertEqual(shifted.count, 2)
        for frame in shifted {
            XCTAssertFalse(frame.intersects(field), "整组都要让开输入框：\(frame)")
            XCTAssertTrue(bounds.contains(frame))
        }
        XCTAssertEqual(shifted[0].minY - base[0].minY, shifted[1].minY - base[1].minY, accuracy: 1,
            "整组同向位移")
        XCTAssertEqual(shifted[1].minY - shifted[0].minY, base[1].minY - base[0].minY, accuracy: 1,
            "堆叠间距不变")
        XCTAssertGreaterThan(shifted[1].minY, shifted[0].minY, "堆叠顺序不变")

        coordinator.updateAnchor(InputAnchor(caretFrame: nil, fieldFrame: nil), session: session)
        let restored = coordinator.visiblePanelFrames
        XCTAssertEqual(restored[0].minY, base[0].minY, accuracy: 1, "输入框移开后整组回到配置槽位")
        XCTAssertEqual(restored[1].minY, base[1].minY, accuracy: 1)
    }

    /// 输入框只与堆叠卡之间的空隙相交、没压住任何一张卡时，整组不得平白挪位。
    func testFixedCardsIgnoreAFieldThatOnlyCrossesTheStackGap() throws {
        let coordinator = makeCoordinator()
        let bounds = try XCTUnwrap(NSScreen.main).visibleFrame
        coordinator.edgeDistance = 48
        coordinator.position = .bottomCenter
        let session = InputSessionID(pid: 1)
        coordinator.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: nil)
        coordinator.followCaret = false
        let longText = Array(repeating: "这是一段用来把剪贴板卡片撑高的长文本。", count: 8).joined(separator: "\n")
        coordinator.show(longText, key: "clip", on: NSScreen.main, origin: .clipboard)
        let base = coordinator.visiblePanelFrames
        XCTAssertEqual(base.count, 2)
        let gap = NSRect(x: base[0].minX + 40, y: base[0].maxY + 2, width: 200,
            height: max(1, base[1].minY - base[0].maxY - 4))
        try XCTSkipUnless(gap.height >= 1 && !base[0].intersects(gap) && !base[1].intersects(gap),
            "该字体度量下堆叠卡之间没有空隙，跳过")
        coordinator.updateAnchor(InputAnchor(caretFrame: nil, fieldFrame: gap), session: session)
        XCTAssertEqual(coordinator.visiblePanelFrames, base, "空隙相交不得挪动整组")
    }

    /// 屏幕没有干净位置时固定卡留在原槽位：不为了避让跑到屏幕外，也不换角。
    func testFixedCardStaysAtItsSlotWhenNoClearSpotExists() throws {
        let coordinator = makeCoordinator()
        let bounds = try XCTUnwrap(NSScreen.main).visibleFrame
        coordinator.edgeDistance = 48
        coordinator.position = .bottomCenter
        let session = InputSessionID(pid: 1)
        // 输入框从底部 40pt 起铺到屏幕顶缘：上下左右都放不下整张卡
        let field = NSRect(x: bounds.minX, y: bounds.minY + 40, width: bounds.width,
            height: bounds.height - 48)
        coordinator.showRealtime(source: "中文。", translation: "English.", key: "live", session: session,
            anchor: InputAnchor(caretFrame: NSRect(x: bounds.midX, y: field.midY, width: 1, height: 20),
                fieldFrame: field))
        coordinator.followCaret = false
        let frame = try XCTUnwrap(coordinator.visiblePanelFrames.first)
        XCTAssertEqual(frame.minY, bounds.minY + 48, accuracy: 1, "没有干净位置时留在配置槽位")
        XCTAssertTrue(bounds.contains(frame))
    }

    private func makeCoordinator() -> OverlayCoordinator {
        let coordinator = OverlayCoordinator()
        coordinator.neverHide = true
        coordinator.cursorOverCard = { _ in false }
        addTeardownBlock { coordinator.hide() }
        return coordinator
    }
}
