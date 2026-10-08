import Foundation

/// Web protocols checked 2026-10-08; independently implemented from wire
/// behavior, without incorporating upstream application source.
/// Google: https://translate.googleapis.com/translate_a/single
/// Bing: https://www.bing.com/translator (rich_tta + abuse-prevention helper).
enum WebTranslationProvider: String, Sendable {
    case google, bing, youdao
    var name: String { switch self { case .google: "Google"; case .bing: "Bing"; case .youdao: "有道" } }
    func language(_ language: Language) -> String {
        guard language == .chinese else { return language.rawValue }
        switch self { case .google: return "zh-CN"; case .bing: return "zh-Hans"; case .youdao: return "zh-CHS" }
    }
}

/// No response body, input, URL, cookie or token can enter this error schema.
/// These closed values can be safely rendered or logged by the caller.
enum WebTranslationError: Error, LocalizedError, Equatable, Sendable {
    case emptyInput(WebTranslationProvider)
    case timeout(WebTranslationProvider)
    case network(WebTranslationProvider, Int)
    case httpStatus(WebTranslationProvider, Int)
    case invalidResponse(WebTranslationProvider)
    case emptyResult(WebTranslationProvider)
    case handshake(WebTranslationProvider)
    case upstream(WebTranslationProvider, Int)
    case decryption(WebTranslationProvider)

    var diagnosticFields: String {
        switch self {
        case .emptyInput(let provider): "provider=\(provider.rawValue) type=empty_input"
        case .timeout(let provider): "provider=\(provider.rawValue) type=timeout"
        case .network(let provider, let code): "provider=\(provider.rawValue) type=network networkCode=\(code)"
        case .httpStatus(let provider, let code): "provider=\(provider.rawValue) type=http statusCode=\(code)"
        case .invalidResponse(let provider): "provider=\(provider.rawValue) type=invalid_response"
        case .emptyResult(let provider): "provider=\(provider.rawValue) type=empty_result"
        case .handshake(let provider): "provider=\(provider.rawValue) type=handshake"
        case .upstream(let provider, let code): "provider=\(provider.rawValue) type=upstream statusCode=\(code)"
        case .decryption(let provider): "provider=\(provider.rawValue) type=decryption"
        }
    }
    var errorDescription: String? {
        switch self {
        case .emptyInput(let provider): "\(provider.name)：没有可翻译的文本。"
        case .timeout(let provider): "\(provider.name)：请求超时，请稍后重试。"
        case .network(let provider, _): "\(provider.name)：网络连接失败。"
        case .httpStatus(let provider, let code): "\(provider.name)：服务返回 HTTP \(code)。"
        case .invalidResponse(let provider): "\(provider.name)：服务响应格式无效。"
        case .emptyResult(let provider): "\(provider.name)：服务没有返回译文。"
        case .handshake(let provider): "\(provider.name)：网页握手参数不可用。"
        case .upstream(let provider, let code): "\(provider.name)：服务返回错误 \(code)。"
        case .decryption(let provider): "\(provider.name)：无法解密服务响应。"
        }
    }
}

/// Percent-encode UTF-8 bytes with only RFC3986 unreserved characters. In
/// particular '+' must be %2B: form/query decoders otherwise turn it to space.
enum WebFormEncoding {
    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { percent($0.0) + "=" + percent($0.1) }.joined(separator: "&")
    }
    static func percent(_ value: String) -> String {
        value.utf8.map { byte -> String in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }
    static func url(_ base: URL, fields: [(String, String)]) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.percentEncodedQuery = encode(fields)
        return parts.url!
    }
}

struct WebHTTP: Sendable {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
    let session: URLSession
    let timeout: TimeInterval

    init(session: URLSession?, timeout: TimeInterval) {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 8
    }
    func request(_ url: URL, form: [(String, String)]? = nil, referer: URL? = nil, origin: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(WebFormEncoding.encode(form).utf8)
        }
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: url), !cookies.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        }
        return request
    }
    func data(_ request: URLRequest, provider: WebTranslationProvider) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw WebTranslationError.invalidResponse(provider) }
            guard (200..<300).contains(response.statusCode) else {
                throw WebTranslationError.httpStatus(provider, response.statusCode)
            }
            // URLSession follows redirects and keeps cookies. Explicitly retain
            // final response cookies as well so injected URLProtocol sessions
            // exercise exactly the same session-bound handshake behavior.
            if let url = response.url {
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                session.configuration.httpCookieStorage?.setCookies(cookies, for: url, mainDocumentURL: url)
            }
            guard !data.isEmpty else { throw WebTranslationError.emptyResult(provider) }
            return (data, response)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? WebTranslationError { throw error }
            if let error = error as? URLError {
                if error.code == .timedOut { throw WebTranslationError.timeout(provider) }
                throw WebTranslationError.network(provider, error.code.rawValue)
            }
            throw WebTranslationError.network(provider, (error as NSError).code)
        }
    }
    static func text(_ result: String, provider: WebTranslationProvider) throws -> String {
        try Task.checkCancellation()
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebTranslationError.emptyResult(provider) }
        return result
    }
    static func validateInput(_ text: String, provider: WebTranslationProvider) throws {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebTranslationError.emptyInput(provider) }
    }
}

