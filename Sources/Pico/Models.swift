import Foundation
import Combine
@preconcurrency import Translation

/// Languages exposed in the translation direction pickers.
///
/// The raw values are the BCP-47 identifiers consumed by the Translation
/// framework and are stable for persistence in UserDefaults.
public enum Language: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chinese = "zh"
    case english = "en"
    case japanese = "ja"
    case russian = "ru"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    public var id: String { rawValue }
    public var locale: Locale.Language { Locale.Language(identifier: rawValue) }

    /// The preferred macOS speech locale for translated text in this language.
    /// AVSpeechSynthesisVoice uses this to select the system's matching
    /// default voice rather than always speaking with an English voice.
    public var speechLocaleIdentifier: String {
        switch self {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .russian: return "ru-RU"
        case .korean: return "ko-KR"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        }
    }

    public var englishName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .russian: return "Russian"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        }
    }

    public var chineseName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .russian: return "俄语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        }
    }
}
public struct TextSnapshot: Sendable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let text: String
    public let selectedRange: NSRange?
    /// Screen-space frame (Cocoa coordinates) of the focused text field, used
    /// to keep the overlay from covering the text being typed.
    public let fieldFrame: NSRect?
    public let caretFrame: NSRect?
    public let isComposing: Bool
    public let timestamp: Date
    public init(
        pid: pid_t, bundleIdentifier: String?, text: String, selectedRange: NSRange?, fieldFrame: NSRect? = nil,
        caretFrame: NSRect? = nil, isComposing: Bool = false, timestamp: Date = .now
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.text = text
        self.selectedRange = selectedRange
        self.fieldFrame = fieldFrame
        self.caretFrame = caretFrame
        self.isComposing = isComposing
        self.timestamp = timestamp
    }
}

public struct ExtractedSentence: Equatable, Sendable {
    public let text: String
    public let range: NSRange
    func key(in session: InputSessionID) -> String { "\(session.token.uuidString):\(range.location)" }
}

public struct SentenceExtractor: Sendable {
    static let sentencePunctuation: Set<Character> = ["。", "？", "！", ".", "?", "!", "；", ";"]
    static let terminators: Set<Character> = sentencePunctuation.union(["\n"])

    public init() {}
    public func extract(from snapshot: TextSnapshot, maxLength: Int = 300) -> String {
        extractSentence(from: snapshot, maxLength: maxLength)?.text ?? ""
    }
    public func extractSentence(from snapshot: TextSnapshot, maxLength: Int = 300) -> ExtractedSentence? {
        let text = snapshot.text
        guard !text.isEmpty, maxLength > 0 else { return nil }
        var caret = Self.caretIndex(in: text, selectedRange: snapshot.selectedRange)
        let requested = min(max(snapshot.selectedRange?.location ?? text.utf16.count, 0), text.utf16.count)
        if caret > text.startIndex, caret.utf16Offset(in: text) == requested {
            let previous = text.index(before: caret)
            if Self.terminators.contains(text[previous]) { caret = previous }
        }
        var range = Self.fragment(in: text, caret: caret)
        if range.isEmpty { range = Self.previousSentence(in: text, before: caret) ?? range }
        guard !range.isEmpty else { return nil }
        if text[range].count > maxLength {
            range = text.index(range.upperBound, offsetBy: -maxLength)..<range.upperBound
        }
        return ExtractedSentence(text: String(text[range]), range: NSRange(range, in: text))
    }

    public func isComplete(_ snapshot: TextSnapshot) -> Bool {
        let text = snapshot.text
        guard !text.isEmpty else { return false }
        let caret = Self.caretIndex(in: text, selectedRange: snapshot.selectedRange)
        let requested = min(max(snapshot.selectedRange?.location ?? text.utf16.count, 0), text.utf16.count)
        return caret.utf16Offset(in: text) == requested && caret > text.startIndex
            && Self.terminators.contains(text[text.index(before: caret)])
    }
    private static func caretIndex(in text: String, selectedRange: NSRange?) -> String.Index {
        let target = min(max(selectedRange?.location ?? text.utf16.count, 0), text.utf16.count)
        var index = text.startIndex, offset = 0
        // AX ranges are UTF-16; snap a malformed interior offset to the start
        // of its complete grapheme, including surrogate pairs and ZWJ emoji.
        while index < text.endIndex {
            let next = text.index(after: index)
            let length = text[index..<next].utf16.count
            guard offset + length <= target else { break }
            offset += length
            index = next
        }
        return index
    }
    private static func fragment(in text: String, caret: String.Index) -> Range<String.Index> {
        var start = caret, end = caret
        while start > text.startIndex {
            let previous = text.index(before: start)
            if terminators.contains(text[previous]) { break }
            start = previous
        }
        while end < text.endIndex, !terminators.contains(text[end]) { end = text.index(after: end) }
        if end < text.endIndex, sentencePunctuation.contains(text[end]) { end = text.index(after: end) }
        while start < end, whitespace(text[start]) { start = text.index(after: start) }
        while end > start, whitespace(text[text.index(before: end)]) { end = text.index(before: end) }
        return start..<end
    }
    private static func previousSentence(in text: String, before caret: String.Index) -> Range<String.Index>? {
        var probe = caret
        while probe > text.startIndex {
            let previous = text.index(before: probe)
            if terminators.contains(text[previous]) {
                let inside = previous > text.startIndex ? text.index(before: previous) : previous
                let range = fragment(in: text, caret: inside)
                return range.isEmpty ? nil : range
            }
            probe = previous
        }
        return nil
    }
    private static func whitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }
}

