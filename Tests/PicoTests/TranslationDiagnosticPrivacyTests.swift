import Foundation
import XCTest
@testable import Pico

@MainActor
final class TranslationDiagnosticPrivacyTests: XCTestCase {
    func testMetadataUsesOnlyKnownCategoriesAndNumericFields() {
        let privateValue = "input-and-key-private-sentinel"
        let httpError = LLMTranslationError.httpStatus(
            model: privateValue, statusCode: 401, message: privateValue)
        XCTAssertEqual(TranslationErrorDiagnostic(httpError).fields, "type=llm_http_status statusCode=401")
        XCTAssertEqual(
            TranslationErrorDiagnostic(URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: privateValue])).fields,
            "type=network networkCode=-1001")
        XCTAssertEqual(TranslationErrorDiagnostic(UntrustedError(secret: privateValue)).fields, "type=unknown")
        let failures = [LLMModelFailure(id: UUID(), modelName: privateValue, message: privateValue)]
        XCTAssertEqual(
            TranslationErrorDiagnostic(LLMTranslationError.allModelsFailed(failures)).fields,
            "type=llm_all_models_failed failureCount=1")
    }

    func testHTTPErrorEchoNeverReachesRingDebugFileOrReport() async throws {
        let defaults = UserDefaults.standard
        let previousFlag = defaults.object(forKey: "debugLogEnabled")
        let logURL = URL(fileURLWithPath: "/tmp/runwu-debug.log")
        let previousLog = try? Data(contentsOf: logURL)
        let previousAttributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        defer {
            if let previousFlag { defaults.set(previousFlag, forKey: "debugLogEnabled") }
            else { defaults.removeObject(forKey: "debugLogEnabled") }
            if let previousLog {
                try? previousLog.write(to: logURL, options: .atomic)
                if let previousAttributes {
                    try? FileManager.default.setAttributes(previousAttributes, ofItemAtPath: logURL.path)
                }
            } else { try? FileManager.default.removeItem(at: logURL) }
        }
        defaults.set(true, forKey: "debugLogEnabled")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoFailureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let router = LLMModelRouter(
            models: [LLMModelConfiguration(
                name: EchoFailureProtocol.inputMarker,
                baseURL: "https://echo.invalid/v1", apiKey: EchoFailureProtocol.keyMarker, model: "test")],
            session: session)
        let coordinator = TranslationCoordinator(engine: router)

        let translated = await coordinator.translate(EchoFailureProtocol.inputMarker)
        XCTAssertNil(translated)
        let recentLog = DiagnosticLog.recentLines()
        let safeEntry = "translation error type=llm_all_models_failed failureCount=1"
        XCTAssertTrue(recentLog.last?.contains(safeEntry) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let debugTail = DiagnosticLog.debugFileTail()
        let debugFile = try String(contentsOf: logURL, encoding: .utf8)
        let report = DiagnosticsReport.render(
            snapshot: Self.snapshot(), recentLog: recentLog, debugLogExists: true, debugLogTail: debugTail)
        for surface in [recentLog.joined(), debugFile, report] {
            XCTAssertTrue(surface.contains(safeEntry))
            XCTAssertFalse(surface.contains(EchoFailureProtocol.inputMarker))
            XCTAssertFalse(surface.contains(EchoFailureProtocol.keyMarker))
        }

        // The UI error contract still has its readable server diagnostic. Only
        // the separate logging path must discard untrusted associated strings.
        do {
            _ = try await router.translate(EchoFailureProtocol.inputMarker, from: .chinese, to: .english)
            XCTFail("The mocked HTTP 400 must fail")
        } catch let error as LLMTranslationError {
            XCTAssertTrue(error.errorDescription?.contains(EchoFailureProtocol.inputMarker) == true)
            XCTAssertTrue(error.errorDescription?.contains(EchoFailureProtocol.keyMarker) == true)
        }
    }

    private static func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "test", appBuild: "1", bundleID: "com.comeg.runwu",
            installPath: "/test/润物.app", installNeedsHealing: false,
            osVersion: "test", hardwareModel: "test", machine: "arm64",
            accessibilityTrusted: false, monitorRunning: false, probeLine: "test",
            weChatVersion: nil, enabled: true, timingRaw: "pause", speedMilliseconds: 450,
            sourceLanguage: "zh", targetLanguage: "en", backendRaw: "languageModel", llmModelCount: 1,
            uiLanguage: "zh", clipboardEnabled: false, clipboardTriggerRaw: "hotkey",
            excludedBundleIDs: [], generatedAt: Date())
    }
}

private struct UntrustedError: Error, LocalizedError, CustomStringConvertible {
    let secret: String
    var errorDescription: String? { secret }
    var description: String { secret }
}

private final class EchoFailureProtocol: URLProtocol {
    static let inputMarker = "原文标记_PRIVACY_REGRESSION_SENTINEL"
    static let keyMarker = "sk-PRIVACY_REGRESSION_SENTINEL"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let message = "invalid input \(Self.inputMarker); authorization=\(Self.keyMarker)"
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
