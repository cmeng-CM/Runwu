@preconcurrency import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Foundation
import OSLog

public struct InputSessionID: Hashable, Sendable {
    public let pid: pid_t
    public let token: UUID
    public init(pid: pid_t, token: UUID = UUID()) {
        self.pid = pid
        self.token = token
    }
}

@MainActor final class InputDebouncer {
    private var task: Task<Void, Never>?
    var delay: Duration = .milliseconds(450)
    func submit(_ snapshot: TextSnapshot, action: @escaping @MainActor (TextSnapshot) -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action(snapshot)
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor final class InputCoordinator {
    private let logger = Logger(subsystem: "com.comeg.runwu", category: "pipeline")
    private let extractor = SentenceExtractor(), detector = LanguageTextDetector(), debouncer = InputDebouncer()
    private var lastSentence = "", lastSentenceKey = "", session: InputSessionID?
    private var observedSentence: ExtractedSentence?
    var isEnabled = true
    var sourceLanguage: Language = .chinese
    var excludedBundleIDs: Set<String> = []
    var delayMilliseconds: Int {
        get {
            Int(
                debouncer.delay.components.seconds * 1000 + debouncer.delay.components.attoseconds
                    / 1_000_000_000_000_000)
        }
        set { debouncer.delay = .milliseconds(newValue) }
    }
    var timing: TranslationTiming = .pause {
        didSet {
            if timing != .pause { debouncer.cancel() }
        }
    }
    var onSentence: ((String, String, InputSessionID, NSScreen?, TextSnapshot) -> Void)?, onEmpty: (() -> Void)?
    func setSourceLanguage(_ language: Language) {
        sourceLanguage = language
        reset()
    }
    func handle(_ snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?) {
        DiagnosticLog.write(
            "snapshot received bundle=\(snapshot.bundleIdentifier ?? "unknown") length=\(snapshot.text.count)")
        logger.info(
            "snapshot received bundle=\(snapshot.bundleIdentifier ?? "unknown", privacy: .public) length=\(snapshot.text.count, privacy: .public)"
        )
        guard isEnabled else { return }
        if excludedBundleIDs.contains(snapshot.bundleIdentifier ?? "") {
            logger.info("snapshot ignored excluded app")
            reset()
            return
        }
        if let previous = self.session, previous != session { reset() }
        self.session = session
        observe(snapshot)
        if snapshot.isComposing {
            debouncer.cancel()
            lastSentence = ""
            lastSentenceKey = ""
            return
        }
        if snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debouncer.cancel()
            lastSentence = ""
            lastSentenceKey = ""
            onEmpty?()
            return
        }
        switch timing {
        case .pause:
            debouncer.submit(snapshot) { [weak self] snapshot in
                guard let self, self.session == session else { return }
                self.emit(snapshot, session: session, screen: screen)
            }
        case .completeSentence:
            debouncer.cancel()
            if extractor.isComplete(snapshot) {
                emit(snapshot, session: session, screen: screen)
            }
        case .shortcut:
            debouncer.cancel()
        }
    }
    func translateNow(_ snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?) {
        guard isEnabled else { return }
        guard !snapshot.isComposing, !excludedBundleIDs.contains(snapshot.bundleIdentifier ?? "") else {
            observe(snapshot)
            debouncer.cancel()
            return
        }
        if let previous = self.session, previous != session { reset() }
        self.session = session
        observe(snapshot)
        emit(snapshot, session: session, screen: screen, force: true)
    }
    func reset() {
        debouncer.cancel()
        session = nil
        observedSentence = nil
        lastSentence = ""
        lastSentenceKey = ""
        onEmpty?()
    }

    private func observe(_ snapshot: TextSnapshot) {
        let current = snapshot.isComposing ? nil : extractor.extractSentence(from: snapshot)
        if current != observedSentence {
            observedSentence = current
            lastSentence = ""
            lastSentenceKey = ""
        }
    }

    private func emit(
        _ snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?, force: Bool = false
    ) {
        guard isEnabled, !snapshot.isComposing, !excludedBundleIDs.contains(snapshot.bundleIdentifier ?? "")
        else { return }
        guard let extracted = extractor.extractSentence(from: snapshot) else { return }
        let sentence = extracted.text
        DiagnosticLog.write(
            "debounce fired sentenceLength=\(sentence.count) source=\(sourceLanguage.rawValue) matches=\(detector.contains(sentence, language: sourceLanguage))")
        logger.info(
            "debounce fired sentenceLength=\(sentence.count, privacy: .public) source=\(self.sourceLanguage.rawValue, privacy: .public) matches=\(self.detector.contains(sentence, language: self.sourceLanguage), privacy: .public)"
        )
        guard !sentence.isEmpty, detector.contains(sentence, language: sourceLanguage) else { return }
        let sentenceKey = extracted.key(in: session)
        if !force, sentence == lastSentence, sentenceKey == lastSentenceKey { return }
        lastSentence = sentence
        lastSentenceKey = sentenceKey
        onSentence?(sentence, sentenceKey, session, screen, snapshot)
    }
}

@MainActor final class AccessibilityMonitor {
    var onSnapshot: ((TextSnapshot, InputSessionID, NSScreen?) -> Void)?
    var onAnchorChanged: ((InputAnchor, InputSessionID) -> Void)?
    var onFocusChanged: (() -> Void)?
    var excludedBundleIDs: Set<String> = []
    var sourceLanguage: Language = .chinese
    private let reader: AXFieldReader
    private let currentApplication: () -> MonitoredApplication?
    private let screenFrames: () -> [NSRect]
    private var appObserver: NSObjectProtocol?, elementObserver: AXObserver?, pollTimer: Timer?
    private var focused: AXUIElement?, focusedApp: AXUIElement?, observedWindow: AXUIElement?
    private var application: MonitoredApplication?
    private var session = InputSessionID(pid: 0)
    private var lastText: String?, lastGoodText: String?, lastSelectedRange: NSRange?, lastComposing: Bool?
    private var lastAnchor: InputAnchor?
    private(set) var isRunning = false
    private(set) var lastExternalApp: (pid: pid_t, bundleID: String)?

