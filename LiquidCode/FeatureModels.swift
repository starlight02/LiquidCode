import Foundation

struct SessionTaskGroup: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var projectPath: String
    var sessionIDs: [String]
    var isCollapsed: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

enum FilePreviewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case preview = "Preview"
    case html = "HTML"
    case source = "Source"
    case edit = "Edit"
    var id: String {
        rawValue
    }
}

struct AttachmentChip: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var path: String
    var size: Int64
    var isImage: Bool
}

struct PendingUserMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var content: String
    var attachments: [AttachmentChip] = []
    var createdAt: Date = Date()
}

struct ActiveTurnSnapshot: Codable, Hashable, Sendable {
    var messageID: String
    var content: String
    var attachments: [AttachmentChip]
}

struct DeletedSessionSnapshot: Identifiable, Sendable {
    var id: String {
        session.id
    }

    var session: SessionRecord
    var messages: [ChatMessage]
    var backupPath: String?
    var originalPath: String?
    var deletedAt: Date
}

struct ComposerSendConfiguration: Codable, Hashable, Sendable {
    var model: String
    var mode: SessionMode
    var thinkingLevel: ThinkingLevel
}

func composerPayloadText(_ text: String, attachments: [AttachmentChip]) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !attachments.isEmpty else {
        return trimmed
    }
    let paths = attachments.map(\.path).joined(separator: "\n")
    return "\(trimmed)\n\nAttached files:\n\(paths)"
}

struct ImageLightboxContent: Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var imageData: Data
    var filePath: String?
    var alt: String?
}

struct ChatFindTarget: Identifiable, Equatable, Sendable {
    var itemID: String
    var occurrenceIndex: Int
    var id: String {
        "\(itemID)#\(occurrenceIndex)"
    }
}

struct MarkdownImageReference: Equatable, Sendable {
    var alt: String
    var source: String
}

struct TranscriptToolItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case use, result }
    let id: String
    let sourceMessage: ChatMessage
    let kind: Kind
    let toolName: String
    let content: String
    var summaryName: String {
        guard kind == .use else {
            return "Tool result"
        }
        if toolName == "Task", let subagentName = taskSubagentType(in: content) {
            return subagentName
        }
        return toolName
    }

    private func taskSubagentType(in text: String) -> String? {
        guard let jsonStart = text.firstIndex(of: "{") else {
            return nil
        }
        let jsonText = String(text[jsonStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = jsonText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let subagentName = object["subagent_type"] as? String
        else {
            return nil
        }
        let clean = subagentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

enum TranscriptDisplayItem: Identifiable, Equatable, Sendable {
    case message(ChatMessage)
    case interaction(PermissionRequest)
    case tool(TranscriptToolItem)
    case toolRun([TranscriptToolItem])

    var id: String {
        switch self {
        case .message(let message): message.id
        case .interaction(let permission): "interaction_\(permission.id)"
        case .tool(let item): item.id
        case .toolRun(let items): "toolrun_" + items.map(\.id).joined(separator: "_")
        }
    }
}

enum TranscriptDisplayBuilder {
    static func displayItems(messages: [ChatMessage], pendingPermissions: [PermissionRequest] = []) -> [TranscriptDisplayItem] {
        let rawItems = messages.flatMap(items)
        var output: [TranscriptDisplayItem] = []
        var index = 0
        while index < rawItems.count {
            switch rawItems[index] {
            case .message(let message):
                output.append(.message(message))
                index += 1
            case .tool(let first):
                var run = [first]
                index += 1
                while index < rawItems.count {
                    guard case .tool(let next) = rawItems[index] else {
                        break
                    }
                    run.append(next)
                    index += 1
                }
                let shouldGroup = run.count >= 2
                if shouldGroup {
                    output.append(.toolRun(run))
                } else {
                    output.append(contentsOf: run.map(TranscriptDisplayItem.tool))
                }
            }
        }
        output.append(contentsOf: pendingPermissions.map(TranscriptDisplayItem.interaction))
        return output
    }

    private static func items(for message: ChatMessage) -> [RawTranscriptDisplayItem] {
        guard message.content.contains("[tool_use:") || message.content.contains("[tool_result") else {
            if message.role == .tool || message.toolName != nil {
                return [.tool(TranscriptToolItem(id: message.id + "_tool", sourceMessage: message, kind: .result, toolName: message.derivedToolName, content: message.content))]
            }
            return [.message(message)]
        }

        var output: [RawTranscriptDisplayItem] = []
        var textLines: [String] = []
        var toolKind: TranscriptToolItem.Kind?
        var toolName = "Tool"
        var toolLines: [String] = []
        var ordinal = 0

        func appendText() {
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                textLines.removeAll(); return
            }
            var copy = message
            copy.id = "\(message.id)_text_\(ordinal)"
            copy.content = text
            copy.toolName = nil
            output.append(.message(copy))
            ordinal += 1
            textLines.removeAll()
        }

        func appendTool() {
            guard let toolKind else {
                return
            }
            let content = toolLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                toolLines.removeAll(); return
            }
            output.append(.tool(TranscriptToolItem(id: "\(message.id)_tool_\(ordinal)", sourceMessage: message, kind: toolKind, toolName: toolName, content: content)))
            ordinal += 1
            toolLines.removeAll()
        }

        for line in message.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let name = toolUseName(from: line) {
                appendTool()
                appendText()
                toolKind = .use
                toolName = name
                toolLines = [line]
            } else if isToolResultMarker(line) {
                appendTool()
                appendText()
                toolKind = .result
                toolName = "Tool result"
                toolLines = [line]
            } else if toolKind != nil {
                toolLines.append(line)
            } else {
                textLines.append(line)
            }
        }
        appendTool()
        appendText()
        return output.isEmpty ? [.message(message)] : output
    }

    private static func toolUseName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[tool_use:") else {
            return nil
        }
        let raw = trimmed.dropFirst("[tool_use:".count)
        let name = raw.split(separator: "]", maxSplits: 1).first.map(String.init) ?? "Tool"
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Tool" : clean
    }

    private static func isToolResultMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[tool_result")
    }
}

