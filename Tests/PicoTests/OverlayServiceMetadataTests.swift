import AppKit
import SwiftUI
import XCTest
@testable import Pico

@MainActor
final class OverlayServiceMetadataTests: XCTestCase {
    private var apps: [AppState] = []
    private var overlays: [OverlayCoordinator] = []
    private var suites: [(UserDefaults, String)] = []
    private var directories: [URL] = []

    override func setUp() async throws { _ = NSApplication.shared }
    override func tearDown() async throws {
        for app in apps { app.input.reset(); app.overlay.hide(); app.applyTranslationSettings() }
        overlays.forEach { $0.hide() }
        for (defaults, name) in suites { defaults.removePersistentDomain(forName: name) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    func testAllFiveNormalRoutesKeepBothOriginsSourceDirectionAndResultService() async throws {
        for backend in TranslationBackend.allCases {
            let engine = MetadataEngine("Fixture translation.")
            let app = makeApp(backend: backend, engines: [backend: engine])
            sendLive(app, "实时原文。")
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            app.translateCopiedText("剪贴板原文。", autoTriggered: false)
            try await wait { app.overlay.shownEntryIDs.count == 2 }
            let requests = await engine.requests
            XCTAssertEqual(requests.map(\.text), ["实时原文。", "剪贴板原文。"])
            XCTAssertTrue(requests.allSatisfy { $0.source == .chinese && $0.target == .english })
            for (id, text) in zip(app.overlay.shownEntryIDs, requests.map(\.text)) {
                XCTAssertEqual(app.overlay.translationContext(for: id), OverlayTranslationContext(
                    sourceText: text, sourceLanguage: .chinese, targetLanguage: .english, backend: backend))
            }
            XCTAssertEqual(try header(app.overlay, at: 0), "润物 · " + backend.displayName(for: .chinese))
            XCTAssertEqual(try header(app.overlay, at: 1), "润物 · " + backend.displayName(for: .chinese))
            // Stored clipboard context does not change its existing body presentation.
            XCTAssertNil(app.overlay.cardContents.last?.source)
        }
    }

    func testPinnedResultsRetainServiceAndDirectionAfterGlobalChangeAndUIRefresh() async throws {
        for clipboard in [false, true] {
            let old = MetadataEngine("Old result."), current = MetadataEngine("New result.")
            let app = makeApp(backend: .youdao, engines: [.youdao: old, .bing: current])
            if clipboard { app.translateCopiedText("旧原文。", autoTriggered: false) }
            else { sendLive(app, "旧原文。") }
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            let id = try XCTUnwrap(app.overlay.shownEntryIDs.first)
            app.overlay.togglePin(of: id)
            let context = try XCTUnwrap(app.overlay.translationContext(for: id))
            let frame = app.overlay.visiblePanelFrames.first
            app.settings.translationBackend = .bing
            app.settings.targetLanguage = .japanese
            app.translateCopiedText("新原文。", autoTriggered: false)
            try await wait { app.overlay.shownEntryIDs.count == 2 }
            app.settings.uiLanguage = .english
            app.overlay.refreshAppearance()
            XCTAssertEqual(app.overlay.translationContext(for: id), context)
            XCTAssertEqual(context.backend, .youdao)
            XCTAssertEqual(context.targetLanguage, .english)
            XCTAssertEqual(try header(app.overlay, at: 0), "润物 · Youdao")
            XCTAssertEqual(app.overlay.visiblePanelFrames.first, frame)
            let newID = try XCTUnwrap(app.overlay.shownEntryIDs.last)
            XCTAssertEqual(app.overlay.translationContext(for: newID)?.backend, .bing)
            XCTAssertEqual(app.overlay.translationContext(for: newID)?.targetLanguage, .japanese)
        }
    }

    func testRefreshUpdatesContextWithSameCardIdentityAndUnknownPreviewClearsIt() throws {
        let overlay = makeOverlay()
        let first = OverlayTranslationContext(sourceText: "第一句。", sourceLanguage: .chinese,
            targetLanguage: .english, backend: .google)
        overlay.show("First.", key: "same", on: NSScreen.main, origin: .clipboard, translationContext: first)
        let id = try XCTUnwrap(overlay.shownEntryIDs.first)
        let second = OverlayTranslationContext(sourceText: "第二句。", sourceLanguage: .chinese,
            targetLanguage: .french, backend: .bing)
        overlay.show("Second.", key: "same", on: NSScreen.main, origin: .clipboard, translationContext: second)
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        XCTAssertEqual(overlay.translationContext(for: id), second)
        XCTAssertEqual(try header(overlay), "润物 · Bing")
        overlay.show("Preview.", key: "same", on: NSScreen.main, origin: .clipboard)
        XCTAssertNil(overlay.translationContext(for: id))
        XCTAssertEqual(try header(overlay), "润物 · " + L10n.previewOverlay(.chinese))
    }

    func testPreviewHasNoOriginalDirectionProviderOrTranslationRequest() async throws {
        let engine = MetadataEngine("Should not run.")
        let app = makeApp(backend: .local, engines: [.local: engine])
        app.showOverlayTest()
        let id = try XCTUnwrap(app.overlay.shownEntryIDs.first)
        XCTAssertNil(app.overlay.translationContext(for: id))
        XCTAssertEqual(try header(app.overlay), "润物 · " + L10n.previewOverlay(.chinese))
        app.settings.uiLanguage = .english
        XCTAssertEqual(try header(app.overlay), "润物 · " + L10n.previewOverlay(.english))
        let requests = await engine.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLateOldServiceCompletionCannotReplaceCurrentMetadataForEitherOrigin() async throws {
        for clipboard in [false, true] {
            let old = MetadataGateEngine(), current = MetadataEngine("Current result.")
            let app = makeApp(backend: .google, engines: [.google: old, .bing: current])
            if clipboard { app.translateCopiedText("旧原文。", autoTriggered: false) }
            else { sendLive(app, "旧原文。") }
            try await wait { await old.started }
            app.settings.translationBackend = .bing
            if clipboard { app.translateCopiedText("新原文。", autoTriggered: false) }
            else { sendLive(app, "新原文。") }
            try await wait { app.overlay.shownEntryIDs.count == 1 }
            await old.complete("Late Google result.")
            try await Task.sleep(for: .milliseconds(40))
            let id = try XCTUnwrap(app.overlay.shownEntryIDs.first)
            XCTAssertEqual(app.overlay.shownEntryIDs.count, 1)
            XCTAssertEqual(app.overlay.translationContext(for: id)?.sourceText, "新原文。")
            XCTAssertEqual(app.overlay.translationContext(for: id)?.backend, .bing)
            XCTAssertEqual(app.overlay.cardContents.first?.translation, "Current result.")
            XCTAssertEqual(try header(app.overlay), "润物 · Bing")
        }
    }

    func testNativeHeaderBindingAndRenderingShowsActualServiceInBothUILanguages() async throws {
        let overlay = makeOverlay()
        for language in [UILanguage.chinese, .english] {
            overlay.uiLanguage = language
            var renderedHeaders = Set<Data>()
            for backend in TranslationBackend.allCases {
                let context = OverlayTranslationContext(sourceText: "固定测试原文。", sourceLanguage: .chinese,
                    targetLanguage: .english, backend: backend)
                overlay.show("Fixture translation.", key: "native", on: NSScreen.main, translationContext: context)
                try await Task.sleep(for: .milliseconds(20))
                let host = try XCTUnwrap(overlay.panelContentViews.first as? NSHostingView<TranslationOverlayView>)
                host.layoutSubtreeIfNeeded()
                let title = "润物 · " + backend.displayName(for: language)
                XCTAssertEqual(host.rootView.headerTitle, title)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                let image = try XCTUnwrap(bitmap.cgImage)
                let scale = CGFloat(image.height) / host.bounds.height
                let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0,
                    width: CGFloat(image.width), height: min(CGFloat(image.height), 36 * scale))))
                renderedHeaders.insert(try XCTUnwrap(NSBitmapImageRep(cgImage: cropped)
                    .representation(using: .png, properties: [:])))
                if let folder = ProcessInfo.processInfo.environment["RUNWU_OVERLAY_EVIDENCE_DIR"] {
                    let file = URL(fileURLWithPath: folder).appendingPathComponent("header-\(language.rawValue)-\(backend.rawValue).png")
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
                }
            }
            XCTAssertEqual(renderedHeaders.count, TranslationBackend.allCases.count,
                "Each service must change the actually rendered native header, with identical body text")
        }
    }
    private func header(_ overlay: OverlayCoordinator, at index: Int = 0) throws -> String {
        try XCTUnwrap(overlay.panelContentViews[index] as? NSHostingView<TranslationOverlayView>).rootView.headerTitle
    }
    private func makeOverlay() -> OverlayCoordinator {
        let overlay = OverlayCoordinator(); overlay.neverHide = true; overlay.followCaret = false
        overlays.append(overlay)
        return overlay
    }
    private func makeApp(backend: TranslationBackend, engines: [TranslationBackend: any TranslationEngine]) -> AppState {
        let name = "OverlayServiceMetadata.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        suites.append((defaults, name))
        let settings = SettingsStore(defaults: defaults, modelKeyStorage: MetadataKeys())
        settings.translationBackend = backend; settings.neverHide = true
        settings.overlayFollowCaret = false; settings.clipboardTranslationEnabled = true
        settings.translationTiming = .completeSentence
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let app = AppState(settings: settings, historyDatabaseURL: directory.appendingPathComponent("history.sqlite"),
            startRuntime: false, engines: engines, clipboardReader: MetadataClipboard())
        apps.append(app)
        return app
    }
    private func sendLive(_ app: AppState, _ text: String) {
        let session = InputSessionID(pid: 1)
        app.monitor.onSnapshot?(TextSnapshot(pid: 1, bundleIdentifier: "metadata.fixture", text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0)), session, NSScreen.main)
    }
    private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Timed out waiting for metadata pipeline", file: file, line: line)
        throw NSError(domain: "OverlayServiceMetadataTests.WaitTimeout", code: 1)
    }
}

private struct MetadataRequest: Sendable {
    let text: String
    let source: Language
    let target: Language
}
private actor MetadataEngine: TranslationEngine {
    private let result: String
    private(set) var requests: [MetadataRequest] = []
    init(_ result: String) { self.result = result }
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        requests.append(MetadataRequest(text: text, source: from, target: to))
        return result
    }
}
private actor MetadataGateEngine: TranslationEngine {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var started = false
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func complete(_ result: String) { continuation?.resume(returning: result); continuation = nil }
}
private struct MetadataKeys: ModelKeyStoring {
    func apiKey(forModelID id: UUID) throws -> String? { nil }
    func setAPIKey(_ value: String?, forModelID id: UUID) throws {}
    func deleteAPIKey(forModelID id: UUID) throws {}
}
@MainActor private final class MetadataClipboard: PasteboardReading {
    var changeCount: Int { 0 }
    func readString() -> String? { XCTFail("Metadata tests must not read any clipboard"); return nil }
}
