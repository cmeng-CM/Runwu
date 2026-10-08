import AppKit
import ApplicationServices
import OSLog
import SwiftUI
@preconcurrency import Translation

@main struct PicoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        MenuBarExtra("润物", image: "MenuBarIcon") {
            MenuBarMenu(state: appDelegate.state)
        }.menuBarExtraStyle(.menu)
        Settings { SettingsView(state: appDelegate.state) }
        Window("Welcome to 润物", id: "welcome") { WelcomeView(state: appDelegate.state) }.defaultSize(
            width: 520, height: 360)
    }
}

struct MenuBarMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings: SettingsStore

    init(state: AppState) {
        self.state = state
        self._settings = ObservedObject(wrappedValue: state.settings)
    }

    var body: some View {
        let lang = settings.uiLanguage
        Button(state.enabled ? L10n.pause(lang) : L10n.resume(lang)) { state.toggle() }
        Divider()
        if let failure = state.realtimeFailure ?? state.clipboardFailure {
            Text(failure)
            Divider()
        }
        Button(L10n.menuSettings(lang)) { state.presentSettings() }
        Button(L10n.quit(lang)) { NSApp.terminate(nil) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    override init() {
        state = AppState()
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        state.startTranslationHost()
    }
    /// Clicking the Dock icon with no visible windows opens settings, so the
    /// app is always configurable even when the menu bar item is hard to spot.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { state.presentSettings() }
        return true
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let lang = state.settings.uiLanguage
        let menu = NSMenu()
        let settings = NSMenuItem(title: L10n.menuSettings(lang), action: #selector(openSettingsFromDock), keyEquivalent: "")
        let toggle = NSMenuItem(
            title: state.enabled ? L10n.pause(lang) : L10n.resume(lang),
            action: #selector(toggleFromDock), keyEquivalent: "")
        let quit = NSMenuItem(title: L10n.quit(lang), action: #selector(quitFromDock), keyEquivalent: "")
        [settings, toggle, quit].forEach {
            $0.target = self
            menu.addItem($0)
        }
        return menu
    }
    @objc private func openSettingsFromDock() { state.presentSettings() }
    @objc private func toggleFromDock() { state.toggle() }
    @objc private func quitFromDock() { NSApp.terminate(nil) }
}

@MainActor final class AppState: ObservableObject {
    private let logger = Logger(subsystem: "com.comeg.runwu", category: "runtime")
    @Published var enabled: Bool
    private var menuBarWatchdog: Timer?
    private var menuBarHealAttempts = 0
    @Published var translation = ""
    @Published private(set) var realtimeFailure: String?
    @Published private(set) var clipboardFailure: String?
    private let liveFailureNotice = TranslationFailureNotice()
    private let clipboardFailureNotice = TranslationFailureNotice()
    @Published var permissionGranted: Bool
    @Published var showWelcome: Bool
    var settings: SettingsStore
    let permission = AccessibilityPermissionManager()
    let monitor = AccessibilityMonitor()
    let input = InputCoordinator()
    let translationService: TranslationService
    let coordinator: TranslationCoordinator
    let clipboardCoordinator: TranslationCoordinator
    let translationHolder: TranslationSessionHolder
    let history: TranslationHistoryController
    let overlay = OverlayCoordinator()
    let speech: SpeechPerforming
    let pasteboardWatcher = PasteboardWatcher()
    let autoUpdater: AutoUpdateController
    private let speechPolicy = SpeechPolicyEvaluator()
    private let hotKey = GlobalHotKey.shared
    private let realtime = RealtimeTranslationState()
    private var configurationGeneration: UInt64 = 0
    private var configurationTask: Task<Void, Never>?
    private let runtimeEnabled: Bool
    private var clipboardRequestID: UUID?
    private var pendingOrigin: OverlayOrigin?
    private var pendingAction: PendingTranslationAction?
    var hasPendingTranslationAction: Bool { pendingAction != nil }
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var installHealWindow: NSWindow?
    private var reauthWindow: NSWindow?
    private var reauthDismissedThisSession = false
    private let permissionWatchdog = AccessibilityPermissionWatchdog()
    private var translationHostWindow: TranslationHostWindowController?
    init(settings store: SettingsStore = SettingsStore(), translationEngine: (any TranslationEngine)? = nil,
        historyDatabaseURL: URL? = nil, startRuntime: Bool = true,
        engines: [TranslationBackend: any TranslationEngine] = [:],
        modelFactory: @escaping TranslationService.ModelFactory = { LLMModelRouter(models: $0, timeoutSeconds: $1) },
        speech suppliedSpeech: (any SpeechPerforming)? = nil) {
        let enabledValue = store.enabled
        let trustedValue = startRuntime && AXIsProcessTrusted()
        let welcomeValue = startRuntime && !UserDefaults.standard.bool(forKey: "onboardingComplete")
        let holder = TranslationSessionHolder()
        holder.configure(source: store.sourceLanguage, target: store.targetLanguage)
        let service = TranslationService(
            localEngine: HostedTranslationEngine(holder: holder),
            backend: store.translationBackend,
            models: store.llmModels,
            timeoutSeconds: store.llmFallbackTimeout, engines: engines, modelFactory: modelFactory)
        let historyController = TranslationHistoryController(databaseURL: historyDatabaseURL)
        settings = store
        runtimeEnabled = startRuntime
        autoUpdater = AutoUpdateController(settings: store)
        enabled = enabledValue
        permissionGranted = trustedValue
        showWelcome = welcomeValue
        translationHolder = holder
        translationService = service
        coordinator = TranslationCoordinator(
            engine: translationEngine ?? service, sourceLanguage: store.sourceLanguage, targetLanguage: store.targetLanguage)
        clipboardCoordinator = TranslationCoordinator(
            engine: translationEngine ?? service, sourceLanguage: store.sourceLanguage, targetLanguage: store.targetLanguage)
        history = historyController
        speech = suppliedSpeech ?? SpeechService()
        NSLog("Runwu startup trusted=%@ enabled=%@", String(trustedValue), String(enabledValue))
        DiagnosticLog.write("startup trusted=\(trustedValue) enabled=\(enabledValue)")
        logger.info("startup trusted=\(trustedValue, privacy: .public) enabled=\(enabledValue, privacy: .public)")
        input.isEnabled = enabled
        input.delayMilliseconds = settings.translationSpeed
        input.sourceLanguage = settings.sourceLanguage
        input.timing = settings.translationTiming
        overlay.hideAfter = settings.hideAfter
        overlay.neverHide = settings.neverHide
        overlay.textSize = settings.textSize
        overlay.position = settings.overlayPosition
        overlay.edgeDistance = settings.overlayEdgeDistance
        overlay.behavior = settings.overlayBehavior
        overlay.cardOpacity = settings.overlayOpacity
        overlay.theme = settings.overlayTheme
        overlay.surface = settings.overlaySurface
        overlay.followCaret = settings.overlayFollowCaret
        monitor.onSnapshot = { [weak self] snapshot, session, screen in
            self?.handleInputSnapshot(snapshot, session: session, screen: screen)
        }
        monitor.onAnchorChanged = { [weak self] anchor, session in
            guard let self, self.realtime.updateAnchor(anchor, session: session) else { return }
            self.overlay.updateAnchor(anchor, session: session)
        }
        monitor.onFocusChanged = { [weak self] in
            self?.invalidateRealtime(clearAnchor: true)
            self?.input.reset()
        }
        input.excludedBundleIDs = settings.excludedBundleIDs
        monitor.excludedBundleIDs = settings.excludedBundleIDs
        monitor.sourceLanguage = settings.sourceLanguage
        settings.onTranslationSettingsChanged = { [weak self] in self?.applyTranslationSettings() }
        settings.onOverlayFollowCaretChanged = { [weak self] in
            guard let self else { return }
            self.overlay.followCaret = self.settings.overlayFollowCaret
        }
        settings.onClipboardSettingsChanged = { [weak self] in self?.applyClipboardSettings() }
        settings.onAutoUpdateChanged = { [weak self] in self?.autoUpdater.startMonitoring() }
        overlay.onCopyToPasteboard = { [weak self] _ in self?.pasteboardWatcher.resyncBaseline() }
        pasteboardWatcher.onCopy = { [weak self] text in self?.translateCopiedText(text, autoTriggered: true) }
        settings.onHistoryRetentionChanged = { [weak self] in
            guard let self else { return }
            self.history.reload(retention: self.settings.historyRetention)
        }
        input.onSentence = { [weak self] text, sentenceKey, session, screen, snapshot in
            self?.translate(text, sentenceKey: sentenceKey, session: session, screen: screen, snapshot: snapshot)
        }
        input.onEmpty = { [weak self] in
            self?.invalidateRealtime()
        }
        guard startRuntime else { return }
        if permissionGranted && enabled {
            monitor.start()
            DiagnosticLog.write("accessibility monitor started")
            logger.info("accessibility monitor started")
        } else {
            DiagnosticLog.write("accessibility monitor skipped")
            logger.info("accessibility monitor skipped")
        }
        // 常驻授权观察器：状态跃迁时回调。restored=更新状态、收起提醒窗、
        // 拉起监控；lost=只更新状态（会话中不弹窗，下次启动或打开主开关
        // 才提醒）。会话中授权再死（系统设置里被手动关掉、策略重置）也能
        // 在重勾后自动恢复——老版轮询恢复后即退出，存在这个缺口。
        permissionWatchdog.onRestored = { [weak self] in
            guard let self else { return }
            permissionGranted = true
            reauthWindow?.orderOut(nil)
            reauthWindow = nil
            monitor.start()
            DiagnosticLog.write("accessibility permission restored, starting monitor")
            logger.info("accessibility permission restored, starting monitor")
        }
        permissionWatchdog.onLost = { [weak self] in
            guard let self else { return }
            permissionGranted = false
            invalidateRealtime(clearAnchor: true)
            monitor.stop()
            DiagnosticLog.write("accessibility permission lost")
            logger.info("accessibility permission lost")
        }
        permissionWatchdog.start()
        hotKey.onAction = { [weak self] action in
            switch action {
            case .replace: self?.handleReplaceHotKey()
            case .copy: self?.handleCopyHotKey()
            case .translate: self?.handleTranslateHotKey()
            case .clipboard: self?.handleClipboardHotKey()
            }
        }
        refreshHotKeys()
        applyTranslationSettings()
        applyClipboardSettings()
        autoUpdater.startMonitoring()
        history.reload(retention: settings.historyRetention)
        DiagnosticLog.write("init showWelcome=\(showWelcome) onboarded=\(UserDefaults.standard.bool(forKey: "onboardingComplete"))")
        if showWelcome {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                DiagnosticLog.write("welcome task firing")
                self?.presentWelcome()
            }
        }
        // 从磁盘映像/下载文件夹运行时提示一键搬到「应用程序」，避免授权反复失效
        if InstallHealer.shouldPrompt() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4.5))
                self?.presentInstallHeal()
            }
        }
        // 授权失效提醒：曾授权过、现在掉了的用户会在启动几秒后看到提示窗
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5.5))
            self?.maybePresentReauth()
        }
    }
    func startTranslationHost() {
        guard translationHostWindow == nil else { return }
        translationHostWindow = TranslationHostWindowController(holder: translationHolder)
        startMenuBarWatchdog()
    }

    /// 系统在菜单栏拥挤或创建时机不巧时，会把状态项停到屏幕外（负坐标）。
    /// 看门狗检测到后移除并重建状态项，让系统重新分配一个可见位置。
    func startMenuBarWatchdog() {
        menuBarWatchdog?.invalidate()
        menuBarWatchdog = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.healMenuBarExtraIfNeeded() }
        }
    }

    private func healMenuBarExtraIfNeeded() {
        guard enabled else { return }
        guard let screen = NSScreen.main else { return }
        // 菜单栏条带：屏幕顶部 24pt
        let barFrame = NSRect(x: 0, y: screen.frame.maxY - 24, width: screen.frame.width, height: 24)
        let statusWindows = NSApp.windows.filter { $0.level == .statusBar }
        guard !statusWindows.isEmpty else { return }
        let misplaced = statusWindows.contains { !barFrame.intersects($0.frame) }
        if misplaced {
            // 把状态项放回条带内、时钟左侧
            var x = screen.frame.maxX - 24 - 8
            for window in statusWindows.reversed() {
                let w = window.frame.width
                window.setFrame(NSRect(x: x - w, y: barFrame.minY, width: w, height: 24), display: true)
                x -= w + 8
            }
            menuBarHealAttempts += 1
        } else {
            menuBarHealAttempts = 0
        }
    }

    /// Applies a settings edit to the running pipeline. Direction, engine,
    /// prompt/model order, and timeout all take effect on the next request;
    /// existing work is invalidated so stale output cannot overwrite it.
    func applyTranslationSettings() {
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        let backend = settings.translationBackend
        let timeout = settings.llmFallbackTimeout
        let models = settings.llmModels
        configurationGeneration &+= 1
        let revision = configurationGeneration
        let previousConfiguration = configurationTask
        clipboardRequestID = nil
        invalidateRealtime(clearAnchor: true)
        input.setSourceLanguage(source)
        monitor.sourceLanguage = source
        translationHolder.configure(source: source, target: target)
        clearPendingAction()
        overlay.hideUnpinned()
        speech.stop()
        clearFailure(realtime: true)
        clearFailure(realtime: false)
        let coordinator = coordinator
        let clipboardCoordinator = clipboardCoordinator
        let service = translationService
        configurationTask = Task { [weak self] in
            await previousConfiguration?.value
            guard self?.configurationGeneration == revision else { return }
            await coordinator.reconfigure(from: source, to: target, revision: revision)
            await clipboardCoordinator.reconfigure(from: source, to: target, revision: revision)
            guard self?.configurationGeneration == revision else { return }
            await service.configure(backend: backend, models: models, timeoutSeconds: timeout, revision: revision)
        }
    }
    private func configurationReady(_ revision: UInt64) async -> Bool {
        let barrier = configurationTask
        await barrier?.value
        return enabled && configurationGeneration == revision && !Task.isCancelled
    }
    func toggle() {
        enabled.toggle()
        settings.enabled = enabled
        input.isEnabled = enabled
        // Pause and resume are request revisions too. Publish matching
        // coordinator/service revisions through the same readiness barrier.
        applyTranslationSettings()
        if enabled {
            if runtimeEnabled {
                permissionGranted = AXIsProcessTrusted()
                monitor.start()
                refreshHotKeys()
                maybePresentReauth()
            }
        } else {
            input.reset()
            monitor.stop()
            clearPendingAction()
            refreshHotKeys()
            speech.stop()
            overlay.hide()
        }
        applyClipboardSettings()
    }
    func requestPermission() {
        permission.request()
        permissionGranted = AXIsProcessTrusted()
        if permissionGranted { monitor.start() }
    }
    func showOverlayTest() { overlay.show("This is a position preview.", on: NSScreen.main) }

    /// 「报告问题」：一键在本机生成脱敏诊断文件（桌面），并在访达中显示。
    /// 不做任何网络上传，文件由用户亲手发给作者。
    func generateDiagnosticsReport() {
        let snapshot = DiagnosticsSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            installPath: Bundle.main.bundlePath,
            installNeedsHealing: InstallHealer.needsHealing(bundlePath: Bundle.main.bundlePath),
            osVersion: DiagnosticsReport.osVersion(),
            hardwareModel: DiagnosticsReport.hardwareModel(),
            machine: DiagnosticsReport.machine(),
            accessibilityTrusted: AXIsProcessTrusted(),
            monitorRunning: monitor.isRunning,
            probeLine: monitor.diagnosticProbe(),
            weChatVersion: DiagnosticsReport.weChatVersion(),
            enabled: enabled,
            timingRaw: settings.translationTiming.rawValue,
            speedMilliseconds: settings.translationSpeed,
            sourceLanguage: settings.sourceLanguage.rawValue,
            targetLanguage: settings.targetLanguage.rawValue,
            backendRaw: settings.translationBackend.rawValue,
            llmModelCount: settings.llmModels.count,
            uiLanguage: settings.uiLanguage.rawValue,
            clipboardEnabled: settings.clipboardTranslationEnabled,
            clipboardTriggerRaw: settings.clipboardTriggerMode.rawValue,
            excludedBundleIDs: settings.excludedBundleIDs.sorted(),
            generatedAt: Date())
        let content = DiagnosticsReport.render(
            snapshot: snapshot, recentLog: DiagnosticLog.recentLines(),
            debugLogExists: DiagnosticLog.debugFileExists(),
            debugLogTail: DiagnosticLog.debugFileTail())
        guard let url = DiagnosticsReport.write(content) else {
            DiagnosticLog.write("diagnostics report write failed")
            return
        }
        DiagnosticLog.write("diagnostics report written \(url.lastPathComponent)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        showWelcome = false
        welcomeWindow?.close()
        welcomeWindow = nil
    }
    func presentSettings() {
        if let settingsWindow {
            updateSettingsWindowTitle()
            settingsWindow.orderFrontRegardless()
            settingsWindow.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.settingsWindowTitle(settings.uiLanguage)
        let hosting = NSHostingView(rootView: SettingsView(state: self))
        hosting.sizingOptions = .minSize
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 840, height: 700))
        centerOnMainScreen(window)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
    /// macOS 26: center() can land a window off-screen (seen on the overlay
    /// prompt); pin the window to the main screen center explicitly.
    private func centerOnMainScreen(_ window: NSWindow) {
        window.center()
        guard let screen = NSScreen.main else { return }
        var frame = window.frame
        frame.origin.x = screen.frame.midX - frame.width / 2
        frame.origin.y = screen.frame.midY - frame.height / 2
        window.setFrameOrigin(frame.origin)
    }

    func updateSettingsWindowTitle() {
        settingsWindow?.title = L10n.settingsWindowTitle(settings.uiLanguage)
    }
    private func presentWelcome() {
        DiagnosticLog.write("presentWelcome called")
        guard welcomeWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Welcome to 润物"
        window.contentView = NSHostingView(rootView: WelcomeView(state: self))
        centerOnMainScreen(window)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }

    /// 非阻塞安装位置提示窗。只用 orderFrontRegardless 展示、不抢键盘
    /// 焦点（窗口曾被误按键触发默认按钮），并按主屏显式居中（macOS 26
    /// 上 center() 会把窗放去屏外）。
    private func presentInstallHeal() {
        guard installHealWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 210), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L10n.installHealTitle(settings.uiLanguage)
        let controller = InstallHealController()
        controller.onDismiss = { [weak self] in
            self?.installHealWindow?.orderOut(nil)
            self?.installHealWindow = nil
        }
        window.contentView = NSHostingView(
            rootView: InstallHealView(controller: controller, lang: settings.uiLanguage)
                .frame(width: 400, height: 182))
        window.center()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            var frame = window.frame
            frame.origin.x = screen.frame.midX - frame.width / 2
            frame.origin.y = screen.frame.midY - frame.height / 2
            window.setFrameOrigin(frame.origin)
        }
        window.isReleasedWhenClosed = false
        // 浮在普通窗口之上但不抢键盘焦点；orderFrontRegardless 的默认 z 序
        // 会被前台应用的窗口整个挡住
        window.level = .floating
        window.orderFrontRegardless()
        installHealWindow = window
    }
    private func handleInputSnapshot(_ snapshot: TextSnapshot, session: InputSessionID, screen: NSScreen?,
        feedInput: Bool = true) {
        if realtime.update(snapshot, session: session, language: settings.sourceLanguage) {
            clearRealtimePresentation()
        }
        if feedInput { input.handle(snapshot, session: session, screen: screen) }
    }
    private func invalidateRealtime(clearAnchor: Bool = false) {
        realtime.invalidate(clearAnchor: clearAnchor)
        clearRealtimePresentation()
    }
    private func clearRealtimePresentation() {
        clearFailure(realtime: true)
        if case .realtime = pendingOrigin { clearPendingAction() }
        overlay.hideRealtime()
        speech.stop()
        let mutation = realtime.mutationID
        let coordinator = coordinator
        Task { [weak self] in
            guard self?.realtime.mutationID == mutation else { return }
            await coordinator.cancel()
        }
    }

    private func translate(
        _ text: String, sentenceKey: String, session: InputSessionID, screen: NSScreen?, snapshot: TextSnapshot
    ) {
        let sourceLanguage = settings.sourceLanguage
        let targetLanguage = settings.targetLanguage
        guard let request = realtime.beginRequest(text: text, key: sentenceKey, session: session) else { return }
        let configuration = configurationGeneration
        let backend = settings.translationBackend
        clearFailure(realtime: true)
        let previous = pendingAction
        let sameSentence = previous?.sentenceKey == sentenceKey && previous?.session == session
        let replacement = settings.replaceOriginal
            ? FieldReplacement.evaluate(fieldText: snapshot.text, source: text, range: request.sentence.range) : nil
        pendingOrigin = .realtime(session)
        pendingAction = PendingTranslationAction(
            text: nil,
            sourceWithTerminator: replacement?.sourceWithTerminator,
            sourceRange: replacement?.range,
            session: session,
            sentenceKey: sentenceKey,
            applyReplaceWhenReady: sameSentence && previous?.applyReplaceWhenReady == true,
            applyCopyWhenReady: sameSentence && previous?.applyCopyWhenReady == true)
        DiagnosticLog.write("translation requested length=\(text.count)")
        logger.info("translation requested length=\(text.count, privacy: .public)")
        let coordinator = coordinator
        Task { [weak self, coordinator] in
            guard await self?.configurationReady(configuration) == true, self?.realtime.accepts(request) == true else { return }
            do {
                let result = try await coordinator.translateThrowing(text, from: sourceLanguage, to: targetLanguage, revision: configuration)
                self?.acceptTranslationResult(
                    result,
                    sourceText: text,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    key: sentenceKey,
                    session: session,
                    screen: screen,
                    origin: .realtime(session),
                    configuration: configuration,
                    liveRequest: request)
            } catch {
                guard self?.realtime.accepts(request) == true,
                    self?.configurationGeneration == configuration, self?.enabled == true else { return }
                if error is CancellationError {
                    self?.discardPending(key: sentenceKey, session: session)
                    return
                }
                self?.presentFailure(error, backend: backend, origin: .realtime(session), key: sentenceKey, session: session)
            }
        }
    }
    private func acceptTranslationResult(
        _ result: String,
        sourceText: String,
        sourceLanguage: Language,
        targetLanguage: Language,
        key sentenceKey: String,
        session: InputSessionID,
        screen: NSScreen?,
        origin: OverlayOrigin,
        configuration: UInt64,
        liveRequest: RealtimeTranslationState.Request? = nil,
        clipboardRequest: UUID? = nil,
        speak: Bool = true
    ) {
        let current: Bool
        switch origin {
        case .realtime:
            current = liveRequest.map(realtime.accepts) ?? false
        case .clipboard:
            current = clipboardRequest != nil && clipboardRequest == clipboardRequestID
        case .fixed:
            current = false
        }
        guard current, configuration == configurationGeneration, enabled else {
            DiagnosticLog.write("translation discarded stale session")
            logger.info("translation discarded stale session")
            return
        }
        translation = result
        if pendingAction?.session == session, pendingAction?.sentenceKey == sentenceKey {
            pendingAction?.text = result
        }
        history.record(
            sourceText: sourceText,
            translatedText: result,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            retention: settings.historyRetention)
        DiagnosticLog.write("translation result accepted length=\(result.count)")
        logger.info("translation result accepted length=\(result.count, privacy: .public)")
        if case .realtime = origin {
            overlay.showRealtime(source: sourceText, translation: result, key: sentenceKey,
                session: session, anchor: realtime.anchor)
        } else {
            overlay.show(result, key: sentenceKey, on: screen, origin: .clipboard)
        }
        if speak { speakIfAllowed(result) }
        if pendingAction?.session == session, pendingAction?.sentenceKey == sentenceKey {
            if pendingAction?.applyReplaceWhenReady == true { applyPendingReplace() }
            if pendingAction?.applyCopyWhenReady == true { applyPendingCopy() }
        }
    }
    private func speakIfAllowed(_ text: String) {
        guard speechPolicy.shouldSpeak(
            speechEnabled: settings.speechEnabled,
            speechTriggers: settings.speechTriggers,
            translationTiming: settings.translationTiming)
        else {
            DiagnosticLog.write("speech skipped")
            return
        }
        DiagnosticLog.write("speech speaking length=\(text.count)")
        speech.speak(text, language: settings.targetLanguage)
    }
    /// 授权失效提醒：走过引导的老用户如果当前没有辅助功能授权（系统更新、
    /// 重装或换签名都可能吊销），启动几秒后主动弹窗指路，避免打字翻译静默
    /// 失效没人发现。纯新用户走欢迎窗，不弹这个。
    func maybePresentReauth() {
        let trusted = AXIsProcessTrusted()
        let onboarded = UserDefaults.standard.bool(forKey: "onboardingComplete")
        let status = "reauth check enabled=\(enabled) onboarded=\(onboarded) trusted=\(trusted) dismissed=\(reauthDismissedThisSession)"
        DiagnosticLog.write(status)
        logger.info("\(status, privacy: .public)")
        guard ReauthGate.shouldPrompt(
            masterEnabled: enabled, onboardingComplete: onboarded,
            dismissedThisSession: reauthDismissedThisSession, currentlyTrusted: trusted)
        else { return }
        // TCC 在启动初期偶发抖动：3 秒后复核仍失败才弹，防止已授权用户被误打扰
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if AXIsProcessTrusted() {
                DiagnosticLog.write("reauth check: trust recovered during confirmation")
                logger.info("reauth check: trust recovered during confirmation")
                return
            }
            self.presentReauth()
        }
    }

    private func presentReauth() {
        guard reauthWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 258), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L10n.reauthTitle(settings.uiLanguage)
        let controller = ReauthController()
        controller.onDismiss = { [weak self] in
            self?.reauthDismissedThisSession = true
            self?.reauthWindow?.orderOut(nil)
            self?.reauthWindow = nil
            DiagnosticLog.write("reauth prompt dismissed")
        }
        window.contentView = NSHostingView(
            rootView: ReauthView(controller: controller, lang: settings.uiLanguage)
                .frame(width: 400, height: 230))
        centerOnMainScreen(window)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.orderFrontRegardless()
        reauthWindow = window
        DiagnosticLog.write("reauth prompt presented")
        NSLog("Runwu reauth prompt presented")
    }

    func setReplaceOriginal(_ enabled: Bool) {
        settings.replaceOriginal = enabled
        refreshHotKeys()
    }

    func setCopyTranslation(_ enabled: Bool) {
        settings.copyTranslation = enabled
        refreshHotKeys()
    }

    func setReplaceShortcut(_ shortcut: ReplaceShortcut) {
        settings.replaceShortcut = shortcut
        refreshHotKeys()
    }

    func setCopyShortcut(_ shortcut: ReplaceShortcut) {
        settings.copyShortcut = shortcut
        refreshHotKeys()
    }

    func setTranslationTiming(_ timing: TranslationTiming) {
        settings.translationTiming = timing
        input.timing = timing
        refreshHotKeys()
    }

    func setTranslateShortcut(_ shortcut: ReplaceShortcut) {
        settings.translateShortcut = shortcut
        refreshHotKeys()
    }

    private func refreshHotKeys() {
        guard runtimeEnabled else { return }
        hotKey.set(.replace, shortcut: enabled && settings.replaceOriginal ? settings.replaceShortcut : nil)
        hotKey.set(.copy, shortcut: enabled && settings.copyTranslation ? settings.copyShortcut : nil)
        hotKey.set(
            .translate,
            shortcut: enabled && settings.translationTiming == .shortcut ? settings.translateShortcut : nil)
        hotKey.set(
            .clipboard,
            shortcut: enabled && settings.clipboardTranslationEnabled ? settings.clipboardShortcut : nil)
    }

    /// Keeps the pasteboard watcher and the clipboard hotkey in sync with the
    /// clipboard settings and the app's master switch.
    func applyClipboardSettings() {
        guard runtimeEnabled else { return }
        let active = enabled && settings.clipboardTranslationEnabled
        if active && settings.clipboardTriggerMode == .autoWatch {
            pasteboardWatcher.start()
        } else {
            pasteboardWatcher.stop()
        }
        refreshHotKeys()
    }

    private func handleClipboardHotKey() {
        translateCopiedText(autoTriggered: false)
    }

    /// Translates the current clipboard content (hotkey) or the freshly
    /// copied text (auto watch). Auto mode only fires for text in the
    /// configured source language so code and links stay quiet.
    func translateCopiedText(_ rawText: String? = nil, autoTriggered: Bool) {
        guard enabled, settings.clipboardTranslationEnabled else { return }
        guard var text = (rawText ?? NSPasteboard.general.string(forType: .string))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        if text.count > 2000 { text = String(text.prefix(2000)) }
        if autoTriggered {
            // 黑名单应用保持完全静音：前台是排除应用时不触发剪贴板翻译
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                settings.excludedBundleIDs.contains(front) {
                return
            }
            guard LanguageTextDetector().contains(text, language: settings.sourceLanguage) else { return }
        }
        // 微信读书等阅读器复制出来的选区没有换行，先按句子重建段落，
        // 译文才能保持分段可读。
        text = TextParagraphing.restoreParagraphBreaks(text)
        let session = InputSessionID(pid: ProcessInfo.processInfo.processIdentifier)
        let requestID = UUID()
        let sentenceKey = "clipboard:\(text)"
        let configuration = configurationGeneration
        let backend = settings.translationBackend
        clearFailure(realtime: false)
        let sourceLanguage = settings.sourceLanguage, targetLanguage = settings.targetLanguage
        clipboardRequestID = requestID
        pendingOrigin = .clipboard
        pendingAction = PendingTranslationAction(
            text: nil, sourceWithTerminator: nil, session: session, sentenceKey: sentenceKey)
        DiagnosticLog.write("clipboard translation requested length=\(text.count)")
        logger.info("clipboard translation requested length=\(text.count, privacy: .public)")
        let coordinator = clipboardCoordinator
        Task { [weak self, coordinator] in
            guard await self?.configurationReady(configuration) == true, self?.clipboardRequestID == requestID else { return }
            do {
                let result = try await coordinator.translateThrowing(text, from: sourceLanguage, to: targetLanguage, revision: configuration)
                self?.acceptTranslationResult(result, sourceText: text, sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, key: sentenceKey, session: session,
                screen: NSScreen.main, origin: .clipboard, configuration: configuration,
                clipboardRequest: requestID, speak: false)
            } catch {
                guard self?.clipboardRequestID == requestID,
                    self?.configurationGeneration == configuration, self?.enabled == true else { return }
                if error is CancellationError {
                    self?.discardPending(key: sentenceKey, session: session)
                    return
                }
                self?.presentFailure(error, backend: backend, origin: .clipboard, key: sentenceKey, session: session)
            }
        }
    }

    private func clearFailure(realtime: Bool) {
        if realtime { realtimeFailure = nil; liveFailureNotice.hide() }
        else { clipboardFailure = nil; clipboardFailureNotice.hide() }
    }
    private func presentFailure(_ error: any Error, backend: TranslationBackend, origin: OverlayOrigin,
        key: String, session: InputSessionID) {
        discardPending(key: key, session: session)
        let message = TranslationFailureMessage.text(for: error, backend: backend, language: settings.uiLanguage)
        switch origin {
        case .realtime:
            overlay.hideRealtime()
            realtimeFailure = message
            liveFailureNotice.show(message, clipboard: false, language: settings.uiLanguage)
        case .clipboard:
            clipboardFailure = message
            clipboardFailureNotice.show(message, clipboard: true, language: settings.uiLanguage)
        case .fixed: break
        }
    }
    private func discardPending(key: String, session: InputSessionID) {
        if pendingAction?.session == session, pendingAction?.sentenceKey == key { clearPendingAction() }
    }

    private func handleTranslateHotKey() {
        guard enabled, settings.translationTiming == .shortcut else { return }
        guard let captured = monitor.snapshotNow() else { return }
        handleInputSnapshot(captured.snapshot, session: captured.session, screen: captured.screen, feedInput: false)
        input.translateNow(captured.snapshot, session: captured.session, screen: captured.screen)
    }

    private func handleReplaceHotKey() {
        guard enabled, settings.replaceOriginal else { return }
        if pendingAction?.text != nil, pendingAction?.sourceWithTerminator != nil {
            applyPendingReplace()
        } else if pendingAction != nil {
            pendingAction?.applyReplaceWhenReady = true
        }
    }

    private func handleCopyHotKey() {
        guard enabled, settings.copyTranslation else { return }
        if pendingAction?.text != nil {
            applyPendingCopy()
        } else if pendingAction != nil {
            pendingAction?.applyCopyWhenReady = true
        }
    }

    private func applyPendingReplace() {
        guard enabled, settings.replaceOriginal else { return }
        guard var pending = pendingAction, let translation = pending.text,
            let source = pending.sourceWithTerminator
        else { return }
        if monitor.replace(sourceWithTerminator: source, translation: translation,
            range: pending.sourceRange, expectedSession: pending.session) {
            pending.sourceWithTerminator = nil
            pending.sourceRange = nil
            pending.applyReplaceWhenReady = false
            pendingAction = pending
        }
    }

    private func applyPendingCopy() {
        guard enabled, settings.copyTranslation else { return }
        _ = TranslationClipboard.copy(pendingAction?.text)
        pasteboardWatcher.resyncBaseline()
        pendingAction?.applyCopyWhenReady = false
    }

    private func clearPendingAction() {
        pendingAction = nil
        pendingOrigin = nil
        translation = ""
    }

    deinit {
        // 授权观察器的 Task 持弱引用，应用退出时随 self 释放自行结束
        let watcher = pasteboardWatcher
        Task { @MainActor in watcher.stop() }
    }
}

