import AppKit
import Foundation
import XCTest
@testable import Pico

@MainActor
final class ServiceRoutingTests: XCTestCase {
    private var suites: [(UserDefaults, String)] = []
    private var apps: [AppState] = []
    private var directories: [URL] = []
    override func tearDown() async throws {
        for app in apps { app.settings.enabled = false; app.applyTranslationSettings(); app.overlay.hide() }
        apps.removeAll()
        for (defaults, name) in suites { defaults.removePersistentDomain(forName: name) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    func testAllFiveBackendsReallyRouteAndOldConfigureCannotOverwriteNew() async throws {
        let engines = Dictionary(uniqueKeysWithValues: TranslationBackend.allCases.map { ($0, RoutingEngine($0.rawValue)) })
        let injected = engines.mapValues { $0 as any TranslationEngine }
        let service = TranslationService(localEngine: engines[.local]!, backend: .local, models: [], timeoutSeconds: 8, engines: injected)
        for (index, backend) in TranslationBackend.allCases.enumerated() {
            await service.configure(backend: backend, models: [], timeoutSeconds: 8, revision: UInt64(index + 1))
            let result = try await service.translate("你好。", from: .chinese, to: .english)
            XCTAssertEqual(result, backend.rawValue)
        }
        await service.configure(backend: .local, models: [], timeoutSeconds: 8, revision: 1)
        let result = try await service.translate("你好。", from: .chinese, to: .english)
        XCTAssertEqual(result, "youdao")
        for engine in engines.values { let count = await engine.count; XCTAssertGreaterThan(count, 0) }
    }

    func testInitializationPublishesActualModelsSynchronouslyWithoutLateInitTask() async throws {
        let factory = RoutingModelFactory()
        let models = [model()]
        let service = TranslationService(localEngine: RoutingEngine("local"), backend: .languageModel,
            models: models, timeoutSeconds: 12, modelFactory: { factory.make($0, $1) })
        let first = try await service.translate("你好。", from: .chinese, to: .english)
        XCTAssertEqual(first, "model-config-1")
        var updated = models; updated[0].systemPrompt = "new prompt"
        await service.configure(backend: .languageModel, models: updated, timeoutSeconds: 20, revision: 1)
        try await Task.sleep(for: .milliseconds(20))
        let second = try await service.translate("你好。", from: .chinese, to: .english)
        XCTAssertEqual(second, "model-config-2")
        XCTAssertEqual(factory.snapshots.last?.models, updated)
        XCTAssertEqual(factory.snapshots.last?.timeout, 20)
    }

    func testAtomicCoordinatorInvalidationPreventsLateCacheWriteAndOldRevisionRequest() async throws {
        let engine = RoutingGateEngine()
        let coordinator = TranslationCoordinator(engine: engine)
        let old = Task { try await coordinator.translateThrowing("你好。", from: .chinese, to: .english, revision: 0) }
        try await wait { await engine.count == 1 }
        await coordinator.reconfigure(from: .chinese, to: .english, revision: 2)
        await engine.complete(0, result: .success("Old."))
        do { _ = try await old.value; XCTFail("Old request must be cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        await coordinator.reconfigure(from: .english, to: .japanese, revision: 1)
        do { _ = try await coordinator.translateThrowing("你好。", from: .chinese, to: .english, revision: 1); XCTFail("Old revision must not run") }
        catch { XCTAssertTrue(error is CancellationError) }
        let new = Task { try await coordinator.translateThrowing("你好。", from: .chinese, to: .english, revision: 2) }
        try await wait { await engine.count == 2 }
        await engine.complete(1, result: .success("New."))
        let result = try await new.value; XCTAssertEqual(result, "New.")
        let cached = try await coordinator.translateThrowing("你好。", from: .chinese, to: .english, revision: 2)
        XCTAssertEqual(cached, "New.")
        let count = await engine.count; XCTAssertEqual(count, 2)
    }

    func testLocalSessionReadinessCancellationDoesNotWaitForEightSecondTimeout() async throws {
        let holder = TranslationSessionHolder()
        let task = Task { () -> Bool in
            do { _ = try await holder.translate("你好。", from: .chinese, to: .english); return false }
            catch { return error is CancellationError }
        }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testLocalHolderSamePairPreservesHostReadinessIntentAndDirectionChangeInvalidatesWaiters() async throws {
        let holder = TranslationSessionHolder()
        XCTAssertFalse(holder.configure(source: .chinese, target: .english), "Same pair has no host translationTask restart")
        var finished = false
        let pending = Task { () -> Bool in
            defer { finished = true }
            do { _ = try await holder.translate("你好。", from: .chinese, to: .english); return false }
            catch { return error is TranslationSessionError }
        }
        try await Task.sleep(for: .milliseconds(20))
        // Backend/model edits and pause/resume use the same configuration
        // path. It must leave both attached readiness and pending waiters.
        XCTAssertFalse(holder.configure(source: .chinese, target: .english))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        XCTAssertTrue(holder.configure(source: .english, target: .japanese), "A different pair restarts the host and rejects old waiters")
        let invalidated = await pending.value
        XCTAssertTrue(invalidated)
        XCTAssertFalse(holder.configure(source: .english, target: .japanese))
        do { _ = try await holder.translate("你好。", from: .chinese, to: .english); XCTFail("An old direction cannot wait for or consume the current session") }
        catch { XCTAssertTrue(error is TranslationSessionError) }
    }

    func testBackendAndFollowCaretPersistWithLegacyRawValuesAndDefaults() {
        let settings = settings()
        XCTAssertEqual(settings.translationBackend, .local)
        XCTAssertTrue(settings.overlayFollowCaret)
        let defaults = suites.last!.0
        for backend in TranslationBackend.allCases {
            settings.translationBackend = backend
            XCTAssertEqual(SettingsStore(defaults: defaults, modelKeyStorage: RoutingKeys()).translationBackend, backend)
        }
        XCTAssertEqual(TranslationBackend.local.rawValue, "local")
        XCTAssertEqual(TranslationBackend.languageModel.rawValue, "language-model")
        settings.overlayFollowCaret = false
        XCTAssertFalse(SettingsStore(defaults: defaults, modelKeyStorage: RoutingKeys()).overlayFollowCaret)
        defaults.set("future-unsupported", forKey: "translationBackend")
        XCTAssertEqual(SettingsStore(defaults: defaults, modelKeyStorage: RoutingKeys()).translationBackend, .local)
    }

    func testAppPauseResumeAndPausedConfigurationRestoreBothOriginsWithoutExtraSettingsEdit() async throws {
        for mode in 0...2 {
            let local = RoutingEngine("Local."), bing = RoutingEngine("Bing."), app = app(engines: [.local: local, .bing: bing])
            sendLive(app, "先前实时中文。")
            app.translateCopiedText("先前剪贴板中文。", autoTriggered: false)
            try await wait { app.overlay.cardContents.count == 2 }
            if mode == 1 { app.settings.translationBackend = .bing }
            app.toggle()
            if mode == 2 { app.settings.translationBackend = .bing }
            app.toggle()
            sendLive(app, "恢复实时中文。")
            app.translateCopiedText("恢复剪贴板中文。", autoTriggered: false)
            try await wait { app.overlay.cardContents.count == 2 }
            XCTAssertTrue(app.overlay.cardContents.allSatisfy { $0.translation == (mode > 0 ? "Bing." : "Local.") })
            XCTAssertNil(app.realtimeFailure); XCTAssertNil(app.clipboardFailure)
        }
    }

    func testKeyPersistenceUsesInjectedKeychainAndNeverSerializesSecret() throws {
        let keys = RoutingKeys(), store = settings(keys: keys), defaults = suites.last!.0
        let configuration = model()
        store.llmModels = [configuration]
        let data = try XCTUnwrap(defaults.data(forKey: "llmModels"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SENTINEL_KEY"))
        XCTAssertEqual(try keys.apiKey(forModelID: configuration.id), "SENTINEL_KEY")
        let reloaded = SettingsStore(defaults: defaults, modelKeyStorage: keys)
        XCTAssertEqual(reloaded.llmModels.first?.apiKey, "SENTINEL_KEY")
        XCTAssertEqual(reloaded.llmModels.first?.baseURL, configuration.baseURL)
        XCTAssertEqual(reloaded.llmModels.first?.systemPrompt, configuration.systemPrompt)
        XCTAssertEqual(reloaded.llmModels.first?.thinking, configuration.thinking)
    }

    func testAppReadyBarrierRapidBackendEditsRouteBothOriginsToFinalConfiguration() async throws {
        let local = RoutingEngine("Old local."), google = RoutingEngine("Old google."), bing = RoutingEngine("Current Bing.")
        let app = app(engines: [.local: local, .google: google, .bing: bing])
        app.settings.translationBackend = .google
        app.settings.translationBackend = .bing
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        sendLive(app, "实时中文。")
        try await wait { app.overlay.cardContents.count == 2 }
        XCTAssertTrue(app.overlay.cardContents.allSatisfy { $0.translation == "Current Bing." })
        let localCount = await local.count, googleCount = await google.count, bingCount = await bing.count
        XCTAssertEqual(localCount, 0); XCTAssertEqual(googleCount, 0); XCTAssertEqual(bingCount, 2)
    }

    func testAppModelEveryParameterChangeInvalidatesBothCachesAndCarriesCompleteSnapshot() async throws {
        let factory = RoutingModelFactory()
        let app = app(modelFactory: { factory.make($0, $1) })
        app.settings.llmModels = [model(), model(name: "second")]
        app.settings.translationBackend = .languageModel
        let session = InputSessionID(pid: 1)
        sendLive(app, "相同中文。", session: session)
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await wait { app.overlay.cardContents.count == 2 }
        for mutation in 0..<9 {
            var models = app.settings.llmModels
            switch mutation {
            case 0: models[0].baseURL = "https://changed.mock/v1"
            case 1: models[0].model = "new-model"
            case 2: models[0].systemPrompt = "new prompt"
            case 3: models[0].apiKey = "SENTINEL_KEY_CHANGED"
            case 4: models[0].thinking = .nonThinking
            case 5: models[0].enabled = false
            case 6: models.swapAt(0, 1)
            case 7: models[0].timeoutSeconds = 3
            default: break
            }
            if mutation == 8 { app.settings.llmFallbackTimeout = 17 }
            else { app.settings.llmModels = models }
            sendLive(app, "相同中文。", session: session)
            app.translateCopiedText("剪贴板中文。", autoTriggered: false)
            try await wait { app.overlay.cardContents.count == 2 }
            let latest = try XCTUnwrap(factory.snapshots.last)
            XCTAssertEqual(latest.models, app.settings.llmModels)
            XCTAssertEqual(latest.timeout, app.settings.llmFallbackTimeout)
            XCTAssertTrue(app.overlay.cardContents.allSatisfy { $0.translation == latest.result })
            let calls = await latest.engine.count; XCTAssertEqual(calls, 2, "Both origin caches must be empty in the new revision")
        }
    }

    func testFollowModeChangeOnlyRelayoutsAndDoesNotInvalidateServiceCache() async throws {
        let engine = RoutingEngine("Cached."), app = app(engines: [.local: engine])
        sendLive(app, "相同中文。")
        try await wait { app.overlay.cardContents.count == 1 }
        app.settings.overlayFollowCaret = false
        XCTAssertFalse(app.overlay.followCaret)
        app.settings.overlayFollowCaret = true
        XCTAssertTrue(app.overlay.followCaret)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "Cached.")
        let count = await engine.count; XCTAssertEqual(count, 1)
    }

    func testFailuresAreSeparateReadableStateNotTranslationHistorySpeechOrPendingActions() async throws {
        let spy = RoutingSpeech()
        for clipboard in [false, true] {
            let engine = RoutingEngine("", error: WebTranslationError.httpStatus(.google, 429))
            let app = app(engines: [.google: engine], speech: spy)
            app.settings.translationBackend = .google
            app.settings.speechTriggers = .all
            if clipboard { app.translateCopiedText("剪贴板中文。", autoTriggered: false) } else { sendLive(app, "实时中文。") }
            try await wait { clipboard ? app.clipboardFailure != nil : app.realtimeFailure != nil }
            XCTAssertTrue((clipboard ? app.clipboardFailure : app.realtimeFailure)?.contains("429") == true)
            XCTAssertEqual(app.translation, "")
            XCTAssertTrue(app.overlay.cardContents.isEmpty)
            XCTAssertTrue(app.history.entries.isEmpty)
            XCTAssertFalse(app.hasPendingTranslationAction)
            XCTAssertTrue(spy.spoken.isEmpty)
        }
        let sentinel = LLMTranslationError.httpStatus(model: "SENTINEL_KEY", statusCode: 400, message: "SENTINEL_INPUT")
        for language in [UILanguage.chinese, .english] {
            let message = TranslationFailureMessage.text(for: sentinel, backend: .languageModel, language: language)
            XCTAssertFalse(message.contains("SENTINEL")); XCTAssertTrue(message.contains("400"))
            let unknown = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "SENTINEL_KEY_INPUT"])
            XCTAssertFalse(TranslationFailureMessage.text(for: unknown, backend: .local, language: language).contains("SENTINEL"))
        }
    }

    func testAppActualLanguageModelRouteWithoutEnabledModelsShowsControlledFailureImmediately() async throws {
        let store = settings()
        store.translationBackend = .languageModel
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let app = AppState(settings: store, historyDatabaseURL: directory.appendingPathComponent("history.sqlite"), startRuntime: false)
        apps.append(app); app.input.delayMilliseconds = 10
        sendLive(app, "未配置模型中文。")
        try await wait { app.realtimeFailure != nil }
        XCTAssertEqual(app.realtimeFailure, "未配置启用的语言模型。")
        XCTAssertFalse(app.hasPendingTranslationAction)
        XCTAssertTrue(app.overlay.cardContents.isEmpty); XCTAssertTrue(app.history.entries.isEmpty)
    }

    func testStaleErrorsAndCancellationStaySilentForBothOrigins() async throws {
        for clipboard in [false, true] {
            let gate = RoutingGateEngine(), good = RoutingEngine("Current.")
            let app = app(engines: [.local: gate, .bing: good])
            if clipboard { app.translateCopiedText("旧剪贴板中文。", autoTriggered: false) } else { sendLive(app, "旧实时中文。") }
            try await wait { await gate.count == 1 }
            app.settings.translationBackend = .bing
            if clipboard { app.translateCopiedText("新剪贴板中文。", autoTriggered: false) } else { sendLive(app, "新实时中文。") }
            await gate.complete(0, result: .failure(WebTranslationError.httpStatus(.google, 503)))
            try await wait { app.overlay.cardContents.count == 1 }
            XCTAssertEqual(app.overlay.cardContents.first?.translation, "Current.")
            XCTAssertNil(app.realtimeFailure); XCTAssertNil(app.clipboardFailure)
            try await wait { app.history.entries.count == 1 }
        }
        let cancelled = RoutingEngine("", error: CancellationError())
        let app = app(engines: [.local: cancelled])
        sendLive(app, "实时取消中文。")
        app.translateCopiedText("剪贴板取消中文。", autoTriggered: false)
        try await wait { await cancelled.count == 2 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(app.realtimeFailure); XCTAssertNil(app.clipboardFailure)
        XCTAssertTrue(app.overlay.cardContents.isEmpty); XCTAssertTrue(app.history.entries.isEmpty)
        XCTAssertFalse(app.hasPendingTranslationAction)
    }

    func testOneOriginFailureDoesNotCancelOtherOriginOrBecomeItsResult() async throws {
        let gate = RoutingGateEngine(), app = app(engines: [.local: gate])
        sendLive(app, "实时中文。")
        try await wait { await gate.count == 1 }
        app.translateCopiedText("剪贴板中文。", autoTriggered: false)
        try await wait { await gate.count == 2 }
        await gate.complete(0, result: .failure(TranslationSessionError.unavailable))
        try await wait { app.realtimeFailure != nil }
        await gate.complete(1, result: .success("Clipboard succeeds."))
        try await wait { app.overlay.cardContents.count == 1 }
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "Clipboard succeeds.")
        XCTAssertNil(app.clipboardFailure)
        try await wait { app.history.entries.count == 1 }
    }

    func testLLMFallbackRetainsModelsAndDefaultTimeoutAcrossActorReentrancy() async throws {
        RoutingHTTP.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RoutingHTTP.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let router = LLMModelRouter(models: [model(name: "first", url: "https://first.mock/v1", timeout: 0),
            model(name: "second", url: "https://second.mock/v1", timeout: 0)], timeoutSeconds: 2, session: session)
        let task = Task { try await router.translate("你好。", from: .chinese, to: .english) }
        try await wait { RoutingHTTP.requests.count == 1 }
        await router.setFallbackTimeout(20)
        await router.setModels([model(name: "new", url: "https://new.mock/v1")])
        let result = try await task.value
        XCTAssertEqual(result, "Translated.")
        XCTAssertEqual(RoutingHTTP.requests.map { $0.url!.host! }, ["first.mock", "second.mock"])
        XCTAssertEqual(RoutingHTTP.requests.map(\.timeoutInterval), [2, 2])
    }

    private func settings(keys: RoutingKeys = RoutingKeys()) -> SettingsStore {
        let name = "RunwuRoutingTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        suites.append((defaults, name))
        let settings = SettingsStore(defaults: defaults, modelKeyStorage: keys)
        settings.neverHide = true; settings.clipboardTranslationEnabled = true
        return settings
    }
    private func app(engines: [TranslationBackend: any TranslationEngine] = [:],
        modelFactory: @escaping TranslationService.ModelFactory = { LLMModelRouter(models: $0, timeoutSeconds: $1) },
        speech: (any SpeechPerforming)? = nil) -> AppState {
        let store = settings(), path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(path)
        let app = AppState(settings: store, historyDatabaseURL: path.appendingPathComponent("history.sqlite"),
            startRuntime: false, engines: engines, modelFactory: modelFactory, speech: speech)
        app.input.delayMilliseconds = 10
        apps.append(app)
        return app
    }
    private func sendLive(_ app: AppState, _ text: String, session: InputSessionID = InputSessionID(pid: 1)) {
        let frame = NSScreen.main!.visibleFrame
        app.monitor.onAnchorChanged?(InputAnchor(caretFrame: NSRect(x: frame.minX + 100, y: frame.midY, width: 1, height: 20), fieldFrame: nil), session)
        app.monitor.onSnapshot?(TextSnapshot(pid: 1, bundleIdentifier: "routing.mock", text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0)), session, NSScreen.main)
    }
    private func model(name: String = "test", url: String = "https://mock.example/v1", timeout: Double = 8) -> LLMModelConfiguration {
        LLMModelConfiguration(name: name, baseURL: url, apiKey: "SENTINEL_KEY", model: "fixture-model",
            systemPrompt: "fixture prompt", thinking: .thinking, timeoutSeconds: timeout)
    }
    private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Timed out waiting for pipeline state", file: file, line: line)
    }
}

private actor RoutingEngine: TranslationEngine {
    private let result: String
    private let error: (any Error)?
    private(set) var count = 0
    init(_ result: String, error: (any Error)? = nil) { self.result = result; self.error = error }
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        count += 1
        if let error { throw error }
        return result
    }
}
private actor RoutingGateEngine: TranslationEngine {
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    private(set) var count = 0
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        let index = count; count += 1
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func complete(_ index: Int, result: Result<String, Error>) { continuations.removeValue(forKey: index)?.resume(with: result) }
}
private final class RoutingModelFactory: @unchecked Sendable {
    struct Snapshot { let models: [LLMModelConfiguration]; let timeout: Double; let engine: RoutingEngine; let result: String }
    private let lock = NSLock()
    private var stored: [Snapshot] = []
    var snapshots: [Snapshot] { lock.withLock { stored } }
    func make(_ models: [LLMModelConfiguration], _ timeout: Double) -> any TranslationEngine {
        lock.withLock {
            let result = "model-config-\(stored.count + 1)", engine = RoutingEngine(result)
            stored.append(Snapshot(models: models, timeout: timeout, engine: engine, result: result))
            return engine
        }
    }
}
private final class RoutingKeys: ModelKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    func apiKey(forModelID id: UUID) throws -> String? { lock.withLock { values[id] } }
    func setAPIKey(_ value: String?, forModelID id: UUID) throws { lock.withLock { values[id] = value } }
    func deleteAPIKey(forModelID id: UUID) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
}
@MainActor private final class RoutingSpeech: SpeechPerforming {
    var spoken: [String] = []
    func speak(_ text: String, language: Language) { spoken.append(text) }
    func stop() {}
}
private final class RoutingHTTP: URLProtocol {
    private static let recorder = RoutingRequestRecorder()
    static var requests: [URLRequest] { recorder.requests }
    static func reset() { recorder.reset() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.recorder.append(request)
        let first = request.url!.host == "first.mock"
        let response = HTTPURLResponse(url: request.url!, statusCode: first ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let data = Data((first ? #"{"error":{"message":"fixture failure"}}"# : #"{"choices":[{"message":{"content":"Translated."}}]}"#).utf8)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + (first ? 0.15 : 0), execute: item)
    }
    override func stopLoading() {}
}
private final class RoutingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    func reset() { lock.withLock { stored.removeAll() } }
}
