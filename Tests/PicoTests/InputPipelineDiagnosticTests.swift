import AppKit
import ApplicationServices
import XCTest
@testable import Pico

@MainActor
final class InputPipelineDiagnosticTests: XCTestCase {
    func testCompositionCancelsRealPendingTaskAndCommitRecovers() async throws {
        let boundary = beginLogCapture()
        let fixture = AXFixture(), input = InputCoordinator(), monitor = fixture.monitor()
        input.delayMilliseconds = 20
        connect(monitor, to: input)
        var emitted: [String] = [], sessions: [InputSessionID] = []
        input.onSentence = { text, _, session, _, _ in emitted.append(text); sessions.append(session) }
        monitor.readSnapshot()
        fixture.marked = NSRange(location: 2, length: 2)
        monitor.readSnapshot()
        // A changed sample during the same composition must not forge another
        // cancel or flood the suppression event.
        fixture.selected.location += 1
        monitor.readSnapshot()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(emitted.isEmpty)
        fixture.marked = NSRange(location: 2, length: 0)
        monitor.readSnapshot()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(emitted, [fixture.text!])
        input.reset() // The expired Task reference is still retained internally.
        let log = capturedLines(after: boundary)
        XCTAssertEqual(count("debounce queued", in: log), 2)
        XCTAssertEqual(count("debounce cancelled reason=composing", in: log), 1)
        XCTAssertEqual(count("debounce cancelled", in: log), 1)
        XCTAssertEqual(count("debounce elapsed", in: log), 1)
        XCTAssertEqual(count("input suppressed reason=composing", in: log), 1)
        XCTAssertTrue(log.contains { $0.contains("debounce elapsed") && $0.contains(sessions[0].token.uuidString) })
    }

    func testReplacementCancelsOnlyPendingTaskAndNotExpiredReference() async throws {
        let boundary = beginLogCapture(), input = InputCoordinator(), session = InputSessionID(pid: 1)
        input.delayMilliseconds = 20
        var emitted: [String] = []
        input.onSentence = { text, _, _, _, _ in emitted.append(text) }
        input.handle(snapshot("旧句子。"), session: session, screen: nil)
        input.handle(snapshot("新句子。"), session: session, screen: nil)
        try await Task.sleep(for: .milliseconds(70))
        input.handle(snapshot("第三句子。"), session: session, screen: nil)
        try await Task.sleep(for: .milliseconds(70))
        input.reset()
        let log = capturedLines(after: boundary)
        XCTAssertEqual(emitted, ["新句子。", "第三句子。"])
        XCTAssertEqual(count("debounce queued", in: log), 3)
        XCTAssertEqual(count("debounce cancelled reason=snapshot_replaced", in: log), 1)
        XCTAssertEqual(count("debounce cancelled", in: log), 1)
        XCTAssertEqual(count("debounce elapsed", in: log), 2)
    }

    func testTimingEmptyAndSessionChangesReportActualCancellationReasons() {
        let boundary = beginLogCapture(), input = InputCoordinator(), first = InputSessionID(pid: 1)
        input.delayMilliseconds = 200
        input.handle(snapshot("待执行句子。"), session: first, screen: nil)
        input.timing = .shortcut
        input.timing = .pause
        input.handle(snapshot("待执行句子。"), session: first, screen: nil)
        input.handle(snapshot(""), session: first, screen: nil)
        input.handle(snapshot("待执行句子。"), session: first, screen: nil)
        let second = InputSessionID(pid: 1)
        input.handle(snapshot("待执行句子。"), session: second, screen: nil)
        input.reset()
        input.reset()
        let log = capturedLines(after: boundary)
        for reason in ["timing_changed", "empty_text", "session_changed", "reset"] {
            XCTAssertEqual(count("debounce cancelled reason=\(reason)", in: log), 1)
        }
        XCTAssertEqual(count("debounce cancelled", in: log), 4)
        XCTAssertEqual(count("debounce elapsed", in: log), 0)
        XCTAssertTrue(log.contains { $0.contains("reason=session_changed") && $0.contains(first.token.uuidString) })
    }

