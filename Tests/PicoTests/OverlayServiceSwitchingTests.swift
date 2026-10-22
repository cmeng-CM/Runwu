import AppKit
import SwiftUI
import XCTest
@testable import Pico

@MainActor final class OverlayServiceSwitchingTests: XCTestCase {
    private var apps: [AppState] = []
    private var suites: [(UserDefaults, String)] = []
    private var directories: [URL] = []
    override func setUp() async throws { _ = NSApplication.shared }
    override func tearDown() async throws {
        for app in apps { app.overlay.hide(); app.input.reset(); app.applyTranslationSettings() }
        for (defaults, name) in suites { defaults.removePersistentDomain(forName: name) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    func testNativeControlHitTestAndMenuActionSwitchBothOriginsWithoutReadingOrWritingInput() async throws {
        for clipboard in [false, true] {
            let old = SwitchEngine("Old."), new = SwitchEngine("New.")
            let app = makeApp(engines: [.google: old, .bing: new])
            if clipboard { app.translateCopiedText("原文 + 😀。", autoTriggered: false) }
            else { sendLive(app, "原文 + 😀。") }
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            let id = try XCTUnwrap(app.overlay.shownEntryIDs.first)
            let button = try control(app.overlay)
            let panel = try XCTUnwrap(button.window)
            let root = try XCTUnwrap(panel.contentView)
            root.layoutSubtreeIfNeeded()
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: root)
            let hit = try XCTUnwrap(root.hitTest(root.convert(center, to: root.superview)))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button), "Service must receive the real native hit")
            XCTAssertFalse(button.window!.isKeyWindow)
            XCTAssertTrue(button.window!.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(button.needsPanelToBecomeKey)
            XCTAssertTrue(button.acceptsFirstMouse(for: nil))
            let menu = try XCTUnwrap(button.menu)
            XCTAssertEqual(menu.items.dropFirst().map(\.representedObject).compactMap { $0 as? String },
                TranslationBackend.allCases.map(\.rawValue))
            XCTAssertEqual(menu.items.filter { $0.state == .on }.first?.representedObject as? String, "google")
            menu.performActionForItem(at: try index(.bing, menu))
            try await wait { app.overlay.translationContext(for: id)?.backend == .bing }
            XCTAssertEqual(app.settings.translationBackend, .bing)
            XCTAssertEqual(suites.last!.0.string(forKey: "translationBackend"), "bing")
            XCTAssertEqual(app.overlay.shownEntryIDs, [id])
            XCTAssertEqual(app.overlay.cardContents.first?.translation, "New.")
            let newRequests = await new.requests
            XCTAssertEqual(newRequests, [SwitchRequest(text: "原文 + 😀。", source: .chinese, target: .english)])
            XCTAssertFalse(app.hasPendingTranslationAction)
            XCTAssertFalse(panel.isKeyWindow)
        }
    }

    func testPinnedOldDirectionUsesTemporaryAppleHolderHostAndKeepsOtherCardAndGlobalDirection() async throws {
        let old = SwitchEngine("Old."), local = SwitchGate()
        let app = makeApp(engines: [.google: old, .local: local])
        app.translateCopiedText("旧方向原文。", autoTriggered: false)
        try await wait { app.overlay.shownEntryIDs.count == 1 }
        let id = app.overlay.shownEntryIDs[0]
        app.overlay.togglePin(of: id)
        app.settings.targetLanguage = .japanese
        app.translateCopiedText("另一张原文。", autoTriggered: false)
        try await wait { app.overlay.shownEntryIDs.count == 2 }
        let other = app.overlay.shownEntryIDs[1]
        app.overlay.togglePin(of: other)
        let otherContext = app.overlay.translationContext(for: other)
        let origin = app.overlay.visiblePanelFrames[0].origin
        app.selectOverlayService(id, backend: .local)
        try await wait { await local.requests.count == 1 }
        let config = try XCTUnwrap(app.temporaryOverlayHostConfigurations.first)
        XCTAssertEqual(config.source, .chinese); XCTAssertEqual(config.target, .english)
        XCTAssertEqual(app.translationHolder.hostConfiguration.target, .japanese)
        XCTAssertEqual(app.settings.targetLanguage, .japanese)
        XCTAssertEqual(app.overlay.pendingService(for: id), .local)
        XCTAssertEqual(app.overlay.translationContext(for: id)?.backend, .google)
        await local.complete(0, "Apple result.")
        try await wait { app.overlay.translationContext(for: id)?.backend == .local }
        XCTAssertTrue(app.temporaryOverlayHostConfigurations.isEmpty)
        XCTAssertEqual(app.overlay.shownEntryIDs, [id, other])
        XCTAssertEqual(app.overlay.translationContext(for: other), otherContext)
        XCTAssertEqual(app.overlay.visiblePanelFrames[0].minX, origin.x, accuracy: 1)
        let requests = await local.requests
        XCTAssertEqual(requests, [SwitchRequest(text: "旧方向原文。", source: .chinese, target: .english)])
    }

