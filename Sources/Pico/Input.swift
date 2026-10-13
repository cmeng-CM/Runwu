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
    // Diagnostic only: the Task reference outlives its deadline in the existing
    // implementation, so its presence cannot establish a real pending cancel.
    private var pendingDiagnosticFields: String?
    var delay: Duration = .milliseconds(450)
    func submit(_ snapshot: TextSnapshot, session: InputSessionID,
        action: @escaping @MainActor (TextSnapshot) -> Void) {
        recordCancellation(reason: .snapshotReplaced)
        task?.cancel()
        let fields = InputDiagnostic.identity(bundle: snapshot.bundleIdentifier, session: session)
        pendingDiagnosticFields = fields
        let milliseconds = delay.components.seconds * 1000 + delay.components.attoseconds / 1_000_000_000_000_000
        DiagnosticLog.write("debounce queued \(fields) delayMilliseconds=\(milliseconds)")
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pendingDiagnosticFields = nil
            DiagnosticLog.write("debounce elapsed \(fields)")
            action(snapshot)
        }
    }
    func cancel(reason: InputDiagnosticReason = .reset) {
        recordCancellation(reason: reason)
        task?.cancel()
        task = nil
    }

    private func recordCancellation(reason: InputDiagnosticReason) {
        guard let fields = pendingDiagnosticFields else { return }
        pendingDiagnosticFields = nil
        DiagnosticLog.write("debounce cancelled reason=\(reason.rawValue) \(fields)")
    }
}