struct GoogleTranslationEngine: TranslationEngine {
    private let http: WebHTTP
    init(session: URLSession? = nil, timeoutSeconds: TimeInterval = 8) { http = WebHTTP(session: session, timeout: timeoutSeconds) }

    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        try WebHTTP.validateInput(text, provider: .google)
        let url = WebFormEncoding.url(URL(string: "https://translate.googleapis.com/translate_a/single")!, fields: [
            ("client", "gtx"), ("sl", WebTranslationProvider.google.language(from)), ("tl", WebTranslationProvider.google.language(to)),
            ("dt", "t"), ("dj", "1"), ("ie", "UTF-8"), ("q", text),
        ])
        let (data, _) = try await http.data(http.request(url), provider: .google)
        struct Response: Decodable {
            struct Segment: Decodable { let trans: String }
            let sentences: [Segment]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw WebTranslationError.invalidResponse(.google)
        }
        return try WebHTTP.text(response.sentences.map(\.trans).joined(), provider: .google)
    }
}

actor BingTranslationEngine: TranslationEngine {
    private struct Handshake: Sendable {
        let page: URL
        let origin: String
        let ig: String
        let iid: String
        let key: String
        let token: String
        let expiresAt: TimeInterval
    }
    private struct Helper: Decodable {
        let key: Int64
        let token: String
        let ttl: Double
        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            key = try values.decode(Int64.self)
            token = try values.decode(String.self)
            ttl = try values.decode(Double.self)
        }
    }
    private let http: WebHTTP
    private let now: @Sendable () -> TimeInterval
    private var cached: Handshake?
    private var sequence: UInt64 = 0
    init(session: URLSession? = nil, timeoutSeconds: TimeInterval = 8,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        http = WebHTTP(session: session, timeout: timeoutSeconds)
        self.now = now
    }

    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        try WebHTTP.validateInput(text, provider: .bing)
        for attempt in 0...1 {
            let handshake = try await bootstrap(force: attempt == 1)
            let sfx = sequence
            sequence &+= 1
            let url = WebFormEncoding.url(URL(string: handshake.origin + "/ttranslatev3")!, fields: [
                ("isVertical", "1"), ("IG", handshake.ig), ("IID", handshake.iid), ("SFX", String(sfx)),
            ])
            let request = http.request(url, form: [
                ("fromLang", WebTranslationProvider.bing.language(from)), ("to", WebTranslationProvider.bing.language(to)),
                ("text", text), ("token", handshake.token), ("key", handshake.key),
            ], referer: handshake.page, origin: handshake.origin)
            let (data, _) = try await http.data(request, provider: .bing)
            struct Status: Decodable { let statusCode: Int }
            if let code = try? JSONDecoder().decode(Status.self, from: data).statusCode {
                if code == 205, attempt == 0 { cached = nil; continue }
                throw WebTranslationError.upstream(.bing, code)
            }
            struct Response: Decodable {
                struct Translation: Decodable { let text: String; let to: String }
                let translations: [Translation]?
                let inputTransliteration: String?
                let script: String?
            }
            guard let response = try? JSONDecoder().decode([Response].self, from: data),
                response.allSatisfy({ group in
                    if let translations = group.translations {
                        return translations.allSatisfy { $0.to.lowercased() == WebTranslationProvider.bing.language(to).lowercased() }
                    }
                    // The live API appends an input-transliteration metadata
                    // entry. Only this known shape may omit translations.
                    return group.inputTransliteration != nil && group.script != nil
                })
            else { throw WebTranslationError.invalidResponse(.bing) }
            return try WebHTTP.text(response.compactMap(\.translations).map { $0.map(\.text).joined() }.joined(separator: "\n"), provider: .bing)
        }
        throw WebTranslationError.upstream(.bing, 205)
    }

    private func bootstrap(force: Bool) async throws -> Handshake {
        if !force, let cached, now() < cached.expiresAt { return cached }
        let page = WebFormEncoding.url(URL(string: "https://www.bing.com/translator")!, fields: [("_", UUID().uuidString)])
        let (data, response) = try await http.data(http.request(page), provider: .bing)
        guard let final = response.url, final.scheme == "https", let host = final.host,
            host == "bing.com" || host.hasSuffix(".bing.com"), final.port == nil || final.port == 443,
            let html = String(data: data, encoding: .utf8),
            let ig = Self.capture(#"\b["']?IG["']?\s*:\s*["']([^"']+)["']"#, in: html),
            let tag = Self.capture(#"(<[^>]*\bid\s*=\s*["']rich_tta["'][^>]*>)"#, in: html),
            let iid = Self.capture(#"\bdata-iid\s*=\s*["']([^"']+)["']"#, in: tag),
            let helper = Self.capture(#"params_AbusePreventionHelper\s*=\s*(\[[^\]]+\])"#, in: html),
            let values = try? JSONDecoder().decode(Helper.self, from: Data(helper.utf8)),
            values.key > 0, !values.token.isEmpty, values.ttl.isFinite, values.ttl > 0
        else { throw WebTranslationError.handshake(.bing) }
        let handshake = Handshake(page: final, origin: "https://" + host, ig: ig, iid: iid,
            key: String(values.key), token: values.token, expiresAt: now() + min(values.ttl / 1000, 86400))
        try Task.checkCancellation()
        cached = handshake
        sequence = 0
        return handshake
    }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
