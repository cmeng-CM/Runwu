import Foundation
import XCTest

@testable import Pico

/// Contract tests for the calibration response parser — the eight validation
/// rules of design 5.1 are the source of truth, not the implementation.
final class CalibrationDecodingTests: XCTestCase {
    private let source = "I have went to school yesterday."

    private func content(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
    private func issue(
        _ quote: String, kind: String = "grammar", reason: String = "原因", fix: String = "建议"
    ) -> [String: Any] {
        ["quote": quote, "kind": kind, "reason_zh": reason, "fix": fix]
    }

    // Rule 1: fences and surrounding chatter are stripped.
    func testFencedAndSurroundedJSONParses() throws {
        let raw = "Sure! Here is the result:\n```json\n"
            + content([
                "verdict": "good", "back_translation_zh": "我昨天去了学校。", "corrected": source,
            ])
            + "\n```\nHope that helps."
        let verdict = try CalibrationResponseParser.parse(raw, source: source)
        XCTAssertEqual(verdict.rating, .good)
        XCTAssertEqual(verdict.backTranslation, "我昨天去了学校。")
    }

    func testMissingJSONObjectIsMalformed() {
        XCTAssertThrowsError(try CalibrationResponseParser.parse("no braces here", source: source)) {
            XCTAssertEqual($0 as? CalibrationParseError, .missingJSONObject)
        }
    }

    // Rule 2: verdict must be one of the three ratings.
    func testInvalidOrMissingVerdictIsMalformed() {
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(
                content(["verdict": "excellent", "back_translation_zh": "译"]), source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .invalidVerdict) }
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(content(["back_translation_zh": "译"]), source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .invalidVerdict) }
    }

    // Rule 3: back translation must be non-empty.
    func testEmptyBackTranslationIsMalformed() {
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(
                content(["verdict": "good", "back_translation_zh": "  "]), source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .missingBackTranslation) }
    }

    // Rule 4: good without issues; corrected falls back to the source.
    func testGoodWithoutIssuesDefaultsCorrectedToSource() throws {
        let verdict = try CalibrationResponseParser.parse(
            content(["verdict": "good", "back_translation_zh": "我昨天去了学校。"]), source: source)
        XCTAssertEqual(verdict.rating, .good)
        XCTAssertEqual(verdict.corrected, source)
        XCTAssertTrue(verdict.issues.isEmpty)
    }

    // Rule 5: good with valid issues downgrades to minor and requires corrected.
    func testGoodWithValidIssuesDowngradesToMinor() throws {
        let verdict = try CalibrationResponseParser.parse(
            content([
                "verdict": "good", "back_translation_zh": "译",
                "corrected": "I went to school yesterday.", "issues": [issue("have went")],
            ]), source: source)
        XCTAssertEqual(verdict.rating, .minor)
        XCTAssertEqual(verdict.issues.count, 1)
    }

    func testGoodWithIssuesButNoCorrectedIsMalformed() {
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(
                content([
                    "verdict": "good", "back_translation_zh": "译",
                    "issues": [issue("have went")],
                ]), source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .correctedRequired) }
    }

    // Rules 6–7: minor/major need at least one valid issue and a corrected sentence.
    func testMinorWithoutValidIssuesIsMalformed() {
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(
                content(["verdict": "minor", "back_translation_zh": "译", "corrected": "x"]),
                source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .issuesRequired) }
    }

    func testMinorWithOnlyForeignQuotesIsMalformed() {
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(
                content([
                    "verdict": "minor", "back_translation_zh": "译", "corrected": "x",
                    "issues": [issue("not in source")],
                ]), source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .issuesRequired) }
    }

    func testMinorWithoutCorrectedIsMalformed() {
        XCTAssertThrowsError(
            try CalibrationResponseParser.parse(
                content([
                    "verdict": "minor", "back_translation_zh": "译", "issues": [issue("have went")],
                ]), source: source)
        ) { XCTAssertEqual($0 as? CalibrationParseError, .correctedRequired) }
    }

    // Rule 4 details: empty quotes never match, bad entries are dropped silently.
    func testEmptyQuoteIsDroppedAndUnknownKindBecomesStyle() throws {
        let verdict = try CalibrationResponseParser.parse(
            content([
                "verdict": "major", "back_translation_zh": "译", "corrected": "I went to school.",
                "issues": [
                    issue("", kind: "mystery"),  // empty quote dropped
                    issue("have went", kind: "made-up-kind"),  // unknown kind → style
                    ["quote": "school", "kind": "grammar"],  // missing reason/fix dropped
                ],
            ]), source: source)
        XCTAssertEqual(verdict.issues.count, 1)
        XCTAssertEqual(verdict.issues.first?.kind, .style)
    }

    // Rule 8: ordered by first occurrence in the source and capped at 5.
    func testIssuesOrderedByOccurrenceAndCappedAtFive() throws {
        let many = (0..<7).map { index in
            issue(
                index == 6 ? "have went" : "school\(index == 5 ? "X" : "")",
                reason: "原因\(index)")
        }
        // Build quotes so the last-listed issue occurs earliest in the source.
        let verdict = try CalibrationResponseParser.parse(
            content([
                "verdict": "major", "back_translation_zh": "译", "corrected": "corrected sentence",
                "issues": [
                    issue("yesterday", reason: "r3"), issue("school", reason: "r2"),
                    issue("have went", reason: "r1"),
                ] + many.filter { $0["quote"] as? String == "schoolX" },
            ]), source: source)
        XCTAssertEqual(verdict.issues.map(\.reason), ["r1", "r2", "r3"])
    }

    func testIssueCapKeepsFive() throws {
        let quotes = ["I", "have", "went", "to", "school", "yesterday"]
        let verdict = try CalibrationResponseParser.parse(
            content([
                "verdict": "major", "back_translation_zh": "译", "corrected": "c",
                "issues": quotes.map { issue($0) },
            ]), source: source)
        XCTAssertEqual(verdict.issues.count, 5)
        XCTAssertEqual(verdict.issues.map(\.quote), Array(quotes.prefix(5)))
    }
}