    func testFailureKeepsOldResultAndServiceAndSameServiceSelectionIsNoOp() async throws {
        let old = SwitchEngine("Old."), failing = SwitchEngine(nil)
        let app = makeApp(engines: [.google: old, .youdao: failing])
        app.translateCopiedText("原文。", autoTriggered: false)
        try await wait { app.overlay.shownEntryIDs.count == 1 }
        let id = app.overlay.shownEntryIDs[0]
        app.selectOverlayService(id, backend: .google)
        try await Task.sleep(for: .milliseconds(20))
        let oldCount = await old.requests.count
        XCTAssertEqual(oldCount, 1)
        app.selectOverlayService(id, backend: .youdao)
        try await wait { app.overlay.serviceFailure(for: id) != nil }
        XCTAssertEqual(app.overlay.translationContext(for: id)?.backend, .google)
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "Old.")
        XCTAssertEqual(app.settings.translationBackend, .youdao)
        XCTAssertFalse(app.hasPendingTranslationAction)
    }

    func testRapidABCAndABARejectNonCooperativeOldReplies() async throws {
        for returnToA in [false, true] {
            let google = SwitchGate(), bing = SwitchGate(), youdao = SwitchGate()
            let app = makeApp(engines: [.google: google, .bing: bing, .youdao: youdao])
            app.translateCopiedText("原文。", autoTriggered: false)
            try await wait { await google.requests.count == 1 }; await google.complete(0, "Initial.")
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            let id = app.overlay.shownEntryIDs[0]
            app.selectOverlayService(id, backend: .bing)
            try await wait { await bing.requests.count == 1 }
            let final: TranslationBackend = returnToA ? .google : .youdao
            app.selectOverlayService(id, backend: final)
            if returnToA { try await wait { await google.requests.count == 2 }; await google.complete(1, "Final.") }
            else { try await wait { await youdao.requests.count == 1 }; await youdao.complete(0, "Final.") }
            try await wait { app.overlay.translationContext(for: id)?.backend == final }
            await bing.complete(0, "LATE.")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(app.overlay.shownEntryIDs, [id])
            XCTAssertEqual(app.overlay.cardContents.first?.translation, "Final.")
        }
    }

    func testClosePauseOrdinarySettingsAndNewLiveInputInvalidateLateReply() async throws {
        for event in 0..<4 {
            let old = SwitchEngine("Old."), gate = SwitchGate()
            let app = makeApp(engines: [.google: old, .bing: gate])
            sendLive(app, "原句。")
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            let id = app.overlay.shownEntryIDs[0]
            app.selectOverlayService(id, backend: .bing)
            try await wait { await gate.requests.count == 1 }
            switch event {
            case 0: (app.overlay.panelContentViews[0] as! NSHostingView<TranslationOverlayView>).rootView.onClose()
            case 1: app.toggle()
            case 2: app.settings.targetLanguage = .japanese
            default: sendLive(app, "新句尚未完成")
            }
            await gate.complete(0, "LATE.")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(app.overlay.translationContext(for: id))
            XCTAssertFalse(app.overlay.cardContents.contains { $0.translation == "LATE." })
        }
    }

    func testMenuTrackingAndInFlightSuspendTimerThenResume() async throws {
        let old = SwitchEngine("Old."), gate = SwitchGate()
        let app = makeApp(engines: [.google: old, .bing: gate])
        app.overlay.neverHide = false; app.overlay.hideAfter = 0.04
        app.overlay.cursorOverCard = { _ in false }
        app.translateCopiedText("原文。", autoTriggered: false)
        try await wait { app.overlay.shownEntryIDs.count == 1 }
        let id = app.overlay.shownEntryIDs[0], button = try control(app.overlay)
        let menu = try XCTUnwrap(button.menu)
        // Native NSMenu tracking delivers the actual delegate while performClick opens the control.
        let driver = SwitchMenuDriver(app: app, card: id, menu: menu, index: try index(.bing, menu))
        let trackingTimer = Timer(timeInterval: 0.12, target: driver,
            selector: #selector(SwitchMenuDriver.fire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(trackingTimer, forMode: .eventTracking)
        button.performClick(nil)
        trackingTimer.invalidate()
        XCTAssertTrue(driver.observedTracking)
        XCTAssertFalse(app.overlay.isMenuOpen(id), "Old native delegate must close after hosting-view replacement")
        try await wait { await gate.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(app.overlay.shownEntryIDs, [id])
        await gate.complete(0, "New.")
        try await wait { app.overlay.translationContext(for: id)?.backend == .bing }
        try await wait { app.overlay.shownEntryIDs.isEmpty }
    }

    func testLongPinnedRetranslationKeepsTopLeftAndNativeControlsAcrossThemes() async throws {
        let old = SwitchEngine("Short."), long = SwitchEngine(String(repeating: "Long translated paragraph. ", count: 160))
        for theme in OverlayTheme.allCases {
            let app = makeApp(engines: [.google: old, .bing: long])
            app.overlay.theme = theme
            app.translateCopiedText("原文。", autoTriggered: false)
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            let id = app.overlay.shownEntryIDs[0]
            app.overlay.togglePin(of: id)
            let panel = try XCTUnwrap(app.overlay.panelContentViews[0].window)
            panel.setFrameOrigin(NSPoint(x: 190, y: 280))
            let x = panel.frame.minX, top = panel.frame.maxY
            try save(panel, name: "short-\(theme.rawValue)")
            app.selectOverlayService(id, backend: .bing)
            try await wait { app.overlay.translationContext(for: id)?.backend == .bing }
            XCTAssertEqual(panel.frame.minX, x, accuracy: 1)
            XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
            XCTAssertLessThanOrEqual(panel.frame.height, 460)
            let root = app.overlay.panelContentViews[0] as! NSHostingView<TranslationOverlayView>
            XCTAssertTrue(root.rootView.contentPinned)
            XCTAssertNotNil(root.rootView.textHeightLimit)
            let button = try control(app.overlay)
            // 译文区改成拖选后：正文中心交给文本选择层，标题栏仍是拖动区。
            let body = root.hitTest(root.convert(NSPoint(x: root.bounds.midX, y: root.bounds.midY), to: root.superview))
            XCTAssertFalse(body is WindowDragCatcherView, "译文区交给文本选择层")
            let headerPoint = NSPoint(x: root.bounds.midX, y: root.isFlipped ? 8 : root.bounds.maxY - 8)
            let header = root.hitTest(root.convert(headerPoint, to: root.superview))
            XCTAssertTrue(header is WindowDragCatcherView, "标题栏仍是拖动区")
            XCTAssertFalse(button.window!.isKeyWindow)
            try save(panel, name: "long-\(theme.rawValue)")
            app.overlay.settleResize(of: id, to: 120)
            app.settings.translationBackend = .youdao
            let refreshed = app.overlay.panelContentViews[0] as! NSHostingView<TranslationOverlayView>
            XCTAssertEqual(refreshed.rootView.textHeightLimit, 120,
                "Only a global checkmark changed; another card's resized viewport must survive")
        }
    }

    func testStatusCardNativeResizeKeepsMeasuredChromeBodyBudgetAndControls() async throws {
        for contentPinned in [false, true] {
            for state in ["loading", "failure", "plain"] {
                let overlay = OverlayCoordinator()
                overlay.neverHide = true
                defer { overlay.hide() }
                let context = OverlayTranslationContext(sourceText: "保存的原文。", sourceLanguage: .chinese,
                    targetLanguage: .english, backend: .google)
                // Use a real result card with the native service menu and header controls.
                overlay.show(String(repeating: "Long translated paragraph. ", count: 160), key: state,
                    on: NSScreen.main, origin: .clipboard, translationContext: context)
                let id = try XCTUnwrap(overlay.shownEntryIDs.first)
                if contentPinned { overlay.togglePin(of: id) }
                if state == "loading" { overlay.beginRetranslation(id, backend: .bing) }
                if state == "failure" { overlay.finishRetranslation(id, failure: "服务暂时不可用，请稍后重试。") }
                let host = try XCTUnwrap(overlay.panelContentViews.first as? NSHostingView<TranslationOverlayView>)
                let panel = try XCTUnwrap(host.window)
                host.layoutSubtreeIfNeeded()
                let initialBody = try XCTUnwrap(host.rootView.textHeightLimit)
                let chrome = panel.frame.height - initialBody
                let x = panel.frame.minX, top = panel.frame.maxY
                XCTAssertEqual(host.rootView.serviceStatus != nil, state != "plain")
                for body: CGFloat in [180, 240] {
                    // Drive the installed view's drag callbacks, then let its recorded
                    // limit render through the existing menu-checkmark refresh path.
                    host.rootView.onResize(body)
                    overlay.selectedService = overlay.selectedService == .local ? .bing : .local
                    host.layoutSubtreeIfNeeded()
                    // Unpinned clipboard relayout consumes recordResize's planned
                    // budget independently of the final settle calculation.
                    if !contentPinned {
                        overlay.followCaret.toggle()
                        XCTAssertEqual(panel.frame.height, body + chrome, accuracy: 1, state + " recorded")
                    }
                    host.rootView.onResizeEnd(body)
                    host.layoutSubtreeIfNeeded()
                    let settledFrame = panel.frame
                    XCTAssertEqual(settledFrame.height, body + chrome, accuracy: 1, state)
                    XCTAssertEqual(host.fittingSize.height, body + chrome, accuracy: 1, state)
                    XCTAssertEqual(host.rootView.textHeightLimit, body)
                    XCTAssertEqual(panel.frame.minX, x, accuracy: 1)
                    XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
                    XCTAssertEqual(host.rootView.contentPinned, contentPinned)
                    XCTAssertEqual(host.rootView.serviceStatus != nil, state != "plain")
                    let button = try control(overlay)
                    XCTAssertTrue(host.bounds.contains(button.convert(button.bounds, to: host)))
                    // Native hit testing retains all three chips and the bottom handle;
                    // the central body remains the existing drag/scroll catcher.
                    let bottom = NSPoint(x: host.bounds.midX, y: host.isFlipped ? host.bounds.maxY - 8 : 8)
                    let handle = host.hitTest(host.convert(bottom, to: host.superview))
                    XCTAssertNotNil(handle); XCTAssertFalse(handle is WindowDragCatcherView)
                    for inset: CGFloat in contentPinned ? [23, 51, 79] : [23, 51] {
                        let point = NSPoint(x: host.bounds.maxX - inset, y: host.isFlipped ? 21 : host.bounds.maxY - 21)
                        let hit = host.hitTest(host.convert(point, to: host.superview))
                        XCTAssertNotNil(hit); XCTAssertFalse(hit is WindowDragCatcherView)
                    }
                    // 译文区改成拖选后：标题栏仍是拖拽层，正文中心让给文本选择层。
                    let headerPoint = NSPoint(
                        x: host.bounds.midX,
                        y: host.isFlipped ? 8 : host.bounds.maxY - 8)
                    let headerHit = host.hitTest(host.convert(headerPoint, to: host.superview))
                    XCTAssertTrue(headerHit is WindowDragCatcherView, "标题栏仍负责拖动")
                    let bodyHit = host.hitTest(host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: host.superview))
                    XCTAssertFalse(bodyHit is WindowDragCatcherView, "译文区应让给文本选择层")
                    print("STATUS_RESIZE", state, "body", body, "chrome", chrome,
                        "pinned", contentPinned, "settledFrame", settledFrame, "fitting", host.fittingSize)
                    try save(panel, name: "resize-\(state)-\(contentPinned)-\(Int(body))")
                }
            }
        }
    }

    func testTemporaryAppleHostIsReleasedOnCancellationWithoutTouchingGlobalHolder() async throws {
        let old = SwitchEngine("Old."), gate = SwitchGate()
        let app = makeApp(engines: [.google: old, .local: gate])
        app.translateCopiedText("原文。", autoTriggered: false)
        try await wait { app.overlay.shownEntryIDs.count == 1 }
        let id = app.overlay.shownEntryIDs[0]
        app.overlay.togglePin(of: id)
        app.settings.targetLanguage = .german
        let global = app.translationHolder.hostConfiguration
        let windowsBefore = Set(NSApp.windows.map(\.windowNumber))
        app.selectOverlayService(id, backend: .local)
        try await wait { await gate.requests.count == 1 }
        XCTAssertEqual(app.temporaryOverlayHostConfigurations.first?.target, .english)
        let temporary = NSApp.windows.filter { !windowsBefore.contains($0.windowNumber) }
        XCTAssertEqual(temporary.count, 1)
        XCTAssertTrue(temporary[0].isVisible)
        app.settings.llmFallbackTimeout += 1
        XCTAssertTrue(app.temporaryOverlayHostConfigurations.isEmpty)
        XCTAssertFalse(temporary[0].isVisible)
        XCTAssertNil(temporary[0].contentView)
        XCTAssertEqual(app.translationHolder.hostConfiguration, global)
        await gate.complete(0, "LATE.")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(app.overlay.translationContext(for: id)?.backend, .google)
    }

    private func save(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["RUNWU_T2_NATIVE_OUTPUT"] else { return }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let url = URL(fileURLWithPath: path).appendingPathComponent(name + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    func testAllFiveExplicitRoutesUseInjectedFactoryAndOldCardCanSelectCurrentGlobalService() async throws {
        for backend in TranslationBackend.allCases {
            let initial = SwitchEngine("Initial."), selected = SwitchEngine("Selected.")
            var engines: [TranslationBackend: any TranslationEngine] = [.google: initial]
            engines[backend] = selected
            let app = makeApp(engines: engines, modelFactory: { _, _ in selected })
            // Build the accepted card before a global edit, including Google selecting itself from an older result.
            let oldBackend: TranslationBackend = backend == .google ? .bing : .google
            let context = OverlayTranslationContext(sourceText: "保存的原文 😀。", sourceLanguage: .chinese,
                targetLanguage: .english, backend: oldBackend)
            app.overlay.show("Initial.", key: UUID().uuidString, on: NSScreen.main,
                origin: .clipboard, translationContext: context)
            let id = app.overlay.shownEntryIDs[0]
            app.overlay.togglePin(of: id)
            app.settings.translationBackend = backend
            let button = try control(app.overlay)
            let menu = try XCTUnwrap(button.menu)
            menu.performActionForItem(at: try index(backend, menu))
            try await wait { app.overlay.translationContext(for: id)?.backend == backend }
            let requests = await selected.requests
            XCTAssertEqual(requests, [SwitchRequest(text: context.sourceText, source: .chinese, target: .english)])
            XCTAssertEqual(app.overlay.cardContents.first?.translation, "Selected.")
            try save(button.window ?? app.overlay.panelContentViews[0].window!, name: "service-\(backend.rawValue)")
        }
    }

    func testCooperativeEngineCancellationReachesRequestTask() async throws {
        let old = SwitchEngine("Old."), cancellable = SwitchCancellable()
        let app = makeApp(engines: [.google: old, .bing: cancellable])
        app.translateCopiedText("原文。", autoTriggered: false)
        try await wait { app.overlay.shownEntryIDs.count == 1 }
        let id = app.overlay.shownEntryIDs[0]
        app.selectOverlayService(id, backend: .bing)
        try await wait { await cancellable.started }
        app.settings.targetLanguage = .japanese
        try await wait { await cancellable.cancelled }
        XCTAssertNil(app.overlay.translationContext(for: id))
    }

    private func makeApp(engines: [TranslationBackend: any TranslationEngine],
        modelFactory: @escaping TranslationService.ModelFactory = { LLMModelRouter(models: $0, timeoutSeconds: $1) }) -> AppState {
        let name = "OverlaySwitch.\(UUID())", defaults = UserDefaults(suiteName: name)!
        suites.append((defaults, name))
        let settings = SettingsStore(defaults: defaults, modelKeyStorage: SwitchKeys())
        settings.translationBackend = .google; settings.overlayFollowCaret = false
        settings.neverHide = true; settings.clipboardTranslationEnabled = true
        settings.translationTiming = .completeSentence
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(dir)
        let app = AppState(settings: settings, historyDatabaseURL: dir.appendingPathComponent("h.sqlite"),
            startRuntime: false, engines: engines, modelFactory: modelFactory, clipboardReader: SwitchClipboard())
        apps.append(app); return app
    }
    private func sendLive(_ app: AppState, _ text: String) {
        app.monitor.onSnapshot?(TextSnapshot(pid: 1, bundleIdentifier: "switch.fixture", text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0)), InputSessionID(pid: 1), NSScreen.main)
    }
    private func control(_ overlay: OverlayCoordinator) throws -> OverlayServicePopUpButton {
        let root = try XCTUnwrap(overlay.panelContentViews.first)
        root.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> OverlayServicePopUpButton? {
            if let button = view as? OverlayServicePopUpButton { return button }
            for child in view.subviews { if let button = find(child) { return button } }
            return nil
        }
        return try XCTUnwrap(find(root))
    }
    private func index(_ backend: TranslationBackend, _ menu: NSMenu) throws -> Int {
        try XCTUnwrap(menu.items.firstIndex { $0.representedObject as? String == backend.rawValue })
    }
    private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Switch timeout", file: file, line: line)
        throw NSError(domain: "OverlaySwitchWait", code: 1)
    }
}
private struct SwitchRequest: Equatable, Sendable { let text: String; let source: Language; let target: Language }
private actor SwitchEngine: TranslationEngine {
    let result: String?
    private(set) var requests: [SwitchRequest] = []
    init(_ result: String?) { self.result = result }
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        requests.append(SwitchRequest(text: text, source: from, target: to))
        guard let result else { throw URLError(.badServerResponse) }; return result
    }
}
private actor SwitchGate: TranslationEngine {
    private(set) var requests: [SwitchRequest] = []
    private var continuations: [Int: CheckedContinuation<String, Never>] = [:]
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        let index = requests.count
        requests.append(SwitchRequest(text: text, source: from, target: to))
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func complete(_ index: Int, _ result: String) { continuations.removeValue(forKey: index)?.resume(returning: result) }
}
private struct SwitchKeys: ModelKeyStoring {
    func apiKey(forModelID id: UUID) throws -> String? { nil }
    func setAPIKey(_ value: String?, forModelID id: UUID) throws {}
    func deleteAPIKey(forModelID id: UUID) throws {}
}
@MainActor private final class SwitchClipboard: PasteboardReading {
    var changeCount: Int { 0 }
    func readString() -> String? { XCTFail("Explicit service selection must not read clipboard"); return nil }
}