/// Failure UI is separate from translation cards: no copy/replace/speech
/// controls, no source text, and no focus activation.
@MainActor
private final class TranslationFailureNotice {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    func show(_ message: String, clipboard: Bool, language: UILanguage) {
        hide()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 70),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        let labelTitle = clipboard ? (language == .chinese ? "剪贴板翻译" : "Clipboard Translation")
            : (language == .chinese ? "实时翻译" : "Realtime Translation")
        panel.title = "润物 · " + labelTitle
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 16, y: 12, width: 328, height: 46)
        label.isSelectable = false
        panel.contentView?.addSubview(label)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.minY + (clipboard ? 160 : 48)))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.hide()
        }
    }
    func hide() {
        dismissal?.cancel(); dismissal = nil
        panel?.close(); panel = nil
    }
}

private struct PendingTranslationAction {
    var text: String?
    var sourceWithTerminator: String?
    var sourceRange: NSRange? = nil
    var session: InputSessionID
    var sentenceKey: String
    var applyReplaceWhenReady = false
    var applyCopyWhenReady = false
}

struct AboutView: View {
    var language: UILanguage = .chinese
    @ObservedObject var autoUpdater: AutoUpdateController

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(
                width: 96, height: 96)
            Text(L10n.productName(language)).font(.largeTitle.bold())
            Text(L10n.version(language)).foregroundStyle(.secondary)
            Text(L10n.aboutBody(language)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(L10n.checkForUpdates(language)) {
                autoUpdater.checkManually()
            }
            .disabled(!AutoUpdateController.isSupported || autoUpdater.isBusy)
            if let statusText = autoUpdater.statusText(for: language) {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Divider()
            aboutLinkRow(
                label: L10n.aboutProjectRepo(language),
                title: "github.com/cmeng-CM/Runwu",
                urlString: "https://github.com/cmeng-CM/Runwu")
            aboutLinkRow(
                label: L10n.aboutContactAuthor(language),
                title: "xinzhu400@gmail.com",
                urlString: "mailto:xinzhu400@gmail.com")
        }
        .padding(28)
        .frame(maxWidth: 420)
    }

