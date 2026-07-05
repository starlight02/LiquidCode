import Foundation
import SwiftUI

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
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
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
        case .code: "Code"
        case .ask: "Ask"
        case .plan: "Plan"
        case .bypass: "Bypass"
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
        case .off: "No think"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X High"
        case .max: "Max"
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
        case .restoreAll: "Restore all"
        case .restoreConversation: "Restore conversation"
        case .restoreCode: "Restore code"
        case .summarize: "Summarize from here"
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
            return "New Chat"
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

    init(
        id: String = UUID().uuidString,
        role: Role,
        content: String,
        timestamp: Date = Date(),
        toolName: String? = nil,
        rawJSON: String? = nil,
        parentID: String? = nil,
        checkpointUuid: String? = nil,
        attachments: [AttachmentChip] = []
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
    var cwd: String
    var model: String?
    var sessionID: String
    var resumeSessionID: String?
    var thinkingLevel: ThinkingLevel
    var mode: SessionMode
    var provider: ProviderRecord?
    var providerAPIKey: String?
}

enum ClaudeEvent: Sendable {
    case sessionStarted(sessionID: String, cliSessionID: String?)
    case textDelta(sessionID: String, text: String)
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