/// Main-actor presentation identity, invalidated synchronously before any
/// asynchronous engine cancellation can run or a debounce can fire.
@MainActor
final class RealtimeTranslationState {
    struct Request: Equatable {
        let revision: UInt64
        let sequence: UInt64
        let session: InputSessionID
        let sentence: ExtractedSentence
        var key: String { sentence.key(in: session) }
    }
    private(set) var session: InputSessionID?
    private(set) var sentence: ExtractedSentence?
    private(set) var anchor: InputAnchor?
    private var revision: UInt64 = 0
    private var sequence: UInt64 = 0
    private(set) var mutationID: UInt64 = 0

    @discardableResult
    func update(_ snapshot: TextSnapshot, session: InputSessionID, language: Language) -> Bool {
        let extracted = snapshot.isComposing ? nil : SentenceExtractor().extractSentence(from: snapshot)
        let next = extracted.flatMap { LanguageTextDetector().contains($0.text, language: language) ? $0 : nil }
        guard self.session != session || sentence != next else { return false }
        revision &+= 1
        mutationID &+= 1
        if self.session != session { anchor = nil }
        self.session = session
        sentence = next
        return true
    }
    func updateAnchor(_ anchor: InputAnchor, session: InputSessionID) -> Bool {
        if self.session == nil { self.session = session }
        guard self.session == session else { return false }
        self.anchor = anchor
        return true
    }
    func invalidate(clearAnchor: Bool = false) {
        revision &+= 1
        mutationID &+= 1
        sentence = nil
        if clearAnchor { session = nil; anchor = nil }
    }
    func beginRequest(text: String, key: String, session: InputSessionID) -> Request? {
        guard self.session == session, let sentence, sentence.text == text, sentence.key(in: session) == key
        else { return nil }
        sequence &+= 1
        mutationID &+= 1
        return Request(revision: revision, sequence: sequence, session: session, sentence: sentence)
    }
    func accepts(_ request: Request) -> Bool {
        request.revision == revision && request.sequence == sequence
            && request.session == session && request.sentence == sentence
    }
}

public struct FieldReplacement: Equatable, Sendable {
    public let prefix: String
    public let sourceWithTerminator: String
    public let suffix: String
    public let caretUTF16Offset: Int

    public var reconstructed: String { prefix + sourceWithTerminator + suffix }
    public var range: NSRange { NSRange(location: prefix.utf16.count, length: sourceWithTerminator.utf16.count) }

    public func applying(translation: String) -> (text: String, caretUTF16Offset: Int) {
        let next = prefix + translation + suffix
        return (next, (prefix as NSString).length + (translation as NSString).length)
    }

    public static func replacing(
        fieldText: String, sourceWithTerminator: String, translation: String, range: NSRange? = nil
    ) -> (text: String, caretUTF16Offset: Int)? {
        guard !sourceWithTerminator.isEmpty else { return nil }
        let nsField = fieldText as NSString
        let matchRange = range ?? nsField.range(of: sourceWithTerminator, options: .backwards)
        guard valid(matchRange, in: nsField), nsField.substring(with: matchRange) == sourceWithTerminator else { return nil }
        let prefix = nsField.substring(to: matchRange.location)
        let suffix = nsField.substring(from: matchRange.location + matchRange.length)
        let next = prefix + translation + suffix
        return (next, (prefix as NSString).length + (translation as NSString).length)
    }

