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
    // The right inspector's open state lives here (not as AppShellView @State) so
    // deeply nested views — the composer's plan-review card — can open the panel to
    // show plan detail without threading a binding down through the whole hierarchy.
    @Published var secondaryOpen = false
    @Published var settingsOpen = false
    @Published var settingsTab: SettingsTab = .general
    @Published var commandPaletteOpen = false
    // Subagent state. Sidechain messages routed off the main transcript live in
    // `subagentMessagesBySession` (keyed by sessionID, grouped later by agentID).
    // `subagentCompletionsBySession` holds task-notification results keyed by the
    // parent spawn toolUseID. `subagentActivitiesBySession` is the built, enriched
    // result the transcript card and inspector read (keyed by sessionID). Loaded
    // subagent transcripts are cached in `subagentChildCallsByAgentID` so the lazy
    // history loader only reads each big jsonl once. `focusedSubagentID` lets the
    // inline card scroll the inspector to a specific activity.
    @Published var subagentMessagesBySession: [String: [ChatMessage]] = [:]
    @Published var subagentCompletionsBySession: [String: [String: SubagentCompletion]] = [:]
    // Live agentID → parent spawn toolUseID links, harvested from permission requests
    // and completion notifications so live sidechain records attribute to the right
    // card before any meta.json is available (history uses metas instead).
    @Published var subagentAgentLinksBySession: [String: [String: String]] = [:]
    @Published var subagentActivitiesBySession: [String: [SubagentActivity]] = [:]
    @Published var subagentChildCallsByAgentID: [String: [String: [TranscriptToolItem]]] = [:]
    // Parsed `.meta.json` companions keyed by sessionID, filled by the lazy history
    // loader so reloaded sessions can attribute persisted sidechain records.
    @Published var subagentMetasBySession: [String: [SubagentMeta]] = [:]
    @Published var focusedSubagentID: String?
    // Pre-first-token / live phase of an active turn, per session. Drives the
    // thinking indicator and activity pill; cleared once the turn ends.
    @Published var turnPhaseBySession: [String: TurnPhase] = [:]
    // Latest TodoWrite checklist per session (authoritative current list, not history).
    @Published var todosBySession: [String: SessionTodoState] = [:]
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
    // Separate watcher for the selected session's transcript file so external writers
    // (a `claude --resume` in the user's terminal, another window) surface live. It
    // must be its own instance: DirectoryWatchManager holds a single desired watch, so
    // sharing directoryWatcher would clobber the workspace file-tree watch.
    let sessionFileWatcher = DirectoryWatchManager()
    var sessionFileWatchTask: Task<Void, Never>?
    var sessionFileWatchGeneration = 0
    var watchedSessionFilePath: String?
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
        sessionFileWatchTask?.cancel()
        directoryWatcher.unwatchAll()
        sessionFileWatcher.unwatchAll()
        engine.killAll()
    }
}
