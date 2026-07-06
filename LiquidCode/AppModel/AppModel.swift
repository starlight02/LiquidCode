import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var sessions: [SessionRecord] = []
    @Published var selectedSessionID: String?
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var displayItemsBySession: [String: [TranscriptDisplayItem]] = [:]
    @Published var streamingTextBySession: [String: String] = [:]
    @Published var streamingMessagesBySession: [String: ChatMessage] = [:]
    @Published var toolCallsBySession: [String: [ToolCall]] = [:]
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var workingDirectory: String = ""
    @Published var recentProjects: [RecentProject] = []
    @Published var fileTree: [FileNode] = []
    @Published var selectedFilePath: String?
    @Published var filePreview: String = ""
    @Published var filePreviewLoadingPath: String?
    @Published var filePreviewContentPath: String?
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

    let engine: ClaudeEngine
    let providerVault = ProviderVault()
    let fileSystem = FileSystemService()
    let claudeUserSettings: ClaudeUserSettingsService
    let directoryWatcher = DirectoryWatchManager()
    let mcpService = MCPService()
    let skillService = SkillService()
    let sessionIndex = SessionIndexService()
    var reloadSessionsGeneration = 0
    @Published var loadingMessageSessionIDs: Set<String> = []
    var fileTreeReloadGeneration = 0
    var mcpSkillsReloadGeneration = 0
    var workspaceWatchGeneration = 0
    var filePreviewLoadGeneration = 0
    var fileTreeReloadTask: Task<Void, Never>?
    var mcpSkillsReloadTask: Task<Void, Never>?
    var workspaceWatchTask: Task<Void, Never>?
    var filePreviewLoadTask: Task<Void, Never>?
    var defaultComposerConfiguration = ComposerSendConfiguration(
        model: AppSettings().selectedModel,
        mode: AppSettings().sessionMode,
        thinkingLevel: AppSettings().thinkingLevel
    )
    let cliService = CLIService()
    let shareService = ShareService()
    // periphery:ignore
    let onboardingService = OnboardingService()
    var filePreviewCleanContent = ""

    init(
        engine: ClaudeEngine = ClaudeEngineFactory.makeDefault(),
        claudeUserSettings: ClaudeUserSettingsService = ClaudeUserSettingsService()
    ) {
        self.engine = engine
        self.claudeUserSettings = claudeUserSettings
    }

    deinit {
        fileTreeReloadTask?.cancel()
        mcpSkillsReloadTask?.cancel()
        workspaceWatchTask?.cancel()
        filePreviewLoadTask?.cancel()
        directoryWatcher.unwatchAll()
        engine.killAll()
    }
}