    private func aboutLinkRow(label: String, title: String, urlString: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let url = URL(string: urlString) {
                Link(title, destination: url).font(.caption)
            }
        }
    }
}

enum AddExcludedAppView {
    @MainActor static func openPanel(state: AppState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.begin { response in
            guard response == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else {
                return
            }
            state.settings.excludedBundleIDs.insert(bundleID)
            state.input.excludedBundleIDs = state.settings.excludedBundleIDs
            state.monitor.excludedBundleIDs = state.settings.excludedBundleIDs
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var state: AppState
    @State private var step = 0
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "character.bubble").font(.system(size: 42)).foregroundStyle(.blue)
            Text(
                step == 0
                    ? "Write in Chinese.\nSee it in English." : step == 1 ? "Accessibility Permission" : "Try it now"
            ).font(.title).multilineTextAlignment(.center)
            Text(
                step == 0
                        ? "润物 translates what you're typing without interrupting your workflow."
                        : step == 1
                            ? "Permission lets 润物 read only the editable text field. Password fields are always skipped."
                            : "Type something in Chinese in any supported text field."
            ).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if step == 1 && !state.permissionGranted {
                Button("Allow Permission") { state.requestPermission() }.buttonStyle(.borderedProminent)
            }
            if step == 1 {
                LanguageResourceRow(
                    language: state.settings.uiLanguage,
                    sourceLanguage: state.settings.sourceLanguage,
                    targetLanguage: state.settings.targetLanguage)
            }
            Spacer()
            Button(step == 2 ? "Done" : "Continue") { if step < 2 { step += 1 } else { state.finishOnboarding() } }
                .buttonStyle(.borderedProminent)
        }.padding(36)
    }
}

