// swiftlint:disable file_length
import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var sessions: [SessionRecord] = []
    @Published var selectedSessionID: String?
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var streamingTextBySession: [String: String] = [:]
    @Published var toolCallsBySession: [String: [ToolCall]] = [:]
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var workingDirectory: String = ""
    @Published var recentProjects: [RecentProject] = []
    @Published var fileTree: [FileNode] = []
    @Published var selectedFilePath: String?
    @Published var filePreview: String = ""
    @Published var changedFiles: Set<String> = []
    @Published var fileChangeBadges: [String: String] = [:]
    @Published var skills: [SkillInfo] = []
    @Published var selectedSkill: SkillInfo?
    @Published var mcpServers: [MCPServer] = []
    @Published var providers: [ProviderRecord] = []
    @Published var activeProviderID: String?
    @Published var modelDisplayNames: [String: String] = [:]
    @Published var secondaryTab: SecondaryTab = .files
    @Published var settingsOpen = false
    @Published var settingsTab: SettingsTab = .general
    @Published var commandPaletteOpen = false
    @Published var agentPanelOpen = false
    @Published var currentError: AppError?
    @Published var composerText = ""
    @Published var composerTextBySession: [String: String] = [:]
    @Published var searchText = ""
    @Published var sessionGroups: [SessionTaskGroup] = []
    @Published var showArchivedSessions = false
    @Published var showRunningSessionsOnly = false
    @Published var sessionSelectionMode = false
    @Published var selectedSessionIDs: Set<String> = []
    @Published var recentlyDeletedSession: DeletedSessionSnapshot?
    @Published var filePreviewMode: FilePreviewMode = .preview
    @Published var fileEditDirty = false
    @Published var attachments: [AttachmentChip] = []
    @Published var attachmentsBySession: [String: [AttachmentChip]] = [:]
    @Published var pendingUserMessagesBySession: [String: [PendingUserMessage]] = [:]
    @Published var activeTurnSnapshots: [String: ActiveTurnSnapshot] = [:]
    @Published var sendConfigurationBySession: [String: ComposerSendConfiguration] = [:]
    @Published var imageLightbox: ImageLightboxContent?
    @Published var toast: ToastMessage?
    @Published var changelogOpen = false
    @Published var cliStatus = CLIStatus()
    @Published var setupProgress = SetupProgress()
    @Published var onboardingPlan = OnboardingPlan.ready
    @Published var chatFindText = ""
    @Published var chatFindIndex = 0
    @Published var currentGreeting = GreetingProvider.random()

    private let engine: ClaudeEngine
    private let providerVault = ProviderVault()
    private let fileSystem = FileSystemService()
    private let claudeUserSettings: ClaudeUserSettingsService
    private let directoryWatcher = DirectoryWatchManager()
    private let mcpService = MCPService()
    private let skillService = SkillService()
    private let sessionIndex = SessionIndexService()
    private var reloadSessionsGeneration = 0
    private let cliService = CLIService()
    private let shareService = ShareService()
    // periphery:ignore
    private let onboardingService = OnboardingService()
    private var filePreviewCleanContent = ""

    init(
        engine: ClaudeEngine = ClaudeEngineFactory.makeDefault(),
        claudeUserSettings: ClaudeUserSettingsService = ClaudeUserSettingsService()
    ) {
        self.engine = engine
        self.claudeUserSettings = claudeUserSettings
    }

    deinit { directoryWatcher.unwatchAll(); engine.killAll() }
}

extension AppModel {

    var selectedSession: SessionRecord? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selectedMessages: [ChatMessage] {
        messagesBySession[selectedSessionID ?? ""] ?? []
    }

    var selectedStreamingText: String {
        streamingTextBySession[selectedSessionID ?? ""] ?? ""
    }

    var selectedToolCalls: [ToolCall] {
        toolCallsBySession[selectedSessionID ?? ""] ?? []
    }

    var activeProvider: ProviderRecord? {
        nil
    }

    var hasActiveTurn: Bool {
        !pendingPermissions.isEmpty || streamingTextBySession.values.contains { !$0.isEmpty } || !activeTurnSnapshots.isEmpty
    }

    var selectedHasActiveTurn: Bool {
        selectedSessionID.map { hasActiveTurn(for: $0) } ?? false
    }

    var selectedPendingUserMessages: [PendingUserMessage] {
        selectedSessionID.flatMap { pendingUserMessagesBySession[$0] } ?? []
    }

    var selectedLastUserMessage: ChatMessage? {
        selectedSessionID.flatMap { lastUserMessage(in: $0) }
    }

    var selectedChatFindTargets: [ChatFindTarget] {
        chatFindTargets(in: selectedMessages, query: chatFindText)
    }

    var selectedChatFindTarget: ChatFindTarget? {
        let targets = selectedChatFindTargets
        guard !targets.isEmpty else {
            return nil
        }
        return targets[min(max(chatFindIndex, 0), targets.count - 1)]
    }

    func hasActiveTurn(for sessionID: String) -> Bool {
        pendingPermissions.contains { $0.sessionID == sessionID } ||
            !(streamingTextBySession[sessionID] ?? "").isEmpty ||
            activeTurnSnapshots[sessionID] != nil
    }

    private func canonicalFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func existingDirectoryPath(_ path: String) -> String? {
        let canonical = PathAccessManager.canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return canonical
    }

    private func forgetRecentProject(_ path: String) {
        let canonical = PathAccessManager.canonicalPath(path)
        recentProjects.removeAll { project in
            project.path == path || PathAccessManager.canonicalPath(project.path) == canonical
        }
        try? JSONFile.save(recentProjects, to: AppPaths.shared.recentProjectsFile)
    }

