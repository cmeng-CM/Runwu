import XCTest

@testable import Pico

@MainActor
final class CalibrationStateTests: XCTestCase {
    private func snapshot(_ text: String, composing: Bool = false) -> TextSnapshot {
        TextSnapshot(
            pid: 1, bundleIdentifier: "test.input", text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            isComposing: composing)
    }

    func testUpdateKeepsLatestNonComposingSentence() {
        let state = CalibrationState()
        let session = InputSessionID(pid: 1)
        XCTAssertTrue(state.update(snapshot("Hello there."), session: session))
        XCTAssertEqual(state.sentence?.text, "Hello there.")
        XCTAssertFalse(state.update(snapshot("Hello there."), session: session))  // no change
        XCTAssertTrue(state.update(snapshot("Hello again."), session: session))
        XCTAssertEqual(state.sentence?.text, "Hello again.")
    }

    func testComposingSnapshotClearsSentence() {
        let state = CalibrationState()
        let session = InputSessionID(pid: 1)
        XCTAssertTrue(state.update(snapshot("Hello there."), session: session))
        XCTAssertTrue(state.update(snapshot("拼音候选", composing: true), session: session))
        XCTAssertNil(state.sentence)
    }

    func testSessionChangeClearsAnchorAndBumpsRevision() {
        let state = CalibrationState()
        let first = InputSessionID(pid: 1), second = InputSessionID(pid: 2)
        state.update(snapshot("Hello there."), session: first)
        let anchor = InputAnchor(caretFrame: .zero, fieldFrame: .zero)
        XCTAssertTrue(state.updateAnchor(anchor, session: first))
        XCTAssertTrue(state.update(snapshot("Hello there."), session: second))
        XCTAssertNil(state.anchor)  // cleared on session change, mirroring RealtimeTranslationState
        XCTAssertFalse(state.updateAnchor(anchor, session: first))  // stale session rejected
    }

    func testBeginRequestIssuesTokenAcceptedUntilStateChanges() {
        let state = CalibrationState()
        let session = InputSessionID(pid: 1)
        state.update(snapshot("Hello there."), session: session)
        let key = state.sentence!.key(in: session)
        guard let request = state.beginRequest(text: "Hello there.", key: key, session: session) else {
            return XCTFail("expected a request token")
        }
        XCTAssertTrue(state.accepts(request))
        state.update(snapshot("Different sentence."), session: session)
        XCTAssertFalse(state.accepts(request))  // late result must be dropped
    }

    func testBeginRequestRejectsStaleTextOrKey() {
        let state = CalibrationState()
        let session = InputSessionID(pid: 1)
        state.update(snapshot("Hello there."), session: session)
        XCTAssertNil(state.beginRequest(text: "Stale text", key: "k", session: session))
        XCTAssertNil(
            state.beginRequest(text: "Hello there.", key: "wrong-key", session: session))
        XCTAssertNil(state.beginRequest(text: "Hello there.", key: "k", session: InputSessionID(pid: 2)))
    }

    func testInvalidateDropsSentenceAndRejectsInFlightRequest() {
        let state = CalibrationState()
        let session = InputSessionID(pid: 1)
        state.update(snapshot("Hello there."), session: session)
        let key = state.sentence!.key(in: session)
        let request = state.beginRequest(text: "Hello there.", key: key, session: session)
        XCTAssertNotNil(request)
        state.invalidate()
        XCTAssertNil(state.sentence)
        XCTAssertFalse(state.accepts(request!))
        state.invalidate(clearAnchor: true)
        XCTAssertNil(state.session)
    }
}
