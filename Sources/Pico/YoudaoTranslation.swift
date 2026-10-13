import Foundation
import CryptoKit
import CommonCrypto

/// Whole-sentence webtranslate protocol, checked 2026-10-12 at
/// https://fanyi.youdao.com and https://dict.youdao.com/webtranslate/key.
/// The bootstrap constant is published by the web client; no user credential
/// is required. Dynamic keys are kept only in this request's local memory.
/// The free sentence endpoint requires the web session cookie that any
/// https://fanyi.youdao.com page view is issued (OUTFOX_SEARCH_USER_ID):
/// without it the translate endpoint answers code 50 instead of a
/// translation. The translate body `keyid` is load-bearing as well: omitted,
/// the same endpoint answers decoy translations that never match the input.
/// Source auto-detection stays forced (`from=auto`); `from` remains available
/// for local input filtering.
struct YoudaoTranslationEngine: TranslationEngine {
    private struct Status: Decodable { let code: Int }
    private struct Bootstrap: Decodable {
        struct Keys: Decodable { let secretKey: String; let aesKey: String; let aesIv: String }
        let data: Keys
    }
    private struct Response: Decodable {
        struct Segment: Decodable { let tgt: String }
        let translateResult: [[Segment]]
    }
    private static let home = URL(string: "https://fanyi.youdao.com/")!
    private static let cookie = "OUTFOX_SEARCH_USER_ID"
    private static let bootstrapKeyID = "webfanyi-key-getter-2025"
    private static let bootstrapKey = "yU5nT5dK3eZ1pI4j"
    private let http: WebHTTP
    private let now: @Sendable () -> Date
    init(session: URLSession? = nil, timeoutSeconds: TimeInterval = 8,
        now: @escaping @Sendable () -> Date = { Date() }) {
        http = WebHTTP(session: session, timeout: timeoutSeconds)
        self.now = now
    }
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        try WebHTTP.validateInput(text, provider: .youdao)
        do {
            return try await translateOnce(text, to: to)
        } catch let error as WebTranslationError where error == .upstream(.youdao, 50) {
            // 50 marks a missing or no-longer-accepted session cookie, the one
            // failure a renewed session can recover: drop the stale cookie,
            // take a fresh one, and retry exactly once.
            forgetSessionCookie()
            return try await translateOnce(text, to: to)
        }
    }
    private func translateOnce(_ text: String, to: Language) async throws -> String {
        try await openSession()
        let keys = try await bootstrap()
        var fields = signed(key: keys.secretKey)
        fields += [("i", text), ("from", "auto"), ("to", WebTranslationProvider.youdao.language(to)),
            ("dictResult", "false"), ("keyid", "webfanyi"), ("noCheckPrivate", "false")]
        let request = http.request(URL(string: "https://dict.youdao.com/webtranslate")!, form: fields,
            referer: Self.home, origin: "https://fanyi.youdao.com")
        let (encrypted, _) = try await http.data(request, provider: .youdao)
        // Some upstream failures use plaintext JSON; retain only numeric code.
        if let code = try? JSONDecoder().decode(Status.self, from: encrypted).code,
            code != 0 { throw WebTranslationError.upstream(.youdao, code) }
        let plain = try Self.decrypt(encrypted, key: keys.aesKey, iv: keys.aesIv)
        try checkCode(plain)
        guard let response = try? JSONDecoder().decode(Response.self, from: plain) else {
            throw WebTranslationError.invalidResponse(.youdao)
        }
        return try WebHTTP.text(response.translateResult.map { $0.map(\.tgt).joined() }.joined(separator: "\n"), provider: .youdao)
    }
    /// The translate endpoint only accepts requests that carry the anonymous
    /// cookie issued by a page view; an existing session is reused as is.
    private func openSession() async throws {
        guard !hasSessionCookie else { return }
        _ = try await http.data(http.request(Self.home), provider: .youdao)
        guard hasSessionCookie else { throw WebTranslationError.handshake(.youdao) }
    }
    private var hasSessionCookie: Bool {
        http.session.configuration.httpCookieStorage?.cookies(for: Self.home)?
            .contains { $0.name == Self.cookie } ?? false
    }
    private func forgetSessionCookie() {
        let storage = http.session.configuration.httpCookieStorage
        for cookie in storage?.cookies(for: Self.home) ?? [] where cookie.name == Self.cookie {
            storage?.deleteCookie(cookie)
        }
    }
    private func bootstrap() async throws -> Bootstrap.Keys {
        let url = WebFormEncoding.url(URL(string: "https://dict.youdao.com/webtranslate/key")!,
            fields: signed(key: Self.bootstrapKey) + [("keyid", Self.bootstrapKeyID)])
        let (data, _) = try await http.data(http.request(url, referer: Self.home), provider: .youdao)
        try checkCode(data)
        guard let keys = try? JSONDecoder().decode(Bootstrap.self, from: data).data,
            !keys.secretKey.isEmpty, !keys.aesKey.isEmpty, !keys.aesIv.isEmpty else {
            throw WebTranslationError.handshake(.youdao)
        }
        return keys
    }
    /// Web-client request signature: the signed string keeps a fixed field
    /// order, and the key is either the published bootstrap constant or the
    /// dynamic per-request secret. The remaining fields are the web client's
    /// fixed request metadata.
    private func signed(key: String) -> [(String, String)] {
        let time = String(Int64(now().timeIntervalSince1970 * 1000))
        let sign = Insecure.MD5.hash(data: Data("client=fanyideskweb&mysticTime=\(time)&product=webfanyi&key=\(key)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [("client", "fanyideskweb"), ("product", "webfanyi"), ("appVersion", "12.0.0"), ("vendor", "web"),
            ("pointParam", "client,mysticTime,product"), ("keyfrom", "fanyi.web"), ("mysticTime", time),
            ("sign", sign), ("mid", "1"), ("screen", "1"), ("model", "1"), ("network", "wifi"),
            ("abtest", "0"), ("yduuid", key)]
    }
    private func checkCode(_ data: Data) throws {
        guard let code = try? JSONDecoder().decode(Status.self, from: data).code
        else { throw WebTranslationError.invalidResponse(.youdao) }
        guard code == 0 else { throw WebTranslationError.upstream(.youdao, code) }
    }
    private static func decrypt(_ data: Data, key: String, iv: String) throws -> Data {
        guard let encoded = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw WebTranslationError.invalidResponse(.youdao)
        }
        var normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard normalized.count % 4 != 1 else { throw WebTranslationError.invalidResponse(.youdao) }
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let cipher = Data(base64Encoded: normalized), !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else {
            throw WebTranslationError.invalidResponse(.youdao)
        }
        let rawKey = Data(Insecure.MD5.hash(data: Data(key.utf8)))
        let rawIV = Data(Insecure.MD5.hash(data: Data(iv.utf8)))
        let capacity = cipher.count + kCCBlockSizeAES128
        var output = Data(count: capacity), written = 0
        let status = rawKey.withUnsafeBytes { keyBytes in
            rawIV.withUnsafeBytes { ivBytes in
                cipher.withUnsafeBytes { input in
                    output.withUnsafeMutableBytes { destination in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                            input.baseAddress, cipher.count, destination.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw WebTranslationError.decryption(.youdao) }
        output.count = written
        // Validate PKCS7 explicitly: a zero padding byte is invalid, even on
        // system implementations that accept it as an unpadded plaintext.
        guard let last = output.last, (1...kCCBlockSizeAES128).contains(Int(last)),
            output.count >= Int(last), output.suffix(Int(last)).allSatisfy({ $0 == last }) else {
            throw WebTranslationError.decryption(.youdao)
        }
        output.removeLast(Int(last))
        return output
    }
}
