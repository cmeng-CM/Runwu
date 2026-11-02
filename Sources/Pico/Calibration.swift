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
