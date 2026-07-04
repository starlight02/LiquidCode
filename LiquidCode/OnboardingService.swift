import Foundation

struct OnboardingPlan: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case firstLaunchNoConfig
        case tokenicodeMigrationAvailable
        case skippedTokenicodeMigration
        case migratedTokenicodeProviders
        case blockedExistingLiquidCodeProviders
        case ready
    }

    var state: State
    var isFirstLaunch: Bool
    var shouldPrompt: Bool
    var canMigrate: Bool
    var canRollback: Bool
    var tokenicodeProviderCount: Int
    var activeProviderID: String?
    var message: String

    static let ready = OnboardingPlan(
        state: .ready,
        isFirstLaunch: false,
        shouldPrompt: false,
        canMigrate: false,
        canRollback: false,
        tokenicodeProviderCount: 0,
        activeProviderID: nil,
        message: "LiquidCode configuration is ready."
    )
}

struct OnboardingMigrationResult: Codable, Sendable {
    var providerFile: ProviderVault.ProviderFile
    var importedProviderIDs: [String]
}

enum OnboardingMigrationError: LocalizedError, Equatable {
    case noTokenicodeProviders
    case skippedTokenicodeMigration
    case existingLiquidCodeProviders
    case rollbackUnavailable
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .noTokenicodeProviders:
            return "No TOKENICODE providers.json was found to migrate."
        case .skippedTokenicodeMigration:
            return "TOKENICODE provider migration was skipped for this LiquidCode profile."
        case .existingLiquidCodeProviders:
            return "LiquidCode providers already exist; migration will not overwrite them without an explicit reset."
        case .rollbackUnavailable:
            return "No TOKENICODE migration rollback is available."
        case .invalidBackup:
            return "The TOKENICODE migration rollback backup is invalid."
        }
    }
}

final class OnboardingService {
    private struct StateFile: Codable {
        var skippedTokenicodeMigrationAt: Date?
        var lastMigrationAt: Date?
        var backup: MigrationBackup?
    }

    private struct MigrationBackup: Codable {
        var createdAt: Date
        var providersFileExisted: Bool
        var providersFileBase64: String?
        var settingsFileExisted: Bool
        var settingsFileBase64: String?
        var importedProviderIDs: [String]
    }

    private struct TokenicodeProviderPayload {
        var providerFile: ProviderVault.ProviderFile
        var apiKeysByProviderID: [String: String]
    }

    private let liquidProvidersURL: URL
    private let liquidSettingsURL: URL
    private let stateURL: URL
    private let tokenicodeProvidersURL: URL
    private let providerKeyWriter: ((String, String) throws -> Void)?
    private let providerKeyDeleter: ((String) throws -> Void)?
    private let fileManager: FileManager

    convenience init() {
        self.init(
            liquidProvidersURL: AppPaths.shared.providersFile,
            liquidSettingsURL: AppPaths.shared.settingsFile,
            stateURL: AppPaths.shared.appSupport.appendingPathComponent("onboarding.json"),
            tokenicodeProvidersURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tokenicode/providers.json"),
            providerKeyWriter: { providerID, key in try ProviderVault().setAPIKey(key, providerID: providerID) },
            providerKeyDeleter: { providerID in ProviderVault().deleteAPIKey(providerID: providerID) }
        )
    }