    private func sameFilePath(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }
        return canonicalFilePath(lhs) == canonicalFilePath(rhs)
    }

    private func snapshotComposerState(for sessionID: String?) {
        guard let sessionID else {
            return
        }
        composerTextBySession[sessionID] = composerText
        attachmentsBySession[sessionID] = attachments
    }

    private func restoreComposerState(for sessionID: String?) {
        guard let sessionID else {
            composerText = ""
            attachments = []
            return
        }
        composerText = composerTextBySession[sessionID] ?? ""
        attachments = attachmentsBySession[sessionID] ?? []
    }

    func updateComposerText(_ text: String) {
        composerText = text
        if let selectedSessionID {
            composerTextBySession[selectedSessionID] = text
        }
    }

    private func setComposerText(_ text: String, for sessionID: String? = nil) {
        let target = sessionID ?? selectedSessionID
        if target == selectedSessionID {
            composerText = text
        }
        if let target {
            composerTextBySession[target] = text
        }
    }

    private func setAttachments(_ next: [AttachmentChip], for sessionID: String? = nil) {
        let target = sessionID ?? selectedSessionID
        if target == selectedSessionID {
            attachments = next
        }
        if let target {
            attachmentsBySession[target] = next
        }
    }

    private func appendToComposer(_ suffix: String) {
        setComposerText(composerText + suffix)
    }

    func resetChatFindIndex() {
        chatFindIndex = 0
    }

    func searchChatNext(direction: Int = 1) {
        let targets = selectedChatFindTargets
        guard !targets.isEmpty else {
            if !chatFindText.isEmpty {
                toastWarning("No matches", chatFindText)
            }
            chatFindIndex = 0
            return
        }
        let step = direction < 0 ? -1 : 1
        chatFindIndex = (chatFindIndex + step + targets.count) % targets.count
    }

    func resolveMarkdownImageURL(_ source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }
        let url: URL
        if trimmed.lowercased().hasPrefix("file://"), let parsed = URL(string: trimmed) {
            url = parsed
        } else if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            guard !workingDirectory.isEmpty else {
                return nil
            }
            url = URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let allowed = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
        guard allowed.contains(resolved.pathExtension.lowercased()) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    func openImageLightbox(source: String, alt: String? = nil) {
        guard let url = resolveMarkdownImageURL(source), let data = try? Data(contentsOf: url) else {
            toastWarning("Image unavailable", source)
            return
        }
        imageLightbox = ImageLightboxContent(imageData: data, filePath: url.path, alt: alt)
    }

    private func finishTurn(sessionID: String, shouldDrainQueue: Bool) {
        activeTurnSnapshots.removeValue(forKey: sessionID)
        guard shouldDrainQueue, let queued = pendingUserMessagesBySession[sessionID], !queued.isEmpty else {
            return
        }
        pendingUserMessagesBySession[sessionID] = []
        let merged = queued.map(\.content).joined(separator: "\n\n")
        let mergedAttachments = queued.flatMap(\.attachments)
        let previousSelection = selectedSessionID
        selectedSessionID = sessionID
        send(merged, attachments: mergedAttachments)
        selectedSessionID = previousSelection
    }

    private func restoreActiveTurnToDraft(sessionID: String) {
        let stopped = activeTurnSnapshots.removeValue(forKey: sessionID)
        let queued = pendingUserMessagesBySession.removeValue(forKey: sessionID) ?? []
        let existingDraft = sessionID == selectedSessionID ? composerText : composerTextBySession[sessionID] ?? ""
        let parts = ([stopped?.content, existingDraft] + queued.map(\.content)).compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            setComposerText(parts.joined(separator: "\n\n"), for: sessionID)
        }
        let restoredAttachments = (stopped?.attachments ?? []) + (sessionID == selectedSessionID ? attachments : attachmentsBySession[sessionID] ?? []) + queued
            .flatMap(\.attachments)
        setAttachments(restoredAttachments, for: sessionID)
        if let stopped {
            messagesBySession[sessionID]?.removeAll { $0.id == stopped.messageID }
        }
    }

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

    private func resolvedModelForActiveProvider() throws -> String {
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
        settings.sidebarWidth = min(450, max(Double(LiquidGlassToken.sidebarWidth), settings.sidebarWidth))
        settings.secondaryWidth = min(Double(LiquidGlassToken.inspectorMaxWidth), max(Double(LiquidGlassToken.inspectorMinWidth), settings.secondaryWidth))
        syncComposerDefaultsFromClaudeUserSettings()
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
        try? JSONFile.save(settings, to: AppPaths.shared.settingsFile)
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

    private func syncComposerDefaultsFromClaudeUserSettings() {
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
        persistSettings()
    }

    private func applyComposerConfigurationChange(model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) {
        if selectedSessionID == nil {
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

    func reloadSessions() {
        reloadSessionsGeneration &+= 1
        let generation = reloadSessionsGeneration
        let index = sessionIndex
        let pinnedArchived = JSONFile.load([String: SessionRecord].self, from: AppPaths.shared.sessionMetaFile) ?? [:]
        let drafts = sessions.filter { $0.isDraft }
        Task.detached(priority: .utility) {
            let discovered = index.discoverAllSessions()
            await MainActor.run {
                // A newer reload started while this scan was running — drop stale results.
                guard generation == self.reloadSessionsGeneration else {
                    return
                }
                self.applyDiscoveredSessions(discovered, meta: pinnedArchived, drafts: drafts)
            }
        }
    }

    private func applyDiscoveredSessions(_ discovered: [SessionRecord], meta: [String: SessionRecord], drafts: [SessionRecord]) {
        var seen = Set<String>()
        var loaded: [SessionRecord] = []
        for var item in discovered where seen.insert(item.id).inserted {
            if let record = meta[item.id] {
                item.customTitle = record.customTitle
                item.pinned = record.pinned
                item.archived = record.archived
            }
            loaded.append(item)
        }
        for draft in drafts where seen.insert(draft.id).inserted {
            loaded.insert(draft, at: 0)
        }
        sessions = loaded.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            if lhs.archived != rhs.archived {
                return !lhs.archived && rhs.archived
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    func saveSessionMeta() {
        let dict = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        try? JSONFile.save(dict, to: AppPaths.shared.sessionMetaFile)
    }

    func selectSession(_ id: String?) {
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = id
        guard let id, let session = sessions.first(where: { $0.id == id }) else {
            workingDirectory = ""
            fileTree = []
            selectedFilePath = nil
            filePreview = ""
            filePreviewCleanContent = ""
            fileEditDirty = false
            resetWorkspaceChangeState()
            directoryWatcher.unwatchAll()
            restoreComposerState(for: nil)
            reloadMCPAndSkills()
            return
        }
        restoreComposerState(for: id)
        resetWorkspaceChangeState()
        if messagesBySession[id] == nil, let path = session.path {
            let loadedMessages = sessionIndex.loadMessages(path: path)
            messagesBySession[id] = loadedMessages
            toolCallsBySession[id] = AgentActivityBuilder.toolCalls(from: loadedMessages, sessionID: id)
        }
        guard let projectDir = existingDirectoryPath(session.projectDir) else {
            workingDirectory = session.projectDir
            fileTree = []
            selectedFilePath = nil
            filePreview = ""
            filePreviewCleanContent = ""
            fileEditDirty = false
            directoryWatcher.unwatchAll()
            toastWarning("Project unavailable", "\(session.projectDir) no longer exists. Reopen the project folder to continue editing files.")
            reloadMCPAndSkills()
            return
        }
        workingDirectory = projectDir
        fileSystem.registerWorkspace(projectDir)
        startWatchingWorkspace()
        reloadFileTree()
        reloadMCPAndSkills()
    }

    func selectNextSession() {
        guard !sessions.isEmpty else {
            return
        }
        let current = selectedSessionID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? -1
        selectSession(sessions[(current + 1 + sessions.count) % sessions.count].id)
    }

    func selectPreviousSession() {
        guard !sessions.isEmpty else {
            return
        }
        let current = selectedSessionID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? 0
        selectSession(sessions[(current - 1 + sessions.count) % sessions.count].id)
    }

    func adjustFontSize(_ delta: Double) {
        settings.fontSize = min(22, max(11, settings.fontSize + delta))
        persistSettings()
    }

    func newChat() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url {
            let projectDir = existingDirectoryPath(url.path) ?? url.path
            let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
            let session = SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: "New chat", cliResumeID: nil, isDraft: true)
            sessions.insert(session, at: 0)
            messagesBySession[id] = []
            snapshotComposerState(for: selectedSessionID)
            selectedSessionID = id
            composerTextBySession[id] = ""
            attachmentsBySession[id] = []
            restoreComposerState(for: id)
            workingDirectory = projectDir
            resetWorkspaceChangeState()
            fileSystem.registerWorkspace(projectDir)
            rememberProject(projectDir)
            startWatchingWorkspace()
            reloadFileTree()
            reloadMCPAndSkills()
        }
    }

    func loadProject(_ path: String) {
        guard let projectDir = existingDirectoryPath(path) else {
            forgetRecentProject(path)
            toastWarning("Project unavailable", "\(path) no longer exists and was removed from Recent Projects.")
            return
        }
        let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
        sessions.insert(SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: "New chat", isDraft: true), at: 0)
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = id
        composerTextBySession[id] = ""
        attachmentsBySession[id] = []
        restoreComposerState(for: id)
        workingDirectory = projectDir
        resetWorkspaceChangeState()
        fileSystem.registerWorkspace(projectDir)
        rememberProject(projectDir)
        startWatchingWorkspace()
        reloadFileTree()
        reloadMCPAndSkills()
    }

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        if !workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        } else if let recent = sessionIndex.mostRecentProjectDirectory() {
            panel.directoryURL = URL(fileURLWithPath: recent, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        setStartWorkingDirectory(url.path, remember: true, showToast: true)
    }

    @discardableResult
    func selectMostRecentClaudeProject(showToast: Bool = true) -> Bool {
        guard let path = sessionIndex.mostRecentProjectDirectory() else {
            if showToast {
                toastWarning("No Claude Code project found", "Choose a project folder manually.")
            }
            return false
        }
        return setStartWorkingDirectory(path, remember: false, showToast: showToast)
    }

    func clearWorkingDirectory() {
        let preservedText = composerText
        let preservedAttachments = attachments
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = nil
        restoreComposerState(for: nil)
        composerText = preservedText
        attachments = preservedAttachments
        workingDirectory = ""
        fileTree = []
        selectedFilePath = nil
        filePreview = ""
        filePreviewCleanContent = ""
        fileEditDirty = false
        resetWorkspaceChangeState()
        directoryWatcher.unwatchAll()
        reloadMCPAndSkills()
    }

    func returnToStartScreen() {
        selectSession(nil)
        syncComposerDefaultsFromClaudeUserSettings()
        autoSelectClaudeRecentProjectIfNeeded()
    }

    private func autoSelectClaudeRecentProjectIfNeeded() {
        guard selectedSessionID == nil, workingDirectory.isEmpty else {
            return
        }
        if !selectMostRecentClaudeProject(showToast: false), let lastProject = recentProjects.first {
            setStartWorkingDirectory(lastProject.path, remember: false, showToast: false)
        }
    }

    @discardableResult
    private func setStartWorkingDirectory(_ path: String, remember: Bool, showToast: Bool) -> Bool {
        guard let projectDir = existingDirectoryPath(path) else {
            forgetRecentProject(path)
            if showToast {
                toastWarning("Project unavailable", "\(path) no longer exists.")
            }
            return false
        }
        let preservedText = composerText
        let preservedAttachments = attachments
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = nil
        restoreComposerState(for: nil)
        composerText = preservedText
        attachments = preservedAttachments
        workingDirectory = projectDir
        selectedFilePath = nil
        filePreview = ""
        filePreviewCleanContent = ""
        fileEditDirty = false
        resetWorkspaceChangeState()
        fileSystem.registerWorkspace(projectDir)
        if remember {
            rememberProject(projectDir)
        }
        startWatchingWorkspace()
        reloadFileTree()
        reloadMCPAndSkills()
        if showToast {
            toastSuccess("Project selected", URL(fileURLWithPath: projectDir).lastPathComponent)
        }
        return true
    }

    func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Auto-create session if none selected
        if selectedSessionID == nil {
            let hasExplicitWorkingDirectory = !workingDirectory.isEmpty
            let projectDir = hasExplicitWorkingDirectory
                ? workingDirectory
                : FileManager.default.homeDirectoryForCurrentUser.path
            let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
            let session = SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: "New chat", cliResumeID: nil, isDraft: true)
            sessions.insert(session, at: 0)
            messagesBySession[id] = []
            selectedSessionID = id
            composerTextBySession[id] = ""
            attachmentsBySession[id] = []
            workingDirectory = projectDir
            resetWorkspaceChangeState()
            fileSystem.registerWorkspace(projectDir)
            if hasExplicitWorkingDirectory {
                rememberProject(projectDir)
            }
            startWatchingWorkspace()
            reloadFileTree()
            reloadMCPAndSkills()
        }

        guard let id = selectedSessionID else { return }
        let currentAttachments = attachments
        setComposerText("", for: id)
        setAttachments([], for: id)
        if hasActiveTurn(for: id) {
            pendingUserMessagesBySession[id, default: []].append(PendingUserMessage(content: text, attachments: currentAttachments))
            return
        }
        send(text, attachments: currentAttachments)
    }

    func send(_ text: String, attachments: [AttachmentChip] = []) {
        guard let id = selectedSessionID else {
            newChat(); return
        }
        let session = sessions.first(where: { $0.id == id })
        let fallbackCWD = workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workingDirectory
        let preferredCWD: String
        if let projectDir = session?.projectDir, !projectDir.isEmpty {
            preferredCWD = projectDir
        } else {
            preferredCWD = fallbackCWD
        }
        guard let cwd = existingDirectoryPath(preferredCWD) ?? existingDirectoryPath(fallbackCWD) else {
            setComposerText(text, for: id)
            setAttachments(attachments, for: id)
            showError("Project unavailable", "\(preferredCWD) no longer exists. Reopen the project folder before sending.")
            return
        }
        do {
            let resolvedModel = try resolvedModelForActiveProvider()
            let configuration = ComposerSendConfiguration(model: resolvedModel, mode: settings.sessionMode, thinkingLevel: settings.thinkingLevel)
            let payload = composerPayloadText(text, attachments: attachments)
            let message = ChatMessage(role: .user, content: text, attachments: attachments)
            messagesBySession[id, default: []].append(message)
            activeTurnSnapshots[id] = ActiveTurnSnapshot(messageID: message.id, content: text, attachments: attachments)
            if toolCallsBySession[id] == nil {
                toolCallsBySession[id] = []
            }
            if streamingTextBySession[id] == nil {
                streamingTextBySession[id] = ""
            }
            if shouldStartSession(session, sessionID: id, configuration: configuration) {
                fileSystem.registerWorkspace(cwd)
                try engine.startSession(ClaudeSessionStartRequest(
                    prompt: payload,
                    cwd: cwd,
                    model: resolvedModel,
                    sessionID: id,
                    resumeSessionID: session?.cliResumeID,
                    thinkingLevel: configuration.thinkingLevel,
                    mode: configuration.mode,
                    provider: activeProvider,
                    providerAPIKey: activeProviderID.flatMap { providerVault.apiKey(providerID: $0) }
                ), eventSink: { [weak self] event in Task { @MainActor in self?.handle(event) } })
            } else {
                try engine.sendMessage(sessionID: id, text: payload)
            }
            sendConfigurationBySession[id] = configuration
        } catch {
            activeTurnSnapshots.removeValue(forKey: id)
            setComposerText(text, for: id)
            setAttachments(attachments, for: id)
            showError("Failed to send", error.localizedDescription)
        }
    }

    private func shouldStartSession(_ session: SessionRecord?, sessionID: String, configuration: ComposerSendConfiguration) -> Bool {
        guard let session, !session.isDraft, session.path != nil else {
            return true
        }
        guard engine.isSessionRunning(sessionID: sessionID) else {
            return true
        }
        guard let previous = sendConfigurationBySession[sessionID] else {
            return true
        }
        return previous != configuration
    }

    func interrupt() {
        guard let id = selectedSessionID else {
            return
        }
        do { try engine.interrupt(sessionID: id) } catch { showError("Failed to interrupt", error.localizedDescription) }
    }

    func respondPermission(_ permission: PermissionRequest, allow: Bool, editedInput: String? = nil) {
        do {
            try engine.respondPermission(permission, allow: allow, updatedInputJSON: editedInput, message: allow ? nil : "User denied this operation")
            pendingPermissions.removeAll { $0.id == permission.id }
            let state = allow ? "Allowed" : "Denied"
            appendMessage(ChatMessage(role: .system, content: "\(state) \(permission.toolName): \(permission.summary)"), sessionID: permission.sessionID)
        } catch { showError("Permission response failed", error.localizedDescription) }
    }

    func handle(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let sessionID, let cliID):
            if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
                if let cliID, !cliID.hasPrefix("desk_") {
                    sessionIndex.trackSession(cliID, projectDir: sessions[idx].projectDir)
                }
                sessions[idx].cliResumeID = cliID ?? sessions[idx].cliResumeID
                sessions[idx].isDraft = false
            }
        case .textDelta(let sessionID, let text):
            streamingTextBySession[sessionID, default: ""] += text
        case .message(let sessionID, let message):
            if message.role == .user, let checkpoint = message.checkpointUuid {
                backfillCheckpoint(checkpoint, echo: message, sessionID: sessionID)
                return
            }
            if !streamingTextBySession[sessionID, default: ""].isEmpty, message.role == .assistant {
                streamingTextBySession[sessionID] = ""
            }
            appendMessage(message, sessionID: sessionID)
        case .toolStarted(let sessionID, let tool),
             .toolUpdated(let sessionID, let tool):
            upsertTool(tool, sessionID: sessionID)
        case .permissionRequested(let permission):
            pendingPermissions.append(permission)
            var tool = ToolCall(
                id: permission.toolUseID ?? permission.requestID,
                sessionID: permission.sessionID,
                name: permission.toolName,
                inputPreview: permission.inputJSON,
                status: .waitingForPermission,
                parentID: permission.parentToolUseID
            )
            tool.resultPreview = permission.summary
            upsertTool(tool, sessionID: permission.sessionID)
        case .turnCompleted(let sessionID):
            if let text = streamingTextBySession[sessionID], !text.isEmpty {
                appendMessage(ChatMessage(role: .assistant, content: text), sessionID: sessionID)
                streamingTextBySession[sessionID] = ""
            }
            finishTurn(sessionID: sessionID, shouldDrainQueue: true)
            reloadSessions()
        case .stderr(let sessionID, let text):
            if text.lowercased().contains("error") {
                appendMessage(ChatMessage(role: .error, content: text), sessionID: sessionID)
            }
        case .exited(let sessionID):
            if let text = streamingTextBySession[sessionID], !text.isEmpty {
                appendMessage(ChatMessage(role: .assistant, content: text), sessionID: sessionID)
                streamingTextBySession[sessionID] = ""
            }
            restoreActiveTurnToDraft(sessionID: sessionID)
            reloadSessions()
        case .failed(let sessionID, let text):
            appendMessage(ChatMessage(role: .error, content: text), sessionID: sessionID)
            restoreActiveTurnToDraft(sessionID: sessionID)
        }
    }

    private func backfillCheckpoint(_ checkpoint: String, echo: ChatMessage, sessionID: String) {
        var messages = messagesBySession[sessionID] ?? []
        if let idx = messages.indices.reversed().first(where: { messages[$0].role == .user && messages[$0].checkpointUuid == nil }) {
            messages[idx].checkpointUuid = checkpoint
            messagesBySession[sessionID] = messages
        } else if !messages.contains(where: { $0.id == echo.id }) {
            messagesBySession[sessionID, default: []].append(echo)
        }
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].lastCheckpointUUID = checkpoint
        }
    }

    private func startWatchingWorkspace() {
        guard !workingDirectory.isEmpty else {
            return
        }
        guard let root = existingDirectoryPath(workingDirectory) else {
            directoryWatcher.unwatchAll()
            fileTree = []
            toastWarning("Project unavailable", "\(workingDirectory) no longer exists. File watching is paused.")
            return
        }
        workingDirectory = root
        do {
            directoryWatcher.unwatchAll()
            try directoryWatcher.watchDirectory(root) { [weak self] paths in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    for path in paths {
                        self.changedFiles.insert(path)
                        self.fileChangeBadges[path] = self.fileChangeBadges[path] ?? "M"
                    }
                    self.reloadFileTree()
                }
            }
        } catch { showError("Watch failed", error.localizedDescription) }
    }

    private func resetWorkspaceChangeState() {
        changedFiles.removeAll()
        fileChangeBadges.removeAll()
    }

    private func appendMessage(_ message: ChatMessage, sessionID: String) {
        messagesBySession[sessionID, default: []].append(message)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].preview = String(message.content.prefix(120))
            sessions[idx].modifiedAt = Date()
        }
    }

    private func upsertTool(_ tool: ToolCall, sessionID: String) {
        var tools = toolCallsBySession[sessionID] ?? []
        if let idx = tools.firstIndex(where: { $0.id == tool.id }) {
            var merged = tool
            let existing = tools[idx]
            if merged.name == "Tool", existing.name != "Tool" {
                merged.name = existing.name
            }
            if merged.inputPreview.isEmpty {
                merged.inputPreview = existing.inputPreview
            }
            if merged.resultPreview.isEmpty {
                merged.resultPreview = existing.resultPreview
            }
            merged.startedAt = existing.startedAt
            if merged.parentID == nil {
                merged.parentID = existing.parentID
            }
            tools[idx] = merged
        } else {
            tools.append(tool)
        }
        toolCallsBySession[sessionID] = tools
    }

}

