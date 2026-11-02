import XCTest

@testable import Pico

@MainActor
final class CalibrationRouteTests: XCTestCase {
    private func decide(
        _ text: String, truncated: Bool = false, source: Language = .chinese, enabled: Bool = true
    ) -> Route {
        RouteDecision.decide(
            text: text, isTruncated: truncated, sourceLanguage: source, calibrationEnabled: enabled)
    }

    // MARK: - Route matrix (design 4.1)

    func testChineseSourceMixedHanSentenceRoutesToTranslation() {
        XCTAssertEqual(decide("你好 world"), .translate)
        XCTAssertEqual(decide("你好 world", enabled: false), .translate)
    }

    func testChineseSourceLatinSentenceRoutesToCalibrationOnlyWhenEnabled() {
        XCTAssertEqual(decide("I have went to school yesterday."), .calibrate)
        XCTAssertEqual(decide("I have went to school yesterday.", enabled: false), .none)
    }

    func testTruncatedLatinSentenceNeverCalibrates() {
        XCTAssertEqual(decide(String(repeating: "a", count: 301), truncated: true), .none)
    }

    func testLatinSourceKeepsTranslationAndNeverCalibrates() {
        XCTAssertEqual(decide("hello world", source: .english), .translate)
        XCTAssertEqual(decide("bonjour", source: .french), .translate)
    }

    func testNonLatinNonChineseSourcesKeepExistingBehavior() {
        XCTAssertEqual(decide("こんにちは", source: .japanese), .translate)
        XCTAssertEqual(decide("hello", source: .japanese), .none)
        XCTAssertEqual(decide("안녕", source: .korean), .translate)
        XCTAssertEqual(decide("Привет", source: .russian), .translate)
    }

    func testNonLanguageContentRoutesToNone() {
        XCTAssertEqual(decide("123 😄"), .none)
        XCTAssertEqual(decide("Привет"), .none)
        XCTAssertEqual(decide("", enabled: true), .none)
    }

    // MARK: - Truncation flag (design D-C14, 300 characters)

    private func snapshot(_ text: String) -> TextSnapshot {
        TextSnapshot(
            pid: 1, bundleIdentifier: "test.input", text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }

    func testLongFragmentIsMarkedTruncatedAndTrimmedTo300Characters() {
        let long = String(repeating: "word ", count: 80) + "end"
        let extracted = SentenceExtractor().extractSentence(from: snapshot(long))
        XCTAssertNotNil(extracted)
        XCTAssertTrue(extracted!.isTruncated)
        XCTAssertEqual(extracted!.text.count, 300)
        XCTAssertEqual(String((long as NSString).substring(from: (long as NSString).length - 300)), extracted!.text)
    }

    func testShortSentenceIsNotMarkedTruncated() {
        let extracted = SentenceExtractor().extractSentence(from: snapshot("I have went to school."))
        XCTAssertNotNil(extracted)
        XCTAssertFalse(extracted!.isTruncated)
    }

    // MARK: - Coordinator emission (route in onSentence, onRouteChanged before debounce)

    func testEnglishSentenceEmitsCalibrationRouteAfterDebounceAndRouteChangeImmediately() async {
        let input = InputCoordinator()
        input.timing = .pause
        input.delayMilliseconds = 20
        input.calibrationEnabled = true
        let session = InputSessionID(pid: 1)
        var routes: [Route] = []
        var routeChanges: [Route] = []
        input.onSentence = { _, _, _, _, _, route in routes.append(route) }
        input.onRouteChanged = { route, _ in routeChanges.append(route) }
        input.handle(snapshot("I have went to school yesterday."), session: session, screen: nil)
        XCTAssertEqual(routeChanges, [.calibrate])  // fired before the debounce elapsed
        XCTAssertNil(routes.first)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(routes, [.calibrate])
    }

    func testDisabledSwitchDropsEnglishSentenceAndSignalsNoneRoute() async {
        let input = InputCoordinator()
        input.timing = .pause
        input.delayMilliseconds = 20
        input.calibrationEnabled = false
        let session = InputSessionID(pid: 1)
        var emitted = 0
        var routeChanges: [Route] = []
        input.onSentence = { _, _, _, _, _, _ in emitted += 1 }
        input.onRouteChanged = { route, _ in routeChanges.append(route) }
        input.handle(snapshot("hello world"), session: session, screen: nil)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(emitted, 0)
        XCTAssertEqual(routeChanges, [.none])
    }

    func testRouteChangeFiresOnEveryLanguageSwitchWithoutDebounce() {
        let input = InputCoordinator()
        input.timing = .shortcut
        input.calibrationEnabled = true
        let session = InputSessionID(pid: 1)
        var routeChanges: [Route] = []
        input.onRouteChanged = { route, _ in routeChanges.append(route) }
        input.handle(snapshot("你好，世界。"), session: session, screen: nil)
        input.handle(snapshot("Hello there."), session: session, screen: nil)
        input.handle(snapshot("你好，世界。"), session: session, screen: nil)
        XCTAssertEqual(routeChanges, [.translate, .calibrate, .translate])
    }

    func testSameRouteOnRepeatDoesNotRefire() {
        let input = InputCoordinator()
        input.timing = .shortcut
        input.calibrationEnabled = true
        let session = InputSessionID(pid: 1)
        var routeChanges: [Route] = []
        input.onRouteChanged = { route, _ in routeChanges.append(route) }
        input.handle(snapshot("Hello there."), session: session, screen: nil)
        input.handle(snapshot("Hello there!"), session: session, screen: nil)
        XCTAssertEqual(routeChanges, [.calibrate])
    }

    func testSetSourceLanguageWithSameLanguageDoesNotReset() {
        let input = InputCoordinator()
        var emptied = 0
        input.onEmpty = { emptied += 1 }
        input.setSourceLanguage(.chinese)  // already the default
        XCTAssertEqual(emptied, 0)
        input.setSourceLanguage(.english)
        XCTAssertEqual(emptied, 1)
    }
}
