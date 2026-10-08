import AppKit
import XCTest
@testable import Pico

@MainActor
final class ClipboardReadBoundaryTests: XCTestCase {
    func testWatcherRejectsBeforeReadAndConsumesRejectedChangeCount() {
        let pasteboard = BoundaryPasteboard(), watcher = PasteboardWatcher(pasteboard: pasteboard)
        var allowed = false, received: [String] = []
        watcher.permitsRead = { allowed }
        watcher.onCopy = { received.append($0) }
        pasteboard.copy("排除应用固定测试原文。")
        watcher.check()
        XCTAssertEqual(pasteboard.reads, 0)
        XCTAssertTrue(received.isEmpty)
        allowed = true
        watcher.check()
        XCTAssertEqual(pasteboard.reads, 0, "Leaving a denied context must not replay its old clipboard")
        pasteboard.copy("允许应用的新复制。")
        watcher.check()
        XCTAssertEqual(pasteboard.reads, 1)
        XCTAssertEqual(received, ["允许应用的新复制。"])
    }

    func testAppAutomaticEntryAndWatcherUseReadBeforeExclusionAndEnabledPolicy() async throws {
        let fixture = BoundaryAppFixture()
        defer { fixture.close() }
        fixture.store.excludedBundleIDs = ["boundary.excluded"]
        fixture.front = "boundary.excluded"
        fixture.pasteboard.copy("排除应用固定测试原文。")
        fixture.app.translateCopiedText(autoTriggered: true)
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 0)
        let excludedRequests = await fixture.engine.count
        XCTAssertEqual(excludedRequests, 0)
        fixture.front = "boundary.allowed"
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 0)
        fixture.pasteboard.copy("允许的新复制。")
        fixture.app.pasteboardWatcher.check()
        try await wait { await fixture.engine.count == 1 }
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        fixture.store.clipboardTranslationEnabled = false
        fixture.pasteboard.copy("关闭监听时复制。")
        fixture.app.translateCopiedText(autoTriggered: true)
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        fixture.store.clipboardTranslationEnabled = true
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        fixture.app.toggle()
        fixture.pasteboard.copy("暂停时复制。")
        fixture.app.translateCopiedText(autoTriggered: true)
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        fixture.app.toggle()
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        fixture.store.clipboardTriggerMode = .hotkey
        fixture.pasteboard.copy("切到快捷键模式后的复制。")
        fixture.app.translateCopiedText(autoTriggered: true)
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        fixture.store.clipboardTriggerMode = .autoWatch
        fixture.app.pasteboardWatcher.check()
        XCTAssertEqual(fixture.pasteboard.reads, 1, "Queued automatic work must obey the current trigger mode")
    }

    func testExplicitClipboardActionInExcludedAppStillReadsAndTranslates() async throws {
        let fixture = BoundaryAppFixture()
        defer { fixture.close() }
        fixture.store.excludedBundleIDs = ["boundary.excluded"]
        fixture.front = "boundary.excluded"
        fixture.store.clipboardTriggerMode = .hotkey
        fixture.pasteboard.copy("用户明确请求固定测试原文。")
        fixture.app.translateCopiedText(autoTriggered: false)
        try await wait { fixture.app.history.entries.count == 1 }
        let explicitRequests = await fixture.engine.count
        XCTAssertEqual(explicitRequests, 1)
        XCTAssertEqual(fixture.pasteboard.reads, 1)
        XCTAssertEqual(fixture.app.overlay.cardContents.count, 1)
        XCTAssertNil(fixture.app.clipboardFailure)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic clipboard translation did not finish")
    }
}

@MainActor private final class BoundaryPasteboard: PasteboardReading {
    var changeCount = 0, reads = 0
    private var text = ""
    func copy(_ text: String) { self.text = text; changeCount += 1 }
    func readString() -> String? { reads += 1; return text }
}

private actor BoundaryEngine: TranslationEngine {
    private(set) var count = 0
    func translate(_ text: String, from: Language, to: Language) async throws -> String {
        count += 1; return "Synthetic translation."
    }
}

@MainActor private final class BoundaryAppFixture {
    let suite = "RunwuClipboardBoundary.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let pasteboard = BoundaryPasteboard(), engine = BoundaryEngine()
    let store: SettingsStore
    var front: String? = "boundary.allowed"
    lazy var app = AppState(settings: store, translationEngine: engine,
        historyDatabaseURL: directory.appendingPathComponent("history.sqlite"), startRuntime: false,
        clipboardReader: pasteboard, frontmostBundleIdentifier: { [weak self] in self?.front })
    init() {
        _ = NSApplication.shared
        store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        store.clipboardTranslationEnabled = true
        store.clipboardTriggerMode = .autoWatch
        store.neverHide = true
        _ = app
    }
    func close() {
        app.input.reset(); app.overlay.hide()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
