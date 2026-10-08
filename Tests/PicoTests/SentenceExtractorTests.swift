import XCTest

@testable import Pico

final class SentenceExtractorTests: XCTestCase {
    func testExtractsSentenceAtCursor() {
        let text = "第一句话。第二句话正在输入。第三句"
        let cursor = (text as NSString).range(of: "第二句话正在输入").location + 3
        let result = SentenceExtractor().extract(
            from: TextSnapshot(
                pid: 1, bundleIdentifier: nil, text: text, selectedRange: NSRange(location: cursor, length: 0)))
        XCTAssertEqual(result, "第二句话正在输入。")
    }
    func testRepeatedSentenceKeepsTheActualUTF16Occurrence() throws {
        let text = "相同句子。相同句子。"
        let extractor = SentenceExtractor()
        let first = try XCTUnwrap(extractor.extractSentence(from: TextSnapshot(pid: 1, bundleIdentifier: nil,
            text: text, selectedRange: NSRange(location: 2, length: 0))))
        let second = try XCTUnwrap(extractor.extractSentence(from: TextSnapshot(pid: 1, bundleIdentifier: nil,
            text: text, selectedRange: NSRange(location: 7, length: 0))))
        XCTAssertEqual(first.text, second.text)
        XCTAssertEqual(first.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(second.range, NSRange(location: 5, length: 5))
    }

    func testUTF16CaretInsideEmojiAndCombiningGraphemesNeverSplitsThem() throws {
        let text = "前句。👨‍👩‍👧‍👦e\u{301}中文😀。后句。"
        let expected = "👨‍👩‍👧‍👦e\u{301}中文😀。"
        let range = (text as NSString).range(of: expected)
        for offset in range.location..<NSMaxRange(range) {
            let snapshot = TextSnapshot(pid: 1, bundleIdentifier: nil, text: text,
                selectedRange: NSRange(location: offset, length: 0))
            let sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: snapshot))
            // The exact boundary after the previous punctuation belongs to the
            // completed previous sentence; interior UTF-16 offsets stay whole.
            if offset == range.location { continue }
            XCTAssertEqual(sentence.text, expected, "UTF16 offset \(offset)")
            XCTAssertEqual(sentence.range, range)
            XCTAssertEqual((text as NSString).substring(with: sentence.range), sentence.text)
        }
    }

    func testTrimmingAndLengthCapAdjustTheReturnedUTF16Range() throws {
        let text = "先前。  中文😀测试。  "
        let snapshot = TextSnapshot(pid: 1, bundleIdentifier: nil, text: text,
            selectedRange: NSRange(location: 9, length: 0))
        let sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: snapshot, maxLength: 4))
        XCTAssertEqual(sentence.text, "😀测试。")
        XCTAssertEqual(sentence.range, (text as NSString).range(of: "😀测试。"))
        XCTAssertEqual((text as NSString).substring(with: sentence.range), sentence.text)
        XCTAssertNil(SentenceExtractor().extractSentence(from: snapshot, maxLength: 0))
    }

    func testMiddleEditingReturnsTheCurrentSentenceRatherThanTrailingText() throws {
        let text = "第一句。中间修改后的句子。最后一句。"
        let snapshot = TextSnapshot(pid: 1, bundleIdentifier: nil, text: text,
            selectedRange: NSRange(location: 8, length: 0))
        let sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: snapshot))
        XCTAssertEqual(sentence.text, "中间修改后的句子。")
        XCTAssertEqual(sentence.range, (text as NSString).range(of: sentence.text))
    }

    func testRangeBasedReplacementTargetsFirstRepeatedSentenceAndRejectsStaleRange() throws {
        let text = "重复😀。重复😀。"
        let source = "重复😀。"
        let first = NSRange(location: 0, length: source.utf16.count)
        let plan = try XCTUnwrap(FieldReplacement.evaluate(fieldText: text, source: source, range: first))
        XCTAssertEqual(plan.prefix, "")
        XCTAssertEqual(plan.suffix, source)
        XCTAssertEqual(plan.range, first)
        let applied = FieldReplacement.replacing(fieldText: text, sourceWithTerminator: source,
            translation: "First.", range: plan.range)
        XCTAssertEqual(applied?.text, "First." + source)
        XCTAssertEqual(applied?.caretUTF16Offset, "First.".utf16.count)
        XCTAssertFalse(FocusedFieldReplacer.replace(currentText: "修改了。" + source,
            sourceWithTerminator: source, translation: "Wrong.", range: first) { _, _ in
                XCTFail("A stale range must never write to the later matching sentence")
                return true
            })
        XCTAssertNil(FieldReplacement.replacing(fieldText: text, sourceWithTerminator: source,
            translation: "Wrong.", range: NSRange(location: NSNotFound, length: 1)))
    }

    func testChineseDetector() {
        XCTAssertTrue(ChineseTextDetector().containsChinese("Hello，我今天有点忙"))
        XCTAssertFalse(ChineseTextDetector().containsChinese("Hello"))
    }

    func testConfiguredLanguageDetectorSupportsRequestedDirections() {
        let detector = LanguageTextDetector()
        XCTAssertTrue(detector.contains("Hello world", language: .english))
        XCTAssertTrue(detector.contains("Привет, мир", language: .russian))
        XCTAssertTrue(detector.contains("こんにちは", language: .japanese))
        XCTAssertFalse(detector.contains("123 !?", language: .english))
    }
    func testFallbackUsesLastSegmentWithoutCursor() {
        let snapshot = TextSnapshot(pid: 1, bundleIdentifier: nil, text: "第一句。正在输入的内容", selectedRange: nil)
        XCTAssertEqual(SentenceExtractor().extract(from: snapshot), "正在输入的内容")
    }
    func testPunctuationStillIncludesCompletedSentence() {
        let text = "我今天会晚一点。"
        let snapshot = TextSnapshot(
            pid: 1, bundleIdentifier: nil, text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(SentenceExtractor().extract(from: snapshot), "我今天会晚一点。")
    }

    func testExtractIncludesQuestionMark() {
        let text = "你今天来吗？"
        let snapshot = TextSnapshot(
            pid: 1, bundleIdentifier: nil, text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(SentenceExtractor().extract(from: snapshot), "你今天来吗？")
    }

    func testExtractOmitsNewlineTerminator() {
        let text = "我今天会晚一点\n"
        let snapshot = TextSnapshot(
            pid: 1, bundleIdentifier: nil, text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(SentenceExtractor().extract(from: snapshot), "我今天会晚一点")
        XCTAssertTrue(SentenceExtractor().isComplete(snapshot))
    }

    func testExtractMatchesCaretBeforeAndAfterTerminators() {
        let extractor = SentenceExtractor()
        let body = "我今天会晚一点"
        for mark in ["。", ".", "？", "?", "！", "!", "；", ";"] {
            let text = body + mark
            let after = (text as NSString).length
            let before = after - (mark as NSString).length
            let afterSnap = TextSnapshot(
                pid: 1, bundleIdentifier: nil, text: text,
                selectedRange: NSRange(location: after, length: 0))
            let beforeSnap = TextSnapshot(
                pid: 1, bundleIdentifier: nil, text: text,
                selectedRange: NSRange(location: before, length: 0))
            let expected = mark == "\n" ? body : text
            XCTAssertEqual(extractor.extract(from: afterSnap), expected, "after \(mark)")
            XCTAssertEqual(extractor.extract(from: beforeSnap), expected, "before \(mark)")
            XCTAssertEqual(
                extractor.extract(from: afterSnap), extractor.extract(from: beforeSnap), "before/after \(mark)")
        }
    }

    func testExtractFallsBackToPreviousSentenceWhenCaretSliceHasNoChinese() {
        let text = "我今天会晚一点。\u{200B}"
        let snapshot = TextSnapshot(
            pid: 1, bundleIdentifier: nil, text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(SentenceExtractor().extract(from: snapshot), "我今天会晚一点。")
    }

    func testCompleteSentenceRequiresTerminatorAtCaret() {
        let extractor = SentenceExtractor()
        let incomplete = "我今天会晚一点"
        XCTAssertFalse(
            extractor.isComplete(
                TextSnapshot(
                    pid: 1, bundleIdentifier: nil, text: incomplete,
                    selectedRange: NSRange(location: (incomplete as NSString).length, length: 0))))
        for terminator in ["。", "？", "！", ".", "?", "!", "；", ";", "\n"] {
            let complete = "我今天会晚一点" + terminator
            XCTAssertTrue(
                extractor.isComplete(
                    TextSnapshot(
                        pid: 1, bundleIdentifier: nil, text: complete,
                        selectedRange: NSRange(location: (complete as NSString).length, length: 0))),
                "expected complete after \(terminator)")
        }
    }

    func testReplaceRangeCoversSourceAndTerminatorWithPrefix() {
        let field = "昨天很好。我今天会晚一点。"
        let plan = FieldReplacement.evaluate(fieldText: field, source: "我今天会晚一点")
        XCTAssertEqual(plan?.prefix, "昨天很好。")
        XCTAssertEqual(plan?.sourceWithTerminator, "我今天会晚一点。")
        XCTAssertEqual(plan?.suffix, "")
        let applied = plan?.applying(translation: "I will be a bit late today.")
        XCTAssertEqual(applied?.text, "昨天很好。I will be a bit late today.")
        XCTAssertEqual(applied?.caretUTF16Offset, ("昨天很好。I will be a bit late today." as NSString).length)
    }

    func testEvaluateDoesNotAppendSecondTerminatorWhenSourceAlreadyHasPunctuation() {
        let field = "昨天很好。我今天会晚一点。"
        let plan = FieldReplacement.evaluate(fieldText: field, source: "我今天会晚一点。")
        XCTAssertEqual(plan?.prefix, "昨天很好。")
        XCTAssertEqual(plan?.sourceWithTerminator, "我今天会晚一点。")
        XCTAssertEqual(plan?.suffix, "")
    }

    func testEvaluateKeepsIncompleteFragmentWithoutTerminator() {
        let field = "昨天很好。我今天会晚一点"
        let plan = FieldReplacement.evaluate(fieldText: field, source: "我今天会晚一点")
        XCTAssertEqual(plan?.prefix, "昨天很好。")
        XCTAssertEqual(plan?.sourceWithTerminator, "我今天会晚一点")
        XCTAssertEqual(plan?.suffix, "")
    }

    func testReplacingSkipsStaleSourceAndFailedWrite() {
        let field = "昨天很好。我今天会晚一点。"
        XCTAssertNil(
            FieldReplacement.replacing(
                fieldText: field, sourceWithTerminator: "别的句子。", translation: "Other."))
        XCTAssertTrue(
            FocusedFieldReplacer.replace(
                currentText: field, sourceWithTerminator: "我今天会晚一点。", translation: "Late."
            ) { text, caret in
                XCTAssertEqual(text, "昨天很好。Late.")
                XCTAssertEqual(caret, ("昨天很好。Late." as NSString).length)
                return true
            })
        XCTAssertFalse(
            FocusedFieldReplacer.replace(
                currentText: "changed", sourceWithTerminator: "我今天会晚一点。", translation: "Late."
            ) { _, _ in
                XCTFail("write should not run for stale source")
                return true
            })
        XCTAssertFalse(
            FocusedFieldReplacer.replace(
                currentText: field, sourceWithTerminator: "我今天会晚一点。", translation: "Late."
            ) { _, _ in false })
    }
}

final class TranslationClipboardTests: XCTestCase {
    func testCopyWritesReadyTextAndSkipsEmpty() {
        let pasteboard = FakePasteboard()
        pasteboard.contents = "keep-me"
        XCTAssertFalse(TranslationClipboard.copy(nil, using: pasteboard))
        XCTAssertFalse(TranslationClipboard.copy("", using: pasteboard))
        XCTAssertEqual(pasteboard.contents, "keep-me")
        XCTAssertTrue(TranslationClipboard.copy("Hello there.", using: pasteboard))
        XCTAssertEqual(pasteboard.contents, "Hello there.")
    }
}

private final class FakePasteboard: PasteboardWriting {
    var contents: String?
    func writeString(_ text: String) { contents = text }
}

private actor DelayedEngine: TranslationEngine {
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        try await Task.sleep(for: .milliseconds(text == "旧" ? 120 : 10))
        return text == "旧" ? "old" : "new"
    }
}

final class TranslationCoordinatorTests: XCTestCase {
    func testNewGenerationWinsWhenOldRequestReturnsLate() async {
        let coordinator = TranslationCoordinator(engine: DelayedEngine())
        async let old = coordinator.translate("旧")
        try? await Task.sleep(for: .milliseconds(20))
        let new = await coordinator.translate("新")
        let oldResult = await old
        XCTAssertEqual(new, "new")
        XCTAssertNil(oldResult)
    }

    func testMissingResourcesReturnsNoTranslation() async {
        let coordinator = TranslationCoordinator(engine: MissingResourceEngine())
        let result = await coordinator.translate("你好")
        XCTAssertNil(result)
    }

    func testDirectionChangesArePassedToEngine() async {
        let coordinator = TranslationCoordinator(engine: DirectionEchoEngine())
        await coordinator.setDirection(from: .english, to: .russian)
        let translated = await coordinator.translate("Hello")
        XCTAssertEqual(translated, "en-ru:Hello")
    }
}

private struct DirectionEchoEngine: TranslationEngine {
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        "\(from.rawValue)-\(to.rawValue):\(text)"
    }
}

private struct MissingResourceEngine: TranslationEngine {
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        throw TranslationTestError.missingResources
    }
}

private enum TranslationTestError: Error {
    case missingResources
}
