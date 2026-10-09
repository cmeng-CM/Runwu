import AppKit
import SwiftUI
import XCTest
@testable import Pico

@MainActor final class SettingsDockTests: XCTestCase {
    override func setUp() async throws { _ = NSApplication.shared }

    func testNativeHookCloseAndCachedUpdatesDoNotReopenDock() async throws {
        let effects = DockEffects(), controller = effects.controller
        controller.start()
        let window = makeWindow(), delegate = DockWindowDelegate()
        window.delegate = delegate
        defer { window.close() }
        let hook = SettingsWindowHookView(controller: controller, title: "Synthetic Settings")
        window.contentView!.addSubview(hook)
        XCTAssertEqual(controller.openSettingsWindowCount, 0, "Attaching to a hidden window only discovers it")
        XCTAssertTrue(window.delegate === delegate)
        window.makeKeyAndOrderFront(nil)
        window.update()
        try await wait { controller.openSettingsWindowCount == 1 }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, "Synthetic Settings")
        XCTAssertEqual(effects.policies, [.accessory, .regular])
        delegate.onClose = {
            // AppKit still reports visible during willClose. A redraw or late
            // native hook must not override the notification's closed state.
            hook.discoverWindow()
        }
        window.close()
        XCTAssertEqual(delegate.closes, 1)
        XCTAssertTrue(delegate.visibleDuringClose)
        XCTAssertEqual(controller.openSettingsWindowCount, 0)
        hook.settingsTitle = "Synthetic Updated"
        hook.discoverWindow()
        window.update()
        XCTAssertEqual(effects.policies, [.accessory, .regular, .accessory])
        window.makeKeyAndOrderFront(nil)
        try await wait { window.isVisible && controller.openSettingsWindowCount == 1 }
        XCTAssertEqual(effects.policies.last, .regular, "A real show transition reopens a cached scene window")
        XCTAssertTrue(window.delegate === delegate)
    }

    func testTwoSettingsWindowsUnrelatedWindowAndLateClose() async throws {
        let effects = DockEffects(), controller = effects.controller
        controller.start()
        let first = makeWindow(), second = makeWindow(), unrelated = makeWindow()
        defer { first.close(); second.close(); unrelated.close() }
        unrelated.makeKeyAndOrderFront(nil)
        unrelated.update()
        unrelated.close()
        XCTAssertEqual(effects.policies, [.accessory])
        controller.showSettingsWindow(first)
        controller.showSettingsWindow(first)
        controller.showSettingsWindow(second)
        XCTAssertEqual(controller.openSettingsWindowCount, 2)
        first.close()
        XCTAssertEqual(controller.openSettingsWindowCount, 1)
        XCTAssertEqual(effects.policies.last, .regular)
        // An obsolete window's duplicate/late notification cannot hide the
        // newer window. Closure is synchronous; no deferred policy task races.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
        controller.registerSettingsWindow(first)
        XCTAssertEqual(controller.openSettingsWindowCount, 1)
        second.close()
        second.close()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible, "Queued activation must not reopen a closed settings window")
        XCTAssertEqual(effects.policies, [.accessory, .regular, .accessory])
    }

    func testAppEntryReusesClosedWindowAndDockReopenRestoresSettings() async throws {
        let fixture = DockAppFixture()
        defer { fixture.close() }
        fixture.controller.start()
        let first = fixture.app.presentSettings()
        try await wait { self.hooks(in: first.contentView!).count == 1 }
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 1)
        XCTAssertTrue(fixture.app.presentSettings() === first)
        first.close()
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 0)
        fixture.store.uiLanguage = .english
        try await Task.sleep(for: .milliseconds(30))
        for hook in hooks(in: first.contentView!) { hook.discoverWindow() }
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 0)
        XCTAssertTrue(fixture.app.presentSettings() === first)
        XCTAssertEqual(first.title, L10n.settingsWindowTitle(.english))
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 1)
        XCTAssertEqual(fixture.effects.policies.last, .regular)
        let unrelated = makeWindow()
        unrelated.orderFront(nil)
        defer { unrelated.close() }
        let delegate = AppDelegate(state: fixture.app)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        try await wait { !first.isMiniaturized && first.isVisible }
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 1)
        first.close()
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(fixture.app.presentSettings() === first)
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 1)
        XCTAssertEqual(fixture.pasteboard.reads, 0)
    }

    func testSettingsViewNativeHookDiscoversSceneStyleWindowWithoutAppEntry() async throws {
        let fixture = DockAppFixture(), window = makeWindow()
        defer { window.close(); fixture.close() }
        fixture.controller.start()
        let delegate = DockWindowDelegate()
        window.delegate = delegate
        window.contentView = NSHostingView(rootView: SettingsView(state: fixture.app))
        window.makeKeyAndOrderFront(nil)
        try await wait { fixture.controller.openSettingsWindowCount == 1 && !self.hooks(in: window.contentView!).isEmpty }
        XCTAssertTrue(window.delegate === delegate)
        XCTAssertEqual(fixture.effects.policies.last, .regular)
        window.close()
        XCTAssertEqual(fixture.effects.policies.last, .accessory)
        for hook in hooks(in: window.contentView!) { hook.discoverWindow() }
        XCTAssertEqual(fixture.controller.openSettingsWindowCount, 0)
        window.makeKeyAndOrderFront(nil)
        try await wait { window.isVisible && fixture.controller.openSettingsWindowCount == 1 }
        XCTAssertEqual(fixture.pasteboard.reads, 0)
    }

    func testFailedPolicyIsReportedAndRetried() {
        var allow = false, attempts = 0
        let controller = SettingsDockController(setPolicy: { _ in attempts += 1; return allow }, activate: {})
        controller.start()
        XCTAssertEqual(controller.lastPolicyChangeSucceeded, false)
        allow = true
        controller.start()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(controller.lastPolicyChangeSucceeded, true)
        controller.start()
        XCTAssertEqual(attempts, 2)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 860, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func hooks(in view: NSView) -> [SettingsWindowHookView] {
        (view as? SettingsWindowHookView).map { [$0] } ?? view.subviews.flatMap { hooks(in: $0) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native settings window transition did not finish")
    }
}

@MainActor private final class DockEffects {
    var policies: [NSApplication.ActivationPolicy] = []
    var activations = 0
    lazy var controller = SettingsDockController(setPolicy: { [weak self] in self?.policies.append($0); return true },
        activate: { [weak self] in self?.activations += 1 })
}

@MainActor private final class DockWindowDelegate: NSObject, NSWindowDelegate {
    var closes = 0, visibleDuringClose = false
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        closes += 1
        visibleDuringClose = (notification.object as? NSWindow)?.isVisible ?? false
        onClose?()
    }
}