    func testExpiredDebounceRecordsEmptyExtractionAndSentenceDedup() async throws {
        let boundary = beginLogCapture(), input = InputCoordinator(), session = InputSessionID(pid: 1)
        input.delayMilliseconds = 20
        var emitted: [String] = []
        input.onSentence = { text, _, _, _, _ in emitted.append(text) }
        // Nonempty document, but no extractable sentence at the leading blank line.
        let blankLine = TextSnapshot(pid: 1, bundleIdentifier: "test.input", text: "\n\n后面的句子。",
            selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(SentenceExtractor().extractSentence(from: blankLine))
        input.handle(blankLine, session: session, screen: nil)
        try await Task.sleep(for: .milliseconds(70))
        let valid = snapshot("同一句子。")
        input.handle(valid, session: session, screen: nil)
        try await Task.sleep(for: .milliseconds(70))
        input.handle(valid, session: session, screen: nil)
        try await Task.sleep(for: .milliseconds(70))
        input.reset()
        let log = capturedLines(after: boundary)
        XCTAssertEqual(emitted, ["同一句子。"])
        XCTAssertEqual(count("debounce elapsed", in: log), 3)
        XCTAssertEqual(count("sentence skipped reason=extraction_empty", in: log), 1)
        XCTAssertEqual(count("sentence skipped reason=sentence_deduplicated", in: log), 1)
        XCTAssertEqual(count("debounce cancelled", in: log), 0)
    }

    func testMappedSnapshotRecordsReportedAndMappedUTF16Metadata() throws {
        let boundary = beginLogCapture(), fixture = AXFixture(), monitor = fixture.monitor()
        let first = "第一行🧑‍💻内容。\n", padding = String(repeating: "垫片行内容需要足够长。\n", count: 3)
        let prefix = first + padding + "第二行内容。\n"
        fixture.hostText = prefix + "第三行光标所在"
        fixture.text = first + "\n" + padding + "第二行内容。\n第三行光标所在"
        let caret = prefix.utf16.count + 1
        fixture.selected = NSRange(location: caret, length: 0)
        var captured: TextSnapshot?, capturedSession: InputSessionID?
        monitor.onSnapshot = { value, session, _ in captured = value; capturedSession = session }
        monitor.readSnapshot()
        let sample = try XCTUnwrap(captured), session = try XCTUnwrap(capturedSession)
        XCTAssertEqual(sample.selectedRange?.location, caret + 1)
        let log = capturedLines(after: boundary)
        let entry = try XCTUnwrap(log.first { $0.contains("snapshot captured") })
        XCTAssertTrue(entry.contains("session=\(session.token.uuidString)"))
        XCTAssertTrue(entry.contains("composingReadable=true composing=false"))
        XCTAssertTrue(entry.contains("utf16Length=\(fixture.text!.utf16.count)"))
        XCTAssertTrue(entry.contains("reportedStart=\(caret) reportedLength=0"))
        XCTAssertTrue(entry.contains("mappedStart=\(caret + 1) mappedLength=0"))
        XCTAssertFalse(entry.contains("第三行"))
        XCTAssertFalse(entry.contains("🧑‍💻"))
    }

    func testMappingAndCorroborationFailuresAreDistinctAndRecoverable() {
        let boundary = beginLogCapture(), fixture = AXFixture(), monitor = fixture.monitor()
        fixture.selected = NSRange(location: 8, length: 0)
        fixture.text = "供应商进度沟通。。\n后续内容"
        fixture.hostText = fixture.text
        var emitted = 0
        monitor.onSnapshot = { _, _, _ in emitted += 1 }
        monitor.readSnapshot()
        fixture.hostText = "供应商进度沟通。啊后续内容"
        monitor.readSnapshot()
        monitor.readSnapshot()
        fixture.hostText = "完全不同的锚窗文字。后续内容"
        monitor.readSnapshot()
        monitor.readSnapshot()
        fixture.anchorReadResult = .unavailable(.cannotComplete)
        monitor.readSnapshot()
        monitor.readSnapshot()
        fixture.anchorReadResult = nil
        fixture.hostText = fixture.text
        monitor.readSnapshot()
        fixture.anchorReadResult = .budgetExhausted
        monitor.readSnapshot()
        let log = capturedLines(after: boundary)
        XCTAssertEqual(emitted, 2)
        XCTAssertEqual(count("input sample blocked reason=post_caret_mismatch", in: log), 1)
        XCTAssertEqual(count("input sample blocked reason=mapping_not_found", in: log), 1)
        XCTAssertEqual(count("input sample blocked reason=anchor_read_failed", in: log), 2)
        XCTAssertEqual(count("input sample recovered reason=anchor_read_failed", in: log), 1)
        XCTAssertEqual(count("input session reset reason=post_caret_mismatch", in: log), 1)
        XCTAssertEqual(count("input session reset reason=mapping_not_found", in: log), 1)
        XCTAssertEqual(count("input session reset reason=anchor_read_failed", in: log), 2)
        XCTAssertEqual(count("anchor caret=", in: log), 1, "Repeated invalidation must not repeat identical geometry logs")
    }

    func testPrivateInputAnchorAndCredentialsNeverReachRingFileOrReport() async throws {
        let defaults = UserDefaults.standard, previousFlag = defaults.object(forKey: "debugLogEnabled")
        let logURL = URL(fileURLWithPath: "/tmp/runwu-debug.log")
        let previousLog = try? Data(contentsOf: logURL)
        let previousAttributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        defer {
            if let previousFlag { defaults.set(previousFlag, forKey: "debugLogEnabled") }
            else { defaults.removeObject(forKey: "debugLogEnabled") }
            if let previousLog {
                try? previousLog.write(to: logURL, options: .atomic)
                if let previousAttributes { try? FileManager.default.setAttributes(previousAttributes, ofItemAtPath: logURL.path) }
            } else { try? FileManager.default.removeItem(at: logURL) }
        }
        defaults.set(true, forKey: "debugLogEnabled")
        let boundary = beginLogCapture(), fixture = AXFixture(), input = InputCoordinator(), monitor = fixture.monitor()
        let privateText = "正文_INPUT_PRIVATE_SENTINEL", privateAnchor = "锚窗_ANCHOR_PRIVATE_SENTINEL"
        let privateKey = "sk-INPUT_PRIVATE_SENTINEL", privateTranslation = "译文_TRANSLATION_PRIVATE_SENTINEL"
        let privateLabel = "标签_LABEL_PRIVATE_SENTINEL"
        fixture.text = privateText + privateKey + privateTranslation + "🧑‍💻。"
        fixture.label = privateLabel
        fixture.selected = NSRange(location: 24, length: 0)
        input.delayMilliseconds = 20
        connect(monitor, to: input)
        monitor.readSnapshot()
        fixture.marked = NSRange(location: 2, length: 2)
        monitor.readSnapshot()
        fixture.markedReadResult = .unavailable(.cannotComplete)
        monitor.readSnapshot()
        fixture.markedReadResult = nil; fixture.marked = nil
        fixture.hostText = privateAnchor
        monitor.readSnapshot()
        fixture.anchorReadResult = .unavailable(.failure)
        monitor.readSnapshot()
        fixture.anchorReadResult = nil; fixture.hostText = nil
        monitor.readSnapshot()
        try await Task.sleep(for: .milliseconds(70))
        input.reset()
        let log = capturedLines(after: boundary)
        let file = try String(contentsOf: logURL, encoding: .utf8)
        let report = DiagnosticsReport.render(snapshot: reportSnapshot(), recentLog: DiagnosticLog.recentLines(),
            debugLogExists: true, debugLogTail: DiagnosticLog.debugFileTail())
        for surface in [DiagnosticLog.recentLines().joined(), file, report] {
            for privateValue in [privateText, privateAnchor, privateKey, privateTranslation, privateLabel] {
                XCTAssertFalse(surface.contains(privateValue))
            }
            for reason in ["composing", "composition_unreadable", "mapping_not_found", "anchor_read_failed"] {
                XCTAssertTrue(surface.contains("reason=\(reason)"))
            }
        }
        XCTAssertEqual(count("debounce cancelled reason=composing", in: log), 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPostReadQualificationFailureKeepsItsCauseAfterSessionRotation() async throws {
        let boundary = beginLogCapture(), fixture = AXFixture(), input = InputCoordinator()
        var access = fixture.access(), rejectAfterRead = false
        let originalRead = access.readAttribute
        access.readAttribute = { element, key in
            let result = originalRead(element, key)
            if rejectAfterRead, key == kAXValueAttribute as String {
                fixture.secureElement = fixture.first
            }
            return result
        }
        let monitor = AccessibilityMonitor(access: access, currentApplication: {
            MonitoredApplication(pid: fixture.pid, bundleID: fixture.bundleID)
        }, screenFrames: { fixture.screens })
        input.delayMilliseconds = 20
        defer { input.reset() }
        monitor.onFocusChanged = { input.reset() }
        var snapshots = 0, emitted = 0
        monitor.onSnapshot = { snapshot, session, screen in
            snapshots += 1
            input.handle(snapshot, session: session, screen: screen)
        }
        input.onSentence = { _, _, _, _, _ in emitted += 1 }
        monitor.readSnapshot()
        let contentReads = fixture.contentReads
        rejectAfterRead = true
        monitor.readSnapshot()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(fixture.contentReads, contentReads + 1, "Qualification changes only after the actual AXValue read")
        XCTAssertEqual(snapshots, 1, "The newly protected sample must still be rejected")
        XCTAssertEqual(emitted, 0, "Qualification failure must retain the existing pending cancellation behavior")
        let log = capturedLines(after: boundary)
        XCTAssertEqual(count("input sample blocked reason=content_qualification_failed", in: log), 1)
        XCTAssertEqual(count("input session reset reason=content_qualification_failed", in: log), 1)
        XCTAssertEqual(count("input sample blocked reason=session_changed", in: log), 0,
            "A session rotation inside permitsContent must not relabel its qualification failure")
        XCTAssertEqual(count("debounce cancelled reason=reset", in: log), 1)
    }

    func testPostReadReentrantSessionChangeShortCircuitsQualification() throws {
        let boundary = beginLogCapture(), fixture = AXFixture()
        var access = fixture.access(), stopDuringRead = false
        weak var activeMonitor: AccessibilityMonitor?
        var attributeReadsAtStop: Int?
        let originalRead = access.readAttribute
        access.readAttribute = { element, key in
            let result = originalRead(element, key)
            if stopDuringRead, key == kAXValueAttribute as String {
                activeMonitor?.stop()
                attributeReadsAtStop = fixture.attributeReads
            }
            return result
        }
        let monitor = AccessibilityMonitor(access: access, currentApplication: {
            MonitoredApplication(pid: fixture.pid, bundleID: fixture.bundleID)
        }, screenFrames: { fixture.screens })
        activeMonitor = monitor
        var snapshots = 0
        monitor.onSnapshot = { _, _, _ in snapshots += 1 }
        monitor.readSnapshot()
        let contentReads = fixture.contentReads
        stopDuringRead = true
        monitor.readSnapshot()
        XCTAssertEqual(fixture.contentReads, contentReads + 1)
        XCTAssertEqual(snapshots, 1, "A session invalidated reentrantly during the read must not emit")
        XCTAssertEqual(fixture.attributeReads, try XCTUnwrap(attributeReadsAtStop),
            "The failed session check must short circuit the post-read qualification calls")
        let log = capturedLines(after: boundary)
        XCTAssertEqual(count("input sample blocked reason=session_changed", in: log), 1)
        XCTAssertEqual(count("input sample blocked reason=content_qualification_failed", in: log), 0)
    }

    private func connect(_ monitor: AccessibilityMonitor, to input: InputCoordinator) {
        monitor.onFocusChanged = { input.reset() }
        monitor.onSnapshot = { input.handle($0, session: $1, screen: $2) }
    }

    private func snapshot(_ text: String) -> TextSnapshot {
        TextSnapshot(pid: 1, bundleIdentifier: "test.input", text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0))
    }

    private func beginLogCapture() -> String {
        let boundary = "input diagnostic boundary session=\(UUID().uuidString)"
        DiagnosticLog.write(boundary)
        return boundary
    }

    private func capturedLines(after boundary: String) -> [String] {
        let lines = DiagnosticLog.recentLines()
        guard let index = lines.firstIndex(where: { $0.contains(boundary) }) else {
            XCTFail("Test boundary must remain inside the existing diagnostic ring")
            return []
        }
        return Array(lines.dropFirst(index + 1))
    }

    private func count(_ event: String, in lines: [String]) -> Int {
        lines.filter { $0.contains(event) }.count
    }

    private func reportSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(appVersion: "test", appBuild: "1", bundleID: "com.comeg.runwu",
            installPath: "/test/润物.app", installNeedsHealing: false, osVersion: "test", hardwareModel: "test",
            machine: "arm64", accessibilityTrusted: false, monitorRunning: false, probeLine: "test",
            weChatVersion: nil, enabled: true, timingRaw: "pause", speedMilliseconds: 450,
            sourceLanguage: "zh", targetLanguage: "en", backendRaw: "local", llmModelCount: 0,
            uiLanguage: "zh", clipboardEnabled: false, clipboardTriggerRaw: "hotkey", excludedBundleIDs: [],
            generatedAt: Date())
    }
}
