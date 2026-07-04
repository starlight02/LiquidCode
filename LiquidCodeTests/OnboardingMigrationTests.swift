import Foundation
@testable import LiquidCode
import XCTest

final class OnboardingMigrationTests: XCTestCase {
    func testFirstLaunchPlanPromptsWithoutExistingConfig() throws {
        let fixture = try OnboardingFixture()
        let plan = fixture.service.plan()
        XCTAssertEqual(plan.state, .firstLaunchNoConfig)
        XCTAssertTrue(plan.isFirstLaunch)
        XCTAssertTrue(plan.shouldPrompt)
        XCTAssertFalse(plan.canMigrate)
    }

    func testTokenicodeMigrationExecuteAndRollbackRestoresPreviousLiquidCodeFiles() throws {
        let fixture = try OnboardingFixture()
        try fixture.writeTokenicodeProviders()
        let originalProviders = Data(#"{"activeProviderID":null,"providers":[]}"#.utf8)
        let originalSettings = Data(#"{"selectedProviderID":"before"}"#.utf8)
        try fixture.write(originalProviders, to: fixture.liquidProvidersURL)
        try fixture.write(originalSettings, to: fixture.liquidSettingsURL)

        let plan = fixture.service.plan()
        XCTAssertEqual(plan.state, .tokenicodeMigrationAvailable)
        XCTAssertTrue(plan.shouldPrompt)
        XCTAssertTrue(plan.canMigrate)
        XCTAssertEqual(plan.tokenicodeProviderCount, 1)

        let result = try fixture.service.executeTokenicodeMigration()
        XCTAssertEqual(result.importedProviderIDs, ["kimi-code"])
        XCTAssertEqual(fixture.capturedKeys, ["kimi-code": "secret-token"])

        let migrated = try XCTUnwrap(JSONFile.load(ProviderVault.ProviderFile.self, from: fixture.liquidProvidersURL))
        XCTAssertEqual(migrated.activeProviderID, "kimi-code")
        XCTAssertEqual(migrated.providers.map(\.id), ["kimi-code"])
        XCTAssertEqual(migrated.providers.first?.modelMappings["sonnet"], "kimi-for-coding")

        let migratedPlan = fixture.service.plan()
        XCTAssertEqual(migratedPlan.state, .migratedTokenicodeProviders)
        XCTAssertTrue(migratedPlan.canRollback)

        try fixture.service.rollbackTokenicodeMigration()
        XCTAssertEqual(try Data(contentsOf: fixture.liquidProvidersURL), originalProviders)
        XCTAssertEqual(try Data(contentsOf: fixture.liquidSettingsURL), originalSettings)
        XCTAssertNil(fixture.capturedKeys["kimi-code"])
        XCTAssertEqual(fixture.service.plan().state, .tokenicodeMigrationAvailable)
    }

    func testSkipSuppressesRepeatedPromptAndBlocksExecute() throws {
        let fixture = try OnboardingFixture()
        try fixture.writeTokenicodeProviders()
        XCTAssertEqual(fixture.service.plan().state, .tokenicodeMigrationAvailable)

        try fixture.service.skipTokenicodeMigration()
        let skipped = fixture.service.plan()
        XCTAssertEqual(skipped.state, .skippedTokenicodeMigration)
        XCTAssertFalse(skipped.shouldPrompt)
        XCTAssertFalse(skipped.canMigrate)

        XCTAssertThrowsError(try fixture.service.executeTokenicodeMigration()) { error in
            XCTAssertEqual(error as? OnboardingMigrationError, .skippedTokenicodeMigration)
        }
    }

    func testExistingLiquidCodeProvidersBlockTokenicodeMigrationWithoutOverwrite() throws {
        let fixture = try OnboardingFixture()
        try fixture.writeTokenicodeProviders()
        let existing = ProviderVault.ProviderFile(
            activeProviderID: "existing",
            providers: [ProviderRecord(
                id: "existing",
                name: "Existing",
                baseURL: "https://existing.example",
                apiFormat: .anthropic,
                modelMappings: [:],
                extraEnv: [:],
                preset: nil
            )]
        )
        try JSONFile.save(existing, to: fixture.liquidProvidersURL)

        let plan = fixture.service.plan()
        XCTAssertEqual(plan.state, .blockedExistingLiquidCodeProviders)
        XCTAssertFalse(plan.shouldPrompt)
        XCTAssertFalse(plan.canMigrate)

        XCTAssertThrowsError(try fixture.service.executeTokenicodeMigration()) { error in
            XCTAssertEqual(error as? OnboardingMigrationError, .existingLiquidCodeProviders)
        }
        let preserved = try XCTUnwrap(JSONFile.load(ProviderVault.ProviderFile.self, from: fixture.liquidProvidersURL))
        XCTAssertEqual(preserved.providers.map(\.id), ["existing"])
    }
}

private final class OnboardingFixture {
    let root: URL
    let liquidProvidersURL: URL
    let liquidSettingsURL: URL
    let stateURL: URL
    let tokenicodeProvidersURL: URL
    var capturedKeys: [String: String] = [:]
    lazy var service: OnboardingService = OnboardingService(
        liquidProvidersURL: liquidProvidersURL,
        liquidSettingsURL: liquidSettingsURL,
        stateURL: stateURL,
        tokenicodeProvidersURL: tokenicodeProvidersURL,
        providerKeyWriter: { [weak self] providerID, key in self?.capturedKeys[providerID] = key },
        providerKeyDeleter: { [weak self] providerID in self?.capturedKeys.removeValue(forKey: providerID) }
    )

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("liquidcode-onboarding-\(UUID().uuidString)", isDirectory: true)
        liquidProvidersURL = root.appendingPathComponent("LiquidCode/providers.json")
        liquidSettingsURL = root.appendingPathComponent("LiquidCode/settings.json")
        stateURL = root.appendingPathComponent("LiquidCode/onboarding.json")
        tokenicodeProvidersURL = root.appendingPathComponent(".tokenicode/providers.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func writeTokenicodeProviders() throws {
        let json = #"""
            {
            "activeProviderId": "kimi-code",
            "providers": [
            {
            "id": "kimi-code",
            "name": "Kimi Code",
            "baseUrl": "https://api.kimi.com/coding/",
            "apiFormat": "anthropic",
            "apiKey": "secret-token",
            "modelMappings": [
            { "tier": "sonnet", "providerModel": "kimi-for-coding" }
            ],
            "extra_env": { "ENABLE_TOOL_SEARCH": "false" },
            "preset": "kimi-code",
            "proxyUrl": "socks5://127.0.0.1:1080"
            }
            ]
            }
        """#
        try write(Data(json.utf8), to: tokenicodeProvidersURL)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
