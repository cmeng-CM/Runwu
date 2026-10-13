import AppKit
import ApplicationServices
import XCTest
@testable import Pico

@MainActor
final class CaretTrackingTests: XCTestCase {
    func testAXOriginUsesPrimaryTopWithDisplaysAboveBelowAndLeft() {
        let layout = InputScreenLayout(frames: [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 0, y: 900, width: 1440, height: 900),
            NSRect(x: 0, y: -900, width: 1440, height: 900),
            NSRect(x: -1440, y: 0, width: 1440, height: 900),
        ])
        XCTAssertEqual(layout.cocoaRect(NSRect(x: 100, y: 150, width: 1, height: 20)).minY, 730)
        XCTAssertEqual(layout.cocoaRect(NSRect(x: 100, y: -300, width: 1, height: 20)).minY, 1180)
        XCTAssertEqual(layout.cocoaRect(NSRect(x: 100, y: 1200, width: 1, height: 20)).minY, -320)
        XCTAssertEqual(layout.axPoint(NSPoint(x: -900, y: 300)), NSPoint(x: -900, y: 600))
        XCTAssertNotNil(layout.caretRect(NSRect(x: -900, y: 600, width: 0, height: 20), field: nil))
    }

    func testNativeRangeGeometryAndSnapshotDefaults() throws {
        let fixture = AXFixture()
        let geometry = try XCTUnwrap(fixture.geometry())
        XCTAssertEqual(geometry.anchor.caretFrame, NSRect(x: 220, y: 730, width: 1, height: 20))
        XCTAssertEqual(geometry.anchor.fieldFrame, NSRect(x: 100, y: 600, width: 400, height: 200))
        XCTAssertEqual(geometry.selectedRange, NSRange(location: 5, length: 0))
        let snapshot = TextSnapshot(pid: 1, bundleIdentifier: nil, text: "", selectedRange: nil)
        XCTAssertNil(snapshot.caretFrame)
        XCTAssertFalse(snapshot.isComposing)
    }

    func testNativeStaleVerticalBoxIsCorrectedByMeasuredPreviousGlyph() throws {
        let fixture = AXFixture()
        fixture.direct = NSRect(x: 220, y: 110, width: 1, height: 20)
        fixture.previous = NSRect(x: 200, y: 150, width: 20, height: 20)
        XCTAssertEqual(try XCTUnwrap(fixture.geometry()).anchor.caretFrame?.minY, 730)
        fixture.direct = NSRect(x: 120, y: 180, width: 1, height: 20)
        XCTAssertEqual(try XCTUnwrap(fixture.geometry()).anchor.caretFrame?.minY, 700,
            "A real next-line caret must keep its own line")
    }

    func testBadNativeBoxUsesPreviousOrNextRealCharacterBounds() throws {
        let fixture = AXFixture()
        fixture.direct = NSRect(x: 0, y: 0, width: 1, height: 20)
        fixture.previous = NSRect(x: 200, y: 150, width: 20, height: 20)
        XCTAssertEqual(try XCTUnwrap(fixture.geometry()).anchor.caretFrame?.minX, 220)
        fixture.previous = nil
        fixture.next = NSRect(x: 240, y: 150, width: 20, height: 20)
        XCTAssertEqual(try XCTUnwrap(fixture.geometry()).anchor.caretFrame?.minX, 240)
    }

    /// 焦点文本节点自己不报矩形时（Chromium contenteditable 实测如此），
    /// 向上取最近的「像输入框」的祖先矩形，浮窗避让才有边界可用。
    func testFieldFrameFallsBackToNearestPlausibleAncestor() throws {
        let fixture = AXFixture()
        fixture.missingFrameFor = fixture.first
        fixture.parents[fixture.first] = fixture.container
        fixture.frames[fixture.container] = NSRect(x: 200, y: 150, width: 600, height: 120)
        let geometry = try XCTUnwrap(fixture.geometry())
        XCTAssertEqual(geometry.anchor.fieldFrame, NSRect(x: 200, y: 630, width: 600, height: 120))
        XCTAssertNotNil(geometry.anchor.caretFrame, "兜底取框不得丢掉光标")
    }

    /// 兜底只认「像输入框」的祖先：接近整屏的整窗/整页容器要跳过，
    /// 否则障碍等于整个屏幕，卡片反而无处可放。
    func testFieldFrameFallbackSkipsWindowSizedContainers() throws {
        let fixture = AXFixture()
        fixture.missingFrameFor = fixture.first
        fixture.parents[fixture.first] = fixture.container
        fixture.frames[fixture.container] = NSRect(x: 0, y: 0, width: 1440, height: 880)
        XCTAssertNil(try XCTUnwrap(fixture.geometry()).anchor.fieldFrame)

        fixture.parents[fixture.container] = fixture.second
        fixture.frames[fixture.second] = NSRect(x: 180, y: 140, width: 700, height: 140)
        let geometry = try XCTUnwrap(fixture.geometry())
        XCTAssertEqual(geometry.anchor.fieldFrame, NSRect(x: 180, y: 620, width: 700, height: 140),
            "整窗容器跳过，继续向上取真正像输入框的那层")
    }

    func testTextMarkerFallbackRejectsSelectionRunAndInvalidCoordinates() throws {
        let fixture = AXFixture()
        fixture.direct = nil
        fixture.marker = NSRect(x: 240, y: 150, width: 1, height: 20)
        XCTAssertEqual(try XCTUnwrap(fixture.geometry()).anchor.caretFrame?.minX, 240)
        for invalid in [
            NSRect(x: 240, y: 150, width: 100, height: 20),
            NSRect(x: 9000, y: 150, width: 1, height: 20),
            NSRect(x: CGFloat.nan, y: 150, width: 1, height: 20),
            NSRect(x: 240, y: 150, width: 1, height: 0),
            NSRect(x: 40, y: 150, width: 1, height: 20),
        ] {
            fixture.marker = invalid
            let geometry = try XCTUnwrap(fixture.geometry())
            XCTAssertNil(geometry.anchor.caretFrame)
            XCTAssertNotNil(geometry.anchor.fieldFrame, "Bad carets degrade to the real input box")
        }
    }

    func testMarkedRangeRequiresValidNonemptyRange() throws {
        let fixture = AXFixture()
        for (range, expected) in [(NSRange(location: 2, length: 2), true),
            (NSRange(location: 2, length: 0), false), (NSRange(location: NSNotFound, length: 2), false)] {
            fixture.marked = range
            XCTAssertEqual(try XCTUnwrap(fixture.geometry()).isComposing, expected)
        }
    }

    func testMonitorEmitsChangedGeometryBeforeUnchangedTextDedup() {
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        var events: [String] = [], anchors: [InputAnchor] = [], sessions: [InputSessionID] = []
        monitor.onAnchorChanged = { anchor, session in
            events.append("anchor"); anchors.append(anchor); sessions.append(session)
        }
        monitor.onSnapshot = { _, _, _ in events.append("text") }
        monitor.readSnapshot()
        fixture.direct?.origin.x += 10
        monitor.readSnapshot()
        fixture.field.origin.x += 20
        monitor.readSnapshot()
        monitor.readSnapshot()
        XCTAssertEqual(events, ["anchor", "text", "anchor", "anchor"])
        XCTAssertEqual(anchors.count, 3)
        XCTAssertEqual(Set(sessions).count, 1)
    }

    func testUnreadableTextDoesNotFreezeGeometricEvents() {
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        var positions = 0, texts = 0
        monitor.onAnchorChanged = { _, _ in positions += 1 }
        monitor.onSnapshot = { _, _, _ in texts += 1 }
        monitor.readSnapshot()
        fixture.text = nil
        fixture.direct?.origin.x += 20
        monitor.readSnapshot()
        XCTAssertEqual(positions, 2)
        XCTAssertEqual(texts, 1)
    }

    func testCompositionCommitWithSameTextAndRangeIsDelivered() async {
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        let input = InputCoordinator()
        input.delayMilliseconds = 20
        var states: [Bool] = [], translated: [String] = []
        monitor.onSnapshot = { snapshot, session, screen in
            states.append(snapshot.isComposing)
            input.handle(snapshot, session: session, screen: screen)
        }
        input.onSentence = { text, _, _, _, _ in translated.append(text) }
        monitor.readSnapshot()
        fixture.marked = NSRange(location: 2, length: 2)
        monitor.readSnapshot()
        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(translated.isEmpty, "Composition cancels the pending debounce")
        XCTAssertNil(monitor.snapshotNow(), "Shortcut must not recover cached text during composition")
        fixture.marked = NSRange(location: 2, length: 0)
        monitor.readSnapshot()
        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(states, [false, true, false])
        XCTAssertEqual(translated, [fixture.text!])
    }

    func testMarkedReadFailuresCancelPendingAndRecoverIdenticalTextAndRange() async {
        for failure in [AXAttributeResult.unavailable(.cannotComplete), .unavailable(.failure),
            .unavailable(.apiDisabled), .budgetExhausted] {
            let fixture = AXFixture(), input = InputCoordinator()
            let monitor = fixture.monitor()
            input.delayMilliseconds = 20
            var emitted: [InputSessionID] = [], anchors: [InputSessionID] = []
            monitor.onFocusChanged = { input.reset() }
            monitor.onSnapshot = { input.handle($0, session: $1, screen: $2) }
            monitor.onAnchorChanged = { _, session in anchors.append(session) }
            input.onSentence = { _, _, session, _, _ in emitted.append(session) }
            monitor.readSnapshot() // Queue a request from a trusted sample.
            let oldSession = anchors.last
            let reads = fixture.contentReads
            fixture.markedReadResult = failure
            fixture.direct?.origin.x += 10
            monitor.readSnapshot()
            XCTAssertNil(monitor.snapshotNow(), "Shortcut must not recover cached text on unknown composition")
            XCTAssertEqual(fixture.contentReads, reads, "Unknown composition must not read raw AXValue")
            try? await Task.sleep(for: .milliseconds(70))
            XCTAssertTrue(emitted.isEmpty, "Unknown composition cancels the older debounce")
            XCTAssertNotEqual(anchors.last, oldSession, "Old realtime request identity must be invalidated")
            fixture.markedReadResult = nil
            monitor.readSnapshot()
            try? await Task.sleep(for: .milliseconds(70))
            XCTAssertEqual(emitted.count, 1, "Identical text/range must recover after a trusted read")
            XCTAssertNotEqual(emitted.first, oldSession)
        }
    }

    func testMarkedErrorAfterActiveCompositionCannotForgeCommitInAnyTimingMode() async {
        for timing in [TranslationTiming.pause, .completeSentence, .shortcut] {
            let fixture = AXFixture(), input = InputCoordinator()
            let monitor = fixture.monitor()
            input.timing = timing; input.delayMilliseconds = 20
            fixture.selected = NSRange(location: fixture.text!.utf16.count, length: 0)
            var emitted = 0
            monitor.onFocusChanged = { input.reset() }
            monitor.onSnapshot = { input.handle($0, session: $1, screen: $2) }
            input.onSentence = { _, _, _, _, _ in emitted += 1 }
            fixture.marked = NSRange(location: 2, length: 2)
            monitor.readSnapshot()
            fixture.errors["AXTextInputMarkedRange"] = .cannotComplete
            let reads = fixture.contentReads
            monitor.readSnapshot()
            if let sample = monitor.snapshotNow() {
                input.translateNow(sample.snapshot, session: sample.session, screen: sample.screen)
            }
            try? await Task.sleep(for: .milliseconds(70))
            XCTAssertEqual(emitted, 0)
            XCTAssertEqual(fixture.contentReads, reads)
            fixture.errors.removeValue(forKey: "AXTextInputMarkedRange")
            fixture.marked = NSRange(location: 2, length: 0)
            monitor.readSnapshot()
            if timing == .shortcut, let sample = monitor.snapshotNow() {
                input.translateNow(sample.snapshot, session: sample.session, screen: sample.screen)
            }
            try? await Task.sleep(for: .milliseconds(70))
            XCTAssertEqual(emitted, 1)
        }
    }

    func testUnknownCompositionInvalidatesRealAppPendingAndRejectsLateResult() async throws {
        _ = NSApplication.shared
        let suite = "RunwuMarkedApp.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(defaults: defaults), engine = MarkedBoundaryEngine()
        store.neverHide = true
        let app = AppState(settings: store, translationEngine: engine,
            historyDatabaseURL: directory.appendingPathComponent("history.sqlite"), startRuntime: false)
        defer {
            app.input.reset(); app.overlay.hide()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        app.input.delayMilliseconds = 10
        let fixture = AXFixture(), monitor = fixture.monitor()
        monitor.onFocusChanged = app.monitor.onFocusChanged
        monitor.onSnapshot = app.monitor.onSnapshot
        monitor.onAnchorChanged = app.monitor.onAnchorChanged
        monitor.readSnapshot()
        for _ in 0..<100 {
            if await engine.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await engine.count
        XCTAssertEqual(started, 1)
        XCTAssertTrue(app.hasPendingTranslationAction)
        fixture.markedReadResult = .unavailable(.cannotComplete)
        monitor.readSnapshot()
        XCTAssertFalse(app.hasPendingTranslationAction, "Production App must invalidate synchronously")
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertTrue(app.history.entries.isEmpty, "Late synthetic response must not become history")
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        fixture.markedReadResult = nil
        monitor.readSnapshot()
        for _ in 0..<100 {
            if app.history.entries.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(app.history.entries.count, 1)
        let recovered = await engine.count
        XCTAssertEqual(recovered, 2)
    }

    func testMarkedUnsupportedAndNoValueAreKnownInactive() throws {
        for error in [AXError.attributeUnsupported, .noValue] {
            let fixture = AXFixture()
            fixture.errors["AXTextInputMarkedRange"] = error
            XCTAssertEqual(try XCTUnwrap(fixture.geometry()).isComposing, false)
            XCTAssertNotNil(fixture.monitor().snapshotNow())
        }
    }

    func testSameAppFieldChangeCreatesSessionBeforeAnchorAndClearsRecovery() {
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        var sessions: [InputSessionID] = [], events: [String] = []
        monitor.onFocusChanged = { events.append("focus") }
        monitor.onAnchorChanged = { _, _ in events.append("anchor") }
        monitor.onSnapshot = { _, session, _ in sessions.append(session); events.append("text") }
        monitor.readSnapshot()
        events.removeAll()
        fixture.focused = fixture.second
        monitor.readSnapshot()
        XCTAssertEqual(events, ["focus", "anchor", "text"])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertNotEqual(sessions[0], sessions[1])
        fixture.focused = fixture.first
        fixture.text = ""
        XCTAssertNil(monitor.snapshotNow(), "The other field's lastGoodText cannot be reused")
    }

    func testExcludedAndSystemSecureInputPerformNoRemoteReadsOrEvents() {
        for secure in [false, true] {
            let fixture = AXFixture()
            fixture.secureInput = secure
            let monitor = fixture.monitor()
            if !secure { monitor.excludedBundleIDs = [fixture.bundleID] }
            var events = 0
            monitor.onAnchorChanged = { _, _ in events += 1 }
            monitor.onSnapshot = { _, _, _ in events += 1 }
            monitor.readSnapshot()
            XCTAssertNil(monitor.snapshotNow())
            XCTAssertEqual(fixture.attributeReads, 0)
            XCTAssertEqual(fixture.contentReads, 0)
            XCTAssertEqual(events, 0)
        }
    }

    func testSecureFieldOrContainerCannotExposeContentsThroughDescendants() {
        for elementIsContainer in [false, true] {
            let fixture = AXFixture()
            fixture.focused = elementIsContainer ? fixture.container : fixture.first
            fixture.secureElement = fixture.focused
            let monitor = fixture.monitor()
            var events = 0
            monitor.onAnchorChanged = { _, _ in events += 1 }
            monitor.onSnapshot = { _, _, _ in events += 1 }
            monitor.readSnapshot()
            XCTAssertNil(monitor.snapshotNow())
            XCTAssertEqual(fixture.contentReads, 0)
            XCTAssertEqual(fixture.childReads, 0)
            XCTAssertEqual(events, 0)
        }
    }

    func testLosingSafeFocusDoesNotRecoverOrReadPreviouslyCachedText() {
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        XCTAssertNotNil(monitor.snapshotNow())
        let previousReads = fixture.contentReads
        fixture.secureElement = fixture.first
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(fixture.contentReads, previousReads)
    }

    func testPasswordLabelWithoutSecureSubroleIsRejectedBeforeValue() {
        let fixture = AXFixture()
        fixture.label = "请输入密码 / Password"
        let monitor = fixture.monitor()
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(fixture.contentReads, 0)
    }

    func testSecurityMetadataAXFailuresDoNotReadText() {
        for key in ["AXRole", "AXSubrole", "AXProtectedContent", "AXTitle", "AXDescription", "AXPlaceholderValue"] {
            for error in [AXError.cannotComplete, .failure, .apiDisabled, .invalidUIElement] {
                let fixture = AXFixture()
                fixture.errors[key] = error
                let monitor = fixture.monitor()
                monitor.readSnapshot()
                XCTAssertNil(monitor.snapshotNow(), "\(key) \(error) must fail closed")
                XCTAssertEqual(fixture.contentReads, 0, "\(key) \(error) must not read AXValue")
            }
        }
    }

    func testOptionalUnsupportedAndNoValueSecurityMetadataRemainCompatible() {
        for error in [AXError.attributeUnsupported, .noValue] {
            let fixture = AXFixture()
            for key in ["AXSubrole", "AXProtectedContent", "AXTitle", "AXDescription", "AXPlaceholderValue"] {
                fixture.errors[key] = error
            }
            XCTAssertNotNil(fixture.monitor().snapshotNow())
            XCTAssertGreaterThan(fixture.contentReads, 0)
        }
    }

    func testHitFallbackRejectsOtherProcessPasswordAndUnfocusedElement() {
        for mode in 0..<3 {
            let fixture = AXFixture()
            fixture.focused = nil
            fixture.hit = mode == 0 ? fixture.foreign : fixture.first
            if mode == 1 { fixture.secureElement = fixture.first }
            if mode == 2 { fixture.hitFocused = false }
            let monitor = fixture.monitor()
            monitor.readSnapshot()
            XCTAssertNil(monitor.snapshotNow())
            XCTAssertEqual(fixture.contentReads, 0)
        }
        let allowed = AXFixture()
        allowed.focused = nil
        allowed.hit = allowed.first
        XCTAssertNotNil(allowed.monitor().snapshotNow())
    }

    func testForeignFocusedElementCannotExposeText() {
        let fixture = AXFixture()
        fixture.focused = fixture.foreign
        let monitor = fixture.monitor()
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(fixture.contentReads, 0)
    }

    func testProtectionRecheckedAfterAnchorCallbackBeforeReadingValue() {
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        monitor.onAnchorChanged = { _, _ in monitor.excludedBundleIDs = [fixture.bundleID] }
        monitor.readSnapshot()
        XCTAssertEqual(fixture.contentReads, 0)
        XCTAssertNil(monitor.snapshotNow())
    }

    func testReentrantFocusChangeDoesNotEmitOldFieldWithNewSession() {
        let boundary = "caret diagnostic boundary session=\(UUID().uuidString)"
        DiagnosticLog.write(boundary)
        let fixture = AXFixture()
        let monitor = fixture.monitor()
        var switched = false, anchors: [InputSessionID] = [], snapshots: [InputSessionID] = []
        monitor.onAnchorChanged = { _, session in
            anchors.append(session)
            if !switched {
                switched = true
                fixture.focused = fixture.second
                monitor.readSnapshot()
            }
        }
        monitor.onSnapshot = { _, session, _ in snapshots.append(session) }
        monitor.readSnapshot()
        XCTAssertEqual(anchors.count, 2)
        XCTAssertNotEqual(anchors[0], anchors[1])
        XCTAssertEqual(snapshots, [anchors[1]])
        XCTAssertEqual(fixture.contentReads, 1)
        let lines = DiagnosticLog.recentLines()
        let log = Array(lines.drop { !$0.contains(boundary) }.dropFirst())
        XCTAssertFalse(log.contains { $0.contains("input sample blocked reason=session_changed") },
            "A superseded outer sample must not overwrite the valid nested read's diagnostic state")
    }

    func testSlowAXSampleStopsBeforeValueAndRecoversOnNextSample() {
        let fixture = AXFixture()
        fixture.readCost = 0.04
        let access = fixture.access().bounded(to: 0.12, now: { fixture.simulatedTime })
        let monitor = AccessibilityMonitor(access: access, currentApplication: {
            MonitoredApplication(pid: fixture.pid, bundleID: fixture.bundleID)
        }, screenFrames: { fixture.screens })
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(fixture.contentReads, 0)
        XCTAssertLessThanOrEqual(fixture.attributeReads, 4, "Expired budget must not keep traversing/read attempts")
        fixture.readCost = 0
        XCTAssertNotNil(monitor.snapshotNow())

        // 锚窗读取同样纳入整次预算：预算恰在锚窗读取前耗尽 → 该读取被拒（未执行），
        // 采样按不可信处理、不读到 AXValue、不发快照；下一采样恢复。
        let gated = AXFixture()
        gated.hostText = gated.text
        gated.selected = NSRange(location: 8, length: 0)
        gated.readCost = 0.04
        // 25 次已计费读取（焦点解析 10 + 几何 15，0.04×25 = 1.00 > 0.98 > 0.04×24）
        // 之后预算耗尽，恰好落在锚窗读取的尝试上。
        var gatedAccess = gated.access().bounded(to: 0.98, now: { gated.simulatedTime })
        var anchorAttempts = 0
        let attempted = gatedAccess.parameterizedResult
        gatedAccess.parameterizedResult = { element, key, parameter in
            anchorAttempts += 1
            return attempted(element, key, parameter)
        }
        let gatedMonitor = AccessibilityMonitor(access: gatedAccess, currentApplication: {
            MonitoredApplication(pid: gated.pid, bundleID: gated.bundleID)
        }, screenFrames: { gated.screens })
        var snapshots = 0, anchors = 0
        gatedMonitor.onSnapshot = { _, _, _ in snapshots += 1 }
        gatedMonitor.onAnchorChanged = { _, _ in anchors += 1 }
        gatedMonitor.readSnapshot()
        XCTAssertEqual(anchorAttempts, 1, "锚窗读取被尝试且受整次预算约束")
        XCTAssertEqual(gated.anchorReads, 0, "预算耗尽后锚窗读取不再执行")
        XCTAssertGreaterThan(gated.parameterizedReads, 0, "光标几何读取先于锚窗读取发生")
        XCTAssertEqual(gated.contentReads, 0)
        XCTAssertEqual(snapshots, 0, "预算耗尽于锚窗读取 → 不翻")
        XCTAssertNil(gatedMonitor.snapshotNow(), "快捷键路径同样不翻")
        XCTAssertEqual(gated.contentReads, 0)
        XCTAssertEqual(snapshots, 0)
        XCTAssertGreaterThan(anchors, 0, "锚点几何已发布")
        gated.readCost = 0
        gatedMonitor.readSnapshot()
        XCTAssertEqual(snapshots, 1, "预算恢复后重新发出采样")
        let recovered = gatedMonitor.snapshotNow()
        XCTAssertEqual(recovered?.snapshot.selectedRange?.location, 8, "原生宿主映射到自身偏移")
        XCTAssertEqual(recovered?.snapshot.text, gated.text)
        XCTAssertEqual(gated.requestedStringRanges.last, NSRange(location: 8, length: 1), "光标后一位字符按 (r, 1) 读取")
    }

    /// 宿主无该读取能力（attributeUnsupported/noValue）：不判定、沿用报告偏移的旧行为。
    func testUnsupportedAnchorReadKeepsReportedOffset() throws {
        for error in [AXError.attributeUnsupported, .noValue] {
            let fixture = AXFixture()
            fixture.selected = NSRange(location: 8, length: 0)
            fixture.anchorReadResult = .unavailable(error)
            let monitor = fixture.monitor()
            var snapshot: TextSnapshot?
            monitor.onSnapshot = { value, _, _ in snapshot = value }
            monitor.readSnapshot()
            XCTAssertGreaterThanOrEqual(fixture.anchorReads, 1, "锚窗读取发生过")
            XCTAssertEqual(try XCTUnwrap(snapshot, "宿主不支持锚窗读取时不应停止翻译").selectedRange?.location, 8)
            XCTAssertEqual(monitor.snapshotNow()?.snapshot.selectedRange?.location, 8)
        }
    }

    /// 显式错误/预算耗尽/读回空：宿主偏移不可信 → 不发快照（宁可不翻，不翻错行）。
    func testFailedAnchorReadEmitsNoSnapshot() {
        for failure in [AXAttributeResult.unavailable(.cannotComplete), .unavailable(.failure),
            .unavailable(.apiDisabled), .budgetExhausted, .value("" as CFString)] {
            let fixture = AXFixture()
            fixture.hostText = fixture.text
            fixture.selected = NSRange(location: 8, length: 0)
            fixture.anchorReadResult = failure
            let monitor = fixture.monitor()
            var snapshots = 0, anchors = 0
            monitor.onSnapshot = { _, _, _ in snapshots += 1 }
            monitor.onAnchorChanged = { _, _ in anchors += 1 }
            monitor.readSnapshot()
            XCTAssertEqual(fixture.contentReads, 1, "映射在 AXValue 读回之后判定")
            XCTAssertEqual(snapshots, 0, "锚窗读取失败 \(failure) 时不出卡")
            XCTAssertNil(monitor.snapshotNow(), "快捷键路径同样不翻")
            XCTAssertEqual(snapshots, 0)
            XCTAssertGreaterThan(anchors, 0, "锚点几何仍发布，跟随不因取句失败停摆")
        }
    }

    func testDiagnosticUnreadableCompositionCancelsRecoversAndCanFailAgain() async throws {
        let boundary = "caret diagnostic boundary session=\(UUID().uuidString)"
        DiagnosticLog.write(boundary)
        let fixture = AXFixture(), input = InputCoordinator(), monitor = fixture.monitor()
        input.delayMilliseconds = 20
        monitor.onFocusChanged = { input.reset() }
        monitor.onSnapshot = { input.handle($0, session: $1, screen: $2) }
        var emitted = 0
        input.onSentence = { _, _, _, _, _ in emitted += 1 }
        monitor.readSnapshot()
        let reads = fixture.contentReads
        fixture.markedReadResult = .unavailable(.cannotComplete)
        for _ in 0..<4 { monitor.readSnapshot() }
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(fixture.contentReads, reads, "Diagnostics must not read text on unknown composition")
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(emitted, 0)
        fixture.markedReadResult = nil
        monitor.readSnapshot()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(emitted, 1, "Trusted identical text/range must still be delivered")
        fixture.markedReadResult = .budgetExhausted
        for _ in 0..<3 { monitor.readSnapshot() }
        let lines = DiagnosticLog.recentLines()
        let index = try XCTUnwrap(lines.firstIndex { $0.contains(boundary) })
        let log = Array(lines.dropFirst(index + 1))
        XCTAssertEqual(log.filter { $0.contains("input sample blocked reason=composition_unreadable") }.count, 2)
        XCTAssertEqual(log.filter { $0.contains("input session reset reason=composition_unreadable") }.count, 2)
        XCTAssertEqual(log.filter { $0.contains("input sample recovered reason=composition_unreadable") }.count, 1)
        XCTAssertEqual(log.filter { $0.contains("debounce cancelled reason=reset") }.count, 1,
            "The second failure occurs after expiry and must not forge a pending cancel")
        XCTAssertEqual(log.filter { $0.contains("debounce elapsed") }.count, 1)
    }

    func testDiagnosticGeometryFailureStaysQuietAcrossFocusReacquisition() throws {
        let boundary = "caret diagnostic boundary session=\(UUID().uuidString)"
        DiagnosticLog.write(boundary)
        let fixture = AXFixture()
        var access = fixture.access(), roleReads = 0, failGeometry = true
        let begin = access.beginRead, read = access.readAttribute
        access.beginRead = { roleReads = 0; begin() }
        access.readAttribute = { element, key in
            if key == kAXRoleAttribute as String {
                roleReads += 1
                if failGeometry, roleReads == 2 { return .unavailable(.cannotComplete) }
            }
            return read(element, key)
        }
        let monitor = AccessibilityMonitor(access: access, currentApplication: {
            MonitoredApplication(pid: fixture.pid, bundleID: fixture.bundleID)
        }, screenFrames: { fixture.screens })
        var snapshots = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        for _ in 0..<4 { monitor.readSnapshot() }
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(fixture.contentReads, 0)
        failGeometry = false
        monitor.readSnapshot()
        XCTAssertEqual(snapshots, 1)
        failGeometry = true
        for _ in 0..<3 { monitor.readSnapshot() }
        let lines = DiagnosticLog.recentLines()
        let index = try XCTUnwrap(lines.firstIndex { $0.contains(boundary) })
        let log = Array(lines.dropFirst(index + 1))
        XCTAssertEqual(log.filter { $0.contains("input sample blocked reason=geometry_unavailable") }.count, 2)
        XCTAssertEqual(log.filter { $0.contains("input sample recovered reason=geometry_unavailable") }.count, 1)
        XCTAssertEqual(log.filter { $0.contains("input session reset reason=geometry_unavailable") }.count, 1,
            "Initial application acquisition has its own application_changed reason")
    }

    func testDiagnosticApplicationAndFieldResetsAreDistinct() throws {
        let boundary = "caret diagnostic boundary session=\(UUID().uuidString)"
        DiagnosticLog.write(boundary)
        let fixture = AXFixture()
        var app: MonitoredApplication? = MonitoredApplication(pid: fixture.pid, bundleID: fixture.bundleID)
        let monitor = AccessibilityMonitor(access: fixture.access(), currentApplication: { app },
            screenFrames: { fixture.screens })
        var sessions: [InputSessionID] = []
        monitor.onSnapshot = { _, session, _ in sessions.append(session) }
        monitor.readSnapshot()
        fixture.focused = fixture.second
        monitor.readSnapshot()
        app = MonitoredApplication(pid: fixture.pid, bundleID: "test.changed")
        monitor.readSnapshot()
        app = nil
        monitor.readSnapshot()
        monitor.readSnapshot()
        XCTAssertEqual(Set(sessions).count, 3)
        let lines = DiagnosticLog.recentLines()
        let index = try XCTUnwrap(lines.firstIndex { $0.contains(boundary) })
        let log = Array(lines.dropFirst(index + 1))
        XCTAssertEqual(log.filter { $0.contains("input session reset reason=focus_changed") }.count, 1)
        XCTAssertEqual(log.filter { $0.contains("input session reset reason=application_changed") }.count, 3)
        XCTAssertEqual(log.filter { $0.contains("input sample blocked reason=application_unavailable") }.count, 1)
    }
}

/// Real CF AX handles plus injected remote replies exercise the monitor and
/// reader without contacting processes, granting AX or changing user settings.
@MainActor
final class AXFixture {
    let pid: pid_t = 700
    let bundleID = "test.input"
    let first = AXUIElementCreateApplication(701), second = AXUIElementCreateApplication(702)
    let container = AXUIElementCreateApplication(703), foreign = AXUIElementCreateApplication(704)
    var focused: AXUIElement?, hit: AXUIElement?, secureElement: AXUIElement?
    var secureInput = false, hitFocused = true
    var text: String? = "我今天会晚一点。"
    var label: String?
    var errors: [String: AXError] = [:]
    var markedReadResult: AXAttributeResult?
    /// 宿主文本通道：`AXStringForRange` 按它切片，与 `text`（AXValue）分离——
    /// Chromium contenteditable 里两者是两套坐标系。nil 表示宿主不提供该读取。
    var hostText: String?
    /// 宿主文本读取的注入结果；nil 时按 `hostText` 切片。
    var anchorReadResult: AXAttributeResult?
    /// 锚窗（`AXStringForRange`）请求范围、锚窗读取次数与旧 parameterized 变体次数。
    var requestedStringRanges: [NSRange] = []
    var anchorReads = 0, parameterizedReads = 0
    var selected = NSRange(location: 5, length: 0), marked: NSRange?
    var direct: NSRect? = NSRect(x: 220, y: 150, width: 1, height: 20)
    var previous: NSRect?, next: NSRect?, marker: NSRect?
    var field = NSRect(x: 100, y: 100, width: 400, height: 200)
    /// 输入框矩形兜底用：该元素不报 AXPosition/AXSize；父链与逐元素矩形覆盖
    var missingFrameFor: AXUIElement?
    var parents: [AXUIElement: AXUIElement] = [:]
    var frames: [AXUIElement: NSRect] = [:]
    var attributeReads = 0, contentReads = 0, childReads = 0
    var simulatedTime: TimeInterval = 0, readCost: TimeInterval = 0
    let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
    init() { focused = first }

    func monitor() -> AccessibilityMonitor {
        AccessibilityMonitor(access: access(), currentApplication: { [self] in
            MonitoredApplication(pid: pid, bundleID: bundleID)
        }, screenFrames: { [self] in screens })
    }
    func geometry() -> AXFieldReader.Geometry? {
        AXFieldReader(access: access()).geometry(first, pid: pid, bundleID: bundleID, excluded: [],
            layout: InputScreenLayout(frames: screens))
    }
    func access() -> AXFieldAccess {
        let attribute: (AXUIElement, String) -> CFTypeRef? = { [self] element, key in
            attributeReads += 1
            simulatedTime += readCost
            switch key {
            case "AXFocusedUIElement": return focused
            case "AXRole":
                return (CFEqual(element, container) ? "AXGroup" : "AXTextArea") as CFString
            case "AXSubrole":
                return (secureElement.map { CFEqual(element, $0) } == true ? "AXSecureTextField" : "") as CFString
            case "AXProtectedContent": return kCFBooleanFalse
            case "AXPlaceholderValue": return label.map { $0 as CFString }
            case "AXEditable", "AXEnabled": return kCFBooleanTrue
            case "AXFocused": return hitFocused ? kCFBooleanTrue : kCFBooleanFalse
            case "AXChildren":
                childReads += 1; return [first] as CFArray
            case "AXSelectedTextRange": return Self.range(selected)
            case "AXTextInputMarkedRange": return marked.map(Self.range)
            case "AXPosition":
                if let missing = missingFrameFor, CFEqual(element, missing) { return nil }
                var point = (frames[element] ?? field).origin
                return AXValueCreate(.cgPoint, &point)
            case "AXSize":
                if let missing = missingFrameFor, CFEqual(element, missing) { return nil }
                var size = (frames[element] ?? field).size
                return AXValueCreate(.cgSize, &size)
            case "AXParent":
                return parents[element]
            case "AXValue":
                contentReads += 1; return text.map { $0 as CFString }
            case "AXNumberOfCharacters": return NSNumber(value: text?.utf16.count ?? 0)
            case "AXSelectedTextMarkerRange": return marker == nil ? nil : NSNumber(value: 1)
            default: return nil
            }
        }
        return AXFieldAccess(readAttribute: { [self] element, key in
            if key == "AXTextInputMarkedRange", let result = markedReadResult { return result }
            if let error = errors[key] { return .unavailable(error) }
            return attribute(element, key).map(AXAttributeResult.value) ?? .unavailable(.attributeUnsupported)
        }, parameterized: { [self] _, key, parameter in
            if key == kAXStringForRangeParameterizedAttribute as String {
                guard let range = Self.parseRange(parameter) else { return nil }
                requestedStringRanges.append(range)
                if case .value(let value) = hostString(range) { return value }
                return nil
            }
            parameterizedReads += 1
            simulatedTime += readCost
            if key == "AXBoundsForTextMarkerRange" { return marker.map(Self.rect) }
            if key == kAXBoundsForRangeParameterizedAttribute as String {
                var range = CFRange()
                guard CFGetTypeID(parameter) == AXValueGetTypeID(),
                    AXValueGetValue(parameter as! AXValue, .cfRange, &range) else { return nil }
                if range.length == 0 { return direct.map(Self.rect) }
                return (range.location == selected.location - 1 ? previous : next).map(Self.rect)
            }
            return nil
        }, parameterizedResult: { [self] _, key, parameter in
            guard key == kAXStringForRangeParameterizedAttribute as String else {
                return .unavailable(.attributeUnsupported)
            }
            guard let range = Self.parseRange(parameter) else { return .unavailable(.failure) }
            requestedStringRanges.append(range)
            return hostString(range)
        }, pid: { [self] in CFEqual($0, foreign) ? 900 : pid },
        secureInputActive: { [self] in secureInput }, enableAccessibility: { _ in },
        hitTest: { [self] _ in hit })
    }
    /// 宿主文本读取（Chromium 形态）：按请求的 UTF-16 范围在 `hostText` 上切片；
    /// 范围越过文本末尾就截断，起始位置越界返回空串（宿主没有更多字符）。
    /// 计入锚窗读取次数与 `readCost`——锚窗读取和属性读取共用整次预算。
    func hostString(_ range: NSRange) -> AXAttributeResult {
        anchorReads += 1
        simulatedTime += readCost
        if let result = anchorReadResult { return result }
        guard let hostText else { return .unavailable(.attributeUnsupported) }
        let text = hostText as NSString
        guard range.location >= 0, range.length >= 0 else { return .unavailable(.failure) }
        guard range.location <= text.length else { return .value("" as CFString) }
        let length = min(range.length, text.length - range.location)
        return .value(text.substring(with: NSRange(location: range.location, length: length)) as CFString)
    }
    static func parseRange(_ value: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
            range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    static func range(_ value: NSRange) -> AXValue {
        var range = CFRange(location: value.location, length: value.length)
        return AXValueCreate(.cfRange, &range)!
    }
    static func rect(_ value: NSRect) -> AXValue {
        var value = value; return AXValueCreate(.cgRect, &value)!
    }
}

private actor MarkedBoundaryEngine: TranslationEngine {
    private(set) var count = 0
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        count += 1
        // Ignore cancellation deliberately to test App identity rejection.
        try? await Task.sleep(for: .milliseconds(100))
        return "Synthetic translation."
    }
}
