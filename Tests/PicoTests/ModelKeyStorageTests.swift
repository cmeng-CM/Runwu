import XCTest
@testable import Pico

/// 模型密钥存本机设置（不再进钥匙串）：日常读写都不碰 KeychainStore，
/// 旧钥匙串密钥只有用户显式导入时才读一次。
@MainActor
final class ModelKeyStorageTests: XCTestCase {
    private final class SpyStorage: ModelKeyStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: String] = [:]
        private var readIDs: [UUID] = []
        private var writtenIDs: [UUID] = []
        private var deletedIDs: [UUID] = []

        init(seed: [UUID: String] = [:]) { values = seed }

        func apiKey(forModelID id: UUID) throws -> String? {
            lock.withLock {
                readIDs.append(id)
                return values[id]
            }
        }
        func setAPIKey(_ value: String?, forModelID id: UUID) throws {
            lock.withLock {
                writtenIDs.append(id)
                values[id] = value
            }
        }
        func deleteAPIKey(forModelID id: UUID) throws {
            lock.withLock {
                deletedIDs.append(id)
                values.removeValue(forKey: id)
            }
        }

        var reads: [UUID] { lock.withLock { readIDs } }
        var writes: [UUID] { lock.withLock { writtenIDs } }
        var deletes: [UUID] { lock.withLock { deletedIDs } }
        func stored(_ id: UUID) -> String? { lock.withLock { values[id] } }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ModelKeyStorageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func model(id: UUID, key: String = "") -> LLMModelConfiguration {
        LLMModelConfiguration(
            id: id, name: "Model", baseURL: "https://example.invalid/v1", apiKey: key, model: "fixture",
            systemPrompt: "prompt", thinking: .automatic, timeoutSeconds: 0)
    }

    func testKeysRoundTripThroughAppSettings() throws {
        let id = UUID()
        let store = SettingsStore(defaults: defaults, modelKeyStorage: SpyStorage())
        store.llmModels = [model(id: id, key: "SENTINEL_KEY")]

        let data = try XCTUnwrap(defaults.data(forKey: "llmModels"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("SENTINEL_KEY"),
            "密钥应当随模型配置写进本机设置")

        let reloaded = SettingsStore(defaults: defaults, modelKeyStorage: SpyStorage())
        XCTAssertEqual(reloaded.llmModels.first?.apiKey, "SENTINEL_KEY")
    }

    func testNormalEditsAndRemovalNeverTouchKeychain() {
        let id = UUID()
        let spy = SpyStorage(seed: [id: "OLD_KEY"])
        let store = SettingsStore(defaults: defaults, modelKeyStorage: spy)

        store.llmModels = [model(id: id, key: "NEW_KEY")]
        var edited = store.llmModels[0]
        edited.name = "Renamed"
        edited.apiKey = ""
        store.llmModels = [edited]
        store.removeLLMModel(id: id)

        XCTAssertEqual(spy.reads, [])
        XCTAssertEqual(spy.writes, [])
        XCTAssertEqual(spy.deletes, [])
        XCTAssertEqual(spy.stored(id), "OLD_KEY", "旧钥匙串条目不动，也不再被读取")
    }

    func testLegacyImportReadsOnlyWhenAsked() {
        let id = UUID()
        let spy = SpyStorage(seed: [id: "OLD_KEY"])
        let store = SettingsStore(defaults: defaults, modelKeyStorage: spy)
        store.llmModels = [model(id: id)]

        XCTAssertEqual(spy.reads, [], "启动和普通编辑都不该读钥匙串")
        XCTAssertEqual(store.legacyAPIKeyFromKeychain(for: id), "OLD_KEY")
        XCTAssertEqual(spy.reads, [id])

        // 界面把导入值写回设置后，下次启动直接从设置读取。
        var imported = store.llmModels[0]
        imported.apiKey = "OLD_KEY"
        store.llmModels = [imported]
        XCTAssertEqual(spy.writes, [], "导入后不再回写钥匙串")
        let reloaded = SettingsStore(defaults: defaults, modelKeyStorage: spy)
        XCTAssertEqual(reloaded.llmModels.first?.apiKey, "OLD_KEY")
    }
}