private enum RawTranscriptDisplayItem {
    case message(ChatMessage)
    case tool(TranscriptToolItem)
}

enum TranscriptToolRunCompletion {
    static func isComplete(_ items: [TranscriptToolItem]) -> Bool {
        let useCount = items.filter { $0.kind == .use }.count
        guard useCount > 0 else {
            return true
        }
        let resultCount = items.filter { $0.kind == .result }.count
        return resultCount >= useCount
    }
}

enum AgentActivityBuilder {
    static func toolCalls(from messages: [ChatMessage], sessionID: String) -> [ToolCall] {
        let items = TranscriptDisplayBuilder.displayItems(messages: messages).flatMap { item -> [TranscriptToolItem] in
            switch item {
            case .tool(let tool): [tool]
            case .toolRun(let tools): tools
            case .message,
                 .interaction: []
            }
        }
        var toolNamesByMessageID: [String: String] = [:]
        for item in items where item.kind == .use {
            toolNamesByMessageID[item.sourceMessage.id] = item.summaryName
        }
        return items.enumerated().map { index, item in
            let resolvedName = item.kind == .result
                ? (item.sourceMessage.parentID.flatMap { toolNamesByMessageID[$0] } ?? item.toolName)
                : item.summaryName
            let call = ToolCall(
                id: "\(item.sourceMessage.id)_agent_\(index)",
                sessionID: sessionID,
                name: resolvedName,
                inputPreview: item.kind == .use ? item.content : "",
                resultPreview: item.kind == .result ? item.content : "",
                status: .succeeded,
                startedAt: item.sourceMessage.timestamp,
                completedAt: item.sourceMessage.timestamp,
                parentID: item.sourceMessage.parentID
            )
            return call
        }
    }
}

extension ChatMessage {
    var derivedToolName: String {
        if let toolName, !toolName.isEmpty {
            return toolName
        }
        if let range = content.range(of: #"\[tool_use:\s*([^\]]+)\]"#, options: .regularExpression) {
            return String(content[range])
                .replacingOccurrences(of: "[tool_use:", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return role == .tool ? "Tool result" : "Tool use"
    }
}

func chatFindTargets(in messages: [ChatMessage], query: String) -> [ChatFindTarget] {
    messages.flatMap { message in
        chatFindOccurrenceRanges(in: message.content, query: query).indices.map { occurrence in
            ChatFindTarget(itemID: message.id, occurrenceIndex: occurrence)
        }
    }
}

enum SlashCommandParser {
    static func query(from composerText: String) -> String? {
        let firstLine = composerText.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard firstLine.hasPrefix("/") else {
            return nil
        }
        let rawQuery = String(firstLine.dropFirst())
        guard !rawQuery.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return rawQuery
    }
}

func markdownImageReference(from line: String) -> MarkdownImageReference? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("![") else {
        return nil
    }
    guard let altEnd = trimmed.firstIndex(of: "]") else {
        return nil
    }
    let afterAlt = trimmed.index(after: altEnd)
    guard afterAlt < trimmed.endIndex, trimmed[afterAlt] == "(" else {
        return nil
    }
    guard trimmed.last == ")" else {
        return nil
    }
    let altStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let sourceStart = trimmed.index(after: afterAlt)
    guard sourceStart < trimmed.endIndex else {
        return nil
    }
    let sourceEnd = trimmed.index(before: trimmed.endIndex)
    let alt = String(trimmed[altStart ..< altEnd])
    let source = String(trimmed[sourceStart ..< sourceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else {
        return nil
    }
    return MarkdownImageReference(alt: alt, source: source)
}

func chatFindOccurrenceRanges(in text: String, query: String) -> [Range<String.Index>] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
        return []
    }
    var ranges: [Range<String.Index>] = []
    var cursor = text.startIndex
    while cursor < text.endIndex, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: cursor ..< text.endIndex) {
        ranges.append(range)
        cursor = range.upperBound
    }
    return ranges
}

