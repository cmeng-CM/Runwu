import AppKit
import ApplicationServices
import XCTest
@testable import Pico

/// Chromium contenteditable（实测 Obsidian）宿主里 `AXSelectedTextRange` 的偏移按
/// 宿主自身文本计数，`AXValue` 则在块边界多出换行/标记字符——两套坐标系。取句前
/// 必须用宿主锚窗把偏移映射回 AXValue 的 UTF-16 索引；锚窗对不上、复核不过或读取
/// 失败时不出卡（宁可不翻，不翻错行）。宿主不提供该读取能力时沿用报告偏移。
@MainActor
final class CaretOffsetMappingTests: XCTestCase {
    /// 回归（先红）：宿主文本在 AXValue 的块边界后多出一个换行，且改写点早于锚窗。
    /// 直接按宿主偏移索引 AXValue 会把当前句取到光标上方一行；映射后取句 = 光标所在行。
    func testBlockBoundaryValueMapsToTheCaretLine() throws {
        let fixture = AXFixture()
        let first = "第一行内容。\n"
        let padding = String(repeating: "垫片行内容需要足够长。\n", count: 3)
        let second = "第二行内容。\n"
        let caretLine = "第三行光标所在"
        fixture.hostText = first + padding + second + caretLine
        fixture.text = first + "\n" + padding + second + caretLine
        let caret = ((first + padding + second) as NSString).length + 1
        fixture.selected = NSRange(location: caret, length: 0)
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        let captured = try XCTUnwrap(snapshot, "可映射的漂移宿主应发出快照")
        XCTAssertEqual(captured.selectedRange?.location, caret + 1,
            "selectedRange 必须是 AXValue 空间的 UTF-16 索引")
        XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, caretLine,
            "取句必须落在光标所在行，而不是上方行")
    }

    /// 锚窗与 AXValue 的实义字符不同（去空白归一化后仍找不到；纯空白形态差异已按
    /// D-07 容忍，见 testWhitespaceVariantAnchorStillMaps）→ 不出卡，也不把报告偏移当索引。
    func testUnmatchableAnchorEmitsNoSnapshot() {
        let fixture = AXFixture()
        fixture.hostText = "早餐吃了吗。\n今天要写周记内容。"
        fixture.text = "早餐吃了吗。\n\n今天要写周报内容。"
        fixture.selected = NSRange(location: (fixture.hostText! as NSString).length, length: 0)
        let monitor = fixture.monitor()
        var snapshots = 0, anchors = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        monitor.onAnchorChanged = { _, _ in anchors += 1 }
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(snapshots, 0, "锚串在 AXValue 里找不到时必须不出卡")
        XCTAssertGreaterThanOrEqual(fixture.anchorReads, 1, "锚窗读取发生过")
        XCTAssertGreaterThan(anchors, 0, "锚点几何仍发布，浮窗跟随不因取句失败停摆")
    }

    /// 宿主返回的锚窗比请求短、候选位置落在宿主偏移之前（违反漂移方向）→ 拒绝，不出卡。
    func testCandidateBeforeHostOffsetIsRejected() {
        let fixture = AXFixture()
        fixture.text = "abcdefghwxyz"
        fixture.hostText = "abcdefgh"
        fixture.selected = NSRange(location: 12, length: 0)
        let monitor = fixture.monitor()
        var snapshots = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(snapshots, 0, "候选倒退（mapped < 宿主偏移）时必须不出卡")
        XCTAssertGreaterThanOrEqual(fixture.anchorReads, 1)
        // 纯函数契约：倒退即拒绝，不倒退才命中。
        XCTAssertNil(CaretOffsetMapping.mappedIndex(anchor: "ABCDEFGH", hostOffset: 12, in: "ABCDEFGHijkl" as NSString))
        XCTAssertNil(CaretOffsetMapping.mappedIndex(anchor: "ABCDEFGH", hostOffset: 10, in: "ABCDEFGHABCDEFGH" as NSString))
        XCTAssertEqual(CaretOffsetMapping.mappedIndex(anchor: "ABCDEFGH", hostOffset: 8, in: "ABCDEFGHijkl" as NSString), 8)
    }

    /// 宿主在光标处改写了实义字符（宿主「啊」/ AXValue「。」）→ 局部甄别不过，不出卡。
    /// 空白/零宽形态的差异不算不一致（按 D-07 跳过甄别，见
    /// testPostCaretWhitespaceSkipsCorroboration）。
    func testPostCaretCharacterMismatchIsRejected() {
        let fixture = AXFixture()
        fixture.hostText = "供应商进度沟通。啊后续内容"
        fixture.text = "供应商进度沟通。。\n后续内容"
        fixture.selected = NSRange(location: 8, length: 0)
        let monitor = fixture.monitor()
        var snapshots = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(snapshots, 0, "光标后一位字符不一致时必须不出卡")
        XCTAssertGreaterThanOrEqual(fixture.anchorReads, 1)
    }

    /// 光标在宿主文本末尾时 `AXStringForRange(r, 1)` 天然取不到后一位字符（越界/错误）：
    /// 复核②不可比只跳过局部甄别，仍按映射出卡——防「笔记末尾永不翻译」的回归。
    func testPostCaretReadUnavailableStillMaps() throws {
        let first = "第一行内容。\n"
        let padding = String(repeating: "垫片行内容需要足够长。\n", count: 3)
        let second = "第二行内容。\n"
        let caretLine = "第三行光标所在"

        // 阶段一：光标在宿主文本末尾（越界，夹具按 hostText 切片返回空串）。
        let fixture = AXFixture()
        fixture.hostText = first + padding + second + caretLine
        fixture.text = first + "\n" + padding + second + caretLine
        let caret = (fixture.hostText! as NSString).length
        fixture.selected = NSRange(location: caret, length: 0)
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        let captured = try XCTUnwrap(snapshot, "文末光标取不到后一位字符时必须照常出卡")
        XCTAssertEqual(captured.selectedRange?.location, caret + 1,
            "后一位字符读取不可得只跳过复核②，映射照常")
        XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, caretLine)
        XCTAssertEqual(fixture.requestedStringRanges.last, NSRange(location: caret, length: 1),
            "后一位字符读取发生过（越界返回空，不可比）")

        // 阶段二：宿主对后一位字符返回显式错误（光标不在末尾）——同样只跳过甄别。
        let mid = AXFixture()
        mid.hostText = first + padding + second + caretLine
        mid.text = first + "\n" + padding + second + caretLine
        let midCaret = ((first + padding + second) as NSString).length + 1
        mid.selected = NSRange(location: midCaret, length: 0)
        var access = mid.access()
        let inner = access.parameterizedResult
        var postReads = 0
        access.parameterizedResult = { element, key, parameter in
            if key == kAXStringForRangeParameterizedAttribute as String,
                let range = AXFixture.parseRange(parameter), range.length == 1 {
                postReads += 1
                return .unavailable(.cannotComplete)
            }
            return inner(element, key, parameter)
        }
        let midMonitor = AccessibilityMonitor(access: access, currentApplication: {
            MonitoredApplication(pid: mid.pid, bundleID: mid.bundleID)
        }, screenFrames: { mid.screens })
        var midSnapshot: TextSnapshot?
        midMonitor.onSnapshot = { value, _, _ in midSnapshot = value }
        midMonitor.readSnapshot()
        XCTAssertEqual(postReads, 1, "后一位字符读取被替换为显式错误（复核②确实不可比）")
        let midCaptured = try XCTUnwrap(midSnapshot, "后一位字符读取出错时不出卡会让文末/出错后永不翻译")
        XCTAssertEqual(midCaptured.selectedRange?.location, midCaret + 1)
        XCTAssertEqual(SentenceExtractor().extractSentence(from: midCaptured)?.text, caretLine)
    }

    /// 命中长度取实际命中（`found.length`），不用锚自身的 UTF-16 长度：
    /// `NSString.range(of:)` 默认按规范等价匹配，锚与文本归一化形式不同时长度会不同。
    func testCanonicallyEquivalentAnchorUsesFoundLength() throws {
        // 文本（AXValue 侧）用 NFC 的 é（1 个 UTF-16 单元）；锚窗（宿主侧）用 NFD 的
        // e + U+0301（2 个单元）：同一段文本两种归一化形式的长度不同。
        let text = "前缀caf\u{00E9}abcdef尾巴" as NSString
        let anchor = "cafe\u{0301}abcdef"
        XCTAssertEqual(anchor.utf16.count, 11, "锚 11 个单元、命中 10 个单元")
        XCTAssertEqual(("前缀caf\u{00E9}abcdef" as NSString).length, 12)
        let mapped = try XCTUnwrap(CaretOffsetMapping.mappedIndex(anchor: anchor, hostOffset: 12, in: text))
        XCTAssertEqual(mapped, 12, "命中起点 2 + 命中长度 10，而不是命中起点 2 + 锚长度 11")
        XCTAssertEqual(text.substring(with: NSRange(location: mapped, length: 1)), "尾")
    }

    /// `AXValue` 读不到但锚窗可读：不能因映射失败吞掉快捷键的 `lastGoodText` 恢复
    /// （force/组合下的空文本路径沿用旧行为）。
    func testUnreadableValueWithReadableAnchorStillRecoversLastGoodText() throws {
        let fixture = AXFixture()
        fixture.hostText = fixture.text
        fixture.selected = NSRange(location: 8, length: 0)
        let monitor = fixture.monitor()
        let sample = try XCTUnwrap(monitor.snapshotNow())
        XCTAssertEqual(sample.snapshot.text, "我今天会晚一点。")
        fixture.text = nil
        let recovered = try XCTUnwrap(monitor.snapshotNow(), "空文本恢复路径不得被映射失败吞掉")
        XCTAssertEqual(recovered.snapshot.text, "我今天会晚一点。")
        XCTAssertEqual(recovered.snapshot.selectedRange?.location, ("我今天会晚一点。" as NSString).length)
    }

    /// 原生宿主（宿主文本 == AXValue）：映射等于报告偏移，行为不变。
    func testNativeHostAnchorHitsItsOwnOffset() throws {
        let fixture = AXFixture()
        fixture.text = "我今天会晚一点，明天再联系你。"
        fixture.hostText = fixture.text
        fixture.selected = NSRange(location: 10, length: 0)
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        let captured = try XCTUnwrap(snapshot)
        XCTAssertEqual(captured.selectedRange?.location, 10, "同源文本映射到自身偏移")
        XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, "我今天会晚一点，明天再联系你。")
        XCTAssertGreaterThan(fixture.anchorReads, 0, "原生宿主同样走锚窗校验")
    }

    /// 锚窗长度上界：文档开头不足 K=24 时从 0 截断读取 (0, r)；r < 8 时不做映射。
    func testAnchorWindowLengthBoundAtDocumentStart() throws {
        let fixture = AXFixture()
        fixture.text = "一二三四五六七八九十甲乙丙"
        fixture.hostText = fixture.text
        fixture.selected = NSRange(location: 12, length: 0)
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        XCTAssertEqual(try XCTUnwrap(snapshot).selectedRange?.location, 12)
        XCTAssertEqual(fixture.requestedStringRanges.first, NSRange(location: 0, length: 12),
            "文档开头锚窗从 0 截断，不假设前方还有文本")
        XCTAssertEqual(fixture.requestedStringRanges.last, NSRange(location: 12, length: 1),
            "光标后一位字符按 (r, 1) 读取")

        let short = AXFixture()
        short.hostText = short.text
        short.selected = NSRange(location: 5, length: 0)
        let shortMonitor = short.monitor()
        var shortSnapshot: TextSnapshot?
        shortMonitor.onSnapshot = { value, _, _ in shortSnapshot = value }
        shortMonitor.readSnapshot()
        XCTAssertEqual(try XCTUnwrap(shortSnapshot).selectedRange?.location, 5, "r < 8 不映射：沿用报告偏移")
        XCTAssertEqual(short.anchorReads, 0, "短锚不读宿主文本")
        XCTAssertEqual(short.requestedStringRanges, [])
    }

    /// 真机形态（2026-10-13 探针 axprobe5，Obsidian 前台，r=312）：宿主锚窗用
    /// `ZWSP+\t` 表示块边界，`AXValue` 同位置是换行（并保留零宽标记）——逐字锚必然
    /// 找不到，逐字匹配版本 fail-closed 到完全不出卡。去空白归一化后命中：
    /// 映射到 AXValue 索引、取句 = 光标所在行。
    func testWhitespaceVariantAnchorStillMaps() throws {
        let first = "第一行内容。\n"
        let padding = String(repeating: "垫片行内容需要足够长。\n", count: 3)
        let hostBoundary = "\u{200B}\t"      // 宿主块边界：零宽空格 + 制表
        let valueBoundary = "\n\u{200B}\n"  // AXValue 块边界：换行 + 零宽标记 + 换行
        let caretLine = "第三行光标所在。"
        let fixture = AXFixture()
        fixture.hostText = first + padding + hostBoundary + caretLine
        fixture.text = first + "\n" + padding + valueBoundary + caretLine
        let caret = ((first + padding + hostBoundary + "第三行光标所") as NSString).length
        fixture.selected = NSRange(location: caret, length: 0)
        // AXValue 空间里光标后的第一个字符：锚的末位实义字符「所」的右边界，
        // 恰好也是宿主光标后一位「在」在 AXValue 里的索引。
        let mapped = ((first + "\n" + padding + valueBoundary + "第三行光标所") as NSString).length
        let hostAnchor = (fixture.hostText! as NSString).substring(
            with: NSRange(location: caret - CaretOffsetMapping.windowLength,
                length: CaretOffsetMapping.windowLength))
        XCTAssertEqual(CaretOffsetMapping.mappedIndex(anchor: hostAnchor, hostOffset: caret,
            in: fixture.text! as NSString), mapped, "逐字找不到时按去空白归一化命中")
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        let captured = try XCTUnwrap(snapshot, "空白形态差异的锚窗必须仍能映射（旧实现此处不出卡）")
        XCTAssertEqual(captured.selectedRange?.location, mapped, "selectedRange 是 AXValue 空间的 UTF-16 索引")
        XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, caretLine,
            "取句必须落在光标所在行")
    }

    /// 行尾后的连续空行不属于实义结尾的锚窗：还原必须停在最后命中字之后，
    /// 不能跳到下一段首字，否则监控快照会取成下一段。
    func testWhitespaceVariantLineEndBeforeBlankLinesMapsToCaretLine() throws {
        let sample = whitespaceVariantLine(suffix: String(repeating: "\n", count: 6) + "下一段内容")
        let captured = try captureSnapshot(from: sample.fixture)
        XCTAssertEqual(captured.selectedRange, NSRange(location: NSMaxRange(sample.valueRange), length: 0),
            "实义锚尾保留当前行的 UTF-16 插入边界，不跨过六个换行")
        let sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: captured))
        XCTAssertEqual(sentence.text, "第三行光标所在")
        XCTAssertEqual(sentence.range, sample.valueRange)
        XCTAssertEqual(sample.fixture.requestedStringRanges.count, 2, "仍只读锚窗和后一位字符")
    }

    /// 归一化命中位于文末时，下一项是原文长度哨兵；末尾空行仍不能把光标拖到哨兵。
    func testWhitespaceVariantDocumentEndWithTrailingBlankLinesMapsToCaretLine() throws {
        let sample = whitespaceVariantLine(suffix: String(repeating: "\n", count: 6))
        let captured = try captureSnapshot(from: sample.fixture)
        XCTAssertEqual(captured.selectedRange?.location, NSMaxRange(sample.valueRange))
        XCTAssertLessThan(try XCTUnwrap(captured.selectedRange).location, captured.text.utf16.count)
        let sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: captured),
            "文末六个空行不能把文字行尾取成空句")
        XCTAssertEqual(sentence.text, "第三行光标所在")
        XCTAssertEqual(sentence.range, sample.valueRange)
    }

    /// 同一份宿主文本从行尾前移一字：映射也只前移一个 UTF-16 单元，取句保持当前行。
    func testWhitespaceVariantMiddleStillMapsToCaretLine() throws {
        let sample = whitespaceVariantLine(suffix: String(repeating: "\n", count: 6) + "下一段内容")
        let fixture = sample.fixture, monitor = fixture.monitor()
        var snapshots: [TextSnapshot] = []
        monitor.onSnapshot = { value, _, _ in snapshots.append(value) }
        monitor.readSnapshot()
        fixture.selected.location -= 1
        monitor.readSnapshot()
        XCTAssertEqual(snapshots.count, 2)
        let atEnd = try XCTUnwrap(snapshots.first), beforeEnd = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(atEnd.selectedRange?.location, NSMaxRange(sample.valueRange))
        XCTAssertEqual(beforeEnd.selectedRange?.location, NSMaxRange(sample.valueRange) - 1)
        XCTAssertEqual(try XCTUnwrap(atEnd.selectedRange).location - XCTUnwrap(beforeEnd.selectedRange).location, 1)
        for snapshot in snapshots {
            XCTAssertEqual(SentenceExtractor().extractSentence(from: snapshot)?.text, "第三行光标所在")
        }
    }

    /// 最后命中单元可能是 emoji 的低代理项或组合附加符；+1 必须还原整个字素之后。
    func testWhitespaceVariantUnicodeLineEndMapsToUTF16Boundary() throws {
        for ending in ["😀", "👩🏽‍💻", "e\u{0301}"] {
            let caretLine = "第三行光标所在" + ending
            let sample = whitespaceVariantLine(caretLine: caretLine,
                suffix: String(repeating: "\n", count: 6) + "下一段内容")
            let captured = try captureSnapshot(from: sample.fixture)
            let mapped = try XCTUnwrap(captured.selectedRange).location
            XCTAssertEqual(mapped, NSMaxRange(sample.valueRange), ending)
            XCTAssertEqual((captured.text as NSString).character(at: mapped), 0x000A)
            let sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: captured))
            XCTAssertEqual(sentence.text, caretLine)
            XCTAssertEqual(sentence.range, sample.valueRange, "取句范围包含完整 emoji/组合字符")
        }
    }

    /// 文末没有尾随空白时，最后实义单元的右边界与原文长度哨兵相等。
    func testWhitespaceVariantDocumentEndWithoutTrailingBlankLinesUsesSentinel() throws {
        let sample = whitespaceVariantLine(suffix: "")
        let captured = try captureSnapshot(from: sample.fixture)
        XCTAssertEqual(captured.selectedRange?.location, captured.text.utf16.count)
        XCTAssertEqual(captured.selectedRange?.location, NSMaxRange(sample.valueRange))
        XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, "第三行光标所在")
        let (_, originals) = CaretOffsetMapping.whitespaceNormalized(captured.text as NSString)
        XCTAssertEqual(originals.last, captured.text.utf16.count)
    }

    /// 锚尾本身是去除字符时仍使用下一保留字符/文末哨兵，不推断空白块归属。
    func testWhitespaceVariantTrailingAnchorWhitespaceKeepsExistingBoundary() throws {
        for trailing in [" ", "\t", "\n", "\u{200B}", "\u{FEFF}"] {
            for following in ["下一段内容", ""] {
                let blankLines = String(repeating: "\n", count: 6)
                let sample = whitespaceVariantLine(caretLine: "第三行光标所在" + trailing,
                    suffix: blankLines + following)
                let captured = try captureSnapshot(from: sample.fixture)
                let expected = NSMaxRange(sample.valueRange) + blankLines.utf16.count
                XCTAssertEqual(captured.selectedRange?.location, expected,
                    "锚尾 \(trailing.debugDescription) 沿用下一保留字符或哨兵")
            }
        }
    }

    /// 修正后的实义结尾在报告偏移之前时仍拒绝；不能借后面的空白或第二个命中绕过守卫。
    func testWhitespaceVariantContentEndRejectsCandidateBeforeHostOffset() {
        let fixture = AXFixture()
        fixture.hostText = "a b c d e f g h"
        fixture.text = "abcdefgh" + String(repeating: "\n", count: 12) + "abcdefgh"
        fixture.selected = NSRange(location: 16, length: 0)
        XCTAssertNil(CaretOffsetMapping.mappedIndex(anchor: fixture.hostText!, hostOffset: 16,
            in: fixture.text! as NSString), "首个命中的正确边界 8 < 16，即使后面还有命中也拒绝")
        let monitor = fixture.monitor()
        var snapshots = 0, anchors = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        monitor.onAnchorChanged = { _, _ in anchors += 1 }
        monitor.readSnapshot()
        XCTAssertEqual(snapshots, 0)
        XCTAssertGreaterThan(anchors, 0, "映射失败仍发布几何")
        XCTAssertEqual(fixture.requestedStringRanges.count, 2, "拒绝不增加 AX 查询")
    }

    /// 用相同块边界差异强制走归一化；期待范围从 AXValue 前缀独立计算。
    private func whitespaceVariantLine(caretLine: String = "第三行光标所在", suffix: String)
        -> (fixture: AXFixture, valueRange: NSRange) {
        let first = "第一行内容。\n"
        let padding = String(repeating: "垫片行内容需要足够长。\n", count: 3)
        let hostPrefix = first + padding + "\u{200B}\t"
        let valuePrefix = first + "\n" + padding + "\n\u{200B}\n"
        let fixture = AXFixture()
        fixture.hostText = hostPrefix + caretLine + suffix
        fixture.text = valuePrefix + caretLine + suffix
        fixture.selected = NSRange(location: (hostPrefix + caretLine).utf16.count, length: 0)
        return (fixture, NSRange(location: valuePrefix.utf16.count, length: caretLine.utf16.count))
    }

    private func captureSnapshot(from fixture: AXFixture) throws -> TextSnapshot {
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        return try XCTUnwrap(snapshot, "可映射的空白形态差异应发出快照")
    }

    /// 归一化后锚不足 8 个非空白单元（形态几乎全是零宽/制表标记）→ 不做归一化匹配，
    /// 不出卡；方向守卫与纯函数契约同样拒绝。
    func testWhitespaceOnlyMatchIsRejected() {
        let fixture = AXFixture()
        let anchorsOnly = "\u{200B}\t\u{200B}\t\u{200B}\t1. \u{200B}\t\u{200B}\t"
        fixture.hostText = anchorsOnly
        fixture.text = "一二三四五六七八九十1. "
        fixture.selected = NSRange(location: (anchorsOnly as NSString).length, length: 0)
        let monitor = fixture.monitor()
        var snapshots = 0, anchors = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        monitor.onAnchorChanged = { _, _ in anchors += 1 }
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow(), "归一化后不足 8 个非空白单元不翻")
        XCTAssertEqual(snapshots, 0)
        XCTAssertGreaterThanOrEqual(fixture.anchorReads, 1, "锚窗读取发生过")
        XCTAssertGreaterThan(anchors, 0, "锚点几何仍发布")
        // 纯函数契约：归一化锚「1.」只有 2 个单元 < 8——即使它能在 AXValue 里命中也不匹配
        // （无门槛时会在「…九十1. 」处命中并从该处向后返回候选索引）。
        XCTAssertNil(CaretOffsetMapping.mappedIndex(
            anchor: anchorsOnly, hostOffset: 10,
            in: "一二三四五六七八九十1. " as NSString), "归一化后不足 8 个非空白单元不做归一化匹配")
    }

    /// 后一位字符甄别的空白容忍（D-07）：宿主在 r 后一位是空白/零宽形态时与
    /// `AXValue[mapped]` 不可比——跳过比较、仍按映射出卡；只有两侧都是实义字符
    /// 才要求相等（不一致的实义字符仍拒绝，见 testPostCaretCharacterMismatchIsRejected）。
    func testPostCaretWhitespaceSkipsCorroboration() throws {
        for boundary in ["\u{200B}", "\u{FEFF}", "\t", "\n", " "] {
            let fixture = AXFixture()
            fixture.hostText = "供应商进度沟通。" + boundary + "后续内容"
            fixture.text = "供应商进度沟通。啊后续内容"
            fixture.selected = NSRange(location: 8, length: 0)
            let monitor = fixture.monitor()
            var snapshot: TextSnapshot?
            monitor.onSnapshot = { value, _, _ in snapshot = value }
            monitor.readSnapshot()
            let captured = try XCTUnwrap(snapshot, "后一位字符为空白（\(boundary.debugDescription)）时不得关闭采样")
            XCTAssertEqual(captured.selectedRange?.location, 8, "映射照常（逐字命中）")
            XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, "供应商进度沟通。")
        }
    }

    /// 甄别两侧共用的空白容忍（D-07，审查探针 P2 形态）：`AXValue[mapped]` 处是空白
    /// 而宿主 `(r, 1)` 是实义字符——同属两套坐标系对空白的表示法差异，跳过比较、
    /// 仍按映射出卡（修复前被判「不一致」拒绝、不出卡）。
    func testValueWhitespaceAtMappedIndexSkipsCorroboration() throws {
        let fixture = AXFixture()
        fixture.hostText = "供应商进度沟通。啊后续内容"
        fixture.text = "供应商进度沟通。\n啊后续内容"
        fixture.selected = NSRange(location: 8, length: 0)
        let monitor = fixture.monitor()
        var snapshot: TextSnapshot?
        monitor.onSnapshot = { value, _, _ in snapshot = value }
        monitor.readSnapshot()
        let captured = try XCTUnwrap(snapshot, "AXValue[mapped] 为空白时不得因此关闭采样")
        XCTAssertEqual(captured.selectedRange?.location, 8, "映射照常（逐字命中）")
        XCTAssertEqual(SentenceExtractor().extractSentence(from: captured)?.text, "供应商进度沟通。")
    }
}