private struct DockKeys: ModelKeyStoring {
    func apiKey(forModelID id: UUID) throws -> String? { nil }
    func setAPIKey(_ value: String?, forModelID id: UUID) throws {}
    func deleteAPIKey(forModelID id: UUID) throws {}
}
private actor DockEngine: TranslationEngine {
    func translate(_ text: String, from: Language, to: Language) async throws -> String { "Synthetic." }
}
@MainActor private final class DockSpeech: SpeechPerforming {
    func speak(_ text: String, language: Language) {}
    func stop() {}
}
@MainActor private final class DockPasteboard: PasteboardReading {
    var changeCount = 0, reads = 0
    func readString() -> String? { reads += 1; return nil }
}
@MainActor private final class DockAppFixture {
    let suite = "RunwuSettingsDock.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RunwuSettingsDock-\(UUID())")
    let store: SettingsStore
    let effects = DockEffects(), pasteboard = DockPasteboard(), engine = DockEngine()
    var controller: SettingsDockController { effects.controller }
    lazy var app = AppState(settings: store, translationEngine: engine,
        historyDatabaseURL: directory.appendingPathComponent("history.sqlite"), startRuntime: false,
        engines: Dictionary(uniqueKeysWithValues: TranslationBackend.allCases.map { ($0, engine as any TranslationEngine) }),
        modelFactory: { _, _ in DockEngine() }, speech: DockSpeech(), clipboardReader: pasteboard,
        frontmostBundleIdentifier: { nil }, settingsDockController: controller)
    init() { store = SettingsStore(defaults: UserDefaults(suiteName: suite)!, modelKeyStorage: DockKeys()) }
    func close() {
        if controller.openSettingsWindowCount > 0 { app.presentSettings().close() }
        app.overlay.hide(); app.input.reset()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
