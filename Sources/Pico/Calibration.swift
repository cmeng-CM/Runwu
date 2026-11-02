import AppKit
import Foundation

/// Single routing authority for the focused-field input pipeline (design 4.1, D-C9).
/// Translation keeps its existing script detector; calibration only claims the
/// sentences that detector already drops: no Han, Latin script, not truncated,
/// source language Chinese, switch on. Everything else that fails the detector
/// stays `.none` exactly as before.
enum Route: Equatable, Sendable {
    case translate
    case calibrate
    case none
}

struct RouteDecision: Sendable {
    static func decide(
        text: String, isTruncated: Bool, sourceLanguage: Language, calibrationEnabled: Bool
    ) -> Route {
        if LanguageTextDetector().contains(text, language: sourceLanguage) {
            return .translate
        }
        if calibrationEnabled, sourceLanguage == .chinese, !isTruncated,
            !LanguageTextDetector().contains(text, language: .chinese),
            LanguageTextDetector().contains(text, language: .english)
        {
            return .calibrate
        }
        return .none
    }
}

/// Mirrors `RealtimeTranslationState`'s token semantics (Models.swift) but only
/// ever receives sentences routed as `.calibrate`; routing itself stays in
/// `RouteDecision` so the two pipelines cannot double-claim a sentence.
@MainActor
final class CalibrationState {
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
    func update(_ snapshot: TextSnapshot, session: InputSessionID) -> Bool {
        let next = snapshot.isComposing ? nil : SentenceExtractor().extractSentence(from: snapshot)
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

// MARK: - Calibration result model (design 5.1)

struct CalibrationIssue: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case grammar
        case usage
        case wordChoice = "word-choice"
        case spelling
        case style

        var label: String {
            switch self {
            case .grammar: return "语法"
            case .usage: return "用法"
            case .wordChoice: return "选词"
            case .spelling: return "拼写"
            case .style: return "风格"
            }
        }
    }
    let quote: String
    let kind: Kind
    /// Chinese explanation of the problem.
    let reason: String
    let fix: String
    var id: String { "\(kind.rawValue)|\(quote)|\(fix)" }
}

struct CalibrationVerdict: Equatable, Sendable {
    enum Rating: String, Sendable {
        case good
        case minor
        case major
    }
    let rating: Rating
    /// Chinese back-translation of the ORIGINAL sentence, errors included
    /// (design D-C11), so the user can verify what they actually said.
    let backTranslation: String
    /// Fully corrected sentence; equals the source when the rating is good.
    let corrected: String
    /// At most 5 issues, ordered by their first occurrence in the source.
    let issues: [CalibrationIssue]
}

enum CalibrationParseError: Error, Equatable, CustomStringConvertible {
    case missingJSONObject
    case invalidVerdict
    case missingBackTranslation
    case issuesRequired
    case correctedRequired

    var description: String {
        switch self {
        case .missingJSONObject: return "no JSON object found in the response"
        case .invalidVerdict: return "verdict missing or not good/minor/major"
        case .missingBackTranslation: return "back_translation_zh missing or empty"
        case .issuesRequired: return "minor/major requires at least one valid issue"
        case .correctedRequired: return "corrected missing or empty"
        }
    }
}

