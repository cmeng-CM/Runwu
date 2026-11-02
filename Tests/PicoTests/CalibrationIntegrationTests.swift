import Foundation
import XCTest

@testable import Pico

/// End-to-end wiring tests for the calibration pipeline through `AppState`
/// (A1/A3/A5/A7/A9/A14/A15/A16 of the design acceptance matrix).
@MainActor
final class CalibrationIntegrationTests: XCTestCase {
    private var suites: [(defaults: UserDefaults, name: String)] = []
    private var directories: [URL] = []
    private var apps: [AppState] = []

    override func tearDown() {
        for app in apps { app.overlay.hide() }
        for (defaults, name) in suites {
            defaults.removePersistentDomain(forName: name)
        }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        suites.removeAll(); directories.removeAll(); apps.removeAll()
        CalibrationMockURLProtocol.reset()
        super.tearDown()
    }

    private let liveSession = InputSessionID(pid: 1)

    private func settings(calibrationEnabled: Bool = false) -> SettingsStore {
        let name = "RunwuCalibrationTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: name)!
        suites.append((defaults, name))
        let settings = SettingsStore(defaults: defaults)
        settings.neverHide = true
        settings.calibrationEnabled = calibrationEnabled
        settings.llmModels = [CalibrationMockURLProtocol.model()]
        return settings
    }

