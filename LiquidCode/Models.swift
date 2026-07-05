import Foundation
import SwiftUI

enum AppLocalization {
    static let supportedLanguageCode = languageCode(for: Locale.preferredLanguages)
    static let locale = Locale(identifier: supportedLanguageCode)

    private static let selectedBundle = bundle(for: supportedLanguageCode)
    private static let englishBundle = bundle(for: "en")

    static func languageCode(for preferredLanguages: [String]) -> String {
        let primary = preferredLanguages.first ?? Locale.current.identifier
        return primary.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    }

    static func localizedString(_ key: String, comment: String = "") -> String {
        _ = comment
        if let selected = selectedBundle {
            let value = selected.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }
        if supportedLanguageCode != "en", let english = englishBundle {
            let value = english.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }
        return key
    }

    private static func bundle(for languageCode: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}

// swiftlint:disable:next identifier_name
func L(_ key: String, comment: String = "") -> String {
    AppLocalization.localizedString(key, comment: comment)
}

func LF(_ key: String, _ arguments: CVarArg..., comment: String = "") -> String {
    String(format: L(key, comment: comment), locale: AppLocalization.locale, arguments: arguments)
}

struct AppError: Identifiable, Error, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

enum ThemeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .system: L("System")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }
}

enum AccentTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case black
    case blue
    case purple
    case green
    var id: String {
        rawValue
    }

    var color: Color {
        switch self {
        case .black: .primary
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        }
    }
}

enum SessionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case code
    case ask
    case plan
    case bypass
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .code: L("Code")
        case .ask: L("Ask")
        case .plan: L("Plan")
        case .bypass: L("Bypass")
        }
    }

    var permissionMode: String {
        switch self {
        case .code: "acceptEdits"
        case .ask: "default"
        case .plan: "plan"
        case .bypass: "bypassPermissions"
        }
    }
}

enum ThinkingLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case medium
    case high
    case xhigh
    case max
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .off: L("No think")
        case .low: L("Low")
        case .medium: L("Medium")
        case .high: L("High")
        case .xhigh: L("X High")
        case .max: L("Max")
        }
    }

    var maxThinkingTokens: Int {
        switch self {
        case .off: 0
        case .low: 4_000
        case .medium: 8_000
        case .high: 16_000
        case .xhigh: 24_000
        case .max: 32_000
        }
    }
}

enum RewindAction: String, CaseIterable, Identifiable, Sendable {
    case restoreAll
    case restoreConversation
    case restoreCode
    case summarize

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .restoreAll: L("Restore all")
        case .restoreConversation: L("Restore conversation")
        case .restoreCode: L("Restore code")
        case .summarize: L("Summarize from here")
        }
    }

    var systemImage: String {
        switch self {
        case .restoreAll: "arrow.uturn.backward.circle"
        case .restoreConversation: "text.bubble"
        case .restoreCode: "curlybraces.square"
        case .summarize: "text.badge.checkmark"
        }
    }
}

enum SecondaryTab: String, CaseIterable, Identifiable, Sendable {
    case files = "Files"
    case plan = "Plan"
    case skills = "Skills"
    var id: String {
        rawValue
    }

    var label: String {
        L(rawValue)
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .plan: "list.bullet.rectangle"
        case .skills: "sparkles"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case mcp = "MCP"
    case cli = "CLI"
    case feedback = "Feedback"
    var id: String {
        rawValue
    }

    var label: String {
        L(rawValue)
    }
}

struct AppSettings: Codable, Sendable {
    var theme: ThemeMode = .system
    var accent: AccentTheme = .black
    var fontSize: Double = 14
    var selectedModel: String = "claude-sonnet-4-6"
    var sessionMode: SessionMode = .ask
    var thinkingLevel: ThinkingLevel = .high
    var selectedProviderID: String?
    var sidebarWidth: Double = 260
    var secondaryWidth: Double = 390
    var locale: String = Locale.current.identifier
    var lastSeenVersion: String = ""
    var sessionConfigurations: [String: ComposerSendConfiguration] = [:]
}

struct SessionRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var path: String?
    var project: String
    var projectDir: String
    var createdAt: Date?
    var modifiedAt: Date
    var preview: String
    var cliResumeID: String?
    var lastCheckpointUUID: String?
    var customTitle: String?
    var pinned: Bool = false
    var archived: Bool = false
    var isDraft: Bool = false

    var title: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        if !preview.isEmpty {
            return preview
        }
        if isDraft {
            return L("New Chat")
        }
        return id
    }
}

enum CLISource: String, Codable, CaseIterable, Sendable {
    case official
    case system
    case appLocal
    case versionManager
    case dynamic
}

struct CLICandidate: Identifiable, Codable, Equatable, Sendable {
    var id: String {
        path
    }

    var path: String
    var source: CLISource
    var isNative: Bool
    var version: String?
    var issues: [String]
}

struct CLICleanupSkipped: Codable, Equatable, Sendable {
    var path: String
    var reason: String
}

struct CLICleanupResult: Codable, Equatable, Sendable {
    var removed: [String] = []
    var skipped: [CLICleanupSkipped] = []
}

struct CLIRepairReport: Codable, Equatable, Sendable {
    var scanned: [String] = []
    var removed: [String] = []
    var notes: [String] = []
}

struct CLIUpdateCheck: Codable, Equatable, Sendable {
    var current: String?
    var latest: String?
    var updateAvailable: Bool
}

struct CLIProgressEvent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case checking, downloading, installing, npmFallback, repairing, complete, failed }
    var phase: Phase
    var percent: Double
    var message: String
}

