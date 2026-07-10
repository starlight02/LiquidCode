import AppKit
import Foundation

extension AppModel {
    private func modelTier(for model: String) -> String? {
        let model = normalizedModelDisplayKey(model)
        let map = [
            "fable": "fable",
            "opus": "opus",
            "sonnet": "sonnet",
            "haiku": "haiku",
            "claude-fable-5": "fable",
            "claude-fable-5-1m": "fable",
            "claude-fable-5[1m]": "fable",
            "claude-opus-4-8": "opus",
            "claude-opus-4-8-1m": "opus",
            "claude-opus-4-8[1m]": "opus",
            "claude-opus-4-6": "opus",
            "claude-opus-4-6-1m": "opus",
            "claude-opus-4-6[1m]": "opus",
            "claude-sonnet-4-6": "sonnet",
            "claude-haiku-4-5": "haiku",
            "claude-haiku-4-5-20251001": "haiku"
        ]
        return map[model]
    }

    private func cliModelName(_ model: String) -> String {
        [
            "claude-fable-5-1m": "claude-fable-5[1m]",
            "claude-opus-4-8-1m": "claude-opus-4-8[1m]",
            "claude-opus-4-6-1m": "claude-opus-4-6[1m]"
        ][model] ?? model
    }

    func resolvedModelForActiveProvider() throws -> String {
        let selected = settings.selectedModel
        return cliModelName(selected)
    }

    func modelDisplayName(_ model: String) -> String {
        let key = normalizedModelDisplayKey(model)
        if let display = modelDisplayNames[key], !display.isEmpty {
            return display
        }
        if let tier = modelTier(for: model), let display = modelDisplayNames[tier], !display.isEmpty {
            return display
        }
        return shortModelName(model)
    }

    func modelMenuDisplayName(_ model: String) -> String {
        if let tier = modelTier(for: model) {
            return "\(modelTierLabel(tier)) · \(modelDisplayName(model))"
        }
        return modelDisplayName(model)
    }

    func modelToolbarDisplayName(_ model: String, compact: Bool = false) -> String {
        guard compact, let tier = modelTier(for: model) else {
            return modelMenuDisplayName(model)
        }
        return modelTierLabel(tier)
    }

    func isComposerModelSelected(_ option: String) -> Bool {
        if normalizedModelDisplayKey(settings.selectedModel) == normalizedModelDisplayKey(option) {
            return true
        }
        return modelTier(for: settings.selectedModel) == modelTier(for: option)
    }

    private func modelTierLabel(_ tier: String) -> String {
        switch tier {
        case "fable": "Fable"
        case "opus": "Opus"
        case "sonnet": "Sonnet"
        case "haiku": "Haiku"
        default: tier.capitalized
        }
    }

    private func normalizedModelDisplayKey(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func bootstrap() {
        settings = JSONFile.load(AppSettings.self, from: AppPaths.shared.settingsFile) ?? AppSettings()
        restorePersistedComposerDrafts()
        sendConfigurationBySession = settings.sessionConfigurations
        settings.sidebarWidth = min(450, max(Double(LiquidGlassToken.sidebarWidth), settings.sidebarWidth))
        settings.secondaryWidth = min(Double(LiquidGlassToken.inspectorMaxWidth), max(Double(LiquidGlassToken.inspectorMinWidth), settings.secondaryWidth))
        // Restore per-session composer configs first, then overlay Claude defaults for the
        // start screen only. Persist once at the end so a mid-bootstrap write cannot drop
        // sessionConfigurations while other maps are still being rebuilt.
        let preservedSessionConfigurations = sendConfigurationBySession
        syncComposerDefaultsFromClaudeUserSettings(persist: false)
        sendConfigurationBySession = preservedSessionConfigurations
        settings.sessionConfigurations = preservedSessionConfigurations
        persistSettings()
        recentProjects = JSONFile.load([RecentProject].self, from: AppPaths.shared.recentProjectsFile) ?? []
        // Filter out temp/system directories from recent projects
        let tempRoot = NSTemporaryDirectory()
        recentProjects = recentProjects.filter { project in
            let projectPath = project.path
            return !projectPath.hasPrefix(tempRoot) && !projectPath.hasPrefix("/var/folders/") && !projectPath.hasPrefix("/tmp/")
        }
        autoSelectClaudeRecentProjectIfNeeded()
        providers = []
        activeProviderID = nil
        settings.selectedProviderID = nil
        onboardingPlan = .ready
        loadSessionGroups()
        refreshCLIStatus()
        reloadSessions()
        reloadMCPAndSkills()
    }

    func persistSettings() {
        settings.selectedProviderID = activeProviderID
        settings.sessionConfigurations = sendConfigurationBySession
        try? JSONFile.save(settings, to: AppPaths.shared.settingsFile)
    }

    func openSettings(tab: SettingsTab = .general) {
        settingsTab = tab
        // Opening settings always wins over other overlays so the control never looks dead.
        commandPaletteOpen = false
        changelogOpen = false
        imageLightbox = nil
        // Open immediately so the control feels responsive. Backdrop dismiss is gated in
        // SettingsPanelView until after the opening click ends.
        settingsOpen = true
    }

    func closeSettings() {
        settingsOpen = false
    }

    func setComposerMode(_ mode: SessionMode) {
        settings.sessionMode = mode
        applyComposerConfigurationChange(model: nil, mode: mode, thinkingLevel: nil)
    }

    func setComposerThinkingLevel(_ level: ThinkingLevel) {
        settings.thinkingLevel = level
        applyComposerConfigurationChange(model: nil, mode: nil, thinkingLevel: level)
    }

    func setComposerModel(_ model: String) {
        settings.selectedModel = model
        applyComposerConfigurationChange(model: model, mode: nil, thinkingLevel: nil)
    }

    func snapshotComposerConfiguration(for sessionID: String?) {
        let configuration = ComposerSendConfiguration(
            model: settings.selectedModel,
            mode: settings.sessionMode,
            thinkingLevel: settings.thinkingLevel
        )
        if let sessionID {
            guard sendConfigurationBySession[sessionID] != configuration else {
                return
            }
            sendConfigurationBySession[sessionID] = configuration
            return
        }
        guard defaultComposerConfiguration != configuration else {
            return
        }
        defaultComposerConfiguration = configuration
    }

    func syncComposerDefaultsFromClaudeUserSettings(persist: Bool = true) {
        let defaults = claudeUserSettings.loadComposerDefaults()
        modelDisplayNames = defaults.modelDisplayNames
        if let model = defaults.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.selectedModel = model
        }
        if let mode = defaults.mode {
            settings.sessionMode = mode
        }
        if let thinkingLevel = defaults.thinkingLevel {
            settings.thinkingLevel = thinkingLevel
        }
        defaultComposerConfiguration = ComposerSendConfiguration(
            model: settings.selectedModel,
            mode: settings.sessionMode,
            thinkingLevel: settings.thinkingLevel
        )
        // Always keep the in-memory session map authoritative before any write.
        settings.sessionConfigurations = sendConfigurationBySession
        if persist {
            persistSettings()
        }
    }