    public static func evaluate(fieldText: String, source: String, range: NSRange? = nil) -> FieldReplacement? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nsField = fieldText as NSString
        let sourceRange = range ?? nsField.range(of: trimmed, options: .backwards)
        guard valid(sourceRange, in: nsField), nsField.substring(with: sourceRange) == trimmed else { return nil }
        let afterSource = sourceRange.location + sourceRange.length
        var terminatorLength = 0
        let alreadyHasPunctuation = trimmed.last.map { SentenceExtractor.sentencePunctuation.contains($0) } ?? false
        if !alreadyHasPunctuation, afterSource < nsField.length {
            let next = nsField.substring(with: NSRange(location: afterSource, length: 1))
            if let ch = next.first, SentenceExtractor.terminators.contains(ch) {
                terminatorLength = 1
            }
        }
        let matchLength = sourceRange.length + terminatorLength
        let matchRange = NSRange(location: sourceRange.location, length: matchLength)
        let prefix = nsField.substring(to: sourceRange.location)
        let matched = nsField.substring(with: matchRange)
        let suffix = nsField.substring(from: matchRange.location + matchRange.length)
        return FieldReplacement(
            prefix: prefix,
            sourceWithTerminator: matched,
            suffix: suffix,
            caretUTF16Offset: matchRange.location + matchRange.length)
    }
    private static func valid(_ range: NSRange, in text: NSString) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.location <= text.length
            && range.length >= 0 && range.length <= text.length - range.location
    }

}

enum FocusedFieldReplacer {
    static func replace(
        currentText: String?,
        sourceWithTerminator: String,
        translation: String,
        range: NSRange? = nil,
        write: (String, Int) -> Bool
    ) -> Bool {
        guard let currentText,
            let next = FieldReplacement.replacing(
                fieldText: currentText, sourceWithTerminator: sourceWithTerminator, translation: translation, range: range)
        else { return false }
        return write(next.text, next.caretUTF16Offset)
    }
}

public struct ChineseTextDetector: Sendable {
    public init() {}
    public func containsChinese(_ text: String) -> Bool {
        LanguageTextDetector().contains(text, language: .chinese)
    }
}

/// Script-based source-text detector. Accessibility snapshots are frequently
/// short, so this intentionally does not try to statistically identify a
/// language; the language configured by the user remains authoritative.
public struct LanguageTextDetector: Sendable {
    public init() {}

    public func contains(_ text: String, language: Language) -> Bool {
        switch language {
        case .chinese:
            return text.unicodeScalars.contains(where: isHan)
        case .japanese:
            return text.unicodeScalars.contains(where: isKana) || text.unicodeScalars.contains(where: isHan)
        case .russian:
            return text.unicodeScalars.contains(where: isCyrillic)
        case .korean:
            return text.unicodeScalars.contains(where: isHangul)
        case .english, .french, .german, .spanish:
            return text.unicodeScalars.contains(where: isLatin)
        }
    }

    private func isHan(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }
    private func isKana(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value)
            || (0xFF66...0xFF9D).contains(value)
    }
    private func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x0400...0x052F).contains(value) || (0x2DE0...0x2DFF).contains(value)
            || (0xA640...0xA69F).contains(value)
    }
    private func isHangul(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value)
            || (0xA960...0xA97F).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0xD7B0...0xD7FF).contains(value)
    }
    private func isLatin(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x0041...0x005A).contains(value) || (0x0061...0x007A).contains(value)
            || (0x00C0...0x02AF).contains(value) || (0x1E00...0x1EFF).contains(value)
    }
}

enum ShortcutSnapshotRecovery {
    static func resolve(live: TextSnapshot, lastGoodText: String?, sourceLanguage: Language = .chinese) -> TextSnapshot {
        guard !live.isComposing else { return live }
        let extractor = SentenceExtractor()
        let detector = LanguageTextDetector()
        if detector.contains(extractor.extract(from: live), language: sourceLanguage) {
            return live
        }
        guard let lastGoodText else { return live }
        let recovered = TextSnapshot(
            pid: live.pid,
            bundleIdentifier: live.bundleIdentifier,
            text: lastGoodText,
            selectedRange: NSRange(location: (lastGoodText as NSString).length, length: 0),
            fieldFrame: live.fieldFrame,
            caretFrame: live.caretFrame,
            isComposing: live.isComposing,
            timestamp: live.timestamp)
        guard detector.contains(extractor.extract(from: recovered), language: sourceLanguage) else { return live }
        return recovered
    }
}

