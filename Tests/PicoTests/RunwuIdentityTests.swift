import XCTest
@testable import Pico

@MainActor
final class RunwuIdentityTests: XCTestCase {
    func testLocalBuildCannotCheckOrInstallEvenWithStoredOptIns() async {
        let suite = "RunwuIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "autoUpdateEnabled")
        defaults.set(true, forKey: "autoInstallUpdates")
        let updater = AutoUpdateController(settings: SettingsStore(defaults: defaults))

        updater.startMonitoring()
        updater.checkManually()
        await updater.runCheck(manual: true)
        updater.confirmUpdate()
        updater.retryInstall()

        XCTAssertEqual(updater.phase, .idle)
        XCTAssertEqual(updater.statusText(for: .chinese), "本地构建不提供自动更新")
    }

    func testRunwuSecretsAndDefaultExclusionsAreIndependent() {
        let suite = "RunwuIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        XCTAssertEqual(KeychainStore.defaultService, "com.comeg.runwu")
        XCTAssertTrue(settings.excludedBundleIDs.contains("com.comeg.runwu"))
        XCTAssertTrue(settings.excludedBundleIDs.contains("com.asiyoua.pico"))
        XCTAssertFalse(settings.autoUpdateEnabled)
    }
}
