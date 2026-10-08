import Foundation
import XCTest
@testable import Pico

/// Wire fixtures checked 2026-10-08 against protocol research and:
/// https://translate.googleapis.com/translate_a/single
/// https://www.bing.com/translator (rich_tta, helper TTL and SFX)
/// https://fanyi.youdao.com
/// https://shared.ydstatic.com/dict/translation-website/1.0.7/js/app.5a9933f2.js
/// AES literals were generated independently with system openssl AES-128-CBC
/// using raw MD5 key/IV bytes. These are synthetic fixture keys, not credentials.
@MainActor
final class WebTranslationTests: XCTestCase {
    private var fixtures: [WebFixture] = []
    private var sessions: [URLSession] = []
    private let special = "你好 + & = % # 😀"
    private static let cipher = "laoZf93DZrR9iFG6a84_Jl6NxLJz1K7tJGT6oYQg0k0gJYjIlTmDSDuz2tTS2jW-foQj1LxpxR3HrNNS4swponw3QWCgFSuNoPpDytLHsVAmxLy_hxJz9YrjTmdFDaaHi2tl0nUz0mAL7SEAnE12T-RVBAPkqpNlz7NvpWpdJr28pc_iLA5aj-Fe1qluRXxVEuNkWkDNe81IQlIfX2IGgg"
    private static let emptyCipher = "laoZf93DZrR9iFG6a84_JiZWRusZYfxAZzJ625zNxEU"
    private static let invalidCipher = "PHOugYFw2mM9zzebnf1qlw"

    override func tearDown() async throws {
        sessions.forEach { $0.invalidateAndCancel() }
        fixtures.forEach { FixtureURLProtocol.registry.remove($0.id) }
    }