@MainActor private final class SwitchMenuDriver: NSObject {
    let app: AppState, card: UUID, menu: NSMenu, index: Int
    var observedTracking = false
    init(app: AppState, card: UUID, menu: NSMenu, index: Int) {
        self.app = app; self.card = card; self.menu = menu; self.index = index
    }
    @objc func fire(_ timer: Timer) {
        observedTracking = app.overlay.isMenuOpen(card)
        print("NATIVE_TRACKING", observedTracking, "options", menu.items.dropFirst().map(\.title))
        if let path = ProcessInfo.processInfo.environment["RUNWU_T2_NATIVE_OUTPUT"] {
            let cardWindow = app.overlay.panelContentViews.first?.window
            for window in NSApp.windows where window.isVisible &&
                (window === cardWindow || String(describing: type(of: window)) == "NSPopupMenuWindow") {
                guard let view = window.contentView,
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent(window === cardWindow
                        ? "expanded-card.png" : "expanded-menu.png"))
                print("NATIVE_TRACKING_WINDOW", type(of: window), window.frame)
            }
        }
        menu.performActionForItem(at: index)
        menu.cancelTrackingWithoutAnimation()
    }
}

private actor SwitchCancellable: TranslationEngine {
    private(set) var started = false, cancelled = false
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        started = true
        do { try await Task.sleep(for: .seconds(20)); return "Unexpected." }
        catch { cancelled = true; throw error }
    }
}