    init(
        liquidProvidersURL: URL,
        liquidSettingsURL: URL,
        stateURL: URL,
        tokenicodeProvidersURL: URL,
        providerKeyWriter: ((String, String) throws -> Void)? = nil,
        providerKeyDeleter: ((String) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) {
        self.liquidProvidersURL = liquidProvidersURL
        self.liquidSettingsURL = liquidSettingsURL
        self.stateURL = stateURL
        self.tokenicodeProvidersURL = tokenicodeProvidersURL
        self.providerKeyWriter = providerKeyWriter
        self.providerKeyDeleter = providerKeyDeleter
        self.fileManager = fileManager
    }

    func plan() -> OnboardingPlan {
        let state = loadState()
        let tokenicode = loadTokenicodeProviderPayload()
        let tokenicodeProviderCount = tokenicode?.providerFile.providers.count ?? 0
        let liquidProvidersExist = fileManager.fileExists(atPath: liquidProvidersURL.path)
        let liquidSettingsExist = fileManager.fileExists(atPath: liquidSettingsURL.path)
        let hasLiquidProviders = hasExistingLiquidCodeProviders()
        let isFirstLaunch = !liquidProvidersExist && !liquidSettingsExist
        let canRollback = state.backup != nil

        if canRollback, state.lastMigrationAt != nil, hasLiquidProviders {
            return OnboardingPlan(
                state: .migratedTokenicodeProviders,
                isFirstLaunch: false,
                shouldPrompt: false,
                canMigrate: false,
                canRollback: true,
                tokenicodeProviderCount: tokenicodeProviderCount,
                activeProviderID: currentProviderFile()?.activeProviderID,
                message: "TOKENICODE providers were migrated. Rollback is available."
            )
        }

        if state.skippedTokenicodeMigrationAt != nil, tokenicodeProviderCount > 0 {
            return OnboardingPlan(
                state: .skippedTokenicodeMigration,
                isFirstLaunch: isFirstLaunch,
                shouldPrompt: false,
                canMigrate: false,
                canRollback: canRollback,
                tokenicodeProviderCount: tokenicodeProviderCount,
                activeProviderID: tokenicode?.providerFile.activeProviderID,
                message: "TOKENICODE provider migration was skipped and will not be shown again."
            )
        }

        if tokenicodeProviderCount > 0 {
            if hasLiquidProviders {
                return OnboardingPlan(
                    state: .blockedExistingLiquidCodeProviders,
                    isFirstLaunch: isFirstLaunch,
                    shouldPrompt: false,
                    canMigrate: false,
                    canRollback: canRollback,
                    tokenicodeProviderCount: tokenicodeProviderCount,
                    activeProviderID: currentProviderFile()?.activeProviderID,
                    message: "TOKENICODE providers were found, but LiquidCode already has providers. Migration will not overwrite them."
                )
            }

            return OnboardingPlan(
                state: .tokenicodeMigrationAvailable,
                isFirstLaunch: isFirstLaunch,
                shouldPrompt: true,
                canMigrate: true,
                canRollback: canRollback,
                tokenicodeProviderCount: tokenicodeProviderCount,
                activeProviderID: tokenicode?.providerFile.activeProviderID,
                message: "Found TOKENICODE provider configuration ready to migrate."
            )
        }

        if isFirstLaunch {
            return OnboardingPlan(
                state: .firstLaunchNoConfig,
                isFirstLaunch: true,
                shouldPrompt: true,
                canMigrate: false,
                canRollback: canRollback,
                tokenicodeProviderCount: 0,
                activeProviderID: nil,
                message: "No LiquidCode configuration exists yet."
            )
        }

        var ready = OnboardingPlan.ready
        ready.canRollback = canRollback
        return ready
    }

    func executeTokenicodeMigration() throws -> OnboardingMigrationResult {
        var state = loadState()
        if state.skippedTokenicodeMigrationAt != nil {
            throw OnboardingMigrationError.skippedTokenicodeMigration
        }
        if hasExistingLiquidCodeProviders() {
            throw OnboardingMigrationError.existingLiquidCodeProviders
        }
        guard let payload = loadTokenicodeProviderPayload(), !payload.providerFile.providers.isEmpty else {
            throw OnboardingMigrationError.noTokenicodeProviders
        }

        try ensureParentDirectory(for: liquidProvidersURL)
        try ensureParentDirectory(for: liquidSettingsURL)
        try ensureParentDirectory(for: stateURL)

        let importedIDs = payload.providerFile.providers.map(\.id)
        state.backup = MigrationBackup(
            createdAt: Date(),
            providersFileExisted: fileManager.fileExists(atPath: liquidProvidersURL.path),
            providersFileBase64: base64ContentsIfPresent(liquidProvidersURL),
            settingsFileExisted: fileManager.fileExists(atPath: liquidSettingsURL.path),
            settingsFileBase64: base64ContentsIfPresent(liquidSettingsURL),
            importedProviderIDs: importedIDs
        )
        state.lastMigrationAt = Date()
        state.skippedTokenicodeMigrationAt = nil

        try JSONFile.save(payload.providerFile, to: liquidProvidersURL)
        for (providerID, key) in payload.apiKeysByProviderID where !key.isEmpty {
            try providerKeyWriter?(providerID, key)
        }
        try saveState(state)

        return OnboardingMigrationResult(providerFile: payload.providerFile, importedProviderIDs: importedIDs)
    }

    func skipTokenicodeMigration() throws {
        var state = loadState()
        state.skippedTokenicodeMigrationAt = Date()
        try saveState(state)
    }

    func rollbackTokenicodeMigration() throws {
        var state = loadState()
        guard let backup = state.backup else {
            throw OnboardingMigrationError.rollbackUnavailable
        }
        try restoreFile(at: liquidProvidersURL, existed: backup.providersFileExisted, base64: backup.providersFileBase64)
        try restoreFile(at: liquidSettingsURL, existed: backup.settingsFileExisted, base64: backup.settingsFileBase64)
        for providerID in backup.importedProviderIDs {
            try providerKeyDeleter?(providerID)
        }
        state.backup = nil
        state.lastMigrationAt = nil
        try saveState(state)
    }

    private func currentProviderFile() -> ProviderVault.ProviderFile? {
        JSONFile.load(ProviderVault.ProviderFile.self, from: liquidProvidersURL)
    }

    private func hasExistingLiquidCodeProviders() -> Bool {
        guard let file = currentProviderFile() else {
            return false
        }
        return !file.providers.isEmpty
    }

    private func loadState() -> StateFile {
        JSONFile.load(StateFile.self, from: stateURL) ?? StateFile(skippedTokenicodeMigrationAt: nil, lastMigrationAt: nil, backup: nil)
    }

    private func saveState(_ state: StateFile) throws {
        try ensureParentDirectory(for: stateURL)
        try JSONFile.save(state, to: stateURL)
    }

    private func loadTokenicodeProviderPayload() -> TokenicodeProviderPayload? {
        guard
            let data = try? Data(contentsOf: tokenicodeProvidersURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawProviders = root["providers"] as? [[String: Any]] ?? []
        var providers: [ProviderRecord] = []
        var apiKeys: [String: String] = [:]

        for raw in rawProviders {
            guard let id = raw["id"] as? String, !id.isEmpty else {
                continue
            }
            let formatRaw = raw["apiFormat"] as? String ?? "anthropic"
            let mappings = (raw["modelMappings"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { output, item in
                guard
                    let tier = item["tier"] as? String,
                    let model = item["providerModel"] as? String,
                    !tier.isEmpty,
                    !model.isEmpty else {
                    return
                }
                output[tier] = model
            }
            let baseURL = (raw["baseUrl"] as? String) ?? (raw["baseURL"] as? String) ?? ""
            let record = ProviderRecord(
                id: id,
                name: raw["name"] as? String ?? id,
                baseURL: baseURL,
                apiFormat: ProviderRecord.APIFormat(rawValue: formatRaw) ?? .anthropic,
                modelMappings: mappings,
                extraEnv: raw["extra_env"] as? [String: String] ?? [:],
                preset: raw["preset"] as? String,
                proxyURL: raw["proxyUrl"] as? String
            )
            if let key = raw["apiKey"] as? String, !key.isEmpty {
                apiKeys[id] = key
            }
            providers.append(record)
        }

        let requestedActive = root["activeProviderId"] as? String
        let active = providers.contains { $0.id == requestedActive } ? requestedActive : providers.first?.id
        return TokenicodeProviderPayload(
            providerFile: ProviderVault.ProviderFile(activeProviderID: active, providers: providers),
            apiKeysByProviderID: apiKeys
        )
    }

    private func base64ContentsIfPresent(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return data.base64EncodedString()
    }

    private func restoreFile(at url: URL, existed: Bool, base64: String?) throws {
        if existed {
            guard let base64, let data = Data(base64Encoded: base64) else {
                throw OnboardingMigrationError.invalidBackup
            }
            try ensureParentDirectory(for: url)
            try data.write(to: url, options: [.atomic])
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureParentDirectory(for url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
