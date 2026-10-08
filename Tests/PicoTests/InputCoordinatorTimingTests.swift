import XCTest

@testable import Pico

@MainActor
final class InputCoordinatorTimingTests: XCTestCase {
    func testComposingTextIsSuppressedInEveryTimingModeAndShortcut() async {
        for timing in [TranslationTiming.pause, .completeSentence, .shortcut] {
            let input = InputCoordinator()
            input.timing = timing
            input.delayMilliseconds = 20
            let session = InputSessionID(pid: 1)
            let composing = TextSnapshot(pid: 1, bundleIdentifier: "test.input", text: "拼音候选。",
                selectedRange: NSRange(location: 5, length: 0), isComposing: true)
            var received: [String] = []
            input.onSentence = { text, _, _, _, _ in received.append(text) }
            input.handle(composing, session: session, screen: nil)
            input.translateNow(composing, session: session, screen: nil)
            try? await Task.sleep(for: .milliseconds(70))
            XCTAssertTrue(received.isEmpty)
            input.translateNow(snapshot("拼音候选。"), session: session, screen: nil)
            XCTAssertEqual(received, ["拼音候选。"])
        }
    }

    func testSameSentenceInDifferentSessionIsNotDeduplicated() {
        let input = InputCoordinator()
        input.timing = .completeSentence
        var sessions: [InputSessionID] = []
        input.onSentence = { _, _, session, _, _ in sessions.append(session) }
        let first = InputSessionID(pid: 1), second = InputSessionID(pid: 1)
        input.handle(snapshot("两个输入框同样内容。"), session: first, screen: nil)
        input.handle(snapshot("两个输入框同样内容。"), session: second, screen: nil)
        XCTAssertEqual(sessions, [first, second])
    }

    func testNewExclusionSuppressesQueuedTranslationAndShortcut() async {
        let input = InputCoordinator()
        input.delayMilliseconds = 20
        let session = InputSessionID(pid: 1)
        var received: [String] = []
        input.onSentence = { text, _, _, _, _ in received.append(text) }
        input.handle(snapshot("待翻译内容。"), session: session, screen: nil)
        input.excludedBundleIDs = ["test.input"]
        try? await Task.sleep(for: .milliseconds(70))
        input.translateNow(snapshot("待翻译内容。"), session: session, screen: nil)
        XCTAssertTrue(received.isEmpty)
    }
    private func snapshot(_ text: String) -> TextSnapshot {
        TextSnapshot(
            pid: 1, bundleIdentifier: "test.input", text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }

    func testPauseModeTranslatesIncompleteAfterDelay() async {
        let input = InputCoordinator()
        input.timing = .pause
        input.delayMilliseconds = 20
        let session = InputSessionID(pid: 1)
        var received: String?
        input.onSentence = { text, _, _, _, _ in received = text }
        input.handle(snapshot("我今天会晚一点"), session: session, screen: nil)
        XCTAssertNil(received)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(received, "我今天会晚一点")
    }

    func testCompleteSentenceIgnoresIncompleteFragment() async {
        let input = InputCoordinator()
        input.timing = .completeSentence
        input.delayMilliseconds = 20
        let session = InputSessionID(pid: 1)
        var received: String?
        input.onSentence = { text, _, _, _, _ in received = text }
        input.handle(snapshot("我今天会晚一点"), session: session, screen: nil)
        XCTAssertNil(received)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(received)
    }

    func testCompleteSentenceTranslatesPunctuatedSentenceImmediately() {
        let input = InputCoordinator()
        input.timing = .completeSentence
        input.delayMilliseconds = 200
        let session = InputSessionID(pid: 1)
        var received: String?
        input.onSentence = { text, _, _, _, _ in received = text }
        input.handle(snapshot("我今天会晚一点。"), session: session, screen: nil)
        XCTAssertEqual(received, "我今天会晚一点。")
    }

    func testShortcutModeDoesNotTranslateFromTyping() async {
        let input = InputCoordinator()
        input.timing = .shortcut
        input.delayMilliseconds = 20
        let session = InputSessionID(pid: 1)
        var received: String?
        input.onSentence = { text, _, _, _, _ in received = text }
        input.handle(snapshot("我今天会晚一点。"), session: session, screen: nil)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(received)
        input.translateNow(snapshot("我今天会晚一点。"), session: session, screen: nil)
        XCTAssertEqual(received, "我今天会晚一点。")
    }

    func testShortcutTranslateNowUsesLastGoodWhenLiveTextIsEmpty() {
        let live = TextSnapshot(
            pid: 1, bundleIdentifier: "test.input", text: "",
            selectedRange: NSRange(location: 0, length: 0))
        let recovered = ShortcutSnapshotRecovery.resolve(live: live, lastGoodText: "我今天会晚一点。")
        XCTAssertEqual(SentenceExtractor().extract(from: recovered), "我今天会晚一点。")

        let input = InputCoordinator()
        input.timing = .shortcut
        let session = InputSessionID(pid: 1)
        var received: String?
        input.onSentence = { text, _, _, _, _ in received = text }
        input.translateNow(live, session: session, screen: nil)
        XCTAssertNil(received)
        input.translateNow(recovered, session: session, screen: nil)
        XCTAssertEqual(received, "我今天会晚一点。")
    }
}