    func testGoogleSendsWholeEncodedSentenceAndConcatenatesAllSegments() async throws {
        let (session, fixture) = makeSession([.text(#"{"sentences":[{"trans":"Hello, "},{"trans":"world."},{"trans":"\nSecond line."}]}"#)])
        let result = try await GoogleTranslationEngine(session: session, timeoutSeconds: 3).translate(special, from: .chinese, to: .english)
        XCTAssertEqual(result, "Hello, world.\nSecond line.")
        let request = try XCTUnwrap(fixture.requests.first)
        let fields = decode(request.url!.query!)
        XCTAssertEqual(fields["q"], special)
        XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
        XCTAssertEqual(fields["sl"], "zh-CN"); XCTAssertEqual(fields["tl"], "en")
        XCTAssertEqual(fields["dj"], "1"); XCTAssertEqual(fields["dt"], "t")
        XCTAssertEqual(request.timeoutInterval, 3)
    }

    func testEveryProviderMapsAllTargetsAndSupportedForcedSources() async throws {
        for provider in [WebTranslationProvider.google, .bing, .youdao] {
            for language in Language.allCases {
                let source = language
                let target = language
                let plans = bootstrap(provider) + [success(provider, target: target)]
                let (session, fixture) = makeSession(plans)
                _ = try await engine(provider, session: session).translate("你好。", from: source, to: target)
                let request = try XCTUnwrap(fixture.requests.last)
                let fields = provider == .google ? decode(request.url!.query!) : decodeBody(request)
                let fromKey = provider == .google ? "sl" : provider == .bing ? "fromLang" : "from"
                let toKey = provider == .google ? "tl" : "to"
                let chinese = provider == .google ? "zh-CN" : provider == .bing ? "zh-Hans" : "zh-CHS"
                XCTAssertEqual(fields[fromKey], provider == .youdao ? "auto" : source == .chinese ? chinese : source.rawValue)
                XCTAssertEqual(fields[toKey], target == .chinese ? chinese : target.rawValue)
            }
        }
    }

    func testBingUsesMainRichTTAIIDFinalHostCookiesAndIndependentSFX() async throws {
        let final = URL(string: "https://cn.bing.com/translator?mkt=zh-CN")!
        let (session, fixture) = makeSession([.text(bingHTML(), url: final,
            headers: ["Set-Cookie": "fixtureCookie=present; Domain=.bing.com; Path=/; Secure; HttpOnly"]), success(.bing), success(.bing)])
        let engine = BingTranslationEngine(session: session)
        let translated = try await engine.translate(special, from: .chinese, to: .english)
        XCTAssertEqual(translated, "Hello, world.")
        _ = try await engine.translate("第二句。", from: .chinese, to: .english)
        XCTAssertEqual(fixture.requests.count, 3, "An unexpired handshake is reused")
        let posts = Array(fixture.requests.dropFirst())
        for (index, request) in posts.enumerated() {
            XCTAssertEqual(request.url!.host, "cn.bing.com")
            XCTAssertEqual(request.url!.path, "/ttranslatev3")
            let query = decode(request.url!.query!)
            XCTAssertEqual(query["IID"], "translator.main")
            XCTAssertEqual(query["IG"], "fixture-IG")
            XCTAssertEqual(query["SFX"], String(index))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), final.absoluteString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cn.bing.com")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("fixtureCookie=present") == true)
        }
        let body = decodeBody(posts[0])
        XCTAssertEqual(body["text"], special); XCTAssertEqual(body["token"], "fixture-token+&")
        XCTAssertEqual(body["fromLang"], "zh-Hans"); XCTAssertEqual(body["to"], "en")
        XCTAssertTrue(String(data: posts[0].httpBody!, encoding: .utf8)!.contains("%2B"))
    }

    func testBingHonorsDynamicTTLAndRefreshesExpiredHandshake() async throws {
        let clock = WebTestClock()
        let (session, fixture) = makeSession([.text(bingHTML(ttl: 60000)), success(.bing), success(.bing),
            .text(bingHTML(token: "fresh-token", ttl: 60000)), success(.bing)])
        let engine = BingTranslationEngine(session: session, now: { clock.value })
        _ = try await engine.translate("第一句。", from: .chinese, to: .english)
        clock.value = 50
        _ = try await engine.translate("第二句。", from: .chinese, to: .english)
        XCTAssertEqual(fixture.requests.count, 3)
        clock.value = 61
        _ = try await engine.translate("第三句。", from: .chinese, to: .english)
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertEqual(decodeBody(fixture.requests[4])["token"], "fresh-token")
    }

    func testBing205RefreshesExactlyOnce() async throws {
        let (session, fixture) = makeSession([.text(bingHTML()), .text(#"{"statusCode":205}"#),
            .text(bingHTML(token: "fresh-token")), success(.bing)])
        let result = try await BingTranslationEngine(session: session).translate("你好。", from: .chinese, to: .english)
        XCTAssertEqual(result, "Hello, world.")
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertNotEqual(fixture.requests[0].url!.query, fixture.requests[2].url!.query, "Refresh must bypass edge page caching")
        XCTAssertEqual(decodeBody(fixture.requests[3])["token"], "fresh-token")
        let (repeatedSession, repeated) = makeSession([.text(bingHTML()), .text(#"{"statusCode":205}"#),
            .text(bingHTML()), .text(#"{"statusCode":205}"#)])
        await assertError(BingTranslationEngine(session: repeatedSession), expected: .upstream(.bing, 205))
        XCTAssertEqual(repeated.requests.count, 4, "A second 205 must stop, never loop")
    }

    func testBingRejectsMissingMainIIDAndUntrustedFinalOriginBeforePOST() async throws {
        for plan in [WebPlan.text(#"<div data-iid="wrong">No rich_tta</div>"#),
            .text(bingHTML(), url: URL(string: "https://bing.com.untrusted.example/translator")!)] {
            let (session, fixture) = makeSession([plan])
            await assertError(BingTranslationEngine(session: session), expected: .handshake(.bing))
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testBingConcatenatesAllTranslationGroupsAndAcceptsKnownTransliterationMetadata() async throws {
        let (session, _) = makeSession(bootstrap(.bing) + [.text(#"[{"translations":[{"text":"Hello, ","to":"en"},{"text":"world.","to":"en"}],"usedLLM":false},{"translations":[{"text":"Second line.","to":"en"}]},{"inputTransliteration":"ni hao","script":"Latn"}]"#)])
        let result = try await BingTranslationEngine(session: session).translate("你好。", from: .chinese, to: .english)
        XCTAssertEqual(result, "Hello, world.\nSecond line.")
        let (malformed, _) = makeSession(bootstrap(.bing) + [.text(#"[{"translations":[{"text":"valid","to":"en"}]},{}]"#)])
        await assertError(BingTranslationEngine(session: malformed), expected: .invalidResponse(.bing))
    }

    func testBingRejectsMalformedNumericHandshakeWithoutPOST() async throws {
        for replacement in ["[true,\"token\",3600000]", "[1700000000123,\"token\",true]", "[1700000000123,\"token\",0]"] {
            let html = bingHTML().replacingOccurrences(of: "[1700000000123,\"fixture-token+&\",3600000]", with: replacement)
            let (session, fixture) = makeSession([.text(html)])
            await assertError(BingTranslationEngine(session: session), expected: .handshake(.bing))
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testYoudaoBootstrapsSignsWholeSentenceAndDecryptsRawMD5CBC() async throws {
        let (session, fixture) = makeSession(bootstrap(.youdao) + [.text(Self.cipher)])
        let engine = YoudaoTranslationEngine(session: session, now: { Date(timeIntervalSince1970: 1700000000.123) })
        let result = try await engine.translate(special, from: .chinese, to: .english)
        XCTAssertEqual(result, "Hello, world.\nSecond line.")
        XCTAssertEqual(fixture.requests.count, 2)
        let getter = fixture.requests[0], post = fixture.requests[1]
        XCTAssertEqual(getter.url!.path, "/webtranslate/key")
        let keyQuery = decode(getter.url!.query!)
        XCTAssertEqual(keyQuery["keyid"], "webfanyi-key-getter")
        XCTAssertEqual(keyQuery["mysticTime"], "1700000000123")
        XCTAssertEqual(keyQuery["sign"], "a90d138db345e175373175dc36a0ef4e")
        XCTAssertEqual(post.url!.path, "/webtranslate"); XCTAssertEqual(post.httpMethod, "POST")
        let body = decodeBody(post)
        XCTAssertEqual(body["keyid"], "webfanyi"); XCTAssertEqual(body["sign"], "a1fb8dba880ff50e4875825336c1a8b0")
        XCTAssertEqual(body["i"], special); XCTAssertEqual(body["from"], "auto"); XCTAssertEqual(body["to"], "en")
        XCTAssertEqual(body["dictResult"], "false")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Referer"), "https://fanyi.youdao.com/")
        XCTAssertFalse(fixture.requests.contains { $0.url!.path.contains("jsonapi") }, "Dictionary results cannot stand in for a sentence")
    }

    func testYoudaoMalformedKeysCiphertextPaddingAndPayloadFailExplicitly() async throws {
        for (plans, expected) in [
            ([WebPlan.text(#"{"code":0,"data":{"secretKey":"fixture-sign-key"}}"#)], WebTranslationError.handshake(.youdao)),
            ([WebPlan.text(#"{"code":false,"data":{"secretKey":"fixture-sign-key","aesKey":"fixture-aes-key","aesIv":"fixture-aes-iv"}}"#)], .invalidResponse(.youdao)),
            (bootstrap(.youdao) + [.text("invalid!base64")], .invalidResponse(.youdao)),
            (bootstrap(.youdao) + [.text("dzTa68kgyc6dT8c56QLCKA")], .decryption(.youdao)),
            (bootstrap(.youdao) + [.text(Self.invalidCipher)], .invalidResponse(.youdao)),
            (bootstrap(.youdao) + [.text(Self.emptyCipher)], .emptyResult(.youdao)),
            (bootstrap(.youdao) + [.text(#"{"code":50,"msg":"SENTINEL_INPUT_SECRET"}"#)], .upstream(.youdao, 50)),
        ] {
            let (session, _) = makeSession(plans)
            await assertError(YoudaoTranslationEngine(session: session), expected: expected)
        }
    }

    func testHTTPRejectionsDoNotRefreshRetryOrExposeEchoedBody() async throws {
        for provider in [WebTranslationProvider.google, .bing, .youdao] {
            for status in [401, 403, 429, 500] {
                let (session, fixture) = makeSession(bootstrap(provider) + [.text("SENTINEL_INPUT_SECRET", status: status)])
                await assertError(engine(provider, session: session), expected: .httpStatus(provider, status))
                XCTAssertEqual(fixture.requests.count, provider == .google ? 1 : 2)
                let error = WebTranslationError.httpStatus(provider, status)
                XCTAssertFalse(error.diagnosticFields.contains("SENTINEL_INPUT_SECRET"))
                XCTAssertFalse(error.localizedDescription.contains("SENTINEL_INPUT_SECRET"))
            }
        }
    }

    func testTimeoutAndNetworkErrorsAreStructuredAndDoNotRetry() async throws {
        for provider in [WebTranslationProvider.google, .bing, .youdao] {
            for code in [URLError.Code.timedOut, .notConnectedToInternet] {
                let (session, fixture) = makeSession([.failure(URLError(code, userInfo: [NSLocalizedDescriptionKey: "SENTINEL_INPUT_SECRET"]))])
                let expected: WebTranslationError = code == .timedOut ? .timeout(provider) : .network(provider, code.rawValue)
                await assertError(engine(provider, session: session), expected: expected)
                XCTAssertEqual(fixture.requests.count, 1)
                XCTAssertFalse(expected.diagnosticFields.contains("SENTINEL_INPUT_SECRET"))
            }
        }
    }

    func testGoogleAndBingMalformedOrEmptyResponsesFail() async throws {
        for (provider, body, expected) in [
            (WebTranslationProvider.google, #"{"sentences":[{"trans":"one"},{}]}"#, WebTranslationError.invalidResponse(.google)),
            (.google, #"{"sentences":[]}"#, .emptyResult(.google)),
            (.google, #"{"sentences":[{"trans":"  "}]}"#, .emptyResult(.google)),
            (.bing, #"[{"translations":[{"text":"wrong","to":"fr"}]}]"#, .invalidResponse(.bing)),
            (.bing, #"[{"translations":[]}]"#, .emptyResult(.bing)),
            (.bing, "", .emptyResult(.bing)),
        ] {
            let (session, fixture) = makeSession(bootstrap(provider) + [.text(body)])
            await assertError(engine(provider, session: session), expected: expected)
            XCTAssertEqual(fixture.requests.count, provider == .google ? 1 : 2)
        }
    }

    func testEmptyInputMakesNoNetworkRequests() async throws {
        for provider in [WebTranslationProvider.google, .bing, .youdao] {
            let (session, fixture) = makeSession([])
            await assertError(engine(provider, session: session), text: " \n", expected: .emptyInput(provider))
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testCancellationDuringHandshakeDoesNotSendTranslation() async throws {
        for provider in [WebTranslationProvider.bing, .youdao] {
            var plan = bootstrap(provider)[0]; plan.delay = 0.5
            let (session, fixture) = makeSession([plan])
            let engine = engine(provider, session: session)
            let task = Task { try await engine.translate("你好。", from: .chinese, to: .english) }
            try await waitUntil { fixture.requests.count == 1 }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(fixture.requests.count, 1)
            XCTAssertGreaterThan(fixture.stopped, 0)
        }
    }

    func testCancellationDuringTranslationStopsURLSessionTask() async throws {
        for provider in [WebTranslationProvider.google, .bing, .youdao] {
            var plan = success(provider); plan.delay = 0.5
            let (session, fixture) = makeSession(bootstrap(provider) + [plan])
            let engine = engine(provider, session: session)
            let count = provider == .google ? 1 : 2
            let task = Task { try await engine.translate("你好。", from: .chinese, to: .english) }
            try await waitUntil { fixture.requests.count == count }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(fixture.requests.count, count)
            XCTAssertGreaterThan(fixture.stopped, 0)
        }
    }

    func testCancelledBeforeStartingMakesNoRequests() async throws {
        for provider in [WebTranslationProvider.google, .bing, .youdao] {
            let (session, fixture) = makeSession([])
            let engine = engine(provider, session: session)
            let task = Task { try await engine.translate("你好。", from: .chinese, to: .english) }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testLiveAdaptersFixedSentenceProbe() async throws {
        guard ProcessInfo.processInfo.environment["RUNWU_WEB_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in live probe: fixed non-sensitive sentence only")
        }
        let adapters: [(WebTranslationProvider, any TranslationEngine)] = [
            (.google, GoogleTranslationEngine(timeoutSeconds: 12)), (.bing, BingTranslationEngine(timeoutSeconds: 12)),
            (.youdao, YoudaoTranslationEngine(timeoutSeconds: 12)),
        ]
        for (provider, adapter) in adapters {
            do {
                let value = try await adapter.translate("你好，世界。", from: .chinese, to: .english)
                print("WEB_LIVE_PROBE provider=\(provider.rawValue) result=success translation=\(String(value.prefix(200)))")
            } catch let error as WebTranslationError {
                print("WEB_LIVE_PROBE result=failed \(error.diagnosticFields)")
            } catch is CancellationError {
                print("WEB_LIVE_PROBE provider=\(provider.rawValue) result=cancelled")
            } catch {
                XCTFail("Unexpected error type; raw error intentionally omitted")
            }
        }
    }

    private func engine(_ provider: WebTranslationProvider, session: URLSession) -> any TranslationEngine {
        switch provider {
        case .google: GoogleTranslationEngine(session: session)
        case .bing: BingTranslationEngine(session: session)
        case .youdao: YoudaoTranslationEngine(session: session)
        }
    }
    private func makeSession(_ plans: [WebPlan]) -> (URLSession, WebFixture) {
        let fixture = WebFixture(plans: plans)
        FixtureURLProtocol.registry.add(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Runwu-Fixture": fixture.id]
        let session = URLSession(configuration: configuration)
        fixtures.append(fixture); sessions.append(session)
        return (session, fixture)
    }
    private func bootstrap(_ provider: WebTranslationProvider) -> [WebPlan] {
        switch provider {
        case .google: []
        case .bing: [.text(bingHTML())]
        case .youdao: [.text(#"{"code":0,"data":{"secretKey":"fixture-sign-key","aesKey":"fixture-aes-key","aesIv":"fixture-aes-iv"}}"#)]
        }
    }
    private func success(_ provider: WebTranslationProvider, target: Language = .english) -> WebPlan {
        switch provider {
        case .google: .text(#"{"sentences":[{"trans":"Hello, world."}]}"#)
        case .bing: .text("[{\"translations\":[{\"text\":\"Hello, world.\",\"to\":\"\(WebTranslationProvider.bing.language(target))\"}]}]")
        case .youdao: .text(Self.cipher)
        }
    }
    private func bingHTML(token: String = "fixture-token+&", ttl: Int = 3600000) -> String {
        """
        <script>var _G={IG:"fixture-IG"};var params_AbusePreventionHelper=[1700000000123,"\(token)",\(ttl)];</script>
        <div data-iid="wrong-before"></div><div data-iid='translator.main' class='translation' id='rich_tta'></div>
        <div id="other" data-iid="wrong-last"></div>
        """
    }
    private func decode(_ form: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: form.split(separator: "&").map { item in
            let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pieces[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!,
                String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!)
        })
    }
    private func decodeBody(_ request: URLRequest) -> [String: String] { decode(String(data: request.httpBody!, encoding: .utf8)!) }
    private func assertError(_ engine: any TranslationEngine, text: String = "你好。", expected: WebTranslationError,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await engine.translate(text, from: .chinese, to: .english); XCTFail("Expected structured failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? WebTranslationError, expected, file: file, line: line) }
    }
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for fixture request", file: file, line: line)
    }
}

private struct WebPlan: @unchecked Sendable {
    var status = 200
    var data = Data()
    var url: URL?
    var headers: [String: String] = [:]
    var error: Error?
    var delay: Double = 0
    static func text(_ text: String, status: Int = 200, url: URL? = nil, headers: [String: String] = [:]) -> Self {
        Self(status: status, data: Data(text.utf8), url: url, headers: headers)
    }
    static func failure(_ error: Error) -> Self { Self(error: error) }
}

private final class WebFixture: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var plans: [WebPlan], recorded: [URLRequest] = []
    private var stopCount = 0
    init(plans: [WebPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var stopped: Int { lock.withLock { stopCount } }
    func take(_ request: URLRequest) -> WebPlan {
        lock.withLock {
            recorded.append(request)
            return plans.isEmpty ? .failure(URLError(.badServerResponse)) : plans.removeFirst()
        }
    }
    func stop() { lock.withLock { stopCount += 1 } }
}

private final class WebFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: WebFixture] = [:]
    func add(_ value: WebFixture) { lock.withLock { values[value.id] = value } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> WebFixture? { lock.withLock { values[id] } }
}

private final class FixtureURLProtocol: URLProtocol {
    static let registry = WebFixtureRegistry()
    private let lock = NSLock()
    private var work: DispatchWorkItem?, stopped = false
    private var fixture: WebFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Runwu-Fixture"), let fixture = Self.registry.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        self.fixture = fixture
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024), data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            recorded.httpBody = data
        }
        let plan = fixture.take(recorded)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            if let error = plan.error { self.client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: plan.url ?? self.request.url!, statusCode: plan.status,
                httpVersion: "HTTP/1.1", headerFields: plan.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: plan.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        lock.withLock { work = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + plan.delay, execute: item)
    }
    override func stopLoading() {
        lock.withLock { stopped = true; work?.cancel() }
        fixture?.stop()
    }
}

private final class WebTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0
    var value: TimeInterval { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