    private func app(
        _ settings: SettingsStore, engines: [TranslationBackend: any TranslationEngine] = [:]
    ) -> AppState {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalibrationMockURLProtocol.self]
        let app = AppState(
            settings: settings,
            historyDatabaseURL: path.appendingPathComponent("history.sqlite"),
            startRuntime: false,
            engines: engines,
            calibrationSession: URLSession(configuration: configuration))
        app.input.delayMilliseconds = 10
        apps.append(app)
        return app
    }

    /// One focused field is one session; a per-call default would fabricate a
    /// session change on every send and reset the pipeline (see InputCoordinator
    /// `.sessionChanged`), which is not what these flows exercise.
    private func sendLive(_ app: AppState, _ text: String, session: InputSessionID) {
        let frame = NSScreen.main!.visibleFrame
        app.monitor.onAnchorChanged?(
            InputAnchor(
                caretFrame: NSRect(x: frame.minX + 100, y: frame.midY, width: 1, height: 20),
                fieldFrame: nil), session)
        app.monitor.onSnapshot?(
            TextSnapshot(
                pid: 1, bundleIdentifier: "calibration.mock", text: text,
                selectedRange: NSRange(location: text.utf16.count, length: 0)), session, NSScreen.main)
    }

    private func wait(_ condition: () async -> Bool, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for pipeline state", line: line)
    }

    /// A14 + A2 logic path: switch persisted on before init → calibration works
    /// without toggling anything (startup sync of input.calibrationEnabled).
    func testStartupWithCalibrationEnabledCalibratesEnglishImmediately() async throws {
        let app = app(settings(calibrationEnabled: true))
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { app.overlay.cardContents.count == 1 }
        XCTAssertEqual(
            app.overlay.cardContents.first?.source, "I have went to school yesterday.")
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "I went to school yesterday.")
        // No history entries: calibration never writes history (D-C6).
        XCTAssertTrue(app.history.entries.isEmpty)
    }

    /// A1: switch off (default) → English sentence produces nothing at all.
    func testDisabledSwitchLeavesEnglishSentencesUntouched() async throws {
        let app = app(settings(calibrationEnabled: false))
        sendLive(app, "hello world", session: liveSession)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        XCTAssertEqual(CalibrationMockURLProtocol.hosts, [])
        XCTAssertNil(app.calibrationFailure)
    }

    /// A3: Chinese→translation card, English→calibration card, back to Chinese.
    func testRouteSwitchSwapsCardsBetweenTranslationAndCalibration() async throws {
        let app = app(settings(calibrationEnabled: true), engines: [.local: CalibrationStaticEngine("Hello World.")])
        sendLive(app, "你好，世界。", session: liveSession)
        try await wait { app.overlay.shownEntryIDs.count == 1 }
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "Hello World.")  // local engine
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { app.overlay.shownEntryIDs.count == 1 && app.overlay.cardContents.first?.translation == "I went to school yesterday." }
        XCTAssertEqual(app.overlay.cardContents.count, 1)  // single active card
        sendLive(app, "你好，再见。", session: liveSession)
        try await wait { app.overlay.shownEntryIDs.count == 1 && app.overlay.cardContents.first?.translation == "Hello World." }
        XCTAssertEqual(app.overlay.cardContents.count, 1)
    }

    /// A5: consecutive English sentences each issue a request and the final
    /// card matches the latest sentence (late results dropped, N-11).
    func testConsecutiveEnglishSentencesEachRequestAndShowLatest() async throws {
        let app = app(settings(calibrationEnabled: true))
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { CalibrationMockURLProtocol.hosts.count >= 1 }
        sendLive(app, "She dont like apples.", session: liveSession)
        try await wait { app.overlay.shownEntryIDs.count == 1 && app.overlay.cardContents.first?.source == "She dont like apples." }
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "She dont like apples.")  // good verdict
        XCTAssertEqual(app.overlay.cardContents.count, 1)
        XCTAssertEqual(CalibrationMockURLProtocol.hosts.count, 2)
    }

    /// A5 (.none): a pure-emoji sentence takes the old calibration card away.
    func testNoneRouteRemovesCalibrationCard() async throws {
        let app = app(settings(calibrationEnabled: true))
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { app.overlay.cardContents.count == 1 }
        sendLive(app, "😄😄", session: liveSession)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
    }

    /// A5 (debounce window): route change is applied before the 10 ms debounce.
    func testRouteChangeCleansUpWithinTheDebounceWindow() async throws {
        let app = app(settings(calibrationEnabled: true))
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { app.overlay.cardContents.count == 1 }
        sendLive(app, "😄😄", session: liveSession)
        // No sleep long enough for any debounce (10 ms) to fire requests.
        XCTAssertLessThan(CalibrationMockURLProtocol.hosts.count, 3)
    }

    /// A7: all models failing shows the calibration failure notice, no card,
    /// and the failure clears when the next calibration succeeds.
    func testAllModelsFailingShowsIndependentCalibrationFailure() async throws {
        let settingsStore = settings(calibrationEnabled: true)
        settingsStore.llmModels = [CalibrationMockURLProtocol.model(url: "https://malformed.mock/v1")]
        let app = app(settingsStore)
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { app.calibrationFailure != nil }
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        XCTAssertFalse(app.calibrationFailure!.contains("I have went"))  // no sentence echo
        // Next successful calibration clears the failure.
        settingsStore.llmModels = [CalibrationMockURLProtocol.model()]
        settingsStore.translationBackend = .local  // model change → affectsCalibration → reconfigure
        sendLive(app, "She dont like apples.", session: liveSession)
        try await wait { app.overlay.shownEntryIDs.count == 1 && app.overlay.cardContents.first?.source == "She dont like apples." }
        XCTAssertNil(app.calibrationFailure)
    }

    /// A15: toggling the calibration switch does not cancel an in-flight
    /// translation or remove its card.
    func testTogglingCalibrationSwitchLeavesTranslationInFlightAlone() async throws {
        let gate = CalibrationGateEngine()
        let settingsStore = settings(calibrationEnabled: true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(path)
        let app = AppState(
            settings: settingsStore, historyDatabaseURL: path.appendingPathComponent("history.sqlite"),
            startRuntime: false, engines: [.local: gate],
            calibrationSession: URLSession(configuration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [CalibrationMockURLProtocol.self]
                return configuration
            }()))
        app.input.delayMilliseconds = 10
        apps.append(app)
        sendLive(app, "你好，世界。", session: liveSession)
        try await wait { await gate.started }
        settingsStore.calibrationEnabled = false  // toggle mid-flight
        await gate.complete("Hello World.")
        try await wait { app.overlay.cardContents.count == 1 }
        XCTAssertEqual(app.overlay.cardContents.first?.translation, "Hello World.")
    }

    /// A16 (design 4.4 / review N-22): backend/target-only changes leave the
    /// calibration pipeline alive (a follow-up sentence still calibrates; an
    /// already shown unpinned card may be收起 by hideUnpinned, which is the
    /// documented behavior); a source change stops calibration routing.
    func testSettingsChangeIsolationForCalibration() async throws {
        let settingsStore = settings(calibrationEnabled: true)
        let app = app(settingsStore)
        sendLive(app, "I have went to school yesterday.", session: liveSession)
        try await wait { CalibrationMockURLProtocol.hosts.count == 1 }
        // Backend-only change: does NOT invalidate calibration state or cache.
        settingsStore.translationBackend = .google
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(app.calibrationFailure)
        // Follow-up English sentence still calibrates through the same config.
        sendLive(app, "She dont like apples.", session: liveSession)
        try await wait { app.overlay.shownEntryIDs.count == 1 && app.overlay.cardContents.first?.source == "She dont like apples." }
        XCTAssertEqual(CalibrationMockURLProtocol.hosts.count, 2)
        // Source change: English now routes to translation instead — no more
        // calibration requests, and the unpinned calibration card is cleared.
        settingsStore.sourceLanguage = .english
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(app.overlay.cardContents.isEmpty)
        let hostCount = CalibrationMockURLProtocol.hosts.count
        sendLive(app, "This goes to translation now.", session: liveSession)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(CalibrationMockURLProtocol.hosts.count, hostCount)
    }
}

