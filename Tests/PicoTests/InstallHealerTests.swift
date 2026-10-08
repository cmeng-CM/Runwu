import XCTest

@testable import Pico

final class InstallHealerTests: XCTestCase {
    func testNeedsHealingFlagsTemporaryLocations() {
        XCTAssertTrue(
            InstallHealer.needsHealing(
                bundlePath: "/private/var/folders/xx/821d/AppTranslocation/AB12/d/Runwu.app"))
        XCTAssertTrue(InstallHealer.needsHealing(bundlePath: "/Volumes/Pico 1/Runwu.app"))
        XCTAssertTrue(InstallHealer.needsHealing(bundlePath: NSHomeDirectory() + "/Downloads/Runwu.app"))
        XCTAssertTrue(InstallHealer.needsHealing(bundlePath: NSHomeDirectory() + "/Downloads/apps/Runwu.app"))
    }

    func testNeedsHealingAcceptsProperInstallLocations() {
        XCTAssertFalse(InstallHealer.needsHealing(bundlePath: "/Applications/Runwu.app"))
        XCTAssertFalse(InstallHealer.needsHealing(bundlePath: NSHomeDirectory() + "/Applications/Runwu.app"))
        XCTAssertFalse(InstallHealer.needsHealing(bundlePath: "/opt/homebrew/Runwu.app"))
    }

    func testNeedsHealingDoesNotMatchLookalikePaths() {
        // 其他用户的下载目录、名字沾边的路径都不该误报
        XCTAssertFalse(InstallHealer.needsHealing(bundlePath: "/Users/other/Downloads/Runwu.app"))
        XCTAssertFalse(InstallHealer.needsHealing(bundlePath: "/Applications/MyVolumes/Runwu.app"))
    }

    func testShouldPromptRespectsDismissedVersion() {
        let path = NSHomeDirectory() + "/Downloads/Runwu.app"
        XCTAssertTrue(
            InstallHealer.shouldPrompt(
                dismissedVersion: nil, currentVersion: "1.0.4", bundlePath: path))
        XCTAssertTrue(
            InstallHealer.shouldPrompt(
                dismissedVersion: "1.0.3", currentVersion: "1.0.4", bundlePath: path))
        XCTAssertFalse(
            InstallHealer.shouldPrompt(
                dismissedVersion: "1.0.4", currentVersion: "1.0.4", bundlePath: path))
        // 位置正常时即使没点过「暂不」也不提示
        XCTAssertFalse(
            InstallHealer.shouldPrompt(
                dismissedVersion: nil, currentVersion: "1.0.4", bundlePath: "/Applications/Runwu.app"))
    }
}
