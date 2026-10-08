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
    }
}

/// Real CF AX handles plus injected remote replies exercise the monitor and
/// reader without contacting processes, granting AX or changing user settings.
@MainActor
private final class AXFixture {
    let pid: pid_t = 700
    let bundleID = "test.input"
    let first = AXUIElementCreateApplication(701), second = AXUIElementCreateApplication(702)
    let container = AXUIElementCreateApplication(703), foreign = AXUIElementCreateApplication(704)
    var focused: AXUIElement?, hit: AXUIElement?, secureElement: AXUIElement?
    var secureInput = false, hitFocused = true
    var text: String? = "我今天会晚一点。"
    var label: String?
    var errors: [String: AXError] = [:]
    var selected = NSRange(location: 5, length: 0), marked: NSRange?
    var direct: NSRect? = NSRect(x: 220, y: 150, width: 1, height: 20)
    var previous: NSRect?, next: NSRect?, marker: NSRect?
    var field = NSRect(x: 100, y: 100, width: 400, height: 200)
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
            case "AXFocused": return hitFocused ? kCFBooleanTrue : kCFBooleanFalse
            case "AXChildren":
                childReads += 1; return [first] as CFArray
            case "AXSelectedTextRange": return Self.range(selected)
            case "AXTextInputMarkedRange": return marked.map(Self.range)
            case "AXPosition":
                var point = field.origin; return AXValueCreate(.cgPoint, &point)
            case "AXSize":
                var size = field.size; return AXValueCreate(.cgSize, &size)
            case "AXValue":
                contentReads += 1; return text.map { $0 as CFString }
            case "AXNumberOfCharacters": return NSNumber(value: text?.utf16.count ?? 0)
            case "AXSelectedTextMarkerRange": return marker == nil ? nil : NSNumber(value: 1)
            default: return nil
            }
        }
        return AXFieldAccess(readAttribute: { [self] element, key in
            if let error = errors[key] { return .unavailable(error) }
            return attribute(element, key).map(AXAttributeResult.value) ?? .unavailable(.attributeUnsupported)
        }, parameterized: { [self] _, key, parameter in
            if key == "AXBoundsForTextMarkerRange" { return marker.map(Self.rect) }
            if key == kAXBoundsForRangeParameterizedAttribute as String {
                var range = CFRange()
                guard CFGetTypeID(parameter) == AXValueGetTypeID(),
                    AXValueGetValue(parameter as! AXValue, .cfRange, &range) else { return nil }
                if range.length == 0 { return direct.map(Self.rect) }
                return (range.location == selected.location - 1 ? previous : next).map(Self.rect)
            }
            return nil
        }, pid: { [self] in CFEqual($0, foreign) ? 900 : pid },
        secureInputActive: { [self] in secureInput }, enableAccessibility: { _ in },
        hitTest: { [self] _ in hit })
    }
    static func range(_ value: NSRange) -> AXValue {
        var range = CFRange(location: value.location, length: value.length)
        return AXValueCreate(.cfRange, &range)!
    }
    static func rect(_ value: NSRect) -> AXValue {
        var value = value; return AXValueCreate(.cgRect, &value)!
    }
}