/// Immediate-result engine for the local translation backend in tests.
private actor CalibrationStaticEngine: TranslationEngine {
    private let result: String
    init(_ result: String) { self.result = result }
    func translate(_ text: String, from: Language, to: Language) async throws -> String { result }
}

/// Local translation engine that holds its result until the test releases it.
private actor CalibrationGateEngine: TranslationEngine {
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var started = false
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        started = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }
    func complete(_ result: String) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// URLProtocol mock for the calibration engine path. `good.mock` serves a
/// valid verdict JSON; `malformed.mock` serves non-JSON content.
private final class CalibrationMockURLProtocol: URLProtocol {
    private static let recorder = CalibrationHostRecorder()
    static var hosts: [String] { recorder.all() }
    static func reset() { recorder.reset() }
    static func model(url: String = "https://good.mock/v1") -> LLMModelConfiguration {
        LLMModelConfiguration(name: "calibration-fixture", baseURL: url, model: "fixture-model")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.recorder.append(host)
        let content: String
        if host == "good.mock" {
            content = Self.verdictJSON(for: request)
        } else {
            content = "Sorry, I cannot answer that."
        }
        let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Sentence-aware payload: "have went" sentences get the major fixture,
    /// anything else gets a clean good verdict whose corrected == source.
    private static func verdictJSON(for request: URLRequest) -> String {
        let sentence = sentence(from: request) ?? ""
        let object: [String: Any]
        if sentence.contains("have went") {
            object = [
                "verdict": "major",
                "back_translation_zh": "我昨天去了学校。",
                "corrected": "I went to school yesterday.",
                "issues": [
                    ["quote": "have went", "kind": "grammar", "reason_zh": "助动词误用", "fix": "went"]
                ],
            ]
        } else {
            object = [
                "verdict": "good",
                "back_translation_zh": "（这句话写得没问题。）",
                "corrected": sentence,
            ]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private static func sentence(from request: URLRequest) -> String? {
        guard let data = request.httpBody ?? request.httpBodyStream.map({ stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = object["messages"] as? [[String: Any]],
            let last = messages.last, let text = last["content"] as? String
        else { return nil }
        return text
    }
}

private final class CalibrationHostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    func append(_ host: String) { lock.lock(); hosts.append(host); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return hosts }
    func reset() { lock.lock(); hosts = []; lock.unlock() }
}