    init(access: AXFieldAccess = .live,
        currentApplication: @escaping () -> MonitoredApplication? = {
            NSWorkspace.shared.frontmostApplication.map {
                MonitoredApplication(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier)
            }
        }, screenFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.frame) }) {
        reader = AXFieldReader(access: access.bounded())
        self.currentApplication = currentApplication
        self.screenFrames = screenFrames
    }

    func start() {
        guard AXIsProcessTrusted() else {
            DiagnosticLog.write("AX trust check failed")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        DiagnosticLog.write("monitor starting")
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.readSnapshot() }
        }
        readSnapshot()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.readSnapshot() }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
        removeObserver()
        application = nil
        focusedApp = nil
        setFocused(nil, force: true)
        isRunning = false
    }

    private func refreshCurrentFocus() {
        guard let app = currentApplication() else {
            if application != nil {
                removeObserver()
                application = nil
                focusedApp = nil
                setFocused(nil, force: true)
            }
            return
        }
        if application?.pid != app.pid || application?.bundleID != app.bundleID {
            removeObserver()
            application = app
            focusedApp = AXUIElementCreateApplication(app.pid)
            setFocused(nil, force: true)
            if app.bundleID != Bundle.main.bundleIdentifier {
                lastExternalApp = (pid: app.pid, bundleID: app.bundleID ?? "unknown")
            }
            if !excludedBundleIDs.contains(app.bundleID ?? ""), !reader.access.secureInputActive(),
                let focusedApp {
                reader.access.enableAccessibility(focusedApp)
                if isRunning { observeApplication(focusedApp, pid: app.pid) }
            }
        }
        guard !excludedBundleIDs.contains(app.bundleID ?? ""), !reader.access.secureInputActive(),
            let focusedApp else {
            setFocused(nil)
            return
        }
        let raw = reader.access.attribute(focusedApp, kAXFocusedUIElementAttribute as String)
        var candidate: AXUIElement?
        if let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            candidate = (raw as! AXUIElement)
        } else {
            let point = InputScreenLayout(frames: screenFrames()).axPoint(NSEvent.mouseLocation)
            if let hit = reader.access.hitTest(point), reader.safe(hit, pid: app.pid),
                reader.access.attribute(hit, kAXFocusedAttribute as String) as? Bool == true {
                candidate = hit
            }
        }
        let resolved = candidate.flatMap { reader.resolve($0, pid: app.pid) }
        setFocused(resolved)
    }

    private func setFocused(_ element: AXUIElement?, force: Bool = false) {
        let same = focused == nil && element == nil
            || focused.flatMap { old in element.map { CFEqual(old, $0) } } == true
        guard force || !same else { return }
        unobserveField()
        focused = element
        session = InputSessionID(pid: application?.pid ?? 0)
        lastText = nil
        lastGoodText = nil
        lastSelectedRange = nil
        lastComposing = nil
        lastAnchor = nil
        onFocusChanged?()
        if isRunning, let element { observeField(element) }
    }

    private func observeApplication(_ element: AXUIElement, pid: pid_t) {
        guard AXObserverCreate(pid, callback, &elementObserver) == .success,
            let observer = elementObserver else { return }
        AXObserverAddNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    private static let fieldNotifications = [
        kAXValueChangedNotification as String, kAXSelectedTextChangedNotification as String,
        kAXMovedNotification as String, kAXResizedNotification as String,
        "AXLayoutChanged", "AXScrollPositionChanged",
    ]
    private static let windowNotifications = [kAXMovedNotification as String, kAXResizedNotification as String]
    private func observeField(_ element: AXUIElement) {
        guard let observer = elementObserver else { return }
        for name in Self.fieldNotifications {
            AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        if let window = reader.access.attribute(element, kAXWindowAttribute as String),
            CFGetTypeID(window) == AXUIElementGetTypeID() {
            observedWindow = (window as! AXUIElement)
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, observedWindow!, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }
    private func unobserveField() {
        guard let observer = elementObserver else { return }
        if let focused {
            for name in Self.fieldNotifications { AXObserverRemoveNotification(observer, focused, name as CFString) }
        }
        if let observedWindow {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, observedWindow, name as CFString)
            }
        }
        observedWindow = nil
    }
    private func removeObserver() {
        unobserveField()
        if let observer = elementObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        elementObserver = nil
    }

    func readSnapshot() {
        reader.access.beginRead()
        refreshCurrentFocus()
        _ = capture(force: false)
    }

    private func capture(force: Bool) -> (snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?)? {
        guard let app = application, currentApplication()?.pid == app.pid, let element = focused,
            let geometry = reader.geometry(element, pid: app.pid, bundleID: app.bundleID,
                excluded: excludedBundleIDs, layout: InputScreenLayout(frames: screenFrames())) else { return nil }
        let capturedSession = session
        // Independent geometry and composition precede text de-duplication.
        if geometry.anchor != lastAnchor {
            lastAnchor = geometry.anchor
            onAnchorChanged?(geometry.anchor, capturedSession)
        }
        guard session == capturedSession else { return nil }
        guard currentApplication()?.pid == app.pid, !excludedBundleIDs.contains(app.bundleID ?? ""),
            reader.safe(element, pid: app.pid) else {
            setFocused(nil)
            return nil
        }
        if force, geometry.isComposing { return nil }
        let read = reader.text(element)
        guard let text = read ?? ((force || geometry.isComposing) ? "" : nil) else { return nil }
        let snapshot = TextSnapshot(pid: app.pid, bundleIdentifier: app.bundleID, text: text,
            selectedRange: geometry.selectedRange, fieldFrame: geometry.anchor.fieldFrame,
            caretFrame: geometry.anchor.caretFrame, isComposing: geometry.isComposing)
        let point = geometry.anchor.caretFrame ?? geometry.anchor.fieldFrame
        let screen = point.flatMap { rect in NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } }
        let changed = text != lastText || geometry.selectedRange != lastSelectedRange
            || geometry.isComposing != lastComposing
        if !text.isEmpty, !geometry.isComposing { lastGoodText = text }
        lastText = text
        lastSelectedRange = geometry.selectedRange
        lastComposing = geometry.isComposing
        if !force, changed { onSnapshot?(snapshot, capturedSession, screen) }
        return (snapshot, capturedSession, screen)
    }

    func snapshotNow() -> (snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?)? {
        reader.access.beginRead()
        refreshCurrentFocus()
        guard let captured = capture(force: true) else { return nil }
        let recovered = ShortcutSnapshotRecovery.resolve(live: captured.snapshot,
            lastGoodText: lastGoodText, sourceLanguage: sourceLanguage)
        guard !recovered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (recovered, captured.session, captured.screen)
    }

    func diagnosticProbe() -> String {
        reader.access.beginRead()
        guard let target = lastExternalApp else { return "probe result=no_external_app_tracked" }
        guard !excludedBundleIDs.contains(target.bundleID), !reader.access.secureInputActive() else {
            return "probe target=\(target.bundleID) result=protected_target"
        }
        guard NSRunningApplication(processIdentifier: target.pid) != nil else {
            return "probe target=\(target.bundleID) result=app_not_running"
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard let raw = reader.access.attribute(app, kAXFocusedUIElementAttribute as String),
            CFGetTypeID(raw) == AXUIElementGetTypeID(),
            let field = reader.resolve(raw as! AXUIElement, pid: target.pid) else {
            return "probe target=\(target.bundleID) result=no_text_element"
        }
        let rawRole = reader.access.attribute(field, kAXRoleAttribute as String) as? String
        let knownRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        let role = rawRole.flatMap { knownRoles.contains($0) ? $0 : nil } ?? "unknown"
        return "probe target=\(target.bundleID) result=text_element_found role=\(role)"
    }

    func replace(sourceWithTerminator: String, translation: String, range: NSRange? = nil,
        expectedSession: InputSessionID? = nil) -> Bool {
        reader.access.beginRead()
        refreshCurrentFocus()
        guard let app = application, let element = focused,
            let geometry = reader.geometry(element, pid: app.pid, bundleID: app.bundleID,
                excluded: excludedBundleIDs, layout: InputScreenLayout(frames: screenFrames())),
            !geometry.isComposing, expectedSession == nil || expectedSession == session else { return false }
        if let range {
            guard let caret = geometry.selectedRange?.location, range.location >= 0,
                range.length >= 0, range.length <= Int.max - range.location,
                caret >= range.location, caret <= range.location + range.length else { return false }
        }
        guard currentApplication()?.pid == app.pid, reader.safe(element, pid: app.pid) else { return false }
        let current = reader.text(element)
        return FocusedFieldReplacer.replace(currentText: current, sourceWithTerminator: sourceWithTerminator,
            translation: translation, range: range) { text, caret in
            guard currentApplication()?.pid == app.pid, expectedSession == nil || expectedSession == session,
                reader.safe(element, pid: app.pid) else { return false }
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
            else { return false }
            var range = CFRange(location: caret, length: 0)
            if let value = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            lastText = text
            lastGoodText = text
            lastSelectedRange = NSRange(location: caret, length: 0)
            return true
        }
    }
}

