import AppKit
import Foundation

extension AppModel {
    // periphery:ignore
    func saveProviders() {
        do { try providerVault.save(.init(activeProviderID: activeProviderID, providers: providers)); persistSettings() } catch { showError(
            "Save providers failed",
            error.localizedDescription
        ) }
    }

    // periphery:ignore
    func setProviderKey(providerID: String, key: String) {
        do { try providerVault.setAPIKey(key, providerID: providerID) } catch { showError("Save API key failed", error.localizedDescription) }
    }

    // periphery:ignore
    func testActiveProvider() {
        guard let activeProvider else {
            showError("No provider", "Select or add a provider first.")
            return
        }
        guard let apiKey = providerVault.apiKey(providerID: activeProvider.id), !apiKey.isEmpty else {
            toastWarning("Provider key missing", LF("Save an API key for %@ before testing the connection.", activeProvider.name))
            return
        }
        do {
            let model = try resolvedModelForActiveProvider()
            toastInfo("Testing provider", LF("Calling %@ with %@…", activeProvider.name, model))
            Task { @MainActor in
                do {
                    let result = try await ProviderConnectionProbe.probe(provider: activeProvider, apiKey: apiKey, model: model)
                    toastSuccess("Provider connected", LF("%@ responded in %dms (HTTP %d).", activeProvider.name, result.latencyMilliseconds, result.statusCode))
                } catch let appError as AppError {
                    showError(appError.title, appError.message)
                } catch {
                    showError("Provider check failed", error.localizedDescription)
                }
            }
        } catch let appError as AppError {
            showError(appError.title, appError.message)
        } catch {
            showError("Provider check failed", error.localizedDescription)
        }
    }

    // periphery:ignore
    func addProvider() {
        let provider = ProviderRecord(
            id: UUID().uuidString,
            name: "Custom Provider",
            baseURL: "https://api.anthropic.com",
            apiFormat: .anthropic,
            modelMappings: [:],
            extraEnv: [:]
        )
        providers.append(provider); activeProviderID = provider.id; saveProviders()
    }

    // periphery:ignore
    func addProvider(from preset: ProviderPreset) {
        let existingCount = providers.filter { $0.preset == preset.id }.count
        let suffix = existingCount > 0 ? " (\(existingCount + 1))" : ""
        let provider = ProviderRecord(
            id: UUID().uuidString,
            name: preset.name + suffix,
            baseURL: preset.baseURL,
            apiFormat: preset.apiFormat,
            modelMappings: preset.modelMappings,
            extraEnv: preset.extraEnv,
            preset: preset.id
        )
        providers.append(provider)
        activeProviderID = provider.id
        saveProviders()
        if let keyURL = preset.keyURL, let url = URL(string: keyURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // periphery:ignore
    func deleteActiveProvider() {
        guard let activeProviderID else {
            return
        }
        providers.removeAll { $0.id == activeProviderID }
        self.activeProviderID = providers.first?.id
        saveProviders()
    }

    // periphery:ignore
    func exportProviders() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "liquidcode-providers.json"
        if
            panel.runModal() == .OK,
            let url = panel.url {
            try? JSONEncoder.liquid.encode(ProviderVault.ProviderFile(activeProviderID: activeProviderID, providers: providers)).write(to: url)
        }
    }

    // periphery:ignore
    func importProviders() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url, let imported = JSONFile.load(ProviderVault.ProviderFile.self, from: url) {
            providers = imported.providers; activeProviderID = imported.activeProviderID; saveProviders(); toastSuccess("Imported providers", LF("%d providers", providers.count))
        }
    }

    // periphery:ignore
    func refreshOnboardingPlan() {
        onboardingPlan = onboardingService.plan()
    }

    // periphery:ignore
    func executeLegacyProviderMigration() {
        do {
            let result = try onboardingService.executeLegacyProviderMigration()
            providers = result.providerFile.providers
            activeProviderID = result.providerFile.activeProviderID ?? settings.selectedProviderID
            persistSettings()
            refreshOnboardingPlan()
            toastSuccess("Migrated providers", LF("Imported %d providers. Rollback is available.", result.importedProviderIDs.count))
        } catch {
            showError("Provider migration failed", error.localizedDescription)
            refreshOnboardingPlan()
        }
    }

    // periphery:ignore
    func skipLegacyProviderMigration() {
        do {
            try onboardingService.skipLegacyProviderMigration()
            refreshOnboardingPlan()
            toastWarning("Skipped provider migration", "LiquidCode will not ask again for this profile.")
        } catch {
            showError("Skip migration failed", error.localizedDescription)
        }
    }

    // periphery:ignore
    func rollbackLegacyProviderMigration() {
        do {
            try onboardingService.rollbackLegacyProviderMigration()
            let providerFile = providerVault.load()
            providers = providerFile.providers
            activeProviderID = providerFile.activeProviderID ?? settings.selectedProviderID
            refreshOnboardingPlan()
            toastSuccess("Rolled back provider migration", "Previous LiquidCode provider configuration was restored.")
        } catch {
            showError("Rollback migration failed", error.localizedDescription)
            refreshOnboardingPlan()
        }
    }

    func refreshCLIStatus() {
        cliStatus = cliService.status(checkForUpdates: false)
        DispatchQueue.global(qos: .utility).async { [cliService] in
            let updated = cliService.status(checkForUpdates: true)
            Task { @MainActor in self.cliStatus = updated }
        }
    }