extension AppModel {
    func togglePin(_ session: SessionRecord) {
        mutateSession(session.id) { $0.pinned.toggle() }
    }

    func toggleArchive(_ session: SessionRecord) {
        mutateSession(session.id) { $0.archived.toggle() }
    }

    func rename(_ session: SessionRecord, to title: String) {
        mutateSession(session.id) { $0.customTitle = title }
    }

    func toggleSessionSelection(_ session: SessionRecord) {
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
        sessionSelectionMode = !selectedSessionIDs.isEmpty
    }

    func clearSessionSelection() {
        selectedSessionIDs.removeAll()
        sessionSelectionMode = false
    }

    func toggleSessionSelectionMode() {
        sessionSelectionMode.toggle()
        if !sessionSelectionMode {
            selectedSessionIDs.removeAll()
        }
    }

    func archiveSelectedSessions() {
        for id in selectedSessionIDs {
            mutateSession(id) { $0.archived = true }
        }
        toastSuccess("Archived sessions", "\(selectedSessionIDs.count) session(s)")
        clearSessionSelection()
    }

    func deleteSelectedSessions() {
        let ids = selectedSessionIDs
        let targets = sessions.filter { ids.contains($0.id) }
        targets.forEach(deleteSession)
        clearSessionSelection()
    }