public actor TranslationCoordinator {
    private let engine: any TranslationEngine
    private var sourceLanguage: Language
    private var targetLanguage: Language
    private var generation = 0
    private var task: Task<String, Error>?
    private struct CacheKey: Hashable, Sendable {
        let text: String
        let source: Language
        let target: Language
    }
    private var cache: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []
    /// Bounds memory during long sessions; FIFO eviction is enough because a
    /// re-translated sentence simply re-inserts at the newest position.
    private static let cacheLimit = 128

    public init(engine: any TranslationEngine, sourceLanguage: Language = .chinese, targetLanguage: Language = .english) {
        self.engine = engine
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    public func setDirection(from source: Language, to target: Language) {
        guard sourceLanguage != source || targetLanguage != target else { return }
        sourceLanguage = source
        targetLanguage = target
        generation += 1
        task?.cancel()
        task = nil
    }

    private var configurationRevision: UInt64 = 0

    /// One actor turn cancels in-flight work and invalidates every cache entry.
    public func reconfigure(from source: Language, to target: Language, revision: UInt64) {
        guard revision >= configurationRevision else { return }
        configurationRevision = revision
        sourceLanguage = source
        targetLanguage = target
        clearCache()
    }

    public func clearCache() {
        cancel()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    public func translate(_ text: String) async -> String? {
        await translate(text, from: sourceLanguage, to: targetLanguage)
    }

    public func translate(_ text: String, from source: Language, to target: Language) async -> String? {
        try? await translateThrowing(text, from: source, to: target)
    }

    public func translateThrowing(_ text: String, from source: Language, to target: Language,
        revision: UInt64? = nil) async throws -> String {
        try Task.checkCancellation()
        let expected = revision ?? configurationRevision
        guard expected == configurationRevision else { throw CancellationError() }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMTranslationError.emptyText }
        guard source != target else { return key }
        generation += 1
        let current = generation
        task?.cancel()
        let cacheKey = CacheKey(text: key, source: source, target: target)
        if let cached = cache[cacheKey] { return cached }
        let newTask = Task { try await engine.translate(key, from: source, to: target) }
        task = newTask
        do {
            let value = try await newTask.value
            guard current == generation, expected == configurationRevision, !Task.isCancelled else { throw CancellationError() }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationResultError.empty }
            storeInCache(cacheKey, value)
            return value
        } catch {
            guard current == generation, expected == configurationRevision, !Task.isCancelled,
                !(error is CancellationError), (error as? URLError)?.code != .cancelled else { throw CancellationError() }
            let fields = (error as? WebTranslationError)?.diagnosticFields ?? TranslationErrorDiagnostic(error).fields
            DiagnosticLog.write("translation error \(fields)")
            throw error
        }
    }

    private func storeInCache(_ key: CacheKey, _ value: String) {
        guard cache[key] == nil else { return }
        cache[key] = value
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

public protocol TranslationEngine: Sendable {
    func translate(_ text: String, from: Language, to: Language) async throws -> String
}

enum TranslationSessionError: Error {
    case unavailable
}

struct TranslationHostConfiguration: Equatable, Sendable {
    let source: Language
    let target: Language
    let generation: UInt64
}

@MainActor
final class TranslationSessionHolder: ObservableObject {
    private var session: TranslationSession?
    private var sessionSource: Language?
    private var sessionTarget: Language?
    @Published private(set) var hostConfiguration = TranslationHostConfiguration(source: .chinese, target: .english, generation: 0)
    private var waiters: [UUID: CheckedContinuation<TranslationSession, Error>] = [:]

    func acceptsHostConfiguration(_ configuration: TranslationHostConfiguration) -> Bool {
        configuration == hostConfiguration
    }

    func attach(_ session: TranslationSession, configuration: TranslationHostConfiguration) {
        // A previous SwiftUI task can complete after its configuration has
        // been invalidated. Even A-B-A must reject the first A's callback,
        // so both the language pair and native host generation must match.
        guard acceptsHostConfiguration(configuration), !Task.isCancelled else { return }
        self.session = session
        sessionSource = configuration.source
        sessionTarget = configuration.target
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume(returning: session) }
    }

    @discardableResult
    func configure(source: Language, target: Language) -> Bool {
        // Same-pair backend edits/resume preserve readiness. Every actual
        // direction change publishes a new host identity, including A-B-A
        // changes coalesced into one SwiftUI render.
        guard hostConfiguration.source != source || hostConfiguration.target != target else { return false }
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: TranslationSessionError.unavailable) }
        session = nil
        sessionSource = nil
        sessionTarget = nil
        hostConfiguration = TranslationHostConfiguration(source: source, target: target,
            generation: hostConfiguration.generation &+ 1)
        return true
    }

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let session = try await readySession(from: source, to: target)
        try Task.checkCancellation()
        return try await session.translate(text).targetText
    }

    private func readySession(from source: Language, to target: Language) async throws -> TranslationSession {
        try Task.checkCancellation()
        guard hostConfiguration.source == source, hostConfiguration.target == target else {
            throw TranslationSessionError.unavailable
        }
        if let session, sessionSource == source, sessionTarget == target { return session }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                Task { await self.failWaiterIfStillEmpty(id) }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    private func failWaiterIfStillEmpty(_ id: UUID) async {
        try? await Task.sleep(for: .seconds(8))
        guard session == nil else { return }
        waiters.removeValue(forKey: id)?.resume(throwing: TranslationSessionError.unavailable)
    }
}