struct ToastMessage: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case info, success, warning, error }
    var id: String = UUID().uuidString
    var kind: Kind
    var title: String
    var message: String
    var createdAt: Date = Date()
}

struct CLIStatus: Codable, Equatable, Sendable {
    var installed: Bool = false
    var path: String?
    var version: String?
    var updateAvailable: Bool = false
    var latestVersion: String?
    var nodeAvailable: Bool = false
    var npmAvailable: Bool = false
    var authStatus: String = "unknown"
}

struct SetupProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case idle
        case checking
        case downloading
        case installing
        case authenticating
        case complete
        case failed
    }

    var phase: Phase = .idle
    var percent: Double = 0
    var message: String = ""
}

struct ChangelogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        version
    }

    var version: String
    var date: String
    var items: [String]
}

let bundledChangelog: [ChangelogEntry] = [
    .init(version: "0.1.0", date: "2026-07-02", items: [
        "Native SwiftUI/AppKit shell matching TOKENICODE's sidebar-chat-secondary layout.",
        "Claude Code stream-json process bridge with stdio permission control.",
        "Keychain-backed provider secrets, MCP/Skills panels, file explorer, session export and Liquid Glass panels."
    ])
]

struct ProviderPreset: Identifiable, Hashable, Sendable {
    enum ThinkingSupport: String, Sendable { case full, ignored, unknown }
    var id: String
    var name: String
    var baseURL: String
    var apiFormat: ProviderRecord.APIFormat
    var extraEnv: [String: String]
    var keyURL: String?
    var thinkingSupport: ThinkingSupport
    var modelMappings: [String: String]
}

let providerPresets: [ProviderPreset] = [
    .init(
        id: "anthropic",
        name: "Anthropic",
        baseURL: "https://api.anthropic.com",
        apiFormat: .anthropic,
        extraEnv: [:],
        keyURL: "https://console.anthropic.com/account/keys",
        thinkingSupport: .full,
        modelMappings: [:]
    ),
    .init(
        id: "deepseek",
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com/v1",
        apiFormat: .openai,
        extraEnv: [:],
        keyURL: "https://platform.deepseek.com/api_keys",
        thinkingSupport: .full,
        modelMappings: ["opus": "deepseek-reasoner", "sonnet": "deepseek-chat", "haiku": "deepseek-chat"]
    ),
    .init(
        id: "zhipu",
        name: "智谱 GLM",
        baseURL: "https://open.bigmodel.cn/api/anthropic",
        apiFormat: .anthropic,
        extraEnv: [:],
        keyURL: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys",
        thinkingSupport: .full,
        modelMappings: ["opus": "glm-5", "sonnet": "glm-5-turbo", "haiku": "glm-4.7"]
    ),
    .init(
        id: "qwen-coder",
        name: "Qwen Coder",
        baseURL: "https://dashscope.aliyuncs.com/apps/anthropic",
        apiFormat: .anthropic,
        extraEnv: [:],
        keyURL: "https://bailian.console.aliyun.com/?apiKey=1",
        thinkingSupport: .unknown,
        modelMappings: ["opus": "qwen3-coder-plus", "sonnet": "qwen3-coder-plus", "haiku": "qwen3-coder-flash"]
    ),
    .init(
        id: "kimi-k2",
        name: "Kimi k2",
        baseURL: "https://api.moonshot.cn/anthropic/",
        apiFormat: .anthropic,
        extraEnv: [:],
        keyURL: "https://platform.moonshot.cn/console/api-keys",
        thinkingSupport: .full,
        modelMappings: ["opus": "kimi-k2.5", "sonnet": "kimi-k2", "haiku": "kimi-k2-turbo-preview"]
    ),
    .init(
        id: "minimax",
        name: "MiniMax",
        baseURL: "https://api.minimaxi.com/anthropic",
        apiFormat: .anthropic,
        extraEnv: ["API_TIMEOUT_MS": "3000000", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"],
        keyURL: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
        thinkingSupport: .full,
        modelMappings: ["opus": "MiniMax-M2.7", "sonnet": "MiniMax-M2.5", "haiku": "MiniMax-M2.1"]
    )
]