@MainActor final class InputCoordinator {
    private let logger = Logger(subsystem: "com.comeg.runwu", category: "pipeline")
    private let extractor = SentenceExtractor(), detector = LanguageTextDetector(), debouncer = InputDebouncer()
    private var lastSentence = "", lastSentenceKey = "", session: InputSessionID?
    private var observedSentence: ExtractedSentence?
    private var diagnosticSuppression: InputDiagnosticReason?
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
            if timing != .pause { debouncer.cancel(reason: .timingChanged) }
        }
    }
    var onSentence: ((String, String, InputSessionID, NSScreen?, TextSnapshot) -> Void)?, onEmpty: (() -> Void)?
    func setSourceLanguage(_ language: Language) {
        sourceLanguage = language
        reset(reason: .sourceLanguageChanged)
    }
    func handle(_ snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?) {
        DiagnosticLog.write(
            "snapshot received bundle=\(snapshot.bundleIdentifier ?? "unknown") length=\(snapshot.text.count)"
                + " pid=\(session.pid) session=\(session.token.uuidString) composing=\(snapshot.isComposing)"
                + " utf16Length=\(snapshot.text.utf16.count)"
                + " selectedStart=\(snapshot.selectedRange?.location ?? -1) selectedLength=\(snapshot.selectedRange?.length ?? -1)")
        logger.info(
            "snapshot received bundle=\(snapshot.bundleIdentifier ?? "unknown", privacy: .public) length=\(snapshot.text.count, privacy: .public)"
        )
        guard isEnabled else {
            recordSuppression(.disabled, snapshot: snapshot, session: session)
            return
        }
        if excludedBundleIDs.contains(snapshot.bundleIdentifier ?? "") {
            logger.info("snapshot ignored excluded app")
            recordSuppression(.excludedApp, snapshot: snapshot, session: session)
            reset(reason: .excludedApp)
            return
        }
        if let previous = self.session, previous != session { reset(reason: .sessionChanged) }
        self.session = session
        observe(snapshot)
        if snapshot.isComposing {
            recordSuppression(.composing, snapshot: snapshot, session: session)
            debouncer.cancel(reason: .composing)
            lastSentence = ""
            lastSentenceKey = ""
            return
        }
        if snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordSuppression(.emptyText, snapshot: snapshot, session: session)
            debouncer.cancel(reason: .emptyText)
            lastSentence = ""
            lastSentenceKey = ""
            onEmpty?()
            return
        }
        diagnosticSuppression = nil
        switch timing {
        case .pause:
            debouncer.submit(snapshot, session: session) { [weak self] snapshot in
                guard let self, self.session == session else { return }
                self.emit(snapshot, session: session, screen: screen)
            }
        case .completeSentence:
            debouncer.cancel(reason: .completeSentence)
            if extractor.isComplete(snapshot) {
                emit(snapshot, session: session, screen: screen)
            }
        case .shortcut:
            debouncer.cancel(reason: .shortcut)
        }
    }
    func translateNow(_ snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?) {
        guard isEnabled else { return }
        guard !snapshot.isComposing, !excludedBundleIDs.contains(snapshot.bundleIdentifier ?? "") else {
            observe(snapshot)
            let reason: InputDiagnosticReason = snapshot.isComposing ? .composing : .excludedApp
            recordSuppression(reason, snapshot: snapshot, session: session)
            debouncer.cancel(reason: reason)
            return
        }
        if let previous = self.session, previous != session { reset(reason: .sessionChanged) }
        self.session = session
        observe(snapshot)
        diagnosticSuppression = nil
        emit(snapshot, session: session, screen: screen, force: true)
    }
    func reset(reason: InputDiagnosticReason = .reset) {
        if let session {
            DiagnosticLog.write("input coordinator reset reason=\(reason.rawValue)"
                + " pid=\(session.pid) session=\(session.token.uuidString)")
        }
        debouncer.cancel(reason: reason)
        session = nil
        observedSentence = nil
        lastSentence = ""
        lastSentenceKey = ""
        onEmpty?()
    }

    private func recordSuppression(_ reason: InputDiagnosticReason, snapshot: TextSnapshot,
        session: InputSessionID) {
        guard diagnosticSuppression != reason else { return }
        diagnosticSuppression = reason
        DiagnosticLog.write("input suppressed reason=\(reason.rawValue) "
            + InputDiagnostic.identity(bundle: snapshot.bundleIdentifier, session: session))
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
        else {
            let reason: InputDiagnosticReason = !isEnabled ? .disabled : snapshot.isComposing ? .composing : .excludedApp
            recordSuppression(reason, snapshot: snapshot, session: session)
            return
        }
        guard let extracted = extractor.extractSentence(from: snapshot) else {
            DiagnosticLog.write("sentence skipped reason=\(InputDiagnosticReason.extractionEmpty.rawValue) "
                + InputDiagnostic.identity(bundle: snapshot.bundleIdentifier, session: session)
                + " utf16Length=\(snapshot.text.utf16.count) selectedStart=\(snapshot.selectedRange?.location ?? -1)")
            return
        }
        let sentence = extracted.text
        DiagnosticLog.write(
            "debounce fired sentenceLength=\(sentence.count) source=\(sourceLanguage.rawValue) matches=\(detector.contains(sentence, language: sourceLanguage))")
        logger.info(
            "debounce fired sentenceLength=\(sentence.count, privacy: .public) source=\(self.sourceLanguage.rawValue, privacy: .public) matches=\(self.detector.contains(sentence, language: self.sourceLanguage), privacy: .public)"
        )
        guard !sentence.isEmpty, detector.contains(sentence, language: sourceLanguage) else {
            let reason: InputDiagnosticReason = sentence.isEmpty ? .extractionEmpty : .sourceLanguageMismatch
            DiagnosticLog.write("sentence skipped reason=\(reason.rawValue) "
                + InputDiagnostic.identity(bundle: snapshot.bundleIdentifier, session: session))
            return
        }
        let sentenceKey = extracted.key(in: session)
        if !force, sentence == lastSentence, sentenceKey == lastSentenceKey {
            DiagnosticLog.write("sentence skipped reason=\(InputDiagnosticReason.sentenceDeduplicated.rawValue) "
                + InputDiagnostic.identity(bundle: snapshot.bundleIdentifier, session: session)
                + " sentenceStart=\(extracted.range.location) sentenceUTF16Length=\(extracted.range.length)")
            return
        }
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
    // These fields only gate diagnostics. A failed sample may rotate the real
    // session and reacquire focus every poll; that is not a diagnostic recovery.
    private var diagnosticCaptureFailure: InputDiagnosticReason?
    private var diagnosticSampleFields: String?
    private var diagnosticReadGeneration: UInt = 0
    private var lastDiagnosticFailure: InputDiagnosticReason?
    private var lastDiagnosticAppPID: pid_t?, lastDiagnosticBundleID: String?
    private var lastDiagnosticAnchor: InputAnchor?
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
        if application != nil || isRunning {
            DiagnosticLog.write("input session reset reason=\(InputDiagnosticReason.monitorStopped.rawValue) "
                + InputDiagnostic.identity(bundle: application?.bundleID, session: session))
        }
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
        let previousSession = session, previousApplication = application
        diagnosticReadGeneration &+= 1
        let diagnosticGeneration = diagnosticReadGeneration
        reader.access.beginRead()
        refreshCurrentFocus()
        beginDiagnosticCapture()
        defer {
            finishDiagnosticCapture(generation: diagnosticGeneration,
                previousSession: previousSession, previousApplication: previousApplication)
        }
        _ = capture(force: false)
    }

    private func beginDiagnosticCapture() {
        diagnosticCaptureFailure = application == nil ? .applicationUnavailable : .focusUnavailable
        diagnosticSampleFields = nil
    }

    private func finishDiagnosticCapture(generation: UInt, previousSession: InputSessionID,
        previousApplication: MonitoredApplication?) {
        // A callback can synchronously read the new field. Its outcome is the
        // current diagnostic state; the superseded outer sample must not replace it.
        guard generation == diagnosticReadGeneration else { return }
        let contextChanged = lastDiagnosticAppPID != application?.pid || lastDiagnosticBundleID != application?.bundleID
        let changed = contextChanged || diagnosticCaptureFailure != lastDiagnosticFailure
        let fields = InputDiagnostic.identity(bundle: application?.bundleID, session: session)
        if previousSession != session, diagnosticCaptureFailure == nil || changed {
            let appChanged = previousApplication?.pid != application?.pid || previousApplication?.bundleID != application?.bundleID
            let reason = appChanged ? InputDiagnosticReason.applicationChanged : diagnosticCaptureFailure ?? .focusChanged
            DiagnosticLog.write("input session reset reason=\(reason.rawValue) \(fields)"
                + " previousSession=\(previousSession.token.uuidString)")
        }
        if let reason = diagnosticCaptureFailure, changed {
            DiagnosticLog.write("input sample blocked reason=\(reason.rawValue) \(fields)"
                + (diagnosticSampleFields.map { " " + $0 } ?? ""))
        } else if diagnosticCaptureFailure == nil, let reason = lastDiagnosticFailure, !contextChanged {
            DiagnosticLog.write("input sample recovered reason=\(reason.rawValue) \(fields)")
        }
        lastDiagnosticFailure = diagnosticCaptureFailure
        lastDiagnosticAppPID = application?.pid
        lastDiagnosticBundleID = application?.bundleID
    }

    private func capture(force: Bool) -> (snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?)? {
        guard let app = application, let element = focused else { return nil }
        guard currentApplication()?.pid == app.pid else {
            diagnosticCaptureFailure = .applicationChanged
            setFocused(nil)
            return nil
        }
        guard let geometry = reader.geometry(element, pid: app.pid, bundleID: app.bundleID,
                excluded: excludedBundleIDs, layout: InputScreenLayout(frames: screenFrames()),
                requiresExplicitFocus: focusedRequiresExplicitFocus) else {
            diagnosticCaptureFailure = .geometryUnavailable
            setFocused(nil)
            return nil
        }
        diagnosticSampleFields = InputDiagnostic.sample(composing: geometry.isComposing, utf16Length: nil,
            reported: geometry.selectedRange, mapped: nil)
        guard let composing = geometry.isComposing else {
            diagnosticCaptureFailure = .compositionUnreadable
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
            // 几何日志：浮窗摆放按这两个矩形算，宿主报偏/不报时只能靠它定位
            // （只记整数坐标，不含文本）。
            if geometry.anchor != lastDiagnosticAnchor {
                lastDiagnosticAnchor = geometry.anchor
                DiagnosticLog.write(
                    "anchor caret=\(Self.coordinates(geometry.anchor.caretFrame))"
                        + " field=\(Self.coordinates(geometry.anchor.fieldFrame))")
            }
            onAnchorChanged?(geometry.anchor, capturedSession)
        }
        guard session == capturedSession else { diagnosticCaptureFailure = .sessionChanged; return nil }
        guard permitsContent(element, app: app) else { diagnosticCaptureFailure = .contentQualificationFailed; return nil }
        if force, composing { diagnosticCaptureFailure = .composing; return nil }
        let read = reader.text(element)
        guard session == capturedSession, permitsContent(element, app: app) else {
            diagnosticCaptureFailure = session == capturedSession ? .contentQualificationFailed : .sessionChanged
            return nil
        }
        guard let text = read ?? ((force || composing) ? "" : nil) else {
            diagnosticCaptureFailure = .contentUnreadable
            return nil
        }
        diagnosticSampleFields = InputDiagnostic.sample(composing: composing, utf16Length: text.utf16.count,
            reported: geometry.selectedRange, mapped: nil)
        var selectedRange = geometry.selectedRange
        if let read {
            // 映射只在 `AXValue` 真有值时进行：读不到值（force/组合下的空文本路径）
            // 沿用旧行为，映射不可用不能吞掉快捷键的 lastGoodText 恢复。
            guard !geometry.anchorReadFailed else {
                diagnosticCaptureFailure = .anchorReadFailed
                // 锚窗读取失败（显式错误/预算耗尽/读回空）：宿主偏移不可信，不出卡。
                invalidateUntrustedSample(geometry, element: element, app: app)
                return nil
            }
            if let hostAnchor = geometry.hostAnchor, let reported = geometry.selectedRange {
                // Chromium contenteditable（实测 Obsidian）的宿主偏移与 AXValue 两套
                // 坐标系：映射回 AXValue 的 UTF-16 索引，再用光标后一位字符局部甄别；
                // 任一不过按不可信采样处理（宁可不翻，不翻错行）。
                guard let mapped = CaretOffsetMapping.mappedIndex(
                    anchor: hostAnchor, hostOffset: reported.location, in: read as NSString) else {
                    diagnosticCaptureFailure = .mappingNotFound
                    invalidateUntrustedSample(geometry, element: element, app: app)
                    return nil
                }
                diagnosticSampleFields = InputDiagnostic.sample(composing: composing, utf16Length: text.utf16.count,
                    reported: geometry.selectedRange, mapped: NSRange(location: mapped, length: reported.length))
                guard postCaretCharacterMatches(geometry.postCaretCharacter, at: mapped, in: read as NSString) else {
                    diagnosticCaptureFailure = .postCaretMismatch
                    invalidateUntrustedSample(geometry, element: element, app: app)
                    return nil
                }
                selectedRange = NSRange(location: mapped, length: reported.length)
            }
        }
        let snapshot = TextSnapshot(pid: app.pid, bundleIdentifier: app.bundleID, text: text,
            selectedRange: selectedRange, fieldFrame: geometry.anchor.fieldFrame,
            caretFrame: geometry.anchor.caretFrame, isComposing: composing)
        let point = geometry.anchor.caretFrame ?? geometry.anchor.fieldFrame
        let screen = point.flatMap { rect in NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } }
        let changed = text != lastText || geometry.selectedRange != lastSelectedRange
            || composing != lastComposing
        if !text.isEmpty, !composing { lastGoodText = text }
        lastText = text
        lastSelectedRange = geometry.selectedRange
        lastComposing = composing
        diagnosticCaptureFailure = nil
        if force || changed {
            DiagnosticLog.write("snapshot captured " + InputDiagnostic.identity(bundle: app.bundleID, session: capturedSession)
                + " " + InputDiagnostic.sample(composing: composing, utf16Length: text.utf16.count,
                    reported: geometry.selectedRange, mapped: selectedRange)
                + " forced=\(force) changed=\(changed)")
        }
        if !force, changed { onSnapshot?(snapshot, capturedSession, screen) }
        return (snapshot, capturedSession, screen)
    }

    func snapshotNow() -> (snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?)? {
        let previousSession = session, previousApplication = application
        diagnosticReadGeneration &+= 1
        let diagnosticGeneration = diagnosticReadGeneration
        reader.access.beginRead()
        refreshCurrentFocus()
        beginDiagnosticCapture()
        defer {
            finishDiagnosticCapture(generation: diagnosticGeneration,
                previousSession: previousSession, previousApplication: previousApplication)
        }
        guard let captured = capture(force: true) else { return nil }
        let recovered = ShortcutSnapshotRecovery.resolve(live: captured.snapshot,
            lastGoodText: lastGoodText, sourceLanguage: sourceLanguage)
        guard !recovered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagnosticCaptureFailure = .shortcutRecoveryEmpty
            return nil
        }
        return (recovered, captured.session, captured.screen)
    }

    /// 不可信采样：与 marked 不可读分支同型——旋转会话、清记账、只发布锚点几何，
    /// 不出卡（映射对不上时不把宿主偏移当索引翻错行）。
    private func invalidateUntrustedSample(_ geometry: AXFieldReader.Geometry,
        element: AXUIElement, app: MonitoredApplication) {
        invalidateInput()
        guard focused.map({ CFEqual($0, element) }) == true,
            currentApplication()?.pid == app.pid else { return }
        lastAnchor = geometry.anchor
        onAnchorChanged?(geometry.anchor, session)
    }

    /// D-06 复核②（D-07 空白容忍）：宿主在 r 处的字符要求与 `AXValue[mapped]` 一致；
    /// 不可比时不要求。任一为空白/零宽形态（两套坐标系对空白的表示法不同，见
    /// `CaretOffsetMapping.strippedCharacters`）即跳过比较；只有两侧都是实义字符
    /// 才要求（规范等价）相等——形态差异不构成「不一致」的证据。
    private func postCaretCharacterMatches(_ character: String?, at index: Int, in text: NSString) -> Bool {
        guard let character else { return true }
        guard index >= 0, index < text.length else { return false }
        let value = text.substring(with: NSRange(location: index, length: 1))
        guard !CaretOffsetMapping.isStripped(character), !CaretOffsetMapping.isStripped(value) else {
            return true
        }
        return value == character
    }

    /// 诊断探针：先报实时链路正在用的锚点几何（卡片摆放就是按它算的）；
    /// 再按 pid 重新推导一次焦点文本元素，看宿主此刻是否给出可用元素。
    /// 只报整数坐标、角色和包含关系，不含任何输入文本。
    func diagnosticProbe() -> String {
        let live = " live_caret=\(Self.coordinates(lastAnchor?.caretFrame))"
            + " live_field=\(Self.coordinates(lastAnchor?.fieldFrame))"
        reader.access.beginRead()
        guard let target = lastExternalApp else { return "probe result=no_external_app_tracked" + live }
        guard !excludedBundleIDs.contains(target.bundleID), !reader.access.secureInputActive() else {
            return "probe target=\(target.bundleID) result=protected_target" + live
        }
        guard NSRunningApplication(processIdentifier: target.pid) != nil else {
            return "probe target=\(target.bundleID) result=app_not_running" + live
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard let raw = reader.access.attribute(app, kAXFocusedUIElementAttribute as String),
            CFGetTypeID(raw) == AXUIElementGetTypeID(),
            let field = reader.resolve(raw as! AXUIElement, pid: target.pid) else {
            return "probe target=\(target.bundleID) result=no_text_element" + live
        }
        let rawRole = reader.access.attribute(field, kAXRoleAttribute as String) as? String
        let knownRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        let role = rawRole.flatMap { knownRoles.contains($0) ? $0 : nil } ?? "unknown"
        let geometry = reader.geometry(field, pid: target.pid, bundleID: target.bundleID,
            excluded: excludedBundleIDs, layout: InputScreenLayout(frames: screenFrames()))
        let caret = geometry?.anchor.caretFrame, box = geometry?.anchor.fieldFrame
        let inside = caret.flatMap { caret in box.map { $0.contains(caret) } }
        return "probe target=\(target.bundleID) result=text_element_found role=\(role)"
            + " caret=\(Self.coordinates(caret)) field=\(Self.coordinates(box))"
            + " caret_in_field=\(inside.map(String.init) ?? "unknown")" + live
    }

    /// 诊断探针用：矩形转整数串；nil 表示宿主没有报告该矩形。宿主报出
    /// 荒谬但有限的坐标（非有限值已被 finite 拦掉）时逐项标 insane——
    /// 坏几何只该出现在报告里，不该让「生成诊断报告」当场崩掉。
    nonisolated static func coordinates(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        func value(_ number: CGFloat) -> String {
            guard number.isFinite, number.magnitude < 10_000_000 else { return "insane" }
            return String(Int(number.rounded()))
        }
        return [rect.minX, rect.minY, rect.width, rect.height].map(value).joined(separator: ",")
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
