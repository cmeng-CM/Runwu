import AppKit
import ApplicationServices
import XCTest
@testable import Pico

@MainActor final class FocusedEditableInputTests: XCTestCase {
    func testFinderDirectoryDoesNotReadFirstUnfocusedReadonlyFilename() {
        let fixture = EditableFixture()
        fixture.focus = fixture.container
        fixture.nodes[fixture.container] = .init(role: "AXBrowser", children: [fixture.first, fixture.second])
        fixture.nodes[fixture.first] = .init(role: "AXTextField", focused: false, editable: false, text: "01-参考资料")
        fixture.nodes[fixture.second] = .init(role: "AXTextField", focused: false, editable: false, text: "80-code", selected: true)
        let monitor = fixture.monitor()
        var emitted = 0
        monitor.onSnapshot = { _, _, _ in emitted += 1 }
        monitor.readSnapshot()
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertEqual(fixture.contentReads.count, 0)
        XCTAssertEqual(emitted, 0)
    }

    func testReadonlyAndDisabledOverrideAllStandardTextRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            for disabled in [false, true] {
                let fixture = EditableFixture()
                fixture.nodes[fixture.first] = .init(role: role, focused: true,
                    editable: disabled ? true : false, enabled: !disabled, text: "只读文本。")
                let monitor = fixture.monitor()
                monitor.readSnapshot()
                XCTAssertNil(monitor.snapshotNow(), "\(role) readonly/disabled")
                XCTAssertFalse(monitor.replace(sourceWithTerminator: "只读文本。", translation: "Readonly."))
                XCTAssertTrue(fixture.contentReads.isEmpty)
            }
        }
    }

    func testDescendantRequiresExplicitFocusAndReadsOnlyFocusedEditor() throws {
        let fixture = EditableFixture()
        fixture.focus = fixture.container
        fixture.nodes[fixture.container] = .init(role: "AXGroup", children: [fixture.first, fixture.second])
        fixture.nodes[fixture.first] = .init(role: "AXTextField", focused: false, editable: true, text: "不应读取。")
        fixture.nodes[fixture.second] = .init(role: "AXTextArea", focused: true, editable: true, text: "真正输入。")
        let sample = try XCTUnwrap(fixture.monitor().snapshotNow())
        XCTAssertEqual(sample.snapshot.text, "真正输入。")
        XCTAssertEqual(fixture.contentReads, [fixture.second])
    }
    func testUnfocusedSafeWrappersReachOnlyFocusedEditableDescendant() throws {
        let (fixture, _, _) = wrappedFixture()
        let monitor = fixture.monitor()
        let sample = try XCTUnwrap(monitor.snapshotNow())
        XCTAssertEqual(sample.snapshot.text, "真正输入。")
        XCTAssertEqual(fixture.contentReads, [fixture.first])
        XCTAssertTrue(monitor.replace(sourceWithTerminator: "真正输入。", translation: "Actual input.",
            expectedSession: sample.session))
        XCTAssertEqual(fixture.writes, ["AXValue", "AXSelectedTextRange"])
    }

    func testUnfocusedWrapperTraversalKeepsRootEditorAndSafetyVetoes() {
        for mode in 0..<10 {
            let (fixture, wrapper, _) = wrappedFixture()
            switch mode {
            case 0: fixture.nodes[fixture.container]?.focused = false
            case 1: fixture.nodes[fixture.first]?.focused = false
            case 2: fixture.nodes[wrapper]?.editable = false
            case 3: fixture.nodes[wrapper]?.enabled = false
            case 4: fixture.nodes[wrapper]?.protected = true
            case 5: fixture.nodes[wrapper]?.role = "AXSecureTextField"
            case 6: fixture.nodes[wrapper]?.pid = 999
            case 7: fixture.nodes[wrapper]?.attributeResults["AXFocused"] = .unavailable(.cannotComplete)
            case 8: fixture.nodes[wrapper]?.attributeResults["AXEditable"] = .value("invalid" as CFString)
            default: fixture.nodes[wrapper]?.attributeResults["AXEnabled"] = .budgetExhausted
            }
            let monitor = fixture.monitor()
            XCTAssertNil(monitor.snapshotNow(), "wrapper veto mode \(mode)")
            XCTAssertFalse(monitor.replace(sourceWithTerminator: "真正输入。", translation: "Input."))
            XCTAssertTrue(fixture.contentReads.isEmpty)
            XCTAssertTrue(fixture.writes.isEmpty)
        }
    }

    private func wrappedFixture() -> (EditableFixture, AXUIElement, AXUIElement) {
        let fixture = EditableFixture()
        let outer = AXUIElementCreateApplication(944), inner = AXUIElementCreateApplication(945)
        fixture.focus = fixture.container
        fixture.nodes[fixture.container] = .init(role: "AXGroup", children: [outer])
        fixture.nodes[outer] = .init(role: "AXGroup", focused: false, children: [inner])
        fixture.nodes[inner] = .init(role: "AXGroup", focused: false, children: [fixture.second, fixture.first])
        fixture.nodes[fixture.second] = .init(role: "AXTextField", focused: false, editable: true, text: "不应读取。")
        fixture.nodes[fixture.first] = .init(role: "AXTextField", focused: true, editable: true, text: "真正输入。")
        return (fixture, outer, inner)
    }

    func testNativeSearchRenameOptionalMetadataAndWebEditorsRemainUsableWithoutCaret() throws {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup"] {
            let fixture = EditableFixture()
            let web = role == "AXGroup"
            fixture.nodes[fixture.first] = .init(role: role, focused: nil, editable: web ? true : nil,
                text: "真正输入。")
            let monitor = fixture.monitor()
            let sample = try XCTUnwrap(monitor.snapshotNow())
            XCTAssertEqual(sample.snapshot.text, "真正输入。")
            XCTAssertNil(sample.snapshot.caretFrame)
            XCTAssertNil(sample.snapshot.selectedRange)
            XCTAssertTrue(monitor.replace(sourceWithTerminator: "真正输入。", translation: "Actual input.",
                expectedSession: sample.session))
            XCTAssertEqual(fixture.writes, ["AXValue", "AXSelectedTextRange"])
        }
    }

    func testMissingFocusedDescendantAndExplicitFalseOriginalFocusNeverReadText() {
        for descendant in [false, true] {
            let fixture = EditableFixture()
            fixture.nodes[fixture.first]?.focused = descendant ? nil : false
            if descendant {
                fixture.focus = fixture.container
                fixture.nodes[fixture.container] = .init(role: "AXGroup", children: [fixture.first])
            }
            let monitor = fixture.monitor()
            XCTAssertNil(monitor.snapshotNow())
            XCTAssertTrue(fixture.contentReads.isEmpty)
            XCTAssertFalse(monitor.replace(sourceWithTerminator: "合成输入。", translation: "Input."))
            XCTAssertTrue(fixture.writes.isEmpty)
        }
    }

    func testQualificationErrorsMalformedValuesAndBudgetNeverReadOrWriteContent() {
        for key in ["AXFocused", "AXEditable", "AXEnabled"] {
            let failures: [AXAttributeResult] = [.unavailable(.cannotComplete), .unavailable(.failure),
                .unavailable(.apiDisabled), .unavailable(.invalidUIElement), .budgetExhausted,
                .value("invalid boolean" as CFString), .value(NSNumber(value: 1))]
            for failure in failures {
                let fixture = EditableFixture()
                fixture.results[key] = failure
                let monitor = fixture.monitor()
                XCTAssertNil(monitor.snapshotNow())
                XCTAssertFalse(monitor.replace(sourceWithTerminator: "合成输入。", translation: "Input."))
                XCTAssertTrue(fixture.contentReads.isEmpty)
                XCTAssertTrue(fixture.writes.isEmpty)
            }
        }
        let slow = EditableFixture()
        slow.readCost = 0.04
        XCTAssertNil(slow.monitor().snapshotNow())
        XCTAssertTrue(slow.contentReads.isEmpty)
        XCTAssertLessThanOrEqual(slow.metadataReads, 4)
    }

    func testOptionalMetadataUnsupportedNoValueRetainsNativeRoleCompatibility() throws {
        for error in [AXError.attributeUnsupported, .noValue] {
            let fixture = EditableFixture()
            for key in ["AXFocused", "AXEditable", "AXEnabled"] { fixture.errors[key] = error }
            XCTAssertNotNil(fixture.monitor().snapshotNow())
        }
    }

    func testQualificationChangeClearsCacheCancelsDebounceAndRecoversIdenticalTextInNewSession() async throws {
        for key in ["AXEditable", "AXFocused", "AXEnabled"] {
            let fixture = EditableFixture(), monitor = fixture.monitor(), input = InputCoordinator()
            input.delayMilliseconds = 15
            var emitted: [InputSessionID] = []
            monitor.onFocusChanged = { input.reset() }
            monitor.onSnapshot = { input.handle($0, session: $1, screen: $2) }
            input.onSentence = { _, _, session, _, _ in emitted.append(session) }
            monitor.readSnapshot()
            let old = try XCTUnwrap(monitor.snapshotNow()).session
            let reads = fixture.contentReads.count
            fixture.results[key] = .value(kCFBooleanFalse!)
            monitor.readSnapshot()
            XCTAssertNil(monitor.snapshotNow())
            XCTAssertEqual(fixture.contentReads.count, reads)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(emitted.isEmpty)
            fixture.results.removeValue(forKey: key)
            monitor.readSnapshot()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(emitted.count, 1)
            XCTAssertNotEqual(emitted.first, old)
        }
    }

    func testRecheckAfterGeometryAndBeforeReplacementWriteAlsoStopsExpiredBudget() throws {
        let fixture = EditableFixture(), monitor = fixture.monitor()
        monitor.onAnchorChanged = { _, _ in fixture.nodes[fixture.first]?.editable = false }
        XCTAssertNil(monitor.snapshotNow())
        XCTAssertTrue(fixture.contentReads.isEmpty)
        for budget in [false, true] {
            let fixture = EditableFixture(), monitor = fixture.monitor()
            let session = try XCTUnwrap(monitor.snapshotNow()).session
            fixture.contentReads.removeAll()
            fixture.afterContentRead = {
                if budget { fixture.time += 1 } else { fixture.nodes[fixture.first]?.editable = false }
            }
            XCTAssertFalse(monitor.replace(sourceWithTerminator: "合成输入。", translation: "Input.", expectedSession: session))
            XCTAssertEqual(fixture.contentReads.count, 1)
            XCTAssertTrue(fixture.writes.isEmpty)
            fixture.afterContentRead = nil
            fixture.nodes[fixture.first]?.text = ""
            XCTAssertNil(monitor.snapshotNow(), "Invalid qualification must clear old recovery text")
        }
        let writeChange = EditableFixture(), writeMonitor = writeChange.monitor()
        writeChange.afterWrite = { writeChange.nodes[writeChange.first]?.focused = false }
        XCTAssertFalse(writeMonitor.replace(sourceWithTerminator: "合成输入。", translation: "Input."))
        XCTAssertEqual(writeChange.writes, ["AXValue"], "Recheck focus before the second selection write")
    }

    func testNativeMissingFocusMetadataRechecksAppAuthorityBeforeReadAndWrite() throws {
        for write in [false, true] {
            let fixture = EditableFixture(), monitor = fixture.monitor()
            fixture.nodes[fixture.first]?.focused = nil
            fixture.nodes[fixture.second] = .init(role: "AXTextField", focused: nil, editable: nil)
            if write {
                fixture.afterContentRead = { fixture.focus = fixture.second }
                XCTAssertFalse(monitor.replace(sourceWithTerminator: "合成输入。", translation: "Input."))
                XCTAssertEqual(fixture.contentReads.count, 1)
                XCTAssertTrue(fixture.writes.isEmpty)
            } else {
                monitor.onAnchorChanged = { _, _ in fixture.focus = fixture.second }
                XCTAssertNil(monitor.snapshotNow())
                XCTAssertTrue(fixture.contentReads.isEmpty)
            }
        }
    }

    func testFinderDirectoryDoesNotRequestTranslationInAnyTimingMode() async throws {
        for timing in [TranslationTiming.pause, .completeSentence, .shortcut] {
            let fixture = EditableFixture(), monitor = fixture.monitor(), input = InputCoordinator()
            fixture.focus = fixture.container
            fixture.nodes[fixture.container] = .init(role: "AXOutline", children: [fixture.first])
            fixture.nodes[fixture.first]?.editable = false
            fixture.nodes[fixture.first]?.focused = false
            input.timing = timing; input.delayMilliseconds = 10
            var requests = 0
            input.onSentence = { _, _, _, _, _ in requests += 1 }
            monitor.onSnapshot = { input.handle($0, session: $1, screen: $2) }
            monitor.onFocusChanged = { input.reset() }
            monitor.readSnapshot()
            if let snapshot = monitor.snapshotNow() {
                input.translateNow(snapshot.snapshot, session: snapshot.session, screen: snapshot.screen)
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(requests, 0)
            XCTAssertTrue(fixture.contentReads.isEmpty)
        }
    }

    func testRealAppRejectsLateReplyWhenSameFieldBecomesReadonlyOrQualificationFails() async throws {
        _ = NSApplication.shared
        for failure in [AXAttributeResult.value(kCFBooleanFalse!), .unavailable(.cannotComplete)] {
            let fixture = EditableFixture(), monitor = fixture.monitor()
            let suite = "FocusedEditableApp.\(UUID())", defaults = UserDefaults(suiteName: suite)!
            let settings = SettingsStore(defaults: defaults, modelKeyStorage: EditableKeys())
            settings.overlayFollowCaret = false; settings.neverHide = true
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let engine = EditableGate()
            let app = AppState(settings: settings, translationEngine: engine,
                historyDatabaseURL: directory.appendingPathComponent("h.sqlite"), startRuntime: false)
            defer {
                app.input.reset(); app.overlay.hide(); defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            app.input.delayMilliseconds = 10
            monitor.onSnapshot = app.monitor.onSnapshot
            monitor.onFocusChanged = app.monitor.onFocusChanged
            monitor.onAnchorChanged = app.monitor.onAnchorChanged
            monitor.readSnapshot()
            for _ in 0..<200 { if await engine.started { break }; try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(app.hasPendingTranslationAction)
            let reads = fixture.contentReads.count
            fixture.results["AXEditable"] = failure
            monitor.readSnapshot()
            XCTAssertFalse(app.hasPendingTranslationAction)
            XCTAssertEqual(fixture.contentReads.count, reads)
            await engine.complete()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(app.overlay.cardContents.isEmpty)
            XCTAssertTrue(app.history.entries.isEmpty)
            fixture.results.removeValue(forKey: "AXEditable")
            monitor.readSnapshot()
            for _ in 0..<200 { if app.history.entries.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(app.history.entries.count, 1)
        }
    }

}

@MainActor private final class EditableFixture {
    struct Node {
        var role: String
        var focused: Bool? = nil
        var editable: Bool? = nil
        var enabled: Bool? = true
        var text: String = "合成输入。"
        var selected: Bool = false
        var children: [AXUIElement] = []
        var protected = false
        var pid: pid_t = 940
        var attributeResults: [String: AXAttributeResult] = [:]
    }
    let pid: pid_t = 940
    let first = AXUIElementCreateApplication(941), second = AXUIElementCreateApplication(942)
    let container = AXUIElementCreateApplication(943)
    var focus: AXUIElement?
    var nodes: [AXUIElement: Node] = [:]
    var errors: [String: AXError] = [:]
    var results: [String: AXAttributeResult] = [:]
    var writes: [String] = []
    var metadataReads = 0
    var time: TimeInterval = 0, readCost: TimeInterval = 0
    var afterContentRead: (() -> Void)?
    var afterWrite: (() -> Void)?
    var selectedRange: NSRange?
    var contentReads: [AXUIElement] = []
    init() { focus = first; nodes[first] = .init(role: "AXTextField", focused: true, editable: true) }
    func monitor() -> AccessibilityMonitor {
        AccessibilityMonitor(access: access().bounded(now: { [self] in time }), currentApplication: {
            MonitoredApplication(pid: 940, bundleID: "com.apple.finder")
        }, screenFrames: { [NSRect(x: 0, y: 0, width: 1400, height: 900)] })
    }
    func access() -> AXFieldAccess {
        AXFieldAccess(readAttribute: { [self] element, key in
            metadataReads += 1; time += readCost
            if let result = results[key] { return result }
            if let error = errors[key] { return .unavailable(error) }
            if key == "AXFocusedUIElement" { return focus.map(AXAttributeResult.value) ?? .unavailable(.noValue) }
            guard let node = nodes[element] else { return .unavailable(.invalidUIElement) }
            if let result = node.attributeResults[key] { return result }
            var value: CFTypeRef?
            switch key {
            case "AXRole": value = node.role as CFString
            case "AXSubrole": value = "" as CFString
            case "AXProtectedContent": value = node.protected ? kCFBooleanTrue : kCFBooleanFalse
            case "AXFocused": value = node.focused.map { $0 ? kCFBooleanTrue! : kCFBooleanFalse! }
            case "AXEditable": value = node.editable.map { $0 ? kCFBooleanTrue! : kCFBooleanFalse! }
            case "AXEnabled": value = node.enabled.map { $0 ? kCFBooleanTrue! : kCFBooleanFalse! }
            case "AXSelected": value = node.selected ? kCFBooleanTrue : kCFBooleanFalse
            case "AXChildren": value = node.children as CFArray
            case "AXSelectedTextRange":
                if let selectedRange {
                    var range = CFRange(location: selectedRange.location, length: selectedRange.length)
                    value = AXValueCreate(.cfRange, &range)
                }
            case "AXValue":
                contentReads.append(element); value = node.text as CFString
                afterContentRead?()
            default: break
            }
            return value.map(AXAttributeResult.value) ?? .unavailable(.attributeUnsupported)
        }, parameterized: { _, _, _ in nil }, pid: { [self] in nodes[$0]?.pid ?? 940 },
            secureInputActive: { false }, enableAccessibility: { _ in }, hitTest: { _ in nil },
            writeAttribute: { [self] element, key, value in
                writes.append(key)
                if key == "AXValue", let text = value as? String { nodes[element]?.text = text }
                afterWrite?()
                return .success
            })
    }
}

private struct EditableKeys: ModelKeyStoring {
    func apiKey(forModelID id: UUID) throws -> String? { nil }
    func setAPIKey(_ value: String?, forModelID id: UUID) throws {}
    func deleteAPIKey(forModelID id: UUID) throws {}
}
private actor EditableGate: TranslationEngine {
    private(set) var started = false
    private var continuation: CheckedContinuation<String, Never>?
    private var calls = 0
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        calls += 1
        if calls > 1 { return "Recovered." }
        return await withCheckedContinuation { continuation = $0; started = true }
    }
    func complete() { continuation?.resume(returning: "Late."); continuation = nil }
}
