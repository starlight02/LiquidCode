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
        guard !cliStatusRefreshing else {
            return
        }
        cliStatusRefreshing = true
        DispatchQueue.global(qos: .utility).async { [cliService] in
            let updated = cliService.status(checkForUpdates: true)
            Task { @MainActor in
                self.cliStatus = updated
                self.cliStatusRefreshing = false
            }
        }
    }

    func installOrUpdateCLI() {
        guard !cliOperationInProgress else {
            return
        }
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
        guard !cliOperationInProgress else {
            return
        }
        setupProgress = SetupProgress(phase: .installing, percent: 0.15, message: L("Repairing Claude CLI"))
        DispatchQueue.global(qos: .userInitiated).async { [cliService] in
            let report = cliService.repairCLI()
            Task { @MainActor in
                let removed = report.removed.isEmpty ? L("No files removed") : LF("Removed %d app-local broken item(s)", report.removed.count)
                let notes = report.notes.prefix(3).joined(separator: "\n")
                let message = [removed, notes].filter { !$0.isEmpty }.joined(separator: "\n")
                self.setupProgress = SetupProgress(phase: .complete, percent: 1, message: message)
                self.refreshCLIStatus()
                self.toastInfo("CLI repair complete", message)
            }
        }
    }

    var cliOperationInProgress: Bool {
        switch setupProgress.phase {
        case .checking, .downloading, .installing:
            return true
        case .idle, .authenticating, .complete, .failed:
            return false
        }
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
        guard cliStatus.installed else {
            toastWarning("CLI missing", "Install Claude Code CLI before logging in.")
            return
        }
        cliService.openTerminalLogin()
        setupProgress = SetupProgress(phase: .complete, percent: 1, message: L("Claude login opened in Terminal"))
        toastInfo("Claude Code CLI", "Claude login opened in Terminal")
    }

    func openClaudeConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data("{}\n".utf8).write(to: url, options: [.atomic])
            }
            try fileSystem.open(url.path, sessionID: nil)
        } catch {
            showError("Open Claude config failed", error.localizedDescription)
        }
    }

    func revealLogs() {
        do { try fileSystem.reveal(AppPaths.shared.logs.path, sessionID: nil) } catch { showError("Reveal logs failed", error.localizedDescription) }
    }

    func diagnosticsReport() -> String {
        let version = UpdateService.currentAppVersion()
        let build = UpdateService.currentAppBuild()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let cliVersion = cliStatus.version ?? "unknown"
        let cliPath = cliPathOrMissing()
        let auth = cliStatus.authStatus
        let theme = settings.theme.rawValue
        let project = workingDirectory.isEmpty ? "(none)" : workingDirectory
        let session = selectedSessionID ?? "(none)"
        return [
            "LiquidCode \(version) (\(build))",
            "macOS \(os)",
            "CLI \(cliVersion) · \(cliPath)",
            "Auth \(auth)",
            "Theme \(theme)",
            "Project \(project)",
            "Session \(session)",
            "Logs \(AppPaths.shared.logs.path)",
            "App Support \(AppPaths.shared.appSupport.path)"
        ].joined(separator: "\n")
    }

    private func cliPathOrMissing() -> String {
        cliStatus.path ?? "missing"
    }

    func copyDiagnosticsToPasteboard() {
        let report = diagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        toastSuccess("Copied diagnostics", AppPaths.shared.logs.path)
    }

    func setBackgroundNotificationsEnabled(_ enabled: Bool) {
        settings.notificationsEnabled = enabled
        persistSettings()
        if enabled {
            AttentionNotificationService.shared.requestAuthorizationIfNeeded()
        }
    }

    func showChangelog() {
        changelogOpen = true
    }

    func checkForAppUpdates(openRelease: Bool = false) {
        guard !appUpdateChecking else {
            return
        }
        appUpdateChecking = true
        let localVersion = UpdateService.currentAppVersion()
        Task { @MainActor in
            do {
                let release = try await UpdateService.fetchLatestRelease()
                let availability = UpdateService.availability(release: release, localVersion: localVersion)
                self.appUpdateStatus = availability
                self.appUpdateRelease = if case .available = availability { release } else { nil }
                self.appUpdateChecking = false
                switch availability {
                case .upToDate(let current):
                    self.toastSuccess("Up to date", LF("LiquidCode %@ is current.", current))
                case .available(_, let availableRelease):
                    self.toastInfo("Update available", LF("LiquidCode %@ is ready.", availableRelease.version))
                    if openRelease {
                        self.openAppUpdateRelease()
                    }
                case .unknown(let reason):
                    self.toastWarning("Updates", reason)
                }
            } catch {
                self.appUpdateChecking = false
                self.appUpdateRelease = nil
                self.appUpdateStatus = .unknown(reason: error.localizedDescription)
                self.toastWarning("Update check failed", error.localizedDescription)
            }
        }
    }

    func openAppUpdateRelease() {
        guard let release = appUpdateRelease else {
            toastWarning("Updates", "Check for updates before opening a release.")
            return
        }
        guard NSWorkspace.shared.open(release.htmlURL) else {
            toastWarning("Updates", "Could not open the GitHub release page.")
            return
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