/// Parses the model's response into a `CalibrationVerdict`, applying the eight
/// validation rules of design 5.1. Malformed output is an error so the router
/// can fail over to the next model instead of faking a result (D-C4).
enum CalibrationResponseParser {
    static func parse(_ content: String, source: String) throws -> CalibrationVerdict {
        // Rule 1: strip code fences and surrounding chatter to the outermost object.
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            throw CalibrationParseError.missingJSONObject
        }
        let jsonText = String(content[start...end])
        guard let data = jsonText.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw CalibrationParseError.missingJSONObject }

        // Rule 2: verdict must exist and be one of the three ratings.
        let verdictRaw = ((object["verdict"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rating = CalibrationVerdict.Rating(rawValue: verdictRaw.lowercased()) else {
            throw CalibrationParseError.invalidVerdict
        }
        // Rule 3: back translation must be non-empty.
        let backTranslation = ((object["back_translation_zh"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !backTranslation.isEmpty else { throw CalibrationParseError.missingBackTranslation }

        // Rule 4: filter issues first — quote must be a non-empty exact substring
        // of the source, reason/fix non-empty; unknown kinds fall back to style.
        let rawIssues = object["issues"] as? [[String: Any]] ?? []
        var candidates: [(offset: Int, issue: CalibrationIssue)] = []
        var dropped = 0
        for entry in rawIssues {
            let quote = ((entry["quote"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = ((entry["reason_zh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fix = ((entry["fix"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty, !reason.isEmpty, !fix.isEmpty, let range = source.range(of: quote) else {
                dropped += 1
                continue
            }
            let kind = CalibrationIssue.Kind(
                rawValue: ((entry["kind"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                ?? .style
            candidates.append(
                (
                    source.distance(from: source.startIndex, to: range.lowerBound),
                    CalibrationIssue(quote: quote, kind: kind, reason: reason, fix: fix)
                ))
        }
        candidates.sort { $0.offset < $1.offset }
        let validIssues = Array(candidates.prefix(5).map(\.issue))
        if dropped > 0 || candidates.count > validIssues.count {
            DiagnosticLog.write(
                "calibration issues dropped=\(dropped) capped=\(max(0, candidates.count - validIssues.count))")
        }
        let corrected = ((object["corrected"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch rating {
        case .good:
            if validIssues.isEmpty {
                // Rule 4 (good): issues may be absent; corrected falls back to the source.
                return CalibrationVerdict(
                    rating: .good, backTranslation: backTranslation,
                    corrected: corrected.isEmpty ? source : corrected, issues: [])
            }
            // Contradiction: keep the conservative rating, but a usable corrected
            // sentence becomes mandatory because issues are being shown.
            guard !corrected.isEmpty else { throw CalibrationParseError.correctedRequired }
            DiagnosticLog.write("calibration verdict downgraded reason=goodWithIssues")
            return CalibrationVerdict(
                rating: .minor, backTranslation: backTranslation, corrected: corrected, issues: validIssues)
        case .minor, .major:
            // Rules 6–7: no "red badge with no findings", and corrected is required.
            guard !validIssues.isEmpty else { throw CalibrationParseError.issuesRequired }
            guard !corrected.isEmpty else { throw CalibrationParseError.correctedRequired }
            return CalibrationVerdict(
                rating: rating, backTranslation: backTranslation, corrected: corrected, issues: validIssues)
        }
    }
}

/// Mirrors `TranslationCoordinator`'s generation/cache/cancel semantics for the
/// calibration pipeline (design 4.2). Holds its own `LLMModelRouter` so model
/// configuration changes never leak into a translation request in flight.
actor CalibrationCoordinator {
    private var router: LLMModelRouter
    private var generation = 0
    private var task: Task<CalibrationVerdict, Error>?
    private var cache: [String: CalibrationVerdict] = [:]
    private var cacheOrder: [String] = []
    /// Cache entries include the prompt version so a prompt change invalidates
    /// every cached verdict (design ch.6).
    private static let cacheLimit = 64
    private var configurationRevision: UInt64 = 0

    private let session: URLSession

    init(
        models: [LLMModelConfiguration] = [], timeoutSeconds: Double = 8, session: URLSession = .shared
    ) {
        self.session = session
        router = LLMModelRouter(models: models, timeoutSeconds: timeoutSeconds, session: session)
    }

    func reconfigure(models: [LLMModelConfiguration], timeoutSeconds: Double, revision: UInt64) {
        guard revision >= configurationRevision else { return }
        configurationRevision = revision
        router = LLMModelRouter(models: models, timeoutSeconds: timeoutSeconds, session: session)
        clearCache()
    }

    func clearCache() {
        cancel()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    func calibrateThrowing(_ text: String, revision: UInt64? = nil) async throws -> CalibrationVerdict {
        try Task.checkCancellation()
        let expected = revision ?? configurationRevision
        guard expected == configurationRevision else { throw CancellationError() }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMTranslationError.emptyText }
        generation += 1
        let current = generation
        task?.cancel()
        let cacheKey = Self.cacheKey(for: key)
        if let cached = cache[cacheKey] { return cached }
        let newTask = Task { try await router.calibrate(key) }
        task = newTask
        do {
            let value = try await newTask.value
            guard current == generation, expected == configurationRevision, !Task.isCancelled else {
                throw CancellationError()
            }
            storeInCache(cacheKey, value)
            return value
        } catch {
            guard current == generation, expected == configurationRevision, !Task.isCancelled,
                !(error is CancellationError), (error as? URLError)?.code != .cancelled else {
                throw CancellationError()
            }
            DiagnosticLog.write("calibration error \(TranslationErrorDiagnostic(error).fields)")
            throw error
        }
    }

    static func cacheKey(for text: String) -> String {
        "\(LLMCalibrationPrompt.version)\u{0}\(text)"
    }

    private func storeInCache(_ key: String, _ value: CalibrationVerdict) {
        guard cache[key] == nil else { return }
        cache[key] = value
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

// MARK: - Calibration card sizing (design 4.3, D-C12)

/// Pure sizing policy for calibration cards: `effectiveNatural` is the larger
/// of the segmented TextKit measurement and the unscrolled natural fitting
/// size; over-budget cards get an explicit scroll plan whose panel height may
/// exceed the limit by the extreme-chrome margin instead of clipping the body
/// (review N-13/N-19/N-21).
enum CalibrationCardSizing {
    struct Plan: Equatable {
        let scrolls: Bool
        let textHeightLimit: CGFloat?
        let cardHeight: CGFloat
    }

    static func plan(
        measuredNatural: CGFloat, fittingNatural: CGFloat, chrome: CGFloat, limit: CGFloat
    ) -> Plan {
        let effective = max(measuredNatural, fittingNatural)
        guard effective > limit else {
            return Plan(scrolls: false, textHeightLimit: nil, cardHeight: effective)
        }
        let textLimit = max(limit - chrome, 60)
        return Plan(scrolls: true, textHeightLimit: textLimit, cardHeight: max(limit, chrome + textLimit))
    }
}
