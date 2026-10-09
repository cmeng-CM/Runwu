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
    private var focusedRequiresExplicitFocus = false
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
        var authoritative = false
        if let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            candidate = (raw as! AXUIElement)
            authoritative = true
        } else {
            let point = InputScreenLayout(frames: screenFrames()).axPoint(NSEvent.mouseLocation)
            if let hit = reader.access.hitTest(point), reader.safe(hit, pid: app.pid),
                reader.access.attribute(hit, kAXFocusedAttribute as String) as? Bool == true {
                candidate = hit
            }
        }
        let resolved = candidate.flatMap {
            reader.resolve($0, pid: app.pid, requiresExplicitFocus: !authoritative)
        }
        let isDescendant = candidate.flatMap { root in resolved.map { !CFEqual(root, $0) } } ?? false
        setFocused(resolved, requiresExplicitFocus: !authoritative || isDescendant)
    }

    private func setFocused(_ element: AXUIElement?, force: Bool = false, requiresExplicitFocus: Bool = false) {
        let same = focused == nil && element == nil
            || focused.flatMap { old in element.map { CFEqual(old, $0) } } == true
        guard force || !same || focusedRequiresExplicitFocus != requiresExplicitFocus else { return }
        unobserveField()
        focused = element
        focusedRequiresExplicitFocus = requiresExplicitFocus
        invalidateInput()
        if isRunning, let element { observeField(element) }
    }

    private func invalidateInput() {
        session = InputSessionID(pid: application?.pid ?? 0)
        lastText = nil
        lastGoodText = nil
        lastSelectedRange = nil
        lastComposing = nil
        lastAnchor = nil
        onFocusChanged?()
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
        guard let app = application, let element = focused else { return nil }
        guard currentApplication()?.pid == app.pid,
            let geometry = reader.geometry(element, pid: app.pid, bundleID: app.bundleID,
                excluded: excludedBundleIDs, layout: InputScreenLayout(frames: screenFrames()),
                requiresExplicitFocus: focusedRequiresExplicitFocus) else {
            setFocused(nil)
            return nil
        }
        guard let composing = geometry.isComposing else {
            // Reject unreadable marked state before AXValue/shortcut recovery.
            // Rotate request identity and clear dedup even for identical text.
            invalidateInput()
            guard focused.map({ CFEqual($0, element) }) == true,
                currentApplication()?.pid == app.pid else { return nil }
            lastAnchor = geometry.anchor
            onAnchorChanged?(geometry.anchor, session)
            return nil
        }
        let capturedSession = session
        // Independent geometry and composition precede text de-duplication.
        if geometry.anchor != lastAnchor {
            lastAnchor = geometry.anchor
            onAnchorChanged?(geometry.anchor, capturedSession)
        }
        guard session == capturedSession else { return nil }
        guard permitsContent(element, app: app) else { return nil }
        if force, composing { return nil }
        let read = reader.text(element)
        guard session == capturedSession, permitsContent(element, app: app) else { return nil }
        guard let text = read ?? ((force || composing) ? "" : nil) else { return nil }
        let snapshot = TextSnapshot(pid: app.pid, bundleIdentifier: app.bundleID, text: text,
            selectedRange: geometry.selectedRange, fieldFrame: geometry.anchor.fieldFrame,
            caretFrame: geometry.anchor.caretFrame, isComposing: composing)
        let point = geometry.anchor.caretFrame ?? geometry.anchor.fieldFrame
        let screen = point.flatMap { rect in NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } }
        let changed = text != lastText || geometry.selectedRange != lastSelectedRange
            || composing != lastComposing
        if !text.isEmpty, !composing { lastGoodText = text }
        lastText = text
        lastSelectedRange = geometry.selectedRange
        lastComposing = composing
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

    /// Recheck the same qualification before value reads and replacement writes;
    /// failed capabilities clear recovery/session and synchronously invalidate App work.
    private func permitsContent(_ element: AXUIElement, app: MonitoredApplication) -> Bool {
        guard currentApplication()?.pid == app.pid,
            focused.map({ CFEqual($0, element) }) == true,
            !excludedBundleIDs.contains(app.bundleID ?? ""),
            reader.eligible(element, pid: app.pid, requiresExplicitFocus: focusedRequiresExplicitFocus) else {
            setFocused(nil)
            return false
        }
        if !focusedRequiresExplicitFocus {
            // Native fields may omit AXFocused. Their authority is the app's
            // current focused element, rechecked across callbacks and writes.
            guard let focusedApp,
                let raw = reader.access.attribute(focusedApp, kAXFocusedUIElementAttribute as String),
                CFGetTypeID(raw) == AXUIElementGetTypeID(), CFEqual(raw, element) else {
                setFocused(nil)
                return false
            }
        }
        return true
    }

    func replace(sourceWithTerminator: String, translation: String, range: NSRange? = nil,
        expectedSession: InputSessionID? = nil) -> Bool {
        reader.access.beginRead()
        refreshCurrentFocus()
        guard let app = application, let element = focused else { return false }
        guard let geometry = reader.geometry(element, pid: app.pid, bundleID: app.bundleID,
            excluded: excludedBundleIDs, layout: InputScreenLayout(frames: screenFrames()),
            requiresExplicitFocus: focusedRequiresExplicitFocus) else {
            setFocused(nil)
            return false
        }
        guard let composing = geometry.isComposing else { invalidateInput(); return false }
        guard !composing, expectedSession == nil || expectedSession == session else { return false }
        if let range {
            guard let caret = geometry.selectedRange?.location, range.location >= 0,
                range.length >= 0, range.length <= Int.max - range.location,
                caret >= range.location, caret <= range.location + range.length else { return false }
        }
        guard permitsContent(element, app: app) else { return false }
        let current = reader.text(element)
        return FocusedFieldReplacer.replace(currentText: current, sourceWithTerminator: sourceWithTerminator,
            translation: translation, range: range) { text, caret in
            guard permitsContent(element, app: app), expectedSession == nil || expectedSession == session else { return false }
            guard reader.access.writeAttribute(element, kAXValueAttribute as String, text as CFTypeRef) == .success
            else { return false }
            guard permitsContent(element, app: app), expectedSession == nil || expectedSession == session else { return false }
            var range = CFRange(location: caret, length: 0)
            if let value = AXValueCreate(.cfRange, &range) {
                _ = reader.access.writeAttribute(element, kAXSelectedTextRangeAttribute as String, value)
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

@MainActor protocol PasteboardReading {
    var changeCount: Int { get }
    func readString() -> String?
}

/// Watches the general pasteboard for user copies. Polling `changeCount` is
/// a cheap integer comparison; the string is read only when it actually
/// changed. Used by the clipboard translation trigger.
@MainActor final class PasteboardWatcher {
    var onCopy: ((String) -> Void)?
    var permitsRead: () -> Bool = { false }
    private var timer: Timer?
    private let pasteboard: any PasteboardReading
    private var lastChangeCount: Int

    init(pasteboard: any PasteboardReading = SystemPasteboard()) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

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
        lastChangeCount = pasteboard.changeCount
    }
    func check() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard permitsRead() else { return }
        guard let text = pasteboard.readString()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        onCopy?(text)
    }
}

struct SystemPasteboard: PasteboardWriting, PasteboardReading {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func readString() -> String? { NSPasteboard.general.string(forType: .string) }
    nonisolated func writeString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