    func installOrUpdateCLI() {
        setupProgress = SetupProgress(phase: .checking, percent: 0.05, message: L("Checking Claude CLI release sources"))
        DispatchQueue.global(qos: .userInitiated).async { [cliService] in
            let result = cliService.installOrUpdate(progress: { event in
                Task { @MainActor in
                    self.setupProgress = SetupProgress(phase: self.setupPhase(from: event.phase), percent: event.percent, message: event.message)
                }
            })
            Task { @MainActor in
                self.setupProgress = SetupProgress(phase: result.ok ? .complete : .failed, percent: 1, message: result.message)
                self.refreshCLIStatus()
            }
        }
    }

    func repairCLI() {
        let report = cliService.repairCLI()
        refreshCLIStatus()
        let removed = report.removed.isEmpty ? L("No files removed") : LF("Removed %d app-local broken item(s)", report.removed.count)
        let notes = report.notes.prefix(3).joined(separator: "\n")
        toastInfo("CLI repair complete", [removed, notes].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private func setupPhase(from phase: CLIProgressEvent.Phase) -> SetupProgress.Phase {
        switch phase {
        case .checking: return .checking
        case .downloading: return .downloading
        case .installing,
             .npmFallback,
             .repairing: return .installing
        case .complete: return .complete
        case .failed: return .failed
        }
    }

    func openClaudeLogin() {
        cliService.openTerminalLogin(); setupProgress = SetupProgress(phase: .authenticating, percent: 0.5, message: L("Claude login opened in Terminal"))
    }

    func openClaudeConfig() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path
        do { try fileSystem.open(path, sessionID: nil) } catch { showError("Open Claude config failed", error.localizedDescription) }
    }

    func revealLogs() {
        do { try fileSystem.reveal(AppPaths.shared.logs.path, sessionID: nil) } catch { showError("Reveal logs failed", error.localizedDescription) }
    }

    func showChangelog() {
        changelogOpen = true
    }

    func checkForAppUpdates(openDownload: Bool = false) {
        guard !appUpdateChecking else {
            return
        }
        guard let feed = UpdateService.resolvedManifestURL(settingsURL: settings.updateManifestURL) else {
            appUpdateStatus = .unknown(reason: "No update feed configured")
            toastWarning("Updates", "Set an update feed URL in Settings → General, or ship LiquidCodeUpdateManifestURL in Info.plist.")
            return
        }
        appUpdateChecking = true
        let localVersion = UpdateService.currentAppVersion()
        let localBuild = UpdateService.currentAppBuild()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try UpdateService.fetchData(from: feed)
                let manifest = try UpdateService.parseManifest(data)
                let availability = UpdateService.availability(
                    manifest: manifest,
                    localVersion: localVersion,
                    localBuild: localBuild
                )
                Task { @MainActor in
                    self.appUpdateStatus = availability
                    self.appUpdateChecking = false
                    switch availability {
                    case .upToDate(let current):
                        self.toastSuccess("Up to date", LF("LiquidCode %@ is current.", current))
                    case .available(_, let latest, _):
                        self.toastInfo("Update available", LF("LiquidCode %@ is ready.", latest))
                        if openDownload {
                            self.downloadAndVerifyUpdate(manifest: manifest, manifestURL: feed)
                        }
                    case .unknown(let reason):
                        self.toastWarning("Updates", reason)
                    }
                }
            } catch {
                Task { @MainActor in
                    self.appUpdateChecking = false
                    self.appUpdateStatus = .unknown(reason: error.localizedDescription)
                    self.toastWarning("Update check failed", error.localizedDescription)
                }
            }
        }
    }

    /// Downloads the updater tarball, verifies checksum + signature, then reveals it in Finder.
    func downloadAndVerifyUpdate(manifest: UpdateManifest, manifestURL: URL) {
        guard let artifactURL = UpdateService.artifactURL(named: manifest.platform.updater, manifestURL: manifestURL) else {
            toastWarning("Update download failed", "Could not resolve updater URL")
            return
        }
        toastInfo("Downloading update", artifactURL.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try UpdateService.fetchData(from: artifactURL, timeout: 120)
                let verification = UpdateService.verify(
                    payload: payload,
                    checksum: manifest.platform.checksum,
                    signature: manifest.platform.signature
                )
                switch verification {
                case .rejected(let reason):
                    Task { @MainActor in
                        self.toastWarning("Update rejected", reason)
                    }
                case .verified(let kind):
                    let dir = AppPaths.shared.appSupport.appendingPathComponent("Updates", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(manifest.platform.updater)
                    try payload.write(to: dest, options: [.atomic])
                    Task { @MainActor in
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                        self.toastSuccess(
                            "Update verified",
                            LF("%@ ready · %@ — quit LiquidCode and replace the app to install.", dest.lastPathComponent, kind.rawValue)
                        )
                    }
                }
            } catch {
                Task { @MainActor in
                    self.toastWarning("Update download failed", error.localizedDescription)
                }
            }
        }
    }

    private func showToast(_ kind: ToastMessage.Kind, _ title: String, _ message: String) {
        let next = ToastMessage(kind: kind, title: L(title), message: L(message))
        toast = next
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if toast?.id == next.id {
                toast = nil
            }
        }
    }

    func toastInfo(_ title: String, _ message: String) {
        showToast(.info, title, message)
    }

    func toastSuccess(_ title: String, _ message: String) {
        showToast(.success, title, message)
    }

    func toastWarning(_ title: String, _ message: String) {
        showToast(.warning, title, message)
    }
}
