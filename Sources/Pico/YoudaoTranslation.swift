import Foundation
import CryptoKit
import CommonCrypto

/// Whole-sentence webtranslate protocol, checked 2026-10-08 at
/// https://fanyi.youdao.com and https://dict.youdao.com/webtranslate/key.
/// The bootstrap constant is published by the web client; no user credential
/// is required. Dynamic keys are kept only in this request's local memory.
/// This free sentence endpoint requires source auto-detection (explicit
/// zh-CHS returns code 50); `from` remains available for local input filtering.
struct YoudaoTranslationEngine: TranslationEngine {
    private struct Status: Decodable { let code: Int }
    private let http: WebHTTP
    private let now: @Sendable () -> Date
    init(session: URLSession? = nil, timeoutSeconds: TimeInterval = 8,
        now: @escaping @Sendable () -> Date = { Date() }) {
        http = WebHTTP(session: session, timeout: timeoutSeconds)
        self.now = now
    }
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        try WebHTTP.validateInput(text, provider: .youdao)
        let referer = URL(string: "https://fanyi.youdao.com/")!
        let bootstrap = WebFormEncoding.url(URL(string: "https://dict.youdao.com/webtranslate/key")!,
            fields: parameters(key: "asdjnjfenknafdfsdfsd", keyID: "webfanyi-key-getter"))
        let (keyData, _) = try await http.data(http.request(bootstrap, referer: referer), provider: .youdao)
        try checkCode(keyData)
        struct Bootstrap: Decodable {
            struct Keys: Decodable { let secretKey: String; let aesKey: String; let aesIv: String }
            let data: Keys
        }
        guard let keys = try? JSONDecoder().decode(Bootstrap.self, from: keyData).data,
            !keys.secretKey.isEmpty, !keys.aesKey.isEmpty, !keys.aesIv.isEmpty else {
            throw WebTranslationError.handshake(.youdao)
        }
        var fields = parameters(key: keys.secretKey, keyID: "webfanyi")
        fields += [("i", text), ("from", "auto"),
            ("to", WebTranslationProvider.youdao.language(to)), ("dictResult", "false")]
        let request = http.request(URL(string: "https://dict.youdao.com/webtranslate")!, form: fields,
            referer: referer, origin: "https://fanyi.youdao.com")
        let (encrypted, _) = try await http.data(request, provider: .youdao)
        // Some upstream failures use plaintext JSON; retain only numeric code.
        if let code = try? JSONDecoder().decode(Status.self, from: encrypted).code,
            code != 0 { throw WebTranslationError.upstream(.youdao, code) }
        let plain = try Self.decrypt(encrypted, key: keys.aesKey, iv: keys.aesIv)
        try checkCode(plain)
        struct Response: Decodable {
            struct Segment: Decodable { let tgt: String }
            let translateResult: [[Segment]]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: plain) else {
            throw WebTranslationError.invalidResponse(.youdao)
        }
        return try WebHTTP.text(response.translateResult.map { $0.map(\.tgt).joined() }.joined(separator: "\n"), provider: .youdao)
    }
    private func parameters(key: String, keyID: String) -> [(String, String)] {
        let time = String(Int64(now().timeIntervalSince1970 * 1000))
        let signed = "client=fanyideskweb&mysticTime=\(time)&product=webfanyi&key=\(key)"
        let sign = Insecure.MD5.hash(data: Data(signed.utf8)).map { String(format: "%02x", $0) }.joined()
        return [("client", "fanyideskweb"), ("product", "webfanyi"), ("appVersion", "1.0.0"), ("vendor", "web"),
            ("pointParam", "client,mysticTime,product"), ("keyfrom", "fanyi.web"), ("mysticTime", time),
            ("keyid", keyID), ("sign", sign)]
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
