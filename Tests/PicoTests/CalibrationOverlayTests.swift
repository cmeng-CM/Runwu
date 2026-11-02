import SwiftUI
import XCTest

@testable import Pico

@MainActor
final class CalibrationOverlayTests: XCTestCase {
    private func verdict(
        rating: CalibrationVerdict.Rating = .major,
        issues: [CalibrationIssue] = []
    ) -> CalibrationVerdict {
        CalibrationVerdict(
            rating: rating,
            backTranslation: "我昨天去了学校。",
            corrected: "I went to school yesterday.",
            issues: issues)
    }

    func testSizingPlanStaysNonScrollingWithinLimit() {
        let plan = CalibrationCardSizing.plan(
            measuredNatural: 200, fittingNatural: 180, chrome: 60, limit: 400)
        XCTAssertFalse(plan.scrolls)
        XCTAssertNil(plan.textHeightLimit)
        XCTAssertEqual(plan.cardHeight, 200)  // max(measured, fitting)
    }

    func testSizingPlanUsesFittingNaturalWhenMeasurementUnderestimates() {
        let plan = CalibrationCardSizing.plan(
            measuredNatural: 150, fittingNatural: 500, chrome: 60, limit: 400)
        XCTAssertTrue(plan.scrolls)
        XCTAssertEqual(plan.textHeightLimit, 340)  // limit - chrome
        XCTAssertEqual(plan.cardHeight, 400)
    }

    func testSizingPlanExtremeChromeNeverClipsBodyBelow60() {
        // chrome + 60 > limit: the panel grows past the limit instead of
        // squeezing the scroll body below 60pt (review N-21/N-23).
        let plan = CalibrationCardSizing.plan(
            measuredNatural: 900, fittingNatural: 900, chrome: 400, limit: 420)
        XCTAssertTrue(plan.scrolls)
        XCTAssertEqual(plan.textHeightLimit, 60)
        XCTAssertEqual(plan.cardHeight, 460)  // chrome + textLimit beats the limit
    }

    /// Realtime cards only come up once a caret anchor exists (follow mode
    /// orders an anchorless realtime panel OUT), so tests pass a real anchor.
    private let anchor = InputAnchor(
        caretFrame: CGRect(x: 500, y: 500, width: 2, height: 16),
        fieldFrame: CGRect(x: 300, y: 400, width: 400, height: 30))

    func testShowCalibrationInstallsRealtimeEntryWithCorrectedAsTranslation() {
        let overlay = OverlayCoordinator()
        let session = InputSessionID(pid: 1)
        overlay.showCalibration(
            verdict(), source: "I have went to school yesterday.", key: "k1", session: session,
            anchor: anchor)
        XCTAssertEqual(overlay.shownEntryIDs.count, 1)
        XCTAssertEqual(
            overlay.cardContents,
            [OverlayCardContent(
                source: "I have went to school yesterday.", translation: "I went to school yesterday.")])
        // The panel hosts a calibration card, not a translation card.
        XCTAssertTrue(
            overlay.panelContentViews.contains {
                $0 is NSHostingView<CalibrationCardView>
            })
    }

    func testSameKeyUpdatesCalibrationInPlace() {
        let overlay = OverlayCoordinator()
        let session = InputSessionID(pid: 1)
        overlay.showCalibration(
            verdict(), source: "Hello there.", key: "k1", session: session, anchor: anchor)
        overlay.showCalibration(
            verdict(rating: .good), source: "Hello there.", key: "k1", session: session, anchor: anchor)
        XCTAssertEqual(overlay.shownEntryIDs.count, 1)
        XCTAssertEqual(overlay.cardContents.first?.translation, "I went to school yesterday.")
    }

    func testHideRealtimeRemovesUnpinnedCalibrationCard() {
        let overlay = OverlayCoordinator()
        let session = InputSessionID(pid: 1)
        overlay.showCalibration(verdict(), source: "Hello.", key: "k1", session: session, anchor: anchor)
        overlay.hideRealtime()
        XCTAssertTrue(overlay.shownEntryIDs.isEmpty)
    }

    func testPinnedCalibrationCardSurvivesHideRealtime() {
        let overlay = OverlayCoordinator()
        let session = InputSessionID(pid: 1)
        overlay.showCalibration(verdict(), source: "Hello.", key: "k1", session: session, anchor: anchor)
        guard let id = overlay.shownEntryIDs.first else { return XCTFail("expected a visible calibration card") }
        overlay.togglePin(of: id)
        overlay.hideRealtime()
        XCTAssertEqual(overlay.shownEntryIDs, [id])
        // Unpinning a formerly pinned realtime card turns it into a history
        // card: it keeps its position, leaves session cleanup, and relies on
        // auto-hide — same semantics as translation cards (design D-C7).
        overlay.togglePin(of: id)
        overlay.hideRealtime()
        XCTAssertEqual(overlay.shownEntryIDs, [id])
    }

    func testServiceMenuRebuildSkipsCalibrationEntries() {
        let overlay = OverlayCoordinator()
        let session = InputSessionID(pid: 1)
        overlay.showCalibration(verdict(), source: "Hello.", key: "k1", session: session, anchor: anchor)
        overlay.selectedService = .bing  // must not replace the calibration host
        XCTAssertTrue(
            overlay.panelContentViews.contains {
                $0 is NSHostingView<CalibrationCardView>
            })
    }
}