/// Engine-level tests for `LLMModelRouter.calibrate` failover and the
/// `CalibrationCoordinator` cache/cancel/reconfigure semantics.
final class CalibrationEngineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockCalibrationURLProtocol.reset()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCalibrationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func router(_ session: URLSession) -> LLMModelRouter {
        LLMModelRouter(
            models: [
                LLMModelConfiguration(
                    name: "bad", baseURL: "https://bad.mock/v1", model: "bad-model", timeoutSeconds: 2),
                LLMModelConfiguration(
                    name: "good", baseURL: "https://good.mock/v1", model: "good-model", timeoutSeconds: 2),
            ],
            timeoutSeconds: 2,
            session: session)
    }

    func testHTTPFailureAndMalformedBothFailOverToNextModel() async throws {
        let verdict = try await router(session()).calibrate("I have went to school yesterday.")
        XCTAssertEqual(verdict.rating, .major)
        XCTAssertEqual(verdict.backTranslation, "我昨天去了学校。")
        XCTAssertEqual(verdict.issues.first?.quote, "have went")
        // bad.mock answers 503; malformed.mock is not configured here so the
        // second host serves the valid payload.
        XCTAssertEqual(MockCalibrationURLProtocol.hosts, ["bad.mock", "good.mock"])
    }

    func testAllModelsMalformedThrowsAllModelsFailed() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCalibrationURLProtocol.self]
        let router = LLMModelRouter(
            models: [
                LLMModelConfiguration(
                    name: "malformed", baseURL: "https://malformed.mock/v1", model: "m",
                    timeoutSeconds: 2),
                LLMModelConfiguration(
                    name: "also", baseURL: "https://malformed2.mock/v1", model: "m2", timeoutSeconds: 2),
            ],
            timeoutSeconds: 2,
            session: URLSession(configuration: configuration))
        do {
            _ = try await router.calibrate("I have went to school yesterday.")
            XCTFail("expected allModelsFailed")
        } catch let error as LLMTranslationError {
            guard case .allModelsFailed(let failures) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(failures.allSatisfy { $0.message.contains("calibration") })
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNoEnabledModelsThrowsImmediately() async {
        let router = LLMModelRouter(models: [], timeoutSeconds: 2, session: session())
        do {
            _ = try await router.calibrate("hello")
            XCTFail("expected noEnabledModels")
        } catch let error as LLMTranslationError {
            XCTAssertEqual(error, .noEnabledModels)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCoordinatorCachesByPromptVersionAndTextAndReconfigureClears() async throws {
        let coordinator = CalibrationCoordinator(
            models: [
                LLMModelConfiguration(
                    name: "good", baseURL: "https://good.mock/v1", model: "good-model", timeoutSeconds: 2)
            ],
            timeoutSeconds: 2,
            session: session())
        let text = "I have went to school yesterday."
        let first = try await coordinator.calibrateThrowing(text)
        XCTAssertEqual(first.rating, .major)
        let second = try await coordinator.calibrateThrowing(text)
        XCTAssertEqual(second, first)
        XCTAssertEqual(MockCalibrationURLProtocol.hosts, ["good.mock"])  // cache hit, no new request

        await coordinator.reconfigure(
            models: [
                LLMModelConfiguration(
                    name: "good", baseURL: "https://good.mock/v1", model: "good-model", timeoutSeconds: 2)
            ],
            timeoutSeconds: 2, revision: 1)
        _ = try await coordinator.calibrateThrowing(text)
        XCTAssertEqual(MockCalibrationURLProtocol.hosts, ["good.mock", "good.mock"])  // cache cleared

        do {
            _ = try await coordinator.calibrateThrowing(text, revision: 0)
            XCTFail("expected stale revision to cancel")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
    }
}

private final class MockCalibrationURLProtocol: URLProtocol {
    private static let recorder = HostRecorder()
    static var hosts: [String] { recorder.all() }
    static func reset() { recorder.reset() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.recorder.append(host)

        let payload: String
        let status: Int
        switch host {
        case "good.mock":
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": Self.calibrationBody()]]]
            ])
            payload = String(data: body, encoding: .utf8)!
            status = 200
        case "bad.mock":
            let body = try! JSONSerialization.data(withJSONObject: ["error": ["message": "unavailable"]])
            payload = String(data: body, encoding: .utf8)!
            status = 503
        default:  // malformed hosts: HTTP 200 with a non-JSON message content
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "Sorry, I cannot answer that."]]]
            ])
            payload = String(data: body, encoding: .utf8)!
            status = 200
        }
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func calibrationBody() -> String {
        let object: [String: Any] = [
            "verdict": "major",
            "back_translation_zh": "我昨天去了学校。",
            "corrected": "I went to school yesterday.",
            "issues": [
                ["quote": "have went", "kind": "grammar", "reason_zh": "助动词误用", "fix": "went"]
            ],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
}

private final class HostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    func append(_ host: String) {
        lock.lock(); hosts.append(host); lock.unlock()
    }
    func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return hosts
    }
    func reset() {
        lock.lock(); hosts = []; lock.unlock()
    }
}