private func callback(
    _ observer: AXObserver?, _ element: AXUIElement?, _ notification: CFString?, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let address = UInt(bitPattern: refcon)
    let name = notification as String? ?? ""
    MainActor.assumeIsolated {
        Unmanaged<AccessibilityMonitor>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).takeUnretainedValue()
            .readForCallback(name)
    }
}
extension AccessibilityMonitor {
    fileprivate func readForCallback(_ name: String) {
        readSnapshot()
    }
}

enum TranslationClipboard {
    static func copy(_ text: String?) -> Bool {
        copy(text, using: SystemPasteboard())
    }

    static func copy(_ text: String?, using pasteboard: PasteboardWriting) -> Bool {
        guard let text, !text.isEmpty else { return false }
        pasteboard.writeString(text)
        return true
    }
}

protocol PasteboardWriting {
    func writeString(_ text: String)
}

/// Watches the general pasteboard for user copies. Polling `changeCount` is
/// a cheap integer comparison; the string is read only when it actually
/// changed. Used by the clipboard translation trigger.
@MainActor final class PasteboardWatcher {
    var onCopy: ((String) -> Void)?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    func start(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        resyncBaseline()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    /// Aligns the baseline with the current pasteboard so an app-initiated
    /// copy (the overlay copy button) does not trigger a translation.
    func resyncBaseline() {
        lastChangeCount = NSPasteboard.general.changeCount
    }
    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        onCopy?(text)
    }
}

struct SystemPasteboard: PasteboardWriting {
    func writeString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