    func generateSessionTitle(_ session: SessionRecord) {
        let source = (messagesBySession[session.id] ?? []).first { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.content ?? session.preview
        let compact = source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = compact.isEmpty ? "New Chat" : String(compact.prefix(42))
        mutateSession(session.id) { $0.customTitle = title }
        toastSuccess("Generated title", title)
    }

    func deleteSession(_ session: SessionRecord) {
        engine.kill(sessionID: session.id)
        fileSystem.clearGrants(sessionID: session.id)
        let backupPath = backupSessionForUndo(session)
        recentlyDeletedSession = DeletedSessionSnapshot(
            session: session,
            messages: messagesBySession[session.id] ?? [],
            backupPath: backupPath,
            originalPath: session.path,
            deletedAt: Date()
        )
        do {
            try sessionIndex.deleteSessionRecord(session)
        } catch {
            toastWarning("Claude session delete failed", error.localizedDescription)
        }
        sessions.removeAll { $0.id == session.id }
        messagesBySession.removeValue(forKey: session.id)
        streamingTextBySession.removeValue(forKey: session.id)
        toolCallsBySession.removeValue(forKey: session.id)
        pendingPermissions.removeAll { $0.sessionID == session.id }
        composerTextBySession.removeValue(forKey: session.id)
        attachmentsBySession.removeValue(forKey: session.id)
        pendingUserMessagesBySession.removeValue(forKey: session.id)
        activeTurnSnapshots.removeValue(forKey: session.id)
        sendConfigurationBySession.removeValue(forKey: session.id)
        selectedSessionIDs.remove(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
        saveSessionMeta()
        toastWarning("Deleted session", "Undo is available for \(session.title)")
    }

    private func backupSessionForUndo(_ session: SessionRecord) -> String? {
        guard let path = session.path, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let backupDir = AppPaths.shared.appSupport.appendingPathComponent("Trash/Sessions", isDirectory: true)
        let backup = backupDir.appendingPathComponent("\(session.id)-\(Int(Date().timeIntervalSince1970)).jsonl")
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(atPath: path, toPath: backup.path)
            return backup.path
        } catch {
            toastWarning("Undo backup failed", error.localizedDescription)
            return nil
        }
    }

    func undoLastSessionDelete() {
        guard let snapshot = recentlyDeletedSession else {
            return
        }
        if
            let original = snapshot.originalPath, let backup = snapshot.backupPath, FileManager.default.fileExists(atPath: backup),
            !FileManager.default.fileExists(atPath: original) {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: original).deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: backup, toPath: original)
            } catch {
                showError("Undo delete failed", error.localizedDescription)
                return
            }
        }
        if let cliID = snapshot.session.cliResumeID ?? (snapshot.session.id.hasPrefix("desk_") ? nil : snapshot.session.id) {
            sessionIndex.trackSession(cliID, projectDir: snapshot.session.projectDir)
        }
        sessions.insert(snapshot.session, at: 0)
        messagesBySession[snapshot.session.id] = snapshot.messages
        selectedSessionID = snapshot.session.id
        workingDirectory = snapshot.session.projectDir
        recentlyDeletedSession = nil
        saveSessionMeta()
        reloadMCPAndSkills()
        reloadFileTree()
        toastSuccess("Restored session", snapshot.session.title)
    }

    private func mutateSession(_ id: String, _ body: (inout SessionRecord) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        body(&sessions[idx]); saveSessionMeta()
    }

    func reloadFileTree() {
        guard !workingDirectory.isEmpty else {
            fileTree = []; return
        }
        guard let root = existingDirectoryPath(workingDirectory) else {
            fileTree = []; return
        }
        do { fileTree = try fileSystem.loadTree(root: URL(fileURLWithPath: root), sessionID: selectedSessionID) } catch { fileTree = []; showError(
            "Load files failed",
            error.localizedDescription
        ) }
    }

    func openFile(_ path: String) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext) {
            let info = try? fileSystem.imageInfo(path, sessionID: selectedSessionID)
            let size = info?.size ?? "unknown size"
            let dimensions = info?.dimensions ?? "unknown dimensions"
            let preview = "Image preview\n\nPath: \(path)\nSize: \(size)\nDimensions: \(dimensions)\n\nUse Open or Reveal for the native image viewer."
            selectedFilePath = path
            filePreview = preview
            filePreviewCleanContent = preview
            fileEditDirty = false
            filePreviewMode = .preview
            secondaryTab = .files
            return
        }
        do {
            let text = try fileSystem.readText(path, sessionID: selectedSessionID)
            selectedFilePath = path
            filePreview = text
            filePreviewCleanContent = text
            fileEditDirty = false
            if ext == "html" || ext == "htm" || ext == "xhtml" {
                filePreviewMode = .html
            } else if ext == "md" || ext == "mdx" {
                filePreviewMode = .preview
            } else {
                filePreviewMode = .source
            }
            secondaryTab = .files
        } catch { showError("Read file failed", error.localizedDescription) }
    }

    func markFilePreviewEdited() {
        guard selectedFilePath != nil else {
            fileEditDirty = false; return
        }
        fileEditDirty = filePreview != filePreviewCleanContent
    }

    func saveSelectedFile() {
        guard let path = selectedFilePath else {
            return
        }
        do {
            try fileSystem.writeText(path, text: filePreview, sessionID: selectedSessionID)
            changedFiles.insert(path)
            fileChangeBadges[path] = fileChangeBadges[path] == "A" ? "A" : "M"
            filePreviewCleanContent = filePreview
            fileEditDirty = false
            reloadFileTree()
            if URL(fileURLWithPath: path).lastPathComponent == "SKILL.md" {
                reloadMCPAndSkills()
                selectedSkill = skills.first { sameFilePath($0.path, path) }
            }
        } catch { showError("Save file failed", error.localizedDescription) }
    }

    func reloadSelectedFile() {
        guard let path = selectedFilePath else {
            return
        }
        guard resolveDirtyFileChange() else {
            return
        }
        openFile(path)
    }

    @discardableResult private func resolveDirtyFileChange() -> Bool {
        guard fileEditDirty else {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Unsaved file changes"
        alert.informativeText = "Save the current file before changing the preview selection?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveSelectedFile()
            return !fileEditDirty
        case .alertSecondButtonReturn:
            filePreview = filePreviewCleanContent
            fileEditDirty = false
            return true
        default:
            return false
        }
    }

    @discardableResult func requestOpenFile(_ path: String) -> Bool {
        if sameFilePath(selectedFilePath, path) {
            secondaryTab = .files; return true
        }
        guard resolveDirtyFileChange() else {
            return false
        }
        openFile(path)
        return sameFilePath(selectedFilePath, path)
    }

    func requestCloseFilePreview() {
        guard resolveDirtyFileChange() else {
            return
        }
        selectedFilePath = nil
        filePreview = ""
        filePreviewCleanContent = ""
        fileEditDirty = false
    }

    @discardableResult func requestSelectFilePath(_ path: String) -> Bool {
        if !sameFilePath(selectedFilePath, path) {
            guard resolveDirtyFileChange() else {
                return false
            }
            selectedFilePath = path
            filePreview = ""
            filePreviewCleanContent = ""
            fileEditDirty = false
        }
        return true
    }

    func requestRenameSelectedFile(to newName: String) {
        guard resolveDirtyFileChange() else {
            return
        }
        renameSelectedFile(to: newName)
    }

    func requestDeleteSelectedFile() {
        guard resolveDirtyFileChange() else {
            return
        }
        deleteSelectedFile()
    }

    func requestRenameFile(_ path: String, to newName: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        requestRenameSelectedFile(to: newName)
    }

    func requestDeleteFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        requestDeleteSelectedFile()
    }

    func requestRevealFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        revealSelectedFile()
    }

    func requestOpenExternalFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        openSelectedFile()
    }

    func requestCopyFilePath(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        copySelectedPath()
    }

    func requestInsertFilePath(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        insertSelectedPathIntoChat()
    }

    func requestShareFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        shareSelectedFile()
    }

    func requestInsertFileContent(_ path: String) {
        if !sameFilePath(selectedFilePath, path) {
            guard resolveDirtyFileChange() else {
                return
            }
            openFile(path)
        }
        guard sameFilePath(selectedFilePath, path) else {
            return
        }
        insertSelectedContentIntoChat()
    }

    func revealSelectedFile() {
        if let path = selectedFilePath {
            do { try fileSystem.reveal(path, sessionID: selectedSessionID) } catch { showError(
                "Reveal failed",
                error.localizedDescription
            ) } } }

    func openSelectedFile() {
        if let path = selectedFilePath {
            do { try fileSystem.open(path, sessionID: selectedSessionID) } catch { showError(
                "Open failed",
                error.localizedDescription
            ) } } }

    func openSelectedInVSCode() {
        if let path = selectedFilePath {
            do { try fileSystem.openInVSCode(path, sessionID: selectedSessionID) } catch { showError(
                "Open in VS Code failed",
                error.localizedDescription
            ) } } }

    private func availablePath(in directory: URL, name: String) -> URL {
        let base = directory.appendingPathComponent(name)
        guard (try? fileSystem.exists(base.path, sessionID: selectedSessionID)) == true else {
            return base
        }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        for index in 2 ... 999 {
            let candidate = directory.appendingPathComponent("\(stem) \(index)").appendingPathExtension(ext)
            if (try? fileSystem.exists(candidate.path, sessionID: selectedSessionID)) != true {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(6))").appendingPathExtension(ext)
    }

    func createFile(inDirectory directory: String, named name: String = "untitled.txt") {
        let url = availablePath(in: URL(fileURLWithPath: directory), name: name)
        do {
            try fileSystem.writeText(url.path, text: "", sessionID: selectedSessionID); changedFiles
                .insert(url.path); fileChangeBadges[url.path] = "A"; reloadFileTree(); toastSuccess(
                    "Created file",
                    url.lastPathComponent
                ) } catch { showError("Create file failed", error.localizedDescription) }
    }

    func createFolder(inDirectory directory: String, named name: String) {
        let url = availablePath(in: URL(fileURLWithPath: directory), name: name)
        do {
            try fileSystem.createDirectory(url.path, sessionID: selectedSessionID); changedFiles.insert(url.path); fileChangeBadges[url.path] = "A"; reloadFileTree(); toastSuccess(
                "Created folder",
                url.lastPathComponent
            ) } catch { showError("Create folder failed", error.localizedDescription) }
    }

    func renameSelectedFile(to newName: String) {
        guard let path = selectedFilePath else {
            return
        }
        let dest = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(newName).path
        do {
            try fileSystem.rename(path, to: dest, sessionID: selectedSessionID); changedFiles.insert(path); changedFiles
                .insert(dest); fileChangeBadges[path] = "D"; fileChangeBadges[dest] = "A"; selectedFilePath = dest; filePreviewCleanContent = filePreview; fileEditDirty =
                false; reloadFileTree(); toastSuccess(
                    "Renamed",
                    newName
                ) } catch { showError("Rename failed", error.localizedDescription) }
    }

    func deleteSelectedFile() {
        guard let path = selectedFilePath else {
            return
        }
        do {
            try fileSystem.delete(path, sessionID: selectedSessionID); changedFiles
                .insert(path); fileChangeBadges[path] = "D"; selectedFilePath = nil; filePreview = ""; filePreviewCleanContent = ""; fileEditDirty =
                false; reloadFileTree(); toastSuccess(
                    "Deleted",
                    URL(fileURLWithPath: path).lastPathComponent
                ) } catch { showError("Delete failed", error.localizedDescription) }
    }

    func copySelectedPath() {
        guard let path = selectedFilePath else {
            return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string); toastSuccess("Copied path", path)
    }

    func insertSelectedPathIntoChat() {
        if let path = selectedFilePath {
            appendToComposer(" @\(path)")
        } }

    func insertSelectedContentIntoChat() {
        if !filePreview.isEmpty {
            appendToComposer("\n\n```\n\(filePreview)\n```")
        } }

    func shareSelectedFile() {
        if let path = selectedFilePath {
            shareService.share(path: path, from: nil)
        } }

    func attachFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            var next = attachments
            for url in panel.urls {
                if let id = selectedSessionID {
                    fileSystem.addGrant(sessionID: id, path: url.path)
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                next.append(AttachmentChip(
                    name: url.lastPathComponent,
                    path: url.path,
                    size: Int64(values?.fileSize ?? 0),
                    isImage: ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased())
                ))
            }
            setAttachments(next)
        }
    }

    func removeAttachment(_ attachment: AttachmentChip) {
        setAttachments(attachments.filter { $0.id != attachment.id })
    }

    func requestRewindToLastUserMessage() {
        performRewind(.restoreAll)
    }

    func performRewind(_ action: RewindAction) {
        guard
            let id = selectedSessionID,
            let session = sessions.first(where: { $0.id == id }),
            let turn = lastUserMessage(in: id) else {
            showError("Rewind unavailable", "No user turn is available to rewind.")
            return
        }

        switch action {
        case .restoreAll:
            guard let output = restoreCodeToCheckpoint(session: session, turn: turn) else {
                return
            }
            rewindConversation(sessionID: id, toMessageID: turn.id)
            toastInfo("Rewind restored", output.isEmpty ? "Conversation and files restored to the last user turn." : output)
        case .restoreCode:
            guard let output = restoreCodeToCheckpoint(session: session, turn: turn) else {
                return
            }
            toastInfo("Code restored", output.isEmpty ? "Files restored to the last Claude checkpoint." : output)
        case .restoreConversation:
            rewindConversation(sessionID: id, toMessageID: turn.id)
            toastInfo("Conversation restored", "Messages after the last user turn were removed; code files were left unchanged.")
        case .summarize:
            setComposerText("/compact Summarize the conversation from this point and preserve open tasks.")
            toastInfo("Summary command ready", "Review and send the /compact command when ready.")
        }
    }

    private func lastUserMessage(in sessionID: String) -> ChatMessage? {
        (messagesBySession[sessionID] ?? []).last { $0.role == .user }
    }

    private func restoreCodeToCheckpoint(session: SessionRecord, turn: ChatMessage) -> String? {
        guard let checkpoint = turn.checkpointUuid ?? session.lastCheckpointUUID else {
            showError("Rewind unavailable", "No Claude checkpoint UUID has been recorded for this turn yet.")
            return nil
        }
        do {
            let output = try engine.rewindFiles(
                sessionID: session.id,
                cliSessionID: session.cliResumeID,
                checkpointUUID: checkpoint,
                cwd: workingDirectory.isEmpty ? session.projectDir : workingDirectory
            )
            reloadFileTree()
            return output ?? ""
        } catch {
            showError("Rewind failed", error.localizedDescription)
            return nil
        }
    }

    private func rewindConversation(sessionID: String, toMessageID messageID: String) {
        guard let index = (messagesBySession[sessionID] ?? []).lastIndex(where: { $0.id == messageID }) else {
            return
        }
        messagesBySession[sessionID] = Array((messagesBySession[sessionID] ?? []).prefix(index + 1))
        streamingTextBySession[sessionID] = ""
        pendingUserMessagesBySession[sessionID] = []
        pendingPermissions.removeAll { $0.sessionID == sessionID }
        toolCallsBySession[sessionID] = []
        activeTurnSnapshots.removeValue(forKey: sessionID)
        engine.kill(sessionID: sessionID)
        if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[sessionIndex].preview = messagesBySession[sessionID]?.last?.content ?? sessions[sessionIndex].preview
            sessions[sessionIndex].modifiedAt = Date()
            sessions[sessionIndex].isDraft = false
        }
        resetChatFindIndex()
        saveSessionMeta()
    }

}