struct HostedTranslationEngine: TranslationEngine, @unchecked Sendable {
    let holder: TranslationSessionHolder
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        try await holder.translate(text, from: from, to: to)
    }
}

enum TranslationResultError: Error { case empty }

/// Entire configurations are synchronously built and published in one actor
/// turn. Requests retain their selected engine through the whole fallback.
actor TranslationService: TranslationEngine {
    typealias ModelFactory = @Sendable ([LLMModelConfiguration], Double) -> any TranslationEngine
    private let engines: [TranslationBackend: any TranslationEngine]
    private let modelFactory: ModelFactory
    private var selected: any TranslationEngine
    private var revision: UInt64 = 0

    init(localEngine: any TranslationEngine, backend: TranslationBackend,
        models: [LLMModelConfiguration], timeoutSeconds: Double,
        engines injected: [TranslationBackend: any TranslationEngine] = [:],
        modelFactory: @escaping ModelFactory = { LLMModelRouter(models: $0, timeoutSeconds: $1) }) {
        var engines: [TranslationBackend: any TranslationEngine] = [
            .local: localEngine, .google: GoogleTranslationEngine(), .bing: BingTranslationEngine(), .youdao: YoudaoTranslationEngine(),
        ]
        engines.merge(injected) { _, value in value }
        self.engines = engines
        self.modelFactory = modelFactory
        selected = engines[backend] ?? modelFactory(models, timeoutSeconds)
    }

    func configure(backend: TranslationBackend, models: [LLMModelConfiguration], timeoutSeconds: Double,
        revision requested: UInt64? = nil) {
        let next = requested ?? (revision &+ 1)
        guard next > revision else { return }
        let engine = engines[backend] ?? modelFactory(models, timeoutSeconds)
        selected = engine
        revision = next
    }

    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        let engine = selected
        return try await engine.translate(text, from: from, to: to)
    }
}

/// Only controlled messages reach error UI, never arbitrary LLM/NSError
/// descriptions that may echo input, endpoint secrets or model names.
enum TranslationFailureMessage {
    static func text(for error: any Error, backend: TranslationBackend, language: UILanguage) -> String {
        let chinese = language == .chinese
        if let error = error as? WebTranslationError {
            if chinese { return error.errorDescription ?? "翻译失败，请重试。" }
            let name = backend.displayName(for: .english)
            switch error {
            case .timeout: return "\(name): request timed out."
            case .httpStatus(_, let code): return "\(name): HTTP \(code)."
            case .upstream(_, let code): return "\(name): service error \(code)."
            case .network: return "\(name): network connection failed."
            case .emptyResult: return "\(name): no translation returned."
            default: return "\(name): invalid service response."
            }
        }
        if let error = error as? LLMTranslationError {
            switch error {
            case .noEnabledModels: return chinese ? "未配置启用的语言模型。" : "No enabled language model configured."
            case .invalidEndpoint: return chinese ? "语言模型地址无效。" : "Invalid language model endpoint."
            case .timeout: return chinese ? "语言模型请求超时。" : "Language model request timed out."
            case .httpStatus(_, let status, _): return chinese ? "语言模型返回 HTTP \(status)。" : "Language model: HTTP \(status)."
            default: return chinese ? "语言模型翻译失败，请检查配置或稍后重试。" : "Language model translation failed. Check settings or retry."
            }
        }
        if error is TranslationSessionError { return chinese ? "苹果本地翻译尚未就绪，请检查语言下载。" : "Apple translation is not ready. Check language downloads." }
        return chinese ? "翻译失败，请检查网络或服务设置。" : "Translation failed. Check network or service settings."
    }
}