    private func applyComposerConfigurationChange(model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) {
        if selectedSessionID == nil {
            defaultComposerConfiguration = ComposerSendConfiguration(
                model: settings.selectedModel,
                mode: settings.sessionMode,
                thinkingLevel: settings.thinkingLevel
            )
            do {
                try claudeUserSettings.saveComposerDefaults(
                    model: settings.selectedModel,
                    mode: settings.sessionMode,
                    thinkingLevel: settings.thinkingLevel
                )
                persistSettings()
            } catch {
                showError("Claude settings update failed", error.localizedDescription)
            }
            return
        }
        if let selectedSessionID {
            sendConfigurationBySession[selectedSessionID] = ComposerSendConfiguration(
                model: settings.selectedModel,
                mode: settings.sessionMode,
                thinkingLevel: settings.thinkingLevel
            )
        }
        persistSettings()
        guard let selectedSessionID else {
            return
        }
        guard engine.isSessionRunning(sessionID: selectedSessionID) else {
            return
        }
        do {
            try engine.updateRuntimeConfiguration(sessionID: selectedSessionID, model: model, mode: mode, thinkingLevel: thinkingLevel)
        } catch {
            showError("Claude runtime update failed", error.localizedDescription)
        }
    }

    func restoreComposerConfiguration(for sessionID: String?) {
        let configuration = sessionID.flatMap { sendConfigurationBySession[$0] } ?? defaultComposerConfiguration
        let current = ComposerSendConfiguration(
            model: settings.selectedModel,
            mode: settings.sessionMode,
            thinkingLevel: settings.thinkingLevel
        )
        guard current != configuration else {
            return
        }
        var next = settings
        next.selectedModel = configuration.model
        next.sessionMode = configuration.mode
        next.thinkingLevel = configuration.thinkingLevel
        settings = next
    }

    /// Aligns the composer model picker with the latest model actually used in a session's
    /// transcript (from assistant `message.model` fields written by Claude Code). Prefer this
    /// over a stale GUI-local snapshot when the user switched models from the CLI.
    func syncComposerModelFromMessages(_ messages: [ChatMessage], sessionID: String) {
        guard
            let latest = messages.last(where: {
                guard let model = $0.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
                    return false
                }
                return model != "<synthetic>" && ($0.role == .assistant || $0.role == .thinking || $0.role == .error)
            })?.model?
                .trimmingCharacters(in: .whitespacesAndNewlines), !latest.isEmpty else {
            return
        }
        applyComposerModel(latest, to: sessionID)
    }

    private func applyComposerModel(_ model: String, to sessionID: String) {
        let existing = sendConfigurationBySession[sessionID]
        let nextConfig = ComposerSendConfiguration(
            model: model,
            mode: existing?.mode ?? settings.sessionMode,
            thinkingLevel: existing?.thinkingLevel ?? settings.thinkingLevel
        )
        if sendConfigurationBySession[sessionID] != nextConfig {
            sendConfigurationBySession[sessionID] = nextConfig
            persistSettings()
        }
        guard selectedSessionID == sessionID else {
            return
        }
        guard normalizedModelDisplayKey(settings.selectedModel) != normalizedModelDisplayKey(model) else {
            return
        }
        settings.selectedModel = model
    }
}
