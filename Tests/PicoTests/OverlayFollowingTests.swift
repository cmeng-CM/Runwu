import AppKit
import SwiftUI
import XCTest
@testable import Pico

@MainActor
final class OverlayFollowingTests: XCTestCase {
    private var overlays: [OverlayCoordinator] = []
    private var applications: [AppState] = []
    private var suites: [(UserDefaults, String)] = []
    private var directories: [URL] = []

    override func setUp() async throws { _ = NSApplication.shared }
    override func tearDown() async throws {
        overlays.forEach { $0.hide() }
        applications.forEach { $0.input.reset(); $0.overlay.hide() }
        applications.removeAll()
        for (defaults, name) in suites { defaults.removePersistentDomain(forName: name) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    func testPlacementPrefersBelowThenAboveAndClampsOnDifferentDisplays() throws {
        let screens = [NSRect(x: 0, y: 0, width: 1000, height: 800),
            NSRect(x: -1000, y: 0, width: 1000, height: 800), NSRect(x: 0, y: 800, width: 1000, height: 800)]
        let size = NSSize(width: 400, height: 180)
        for caret in [NSRect(x: 200, y: 400, width: 1, height: 20),
            NSRect(x: -200, y: 400, width: 1, height: 20), NSRect(x: 200, y: 1200, width: 1, height: 20)] {
            let frame = try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
                anchor: InputAnchor(caretFrame: caret, fieldFrame: nil), screens: screens))
            XCTAssertEqual(frame.maxY, caret.minY - 6)
            XCTAssertTrue(screens.contains { $0.contains(frame) })
        }
        let bottom = NSRect(x: 900, y: 10, width: 1, height: 20)
        let above = try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
            anchor: InputAnchor(caretFrame: bottom, fieldFrame: nil), screens: screens))
        XCTAssertEqual(above.minY, bottom.maxY + 6)
        XCTAssertTrue(screens[0].contains(above))
        let field = NSRect(x: 100, y: 300, width: 700, height: 200)
        let fallback = try XCTUnwrap(OverlayFollowingLayout.frame(size: size,
            anchor: InputAnchor(caretFrame: nil, fieldFrame: field), screens: screens))
        XCTAssertEqual(fallback.maxY, field.minY - 6)
        let invalidCaret = InputAnchor(caretFrame: NSRect(x: CGFloat.nan, y: 100, width: 1, height: 20), fieldFrame: field)
        XCTAssertEqual(OverlayFollowingLayout.frame(size: size, anchor: invalidCaret, screens: screens), fallback)
        XCTAssertNil(OverlayFollowingLayout.frame(size: size,
            anchor: InputAnchor(caretFrame: nil, fieldFrame: nil), screens: screens))
    }

    func testGeometryUpdatesKeepContentIdentityAndOriginalHideDeadline() async throws {
        let overlay = makeOverlay()
        overlay.neverHide = false; overlay.hideAfter = 0.35
        let session = InputSessionID(pid: 1)
        overlay.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: anchor())
        let view = try XCTUnwrap(overlay.panelContentViews.first)
        let id = try XCTUnwrap(overlay.shownEntryIDs.first)
        let before = try XCTUnwrap(overlay.visiblePanelFrames.first)
        try await Task.sleep(for: .milliseconds(200))
        overlay.updateAnchor(anchor(dx: 80), session: session)
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        XCTAssertTrue(overlay.panelContentViews.first === view)
        XCTAssertNotEqual(overlay.visiblePanelFrames.first?.origin, before.origin)
        try await Task.sleep(for: .milliseconds(80))
        overlay.updateAnchor(anchor(dx: 100), session: session)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(overlay.shownEntryIDs.isEmpty, "Geometry must not renew the original timer")
        overlay.updateAnchor(anchor(), session: session)
        XCTAssertTrue(overlay.shownEntryIDs.isEmpty, "Auto-hidden cards cannot be revived by geometry")
    }

    func testMissingAnchorTemporarilyHidesAndRestoresWithoutRebuilding() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: anchor())
        let id = try XCTUnwrap(overlay.shownEntryIDs.first), view = try XCTUnwrap(overlay.panelContentViews.first)
        overlay.updateAnchor(InputAnchor(caretFrame: nil, fieldFrame: nil), session: session)
        XCTAssertTrue(overlay.shownEntryIDs.isEmpty)
        overlay.updateAnchor(anchor(dx: 30), session: session)
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        XCTAssertTrue(overlay.panelContentViews.first === view)
        let host = try XCTUnwrap(view as? NSHostingView<TranslationOverlayView>)
        host.rootView.onClose()
        overlay.updateAnchor(anchor(), session: session)
        XCTAssertTrue(overlay.shownEntryIDs.isEmpty, "Explicitly closed cards cannot return")
    }

    func testMissingAnchorKeepsHideDeadlineAndExpiredCardCannotReturn() async throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.neverHide = false; overlay.hideAfter = 0.12
        overlay.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: anchor())
        overlay.updateAnchor(InputAnchor(caretFrame: nil, fieldFrame: nil), session: session)
        try await Task.sleep(for: .milliseconds(250))
        overlay.updateAnchor(anchor(), session: session)
        XCTAssertTrue(overlay.shownEntryIDs.isEmpty)
        XCTAssertTrue(overlay.cardContents.isEmpty)
    }

    func testUnpinnedHistoricalLiveCardDoesNotRejoinCurrentFollowing() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.showRealtime(source: "旧。", translation: "Old.", key: "same", session: session, anchor: anchor())
        let old = try XCTUnwrap(overlay.shownEntryIDs.first), frame = try XCTUnwrap(overlay.visiblePanelFrames.first)
        overlay.togglePin(of: old)
        overlay.showRealtime(source: "新。", translation: "New.", key: "same", session: session, anchor: anchor(dx: 90))
        overlay.togglePin(of: old)
        overlay.updateAnchor(anchor(dx: 120), session: session)
        XCTAssertEqual(overlay.visiblePanelFrames.first, frame)
        XCTAssertEqual(overlay.cardContents.first, OverlayCardContent(source: "旧。", translation: "Old."))
    }

    func testPinnedSameKeyKeepsContentAndFrameWhileNewLiveCardFollows() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.showRealtime(source: "旧中文。", translation: "Old.", key: "same", session: session, anchor: anchor())
        let pinned = try XCTUnwrap(overlay.shownEntryIDs.first), frame = try XCTUnwrap(overlay.visiblePanelFrames.first)
        overlay.togglePin(of: pinned)
        overlay.showRealtime(source: "新中文。", translation: "New.", key: "same", session: session, anchor: anchor(dx: 90))
        XCTAssertEqual(overlay.shownEntryIDs.count, 2)
        XCTAssertEqual(overlay.cardContents, [OverlayCardContent(source: "旧中文。", translation: "Old."),
            OverlayCardContent(source: "新中文。", translation: "New.")])
        overlay.updateAnchor(anchor(dx: 140), session: session)
        XCTAssertEqual(overlay.visiblePanelFrames.first, frame)
        overlay.hideRealtime()
        XCTAssertEqual(overlay.shownEntryIDs, [pinned])
        XCTAssertEqual(overlay.visiblePanelFrames, [frame])
    }

    func testUserPlacedRealtimeCardFreezesAndDoesNotSetClipboardDragAnchor() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.showRealtime(source: "旧。", translation: "Old.", key: "same", session: session, anchor: anchor())
        let panel = try XCTUnwrap(overlay.panelContentViews.first?.window)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 30, y: panel.frame.minY + 30))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        let frame = panel.frame, id = try XCTUnwrap(overlay.shownEntryIDs.first)
        overlay.updateAnchor(anchor(dx: 100), session: session)
        overlay.showRealtime(source: "新。", translation: "New.", key: "same", session: session, anchor: anchor(dx: 100))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(overlay.cardContents.first, OverlayCardContent(source: "旧。", translation: "Old."))
        overlay.hideRealtime()
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        overlay.show("Clipboard", key: "clip", on: NSScreen.main, origin: .clipboard)
        XCTAssertNotEqual(overlay.visiblePanelFrames.last?.origin, frame.origin)
    }

    func testFixedModeKeepsItsPositionAndDoesNotRequireAXAnchor() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.followCaret = false
        overlay.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: nil)
        let frame = try XCTUnwrap(overlay.visiblePanelFrames.first)
        overlay.updateAnchor(anchor(dx: 100), session: session)
        XCTAssertEqual(overlay.visiblePanelFrames, [frame])
    }

    func testFixedModeRestoresLiveCardAfterSharedClipboardDragAnchorAndAXLoss() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.show("Clipboard", key: "clip", on: NSScreen.main, origin: .clipboard)
        let panel = try XCTUnwrap(overlay.panelContentViews.first?.window)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 30, y: panel.frame.minY + 30))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: panel)
        overlay.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: nil)
        XCTAssertEqual(overlay.shownEntryIDs.count, 1)
        overlay.followCaret = false
        XCTAssertEqual(overlay.shownEntryIDs.count, 2, "Fixed drag-anchor branch must order the surviving card front")
    }

    func testClipboardWithoutAXSurvivesRealtimeAnchorLossAndFocusClear() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.show("Copied English", key: "clip", on: NSScreen.main, origin: .clipboard)
        let id = try XCTUnwrap(overlay.shownEntryIDs.first), frame = try XCTUnwrap(overlay.visiblePanelFrames.first)
        overlay.showRealtime(source: "中文。", translation: "English.", key: "live", session: session, anchor: anchor())
        overlay.updateAnchor(InputAnchor(caretFrame: nil, fieldFrame: nil), session: session)
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        XCTAssertEqual(overlay.visiblePanelFrames, [frame])
        overlay.hideRealtime()
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        overlay.showRealtime(source: "中文。", translation: "", key: "empty", session: session, anchor: nil)
        XCTAssertEqual(overlay.shownEntryIDs, [id], "An empty live result must not hide the clipboard card")
    }

    func testRepeatedSentenceMovementEmitsDifferentRealRangeKey() {
        let input = InputCoordinator()
        input.timing = .completeSentence
        let session = InputSessionID(pid: 1), text = "重复。重复。"
        var keys: [String] = []
        input.onSentence = { _, key, _, _, _ in keys.append(key) }
        input.handle(snapshot(text, caret: 3), session: session, screen: nil)
        input.handle(snapshot(text, caret: 6), session: session, screen: nil)
        XCTAssertEqual(keys, ["\(session.token.uuidString):0", "\(session.token.uuidString):3"])
    }

    func testRealtimeRevisionRejectsOldSentenceSessionAndRequestSynchronously() throws {
        let state = RealtimeTranslationState(), session = InputSessionID(pid: 1)
        let text = "旧中文。", sentence = try XCTUnwrap(SentenceExtractor().extractSentence(from: snapshot(text)))
        state.update(snapshot(text), session: session, language: .chinese)
        let first = try XCTUnwrap(state.beginRequest(text: text, key: sentence.key(in: session), session: session))
        let second = try XCTUnwrap(state.beginRequest(text: text, key: sentence.key(in: session), session: session))
        XCTAssertFalse(state.accepts(first)); XCTAssertTrue(state.accepts(second))
        state.update(snapshot("新中文。"), session: session, language: .chinese)
        XCTAssertFalse(state.accepts(second), "Invalidated before engine cancellation or debounce")
        state.invalidate(clearAnchor: true)
        XCTAssertFalse(state.accepts(second)); XCTAssertNil(state.session)
        XCTAssertTrue(state.updateAnchor(anchor(), session: InputSessionID(pid: 1)))
        XCTAssertFalse(state.updateAnchor(anchor(), session: session), "Old session anchors are ignored")
    }

    func testAppUsesLatestAnchorOnReturnAndGeometryDoesNotRetranslate() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine), session = InputSessionID(pid: 1)
        app.monitor.onAnchorChanged?(anchor(), session)
        app.monitor.onSnapshot?(snapshot("原文。"), session, NSScreen.main)
        try await waitUntil { await engine.count == 1 }
        app.monitor.onAnchorChanged?(anchor(dx: 100), session)
        await engine.complete(0, with: "Translated.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        let expected = try XCTUnwrap(OverlayFollowingLayout.frame(size: app.overlay.visiblePanelFrames[0].size,
            anchor: anchor(dx: 100), screens: NSScreen.screens.map(\.visibleFrame)))
        let actual = app.overlay.visiblePanelFrames[0]
        // AppKit aligns window frames to backing pixels (observed 0.5pt).
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(actual.size, expected.size)
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: "原文。", translation: "Translated.")])
        app.monitor.onAnchorChanged?(anchor(dx: 120), session)
        app.monitor.onSnapshot?(snapshot("原文。"), session, NSScreen.main)
        try await Task.sleep(for: .milliseconds(80))
        let count = await engine.count
        XCTAssertEqual(count, 1)
    }

    func testAppClearsOldEnglishImmediatelyAndRejectsOldResponseDuringDebounce() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine), session = InputSessionID(pid: 1)
        app.monitor.onAnchorChanged?(anchor(), session)
        app.monitor.onSnapshot?(snapshot("旧中文。"), session, NSScreen.main)
        try await waitUntil { await engine.count == 1 }
        app.monitor.onSnapshot?(snapshot("新中文。"), session, NSScreen.main)
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        await engine.complete(0, with: "Old English.")
        try await waitUntil { await engine.count == 2 }
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        await engine.complete(1, with: "New English.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: "新中文。", translation: "New English.")])
        app.monitor.onSnapshot?(snapshot("又修改。"), session, NSScreen.main)
        XCTAssertTrue(app.overlay.cardContents.isEmpty, "Ready English must disappear before the next debounce")
        try await waitUntil { await engine.count == 3 }
        await engine.complete(2, with: "Another.")
    }

    func testAppFocusAndEmptyInvalidatePendingRequestWithoutNewText() async throws {
        for empty in [false, true] {
            let engine = FollowingEngine(), app = makeApp(engine: engine), session = InputSessionID(pid: 1)
            app.monitor.onAnchorChanged?(anchor(), session)
            app.monitor.onSnapshot?(snapshot("旧中文。"), session, NSScreen.main)
            try await waitUntil { await engine.count == 1 }
            if empty { app.monitor.onSnapshot?(snapshot(""), session, NSScreen.main) }
            else { app.monitor.onFocusChanged?() }
            await engine.complete(0, with: "Late.")
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(app.overlay.cardContents.isEmpty)
        }
    }

    func testAppCompositionEndingWithIdenticalCommittedTextRestoresCachedPair() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine), session = InputSessionID(pid: 1)
        let text = "已译中文。"
        app.monitor.onAnchorChanged?(anchor(), session)
        app.monitor.onSnapshot?(snapshot(text), session, NSScreen.main)
        try await waitUntil { await engine.count == 1 }
        await engine.complete(0, with: "Translated.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        app.monitor.onSnapshot?(snapshot(text, composing: true), session, NSScreen.main)
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        app.monitor.onSnapshot?(snapshot(text), session, NSScreen.main)
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: text, translation: "Translated.")])
        let count = await engine.count
        XCTAssertEqual(count, 1, "Composition commit may hit cache, pure geometry must not issue requests")
    }

    func testAppReturningToTranslatedSentenceAfterUntranslatableOrIncompleteSentenceRestoresCache() async throws {
        for other in ["English.", "未完成中文"] {
            let engine = FollowingEngine(), app = makeApp(engine: engine), session = InputSessionID(pid: 1)
            app.input.timing = .completeSentence
            let text = "已译中文。" + other
            let firstCaret = "已译中文。".utf16.count
            app.monitor.onAnchorChanged?(anchor(), session)
            app.monitor.onSnapshot?(snapshot(text, caret: firstCaret), session, NSScreen.main)
            try await waitUntil { await engine.count == 1 }
            await engine.complete(0, with: "Translated.")
            try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
            app.monitor.onSnapshot?(snapshot(text), session, NSScreen.main)
            XCTAssertTrue(app.overlay.cardContents.isEmpty)
            app.monitor.onSnapshot?(snapshot(text, caret: firstCaret), session, NSScreen.main)
            try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
            XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: "已译中文。", translation: "Translated.")])
            let count = await engine.count
            XCTAssertEqual(count, 1)
        }
    }

    func testAppClipboardPendingWithoutAXSurvivesFocusAndLiveRequest() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine)
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await waitUntil { await engine.count == 1 }
        app.monitor.onFocusChanged?()
        let session = InputSessionID(pid: 1)
        app.monitor.onAnchorChanged?(anchor(), session)
        app.monitor.onSnapshot?(snapshot("实时中文。"), session, NSScreen.main)
        try await waitUntil { await engine.count == 2 }
        await engine.complete(0, with: "Clipboard English.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: nil, translation: "Clipboard English.")])
        await engine.complete(1, with: "Live English.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 2 }
        app.monitor.onAnchorChanged?(InputAnchor(caretFrame: nil, fieldFrame: nil), session)
        app.monitor.onFocusChanged?()
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: nil, translation: "Clipboard English.")])
    }

    func testAppClipboardWithoutAnyAXAnchorDisplaysAfterFocusInvalidation() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine)
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await waitUntil { await engine.count == 1 }
        app.monitor.onFocusChanged?()
        await engine.complete(0, with: "Clipboard English.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        let session = InputSessionID(pid: 1)
        app.monitor.onAnchorChanged?(InputAnchor(caretFrame: nil, fieldFrame: nil), session)
        app.monitor.onSnapshot?(snapshot(""), session, NSScreen.main)
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: nil, translation: "Clipboard English.")])
        XCTAssertEqual(app.overlay.shownEntryIDs.count, 1)
    }

    func testAppSameProcessNewFieldSessionDiscardsLateOldFieldResponse() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine)
        let old = InputSessionID(pid: 1), new = InputSessionID(pid: 1)
        app.monitor.onAnchorChanged?(anchor(), old)
        app.monitor.onSnapshot?(snapshot("相同中文。"), old, NSScreen.main)
        try await waitUntil { await engine.count == 1 }
        app.monitor.onFocusChanged?()
        app.monitor.onAnchorChanged?(anchor(dx: 80), new)
        app.monitor.onSnapshot?(snapshot("相同中文。"), new, NSScreen.main)
        try await waitUntil { await engine.count == 2 }
        await engine.complete(0, with: "Old field.")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        await engine.complete(1, with: "New field.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        XCTAssertEqual(app.overlay.cardContents, [OverlayCardContent(source: "相同中文。", translation: "New field.")])
    }

    func testAppConfigurationInvalidatesBothPendingOrigins() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine), session = InputSessionID(pid: 1)
        app.monitor.onAnchorChanged?(anchor(), session)
        app.monitor.onSnapshot?(snapshot("实时中文。"), session, NSScreen.main)
        try await waitUntil { await engine.count == 1 }
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await waitUntil { await engine.count == 2 }
        app.settings.targetLanguage = .japanese
        await engine.complete(0, with: "Old live configuration.")
        await engine.complete(1, with: "Old clipboard configuration.")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
    }

    func testClipboardStackCapDoesNotEvictTheActiveRealtimeCard() throws {
        let overlay = makeOverlay(), session = InputSessionID(pid: 1)
        overlay.showRealtime(source: "中文。", translation: "Live.", key: "live", session: session, anchor: anchor())
        let live = try XCTUnwrap(overlay.shownEntryIDs.first)
        for index in 0..<4 { overlay.show("Clipboard \(index)", key: "clip\(index)", on: NSScreen.main, origin: .clipboard) }
        XCTAssertTrue(overlay.shownEntryIDs.contains(live))
        XCTAssertEqual(overlay.shownEntryIDs.count, 4)
        XCTAssertEqual(overlay.cardContents.map(\.translation), ["Live.", "Clipboard 1", "Clipboard 2", "Clipboard 3"])
    }

    func testAppRepeatedClipboardTextReusesItsFixedCardAndCachedTranslation() async throws {
        let engine = FollowingEngine(), app = makeApp(engine: engine)
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await waitUntil { await engine.count == 1 }
        await engine.complete(0, with: "Clipboard English.")
        try await waitUntil { app.overlay.shownEntryIDs.count == 1 }
        let id = try XCTUnwrap(app.overlay.shownEntryIDs.first)
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(app.overlay.shownEntryIDs, [id])
        let count = await engine.count
        XCTAssertEqual(count, 1)
    }

    private func makeOverlay() -> OverlayCoordinator {
        let overlay = OverlayCoordinator()
        overlay.neverHide = true; overlay.cursorOverCard = { _ in false }
        overlays.append(overlay)
        return overlay
    }
    private func makeApp(engine: FollowingEngine) -> AppState {
        let name = "RunwuFollowingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        suites.append((defaults, name))
        let settings = SettingsStore(defaults: defaults)
        settings.enabled = true; settings.translationSpeed = 20; settings.translationTiming = .pause
        settings.neverHide = true; settings.clipboardTranslationEnabled = true; settings.clipboardTriggerMode = .hotkey
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        directories.append(directory)
        let app = AppState(settings: settings, translationEngine: engine,
            historyDatabaseURL: directory.appendingPathComponent("history.sqlite"), startRuntime: false)
        app.overlay.neverHide = true; app.overlay.cursorOverCard = { _ in false }
        app.input.delayMilliseconds = 20
        applications.append(app)
        return app
    }
    private func snapshot(_ text: String, caret: Int? = nil, composing: Bool = false) -> TextSnapshot {
        TextSnapshot(pid: 1, bundleIdentifier: "test.input", text: text,
            selectedRange: NSRange(location: caret ?? text.utf16.count, length: 0), isComposing: composing)
    }
    private func anchor(dx: CGFloat = 0) -> InputAnchor {
        let frame = NSScreen.main!.visibleFrame
        return InputAnchor(caretFrame: NSRect(x: frame.minX + 100 + dx, y: frame.midY, width: 1, height: 20), fieldFrame: nil)
    }
    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for pipeline state", file: file, line: line)
    }
}

private actor FollowingEngine: TranslationEngine {
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    private(set) var count = 0
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        let id = count
        count += 1
        return try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }
    func complete(_ id: Int, with value: String) { continuations.removeValue(forKey: id)?.resume(returning: value) }
}
