import XCTest

@testable import Pico

final class DiagnosticsReportTests: XCTestCase {
    private func makeSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "1.0.8", appBuild: "9", bundleID: "com.comeg.runwu",
            installPath: "/Applications/润物.app", installNeedsHealing: false,
            osVersion: "14.6.1", hardwareModel: "Mac15,6", machine: "arm64",
            accessibilityTrusted: false, monitorRunning: false,
            probeLine: "probe target=com.tencent.xinWeChat result=no_text_element",
            weChatVersion: "4.1.5.16", enabled: true, timingRaw: "pause", speedMilliseconds: 450,
            sourceLanguage: "zh", targetLanguage: "en", backendRaw: "local", llmModelCount: 0,
            uiLanguage: "zh", clipboardEnabled: true, clipboardTriggerRaw: "auto-watch",
            excludedBundleIDs: ["com.comeg.runwu"], generatedAt: Date(timeIntervalSince1970: 1_789_000_000))
    }

    func testRenderContainsKeyDiagnosticLines() {
        let content = DiagnosticsReport.render(
            snapshot: makeSnapshot(), recentLog: ["log-line-1"], debugLogExists: false,
            debugLogTail: [])
        XCTAssertTrue(content.contains("accessibility_trusted: false"))
        XCTAssertTrue(content.contains("version: 1.0.8 (build 9)"))
        XCTAssertTrue(content.contains("probe target=com.tencent.xinWeChat result=no_text_element"))
        XCTAssertTrue(content.contains("wechat_version: 4.1.5.16"))
        XCTAssertTrue(content.contains("log-line-1"))
        // 调试文件不存在时不得凭空出现该节内容
        XCTAssertFalse(content.contains("exists=false\n/tmp"))
    }

    func testRenderNeverCarriesPrivateSurfaces() {
        let content = DiagnosticsReport.render(
            snapshot: makeSnapshot(), recentLog: [], debugLogExists: false, debugLogTail: [])
        // 报告只有模型数量，没有模型名/服务地址/密钥的容身之处
        XCTAssertFalse(content.lowercased().contains("apikey"))
        XCTAssertFalse(content.lowercased().contains("baseurl"))
        XCTAssertFalse(content.contains("sk-"))
    }

    func testWriteLandsInGivenDirectoryAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pico-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = DiagnosticsReport.write("报告内容", at: Date(), in: directory)
        XCTAssertEqual(url?.deletingLastPathComponent(), directory)
        let written = try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)
        XCTAssertEqual(written, "报告内容")
    }

    func testFileNameFormatIsAttachmentFriendly() {
        XCTAssertTrue(
            DiagnosticsReport.fileName(at: Date()).matches(pattern: #"^Runwu-Diagnostics-\d{8}-\d{6}\.txt$"#))
    }

    /// 探针几何：整数坐标进报告，宿主没报告的矩形显式写 nil——跟随卡避让
    /// 输入框依赖输入框矩形，「缺失」与「偏移」必须能一眼区分。
    func testProbeGeometryFormattingRoundsAndMarksMissingRects() {
        XCTAssertEqual(
            AccessibilityMonitor.coordinates(NSRect(x: 302.4, y: 288.6, width: 1, height: 20.2)),
            "302,289,1,20")
        XCTAssertEqual(AccessibilityMonitor.coordinates(nil), "nil")
        // 坏宿主报出荒谬但有限的值时不许在 Int() 上崩：逐项标 insane
        XCTAssertEqual(AccessibilityMonitor.coordinates(NSRect(x: 1e300, y: 0, width: 10, height: 10)),
            "insane,0,10,10")
        XCTAssertEqual(AccessibilityMonitor.coordinates(NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)),
            "0,0,insane,10")
    }

    func testRingBufferKeepsRecentLinesInOrderAndBounded() {
        DiagnosticLog.write("ring-test-first")
        for index in 0..<405 { DiagnosticLog.write("ring-test-fill-\(index)") }
        let lines = DiagnosticLog.recentLines()
        XCTAssertLessThanOrEqual(lines.count, 400)
        XCTAssertEqual(lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("ring-test-fill-404"), true)
        XCTAssertFalse(lines.contains { $0.contains("ring-test-first") })
    }
}

private extension String {
    func matches(pattern: String) -> Bool {
        return range(of: pattern, options: .regularExpression, range: nil, locale: nil) != nil
    }
}