struct CLIActionResult: Codable, Equatable, Sendable {
    var ok: Bool
    var version: String?
    var source: String
    var message: String
}

enum ChatContentBlockKind: String, Codable, Sendable {
    case text
    case thinking
    case toolUse
    case toolResult
    case image
    case unknown
}

struct ChatContentBlock: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: ChatContentBlockKind
    var text: String
    var toolUseID: String?
    var toolName: String?
    var inputJSON: String?
    var isError: Bool
    var image: MessageImageReference?
    var rawType: String?
    var rawJSON: String?

    init(
        id: String = UUID().uuidString,
        kind: ChatContentBlockKind,
        text: String = "",
        toolUseID: String? = nil,
        toolName: String? = nil,
        inputJSON: String? = nil,
        isError: Bool = false,
        image: MessageImageReference? = nil,
        rawType: String? = nil,
        rawJSON: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.inputJSON = inputJSON
        self.isError = isError
        self.image = image
        self.rawType = rawType
        self.rawJSON = rawJSON
    }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, system, tool, error, thinking }
    var id: String
    var role: Role
    var content: String
    var timestamp: Date
    var toolName: String?
    var rawJSON: String?
    var parentID: String?
    var checkpointUuid: String?
    var attachments: [AttachmentChip]
    var images: [MessageImageReference]
    var blocks: [ChatContentBlock]

    init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        timestamp: Date = Date(),
        toolName: String? = nil,
        rawJSON: String? = nil,
        parentID: String? = nil,
        checkpointUuid: String? = nil,
        attachments: [AttachmentChip] = [],
        images: [MessageImageReference] = [],
        blocks: [ChatContentBlock] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.rawJSON = rawJSON
        self.parentID = parentID
        self.checkpointUuid = checkpointUuid
        self.attachments = attachments
        self.images = images
        self.blocks = blocks
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case timestamp
        case toolName
        case rawJSON
        case parentID
        case checkpointUuid
        case attachments
        case images
        case blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        rawJSON = try container.decodeIfPresent(String.self, forKey: .rawJSON)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        checkpointUuid = try container.decodeIfPresent(String.self, forKey: .checkpointUuid)
        attachments = try container.decodeIfPresent([AttachmentChip].self, forKey: .attachments) ?? []
        images = try container.decodeIfPresent([MessageImageReference].self, forKey: .images) ?? []
        blocks = try container.decodeIfPresent([ChatContentBlock].self, forKey: .blocks) ?? []
    }
}

struct ToolCall: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case streamingInput, waitingForPermission, running, succeeded, failed, denied }
    var id: String
    var sessionID: String
    var name: String
    var inputPreview: String
    var resultPreview: String = ""
    var status: Status
    var startedAt: Date = Date()
    var completedAt: Date?
    var parentID: String?
}

struct PermissionRequest: Identifiable, Codable, Equatable, Sendable {
    enum Risk: String, Codable, Sendable { case readOnly, write, shell, destructive, network, externalMcp }
    var id: String
    var sessionID: String
    var requestID: String
    var toolName: String
    var title: String
    var summary: String
    var inputJSON: String
    var toolUseID: String?
    var parentToolUseID: String?
    var agentID: String?
    var risk: Risk
}

struct FileNode: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        path
    }

    var name: String
    var path: String
    var isDirectory: Bool
    var children: [FileNode] = []
}

struct SkillInfo: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        path
    }

    var name: String
    var description: String
    var path: String
    var scope: String
    var disabled: Bool
    var content: String = ""
    var allowedTools: [String]?
    var model: String?
    var context: String?
    var version: String?
}

struct MCPServer: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        name
    }

    var name: String
    var transport: String
    var command: String?
    var url: String?
    var args: [String]
    var enabled: Bool = true
    var source: String = "Claude"
    var lastError: String?
}

struct ProviderRecord: Identifiable, Codable, Hashable, Sendable {
    enum APIFormat: String, Codable, CaseIterable, Identifiable, Sendable { case anthropic, openai; var id: String {
        rawValue
    } }
    var id: String
    var name: String
    var baseURL: String
    var apiFormat: APIFormat
    var modelMappings: [String: String]
    var extraEnv: [String: String]
    var preset: String?
    var proxyURL: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct RecentProject: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        path
    }

    var name: String
    var path: String
    var lastUsed: Date
}

struct ClaudeSessionStartRequest: Sendable {
    var prompt: String
    var content: ClaudeUserMessageContent = .empty
    var cwd: String
    var model: String?
    var sessionID: String
    var resumeSessionID: String?
    var thinkingLevel: ThinkingLevel
    var mode: SessionMode
    var provider: ProviderRecord?
    var providerAPIKey: String?

    var userMessageContent: ClaudeUserMessageContent {
        content.isEmpty ? ClaudeUserMessageContent(text: prompt) : content
    }
}

enum ClaudeEvent: Sendable {
    case sessionStarted(sessionID: String, cliSessionID: String?)
    case textDelta(sessionID: String, text: String)
    case streamBlockStarted(sessionID: String, index: Int?, ChatContentBlock)
    case streamBlockDelta(sessionID: String, index: Int?, kind: ChatContentBlockKind, text: String)
    case message(sessionID: String, ChatMessage)
    case toolStarted(sessionID: String, ToolCall)
    case toolUpdated(sessionID: String, ToolCall)
    case permissionRequested(PermissionRequest)
    case turnCompleted(sessionID: String)
    case stderr(sessionID: String, String)
    case exited(sessionID: String)
    case failed(sessionID: String, String)
}

let defaultModels = [
    "fable",
    "opus",
    "sonnet",
    "haiku"
]