extension AppModel {
    func reloadMCPAndSkills() {
        mcpServers = mcpService.loadServers(projectPath: workingDirectory.isEmpty ? nil : workingDirectory)
        skills = skillService.loadSkills(projectPath: workingDirectory.isEmpty ? nil : workingDirectory)
    }

    func useSkillInComposer(_ skill: SkillInfo) {
        let command = "/\(skill.name) "
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setComposerText(command)
        } else {
            let separator = composerText.hasSuffix(" ") || composerText.hasSuffix("\n") ? "" : "\n"
            setComposerText(composerText + separator + command)
        }
        toastSuccess("Inserted skill command", command)
    }

    func duplicateSkill(_ skill: SkillInfo) {
        if sameFilePath(selectedFilePath, skill.path) {
            guard resolveDirtyFileChange() else {
                return
            }
        }
        let originalURL = URL(fileURLWithPath: skill.path)
        let parent = originalURL.deletingLastPathComponent().deletingLastPathComponent()
        let baseName = "\(skill.name)-copy"
        var candidateName = baseName
        var suffix = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidateName, isDirectory: true).path) {
            candidateName = "\(baseName)-\(suffix)"
            suffix += 1
        }
        let targetDir = parent.appendingPathComponent(candidateName, isDirectory: true)
        let targetFile = targetDir.appendingPathComponent("SKILL.md")
        do {
            if !workingDirectory.isEmpty {
                fileSystem.registerWorkspace(workingDirectory)
            }
            try fileSystem.createDirectory(targetDir.path, sessionID: selectedSessionID)
            try fileSystem.writeText(targetFile.path, text: skillContent(skill.content, settingName: candidateName), sessionID: selectedSessionID)
            reloadMCPAndSkills()
            if requestOpenFile(targetFile.path) {
                selectedSkill = skills.first { sameFilePath($0.path, targetFile.path) }
            }
            toastSuccess("Duplicated skill", candidateName)
        } catch {
            showError("Duplicate skill failed", error.localizedDescription)
        }
    }

    func createSkill(name: String, projectScoped: Bool) {
        let root = projectScoped && !workingDirectory.isEmpty
            ? URL(fileURLWithPath: workingDirectory).appendingPathComponent(".claude/skills/\(name)")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/\(name)")
        do {
            try fileSystem.createDirectory(root.path, sessionID: selectedSessionID)
            let file = root.appendingPathComponent("SKILL.md")
            let content = "---\nname: \(name)\ndescription: Use this skill when its project-specific instructions apply.\n---\n\n# \(name)\n\nAdd concrete instructions, examples, and boundaries for this skill.\n"
            try fileSystem.writeText(file.path, text: content, sessionID: selectedSessionID)
            reloadMCPAndSkills()
            if requestOpenFile(file.path) {
                selectedSkill = skills.first { sameFilePath($0.path, file.path) }
            }
            toastSuccess("Created skill", name)
        } catch { showError("Create skill failed", error.localizedDescription) }
    }

    func deleteSelectedSkill() {
        guard let skill = selectedSkill else {
            return
        }
        if sameFilePath(selectedFilePath, skill.path) {
            guard resolveDirtyFileChange() else {
                return
            }
        }
        do {
            try skillService.deleteSkill(skill)
            if sameFilePath(selectedFilePath, skill.path) {
                requestCloseFilePreview()
            }
            selectedSkill = nil
            reloadMCPAndSkills()
            toastSuccess("Deleted skill", skill.name)
        } catch { showError("Delete skill failed", error.localizedDescription) }
    }

    func toggleSelectedSkillEnabled() {
        guard var skill = selectedSkill else {
            return
        }
        skill.disabled.toggle()
        let source = sameFilePath(selectedFilePath, skill.path) ? filePreview : skill.content
        skill.content = skillContent(source, settingDisabled: skill.disabled)

        do {
            try skillService.writeSkill(skill)
            if sameFilePath(selectedFilePath, skill.path) {
                filePreview = skill.content
                filePreviewCleanContent = skill.content
                fileEditDirty = false
            }
            selectedSkill = skill
            reloadMCPAndSkills()
            selectedSkill = skills.first { sameFilePath($0.path, skill.path) } ?? skill
            toastSuccess(skill.disabled ? "Disabled skill" : "Enabled skill", skill.name)
        } catch { showError("Save skill failed", error.localizedDescription) }
    }

    private func skillContent(_ content: String, settingDisabled disabled: Bool) -> String {
        let canonicalKey = "disable_model_invocation"
        let legacyKey = "disable-model-invocation"
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var frontmatter = Array(lines[1 ..< end])
            var wroteCanonical = false
            frontmatter = frontmatter.compactMap { line in
                if line.hasPrefix("\(canonicalKey):") {
                    wroteCanonical = true
                    return "\(canonicalKey): \(disabled)"
                }
                if line.hasPrefix("\(legacyKey):") {
                    return nil
                }
                return line
            }
            if !wroteCanonical {
                frontmatter.insert("\(canonicalKey): \(disabled)", at: 0)
            }
            lines = ["---"] + frontmatter + Array(lines[end...])
            return lines.joined(separator: "\n")
        }
        return "---\n\(canonicalKey): \(disabled)\n---\n\n" + content
    }

    private func skillContent(_ content: String, settingName name: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var frontmatter = Array(lines[1 ..< end])
            var wroteName = false
            frontmatter = frontmatter.map { line in
                if line.hasPrefix("name:") {
                    wroteName = true
                    return "name: \(name)"
                }
                return line
            }
            if !wroteName {
                frontmatter.insert("name: \(name)", at: 0)
            }
            lines = ["---"] + frontmatter + Array(lines[end...])
            return lines.joined(separator: "\n")
        }
        return "---\nname: \(name)\n---\n\n" + content
    }

    func addMCPServer(name: String, command: String) {
        let server = appLocalMCPServer(name: name, commandLine: command)
        mcpServers.removeAll { $0.source == "LiquidCode" && $0.name == server.name }
        mcpServers.append(server)
        saveAppMCPServers()
    }

    func updateMCPServer(_ server: MCPServer, name: String, command: String) {
        guard server.source == "LiquidCode" else {
            toastWarning("MCP is read-only", "\(server.name) is managed by \(server.source).")
            return
        }
        let next = appLocalMCPServer(name: name, commandLine: command)
        mcpServers.removeAll { $0.source == "LiquidCode" && ($0.name == server.name || $0.name == next.name) }
        mcpServers.append(next)
        saveAppMCPServers()
    }

    func deleteMCPServer(_ server: MCPServer) {
        guard server.source == "LiquidCode" else {
            toastWarning("MCP is read-only", "\(server.name) is managed by \(server.source).")
            return
        }
        mcpServers.removeAll { $0.name == server.name && $0.source == "LiquidCode" }
        saveAppMCPServers()
    }

    func testMCPServer(_ server: MCPServer) {
        if let url = server.url, URL(string: url) != nil {
            toastSuccess("MCP config valid", "\(server.name) uses \(url)"); return
        }
        guard let command = server.command?.split(separator: " ").first.map(String.init), !command.isEmpty else {
            toastWarning(
                "MCP config incomplete",
                "\(server.name) has no command or URL"
            ); return }
        let resolved = command.contains("/") ? (FileManager.default.isExecutableFile(atPath: command) ? command : nil) : Shell.capture("/usr/bin/env", ["which", command])
        if let resolved, !resolved.isEmpty {
            toastSuccess("MCP command found", "\(server.name): \(resolved)")
        } else {
            toastWarning(
                "MCP command missing",
                "\(server.name): \(command)"
            ) }
    }

    private func saveAppMCPServers() {
        do { try mcpService.saveAppServers(mcpServers.filter { $0.source == "LiquidCode" }); reloadMCPAndSkills(); toastSuccess("Saved MCP", "App-local MCP profile updated")
        } catch { showError(
            "Save MCP failed",
            error.localizedDescription
        ) }
    }

    private func appLocalMCPServer(name: String, commandLine: String) -> MCPServer {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommand = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: cleanCommand), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return MCPServer(name: cleanName, transport: "http", command: nil, url: cleanCommand, args: [], enabled: true, source: "LiquidCode")
        }
        let parts = shellWords(cleanCommand)
        return MCPServer(
            name: cleanName,
            transport: "stdio",
            command: parts.first ?? cleanCommand,
            url: nil,
            args: Array(parts.dropFirst()),
            enabled: true,
            source: "LiquidCode"
        )
    }

    private func shellWords(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for char in input {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if char == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            if char.isWhitespace {
                if !current.isEmpty {
                    words.append(current); current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

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
            toastWarning("Provider key missing", "Save an API key for \(activeProvider.name) before testing the connection.")
            return
        }
        do {
            let model = try resolvedModelForActiveProvider()
            toastInfo("Testing provider", "Calling \(activeProvider.name) with \(model)…")
            Task { @MainActor in
                do {
                    let result = try await ProviderConnectionProbe.probe(provider: activeProvider, apiKey: apiKey, model: model)
                    toastSuccess("Provider connected", "\(activeProvider.name) responded in \(result.latencyMilliseconds)ms (HTTP \(result.statusCode)).")
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
            providers = imported.providers; activeProviderID = imported.activeProviderID; saveProviders(); toastSuccess("Imported providers", "\(providers.count) providers")
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
            toastSuccess("Migrated providers", "Imported \(result.importedProviderIDs.count) providers. Rollback is available.")
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
        setupProgress = SetupProgress(phase: .checking, percent: 0.05, message: "Checking Claude CLI release sources")
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
        let removed = report.removed.isEmpty ? "No files removed" : "Removed \(report.removed.count) app-local broken item(s)"
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
        cliService.openTerminalLogin(); setupProgress = SetupProgress(phase: .authenticating, percent: 0.5, message: "Claude login opened in Terminal")
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

    private func showToast(_ kind: ToastMessage.Kind, _ title: String, _ message: String) {
        let next = ToastMessage(kind: kind, title: title, message: message)
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

    func loadSessionGroups() {
        sessionGroups = JSONFile.load([SessionTaskGroup].self, from: AppPaths.shared.appSupport.appendingPathComponent("groups.json")) ?? []
    }

    func saveSessionGroups() {
        try? JSONFile.save(sessionGroups, to: AppPaths.shared.appSupport.appendingPathComponent("groups.json"))
    }

    func createGroup(name: String) {
        guard !workingDirectory.isEmpty else {
            return
        }
        sessionGroups.append(SessionTaskGroup(name: name, projectPath: workingDirectory, sessionIDs: [])); saveSessionGroups()
    }

    func addSession(_ session: SessionRecord, to group: SessionTaskGroup) {
        guard let idx = sessionGroups.firstIndex(where: { $0.id == group.id }) else {
            return
        }
        guard session.projectDir == sessionGroups[idx].projectPath else {
            return
        }
        if !sessionGroups[idx].sessionIDs.contains(session.id) {
            sessionGroups[idx].sessionIDs.append(session.id); sessionGroups[idx].updatedAt = Date(); saveSessionGroups()
        }
    }

    func removeSession(_ session: SessionRecord, from group: SessionTaskGroup) {
        guard let idx = sessionGroups.firstIndex(where: { $0.id == group.id }) else {
            return
        }
        sessionGroups[idx].sessionIDs.removeAll { $0 == session.id }; sessionGroups[idx].updatedAt = Date(); saveSessionGroups()
    }

    func deleteGroup(_ group: SessionTaskGroup) {
        sessionGroups.removeAll { $0.id == group.id }; saveSessionGroups()
    }

    func exportMarkdown(session: SessionRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(session.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if let path = session.path {
                    try sessionIndex.exportMarkdown(path: path, outputPath: url.path)
                } else {
                    let messages = messagesBySession[session.id] ?? []
                    let markdown = messages.map { "### \($0.role.rawValue)\n\n\($0.content)" }.joined(separator: "\n\n")
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch { showError("Export Markdown failed", error.localizedDescription) }
        }
    }

    func exportJSON(session: SessionRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(session.title).json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if let path = session.path {
                    try sessionIndex.exportJSON(path: path, outputPath: url.path)
                } else {
                    try JSONEncoder.liquid.encode(messagesBySession[session.id] ?? []).write(to: url)
                }
            } catch { showError("Export JSON failed", error.localizedDescription) }
        }
    }

    func runCommand(_ command: PaletteCommand) {
        commandPaletteOpen = false
        switch command.kind {
        case .newChat: newChat()
        case .settings: settingsOpen = true
        case .mcpSettings: settingsTab = .mcp; settingsOpen = true
        case .agentsOverlay: agentPanelOpen = true
        case .panel(let tab): secondaryTab = tab
        case .mode(let mode): setComposerMode(mode)
        case .model(let model): setComposerModel(model)
        case .sendSlash(let slash): setComposerText(slash + " ")
        case .installCLI: installOrUpdateCLI()
        case .loginCLI: openClaudeLogin()
        case .exportCurrent: if let selectedSession {
                exportMarkdown(session: selectedSession)
            }
        case .rewind: requestRewindToLastUserMessage()
        case .changelog: showChangelog()
        }
    }

    var paletteCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = [
            .init(title: "New Chat", subtitle: "Open a project and start a draft", kind: .newChat),
            .init(title: "Settings", subtitle: "CLI, MCP, appearance", kind: .settings),
            .init(title: "Files Panel", subtitle: "Show project files", kind: .panel(.files)),
            .init(title: "Plan Panel", subtitle: "Review plan drafts and approvals", kind: .panel(.plan)),
            .init(title: "Skills Panel", subtitle: "Show Claude skills", kind: .panel(.skills)),
            .init(title: "MCP Settings", subtitle: "Show MCP servers in Settings", kind: .mcpSettings),
            .init(title: "Agents Panel", subtitle: "Show agent activity overlay", kind: .agentsOverlay),
            .init(title: "Install or Update Claude CLI", subtitle: cliStatus.version ?? "Claude CLI", kind: .installCLI),
            .init(title: "Claude Login", subtitle: cliStatus.authStatus, kind: .loginCLI),
            .init(title: "Export Current Session", subtitle: "Markdown export", kind: .exportCurrent),
            .init(title: "Rewind to Last User Turn", subtitle: "Request Claude checkpoint restore", kind: .rewind),
            .init(title: "What's New", subtitle: "Open changelog", kind: .changelog)
        ]
        commands += SessionMode.allCases.map { .init(title: "Mode: \($0.label)", subtitle: $0.permissionMode, kind: .mode($0)) }
        commands += defaultModels.map { .init(title: "Model: \(modelMenuDisplayName($0))", subtitle: "Switch Claude model", kind: .model($0)) }
        commands += ["/compact", "/cost", "/doctor", "/help", "/init", "/memory", "/mcp", "/permissions", "/pr_comments", "/review"].map { .init(
            title: $0,
            subtitle: "Insert slash command",
            kind: .sendSlash($0)
        ) }
        commands += skills.map { .init(title: "/\($0.name)", subtitle: $0.description, kind: .sendSlash("/\($0.name)")) }
        return commands
    }

    func filteredPaletteCommands(_ query: String) -> [PaletteCommand] {
        guard !query.isEmpty else {
            return paletteCommands
        }
        return paletteCommands.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    private func rememberProject(_ path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        recentProjects.removeAll { $0.path == path }
        recentProjects.insert(RecentProject(name: name, path: path, lastUsed: Date()), at: 0)
        recentProjects = Array(recentProjects.prefix(20))
        try? JSONFile.save(recentProjects, to: AppPaths.shared.recentProjectsFile)
    }

    private func showError(_ title: String, _ message: String) {
        currentError = AppError(title: title, message: message)
    }

}

struct PaletteCommand: Identifiable, Hashable {
    enum Kind: Hashable { case newChat, settings, panel(SecondaryTab), mcpSettings, agentsOverlay, mode(SessionMode), model(String), sendSlash(String), installCLI, loginCLI,
                               exportCurrent, rewind, changelog }

    let id = UUID()
    let title: String
    let subtitle: String
    let kind: Kind
}