/// Production and the no-language-package harness share this actual SwiftUI
/// identity boundary. A-B-A still creates a new child, even though the final
/// language pair equals the pair in the preceding render.
struct TranslationHostGenerationView<Content: View>: View {
    @ObservedObject var holder: TranslationSessionHolder
    let content: (TranslationHostConfiguration) -> Content
    var body: some View {
        let request = holder.hostConfiguration
        content(request).id(request.generation)
    }
}

struct TranslationHostView: View {
    let holder: TranslationSessionHolder
    var body: some View {
        TranslationHostGenerationView(holder: holder) { request in
            TranslationHostTaskView(holder: holder, request: request)
        }
    }
}

private struct TranslationHostTaskView: View {
    let holder: TranslationSessionHolder
    let request: TranslationHostConfiguration
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(TranslationSession.Configuration(source: request.source.locale, target: request.target.locale)) { session in
                // Capture the child generation that created this native task;
                // never read a newer generation when an old task returns.
                holder.attach(session, configuration: request)
            }
    }
}

@MainActor final class TranslationHostWindowController {
    private let window: NSWindow

    init(holder: TranslationSessionHolder) {
        let panel = NSPanel(
            contentRect: NSRect(x: -2000, y: -2000, width: 8, height: 8),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: TranslationHostView(holder: holder))
        panel.orderFrontRegardless()
        window = panel
    }
}
