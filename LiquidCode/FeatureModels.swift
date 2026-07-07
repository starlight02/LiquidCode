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

    var label: String {
        L(rawValue)
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

/// One item from a TodoWrite payload. The CLI sends `content` (imperative form),
/// `activeForm` (present-continuous, shown while in progress), and `status`.
struct TodoItem: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    let id: String
    let content: String
    let activeForm: String
    let status: Status
}

/// Decodes a `TodoWrite` tool call's `inputJSON` into structured todo items.
/// Returns `nil` when the payload is not a recognizable todo list, so the caller
/// can fall back to the generic tool card instead of rendering a broken checklist.
enum TodoPayloadParser {
    static func parse(inputJSON: String) -> [TodoItem]? {
        let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = trimmed.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawTodos = object["todos"] as? [[String: Any]]
        else {
            return nil
        }
        var todos: [TodoItem] = []
        for (index, raw) in rawTodos.enumerated() {
            guard let content = (raw["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                continue
            }
            let activeForm = (raw["activeForm"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = TodoItem.Status(rawValue: (raw["status"] as? String) ?? "pending") ?? .pending
            todos.append(TodoItem(id: "\(index)_\(content.hashValue)", content: content, activeForm: activeForm, status: status))
        }
        // An empty `todos` array is a valid payload the CLI sends to clear the list;
        // still return it so the card can show a cleared state rather than a JSON dump.
        return todos
    }
}

/// A parsed plan drafted by the agent before ExitPlanMode approval. The markdown
/// lives in the control request's `input.plan` field; older shapes only carry it
/// in the request description, so we fall back through summary then raw JSON.
struct PlanDraft: Equatable, Sendable {
    let markdown: String
    let stepCount: Int
}

enum PlanPayloadParser {
    static func parse(inputJSON: String, fallbackSummary: String) -> PlanDraft {
        let markdown = extractedMarkdown(inputJSON: inputJSON) ?? nonEmpty(fallbackSummary) ?? inputJSON
        return PlanDraft(markdown: markdown, stepCount: numberedStepCount(in: markdown))
    }

    /// Walks the same nested candidate objects as `InteractionAdapter` (input /
    /// metadata / request) looking for a plan field, so both surfaces agree on
    /// where the plan text lives.
    private static func extractedMarkdown(inputJSON: String) -> String? {
        guard
            let data = inputJSON.data(using: .utf8),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        var candidates = [root]
        for key in ["input", "metadata", "request"] {
            if let nested = root[key] as? [String: Any] {
                candidates.append(nested)
            }
        }
        for object in candidates {
            for key in ["plan", "planContent", "plan_content"] {
                if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func numberedStepCount(in markdown: String) -> Int {
        let lines = markdown.split(separator: "\n")
        return lines.filter { $0.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil }.count
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct TranscriptToolItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case use, result }
    let id: String
    let sourceMessage: ChatMessage
    let kind: Kind
    let toolName: String
    let content: String
    var toolUseID: String?
    var isError: Bool = false
    var summaryName: String {
        guard kind == .use else {
            return L("Tool result")
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

struct TranscriptQuestionItem: Identifiable, Equatable, Sendable {
    let id: String
    let sourceMessage: ChatMessage
    let toolUseID: String?
    let inputJSON: String
    var isPending: Bool = false
}

struct TranscriptTodoItem: Identifiable, Equatable, Sendable {
    let id: String
    let sourceMessage: ChatMessage
    let items: [TodoItem]
}

enum TranscriptDisplayItem: Identifiable, Equatable, Sendable {
    case message(ChatMessage)
    case interaction(PermissionRequest)
    case question(TranscriptQuestionItem)
    case todo(TranscriptTodoItem)
    case tool(TranscriptToolItem)
    case toolRun([TranscriptToolItem])

    var id: String {
        switch self {
        case .message(let message): message.id
        case .interaction(let permission): "interaction_\(permission.id)"
        case .question(let question): question.id
        case .todo(let item): item.id
        case .tool(let item): item.id
        case .toolRun(let items): "toolrun_" + items.map(\.id).joined(separator: "_")
        }
    }
}

struct TranscriptToolExpansionState: Equatable, Sendable {
    var expandedDisplayItemID: String?
    var expandedToolItemID: String?

    static let collapsed = TranscriptToolExpansionState(expandedDisplayItemID: nil, expandedToolItemID: nil)
}

enum TranscriptAutoExpansionPolicy {
    static func state(for displayItems: [TranscriptDisplayItem], isStreaming: Bool) -> TranscriptToolExpansionState {
        guard isStreaming, let item = displayItems.last else {
            return .collapsed
        }
        switch item {
        case .tool(let tool):
            guard tool.kind == .use else {
                return .collapsed
            }
            return TranscriptToolExpansionState(expandedDisplayItemID: item.id, expandedToolItemID: tool.id)
        case .toolRun(let tools):
            guard !TranscriptToolRunCompletion.isComplete(tools), let tool = tools.last(where: { $0.kind == .use }) else {
                return .collapsed
            }
            return TranscriptToolExpansionState(expandedDisplayItemID: item.id, expandedToolItemID: tool.id)
        case .message,
             .interaction,
             .question,
             .todo:
            return .collapsed
        }
    }
}

enum TranscriptDisplayBuilder {
    static func displayItems(messages: [ChatMessage], pendingPermissions: [PermissionRequest] = []) -> [TranscriptDisplayItem] {
        let pending = deduplicatedPendingPermissions(pendingPermissions)
        let pendingQuestionToolIDs = Set(pending.compactMap { permission -> String? in
            guard InteractionAdapter(permission: permission).kind == .question else {
                return nil
            }
            return permission.toolUseID ?? permission.requestID
        })
        let pendingQuestionSignatures = Set(pending.compactMap { permission -> String? in
            guard InteractionAdapter(permission: permission).kind == .question else {
                return nil
            }
            let signature = questionSignature(inputJSON: permission.inputJSON, fallback: permission.summary)
            return signature.isEmpty ? nil : signature
        })
        let rawItems = messages.flatMap {
            items(
                for: $0,
                suppressedQuestionToolIDs: pendingQuestionToolIDs,
                suppressedQuestionSignatures: pendingQuestionSignatures
            )
        }
        var output: [TranscriptDisplayItem] = []
        var index = 0
        while index < rawItems.count {
            switch rawItems[index] {
            case .message(let message):
                output.append(.message(message))
                index += 1
            case .question(let question):
                output.append(.question(question))
                index += 1
            case .todo(let todo):
                output.append(.todo(todo))
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
        output.append(contentsOf: pending.map(TranscriptDisplayItem.interaction))
        return output
    }

    private static func deduplicatedPendingPermissions(_ permissions: [PermissionRequest]) -> [PermissionRequest] {
        var seen = Set<String>()
        var output: [PermissionRequest] = []
        for permission in permissions {
            let key = permission.toolUseID ?? permission.requestID
            guard seen.insert(key).inserted else {
                continue
            }
            output.append(permission)
        }
        return output
    }

    private static func items(
        for message: ChatMessage,
        suppressedQuestionToolIDs: Set<String>,
        suppressedQuestionSignatures: Set<String>
    ) -> [RawTranscriptDisplayItem] {
        if !message.blocks.isEmpty {
            return structuredItems(
                for: message,
                suppressedQuestionToolIDs: suppressedQuestionToolIDs,
                suppressedQuestionSignatures: suppressedQuestionSignatures
            )
        }
        return legacyItems(
            for: message,
            suppressedQuestionToolIDs: suppressedQuestionToolIDs,
            suppressedQuestionSignatures: suppressedQuestionSignatures
        )
    }

    private static func structuredItems(
        for message: ChatMessage,
        suppressedQuestionToolIDs: Set<String>,
        suppressedQuestionSignatures: Set<String>
    ) -> [RawTranscriptDisplayItem] {
        let hasStructuralBlocks = message.blocks.contains { block in
            switch block.kind {
            case .text, .image:
                return false
            case .thinking, .toolUse, .toolResult, .unknown:
                return true
            }
        }
        if !hasStructuralBlocks {
            return [.message(message)]
        }

        var output: [RawTranscriptDisplayItem] = []
        var textSegments: [String] = []
        var imageSegments: [MessageImageReference] = []
        var ordinal = 0
        var emittedQuestionKeys = Set<String>()

        func appendMessageSegment() {
            let text = textSegments.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let images = deduplicatedImages(imageSegments)
            guard !text.isEmpty || !images.isEmpty else {
                textSegments.removeAll()
                imageSegments.removeAll()
                return
            }
            var copy = message
            copy.id = "\(message.id)_content_\(ordinal)"
            copy.content = text
            copy.toolName = nil
            copy.images = images
            copy.blocks = []
            output.append(.message(copy))
            ordinal += 1
            textSegments.removeAll()
            imageSegments.removeAll()
        }

        for block in message.blocks {
            switch block.kind {
            case .text:
                if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textSegments.append(block.text)
                }
            case .image:
                if let image = block.image {
                    imageSegments.append(image)
                }
            case .thinking:
                appendMessageSegment()
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    continue
                }
                var thinking = message
                thinking.id = "\(message.id)_thinking_\(ordinal)"
                thinking.role = .thinking
                thinking.content = text
                thinking.images = []
                thinking.toolName = nil
                thinking.blocks = [block]
                output.append(.message(thinking))
                ordinal += 1
            case .toolUse:
                appendMessageSegment()
                let toolName = block.toolName ?? "Tool"
                let toolUseID = block.toolUseID ?? block.id
                let signature = questionSignature(inputJSON: block.inputJSON ?? "{}", fallback: "")
                let questionKey = signature.isEmpty ? toolUseID : signature
                if
                    isAskUserQuestion(toolName),
                    !suppressedQuestionToolIDs.contains(toolUseID),
                    signature.isEmpty || !suppressedQuestionSignatures.contains(signature),
                    emittedQuestionKeys.insert(questionKey).inserted {
                    output.append(.question(TranscriptQuestionItem(
                        id: "\(message.id)_question_\(block.id)",
                        sourceMessage: message,
                        toolUseID: toolUseID,
                        inputJSON: block.inputJSON ?? "{}"
                    )))
                } else if toolName == "TodoWrite", let todos = TodoPayloadParser.parse(inputJSON: block.inputJSON ?? "") {
                    // A recognizable TodoWrite becomes its own checklist item; an
                    // unparsable payload falls through to the generic tool card below.
                    output.append(.todo(TranscriptTodoItem(
                        id: "\(message.id)_todo_\(ordinal)_\(block.id)",
                        sourceMessage: message,
                        items: todos
                    )))
                } else if !isAskUserQuestion(toolName) {
                    output.append(.tool(TranscriptToolItem(
                        id: "\(message.id)_tool_\(ordinal)_\(block.id)",
                        sourceMessage: message,
                        kind: .use,
                        toolName: toolName,
                        content: block.inputJSON ?? "",
                        toolUseID: block.toolUseID ?? block.id
                    )))
                }
                ordinal += 1
            case .toolResult:
                appendMessageSegment()
                let content = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                output.append(.tool(TranscriptToolItem(
                    id: "\(message.id)_tool_result_\(ordinal)_\(block.toolUseID ?? block.id)",
                    sourceMessage: message,
                    kind: .result,
                    toolName: L("Tool result"),
                    content: content,
                    toolUseID: block.toolUseID,
                    isError: block.isError
                )))
                ordinal += 1
            case .unknown:
                if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textSegments.append(block.text)
                }
            }
        }
        appendMessageSegment()
        if output.isEmpty {
            let hasVisibleFallback = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.displayImages.isEmpty
            return hasVisibleFallback ? [.message(message)] : []
        }
        return output
    }

    private static func legacyItems(
        for message: ChatMessage,
        suppressedQuestionToolIDs: Set<String>,
        suppressedQuestionSignatures: Set<String>
    ) -> [RawTranscriptDisplayItem] {
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
                toolName = L("Tool result")
                toolLines = [line]
            } else if toolKind != nil {
                toolLines.append(line)
            } else {
                textLines.append(line)
            }
        }
        appendTool()
        appendText()
        var emittedQuestionKeys = Set<String>()
        let converted = output.compactMap { item -> RawTranscriptDisplayItem? in
            if case .tool(let tool) = item, tool.kind == .use, isAskUserQuestion(tool.toolName) {
                let payload = cleanToolPayload(tool.content)
                let signature = questionSignature(inputJSON: payload, fallback: tool.content)
                let questionKey = signature.isEmpty ? (tool.toolUseID ?? tool.id) : signature
                guard
                    !suppressedQuestionToolIDs.contains(tool.toolUseID ?? tool.id),
                    signature.isEmpty || !suppressedQuestionSignatures.contains(signature),
                    emittedQuestionKeys.insert(questionKey).inserted
                else {
                    return nil
                }
                return .question(TranscriptQuestionItem(
                    id: "\(message.id)_question_legacy_\(tool.id)",
                    sourceMessage: message,
                    toolUseID: tool.toolUseID,
                    inputJSON: payload
                ))
            }
            if
                case .tool(let tool) = item,
                tool.kind == .use,
                tool.toolName == "TodoWrite",
                let todos = TodoPayloadParser.parse(inputJSON: cleanToolPayload(tool.content)) {
                return .todo(TranscriptTodoItem(
                    id: "\(message.id)_todo_legacy_\(tool.id)",
                    sourceMessage: message,
                    items: todos
                ))
            }
            return item
        }
        if converted.isEmpty, output.isEmpty {
            return [.message(message)]
        }
        return converted
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

    private static func isAskUserQuestion(_ toolName: String) -> Bool {
        let lower = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "askuserquestion" || lower == "ask_user_question" || lower.contains("askuserquestion")
    }

    private static func questionSignature(inputJSON: String, fallback: String) -> String {
        let prompts = questionPrompts(from: inputJSON, fallback: fallback)
        if !prompts.isEmpty {
            return prompts.map { prompt in
                ([prompt.header, prompt.question] + prompt.options.flatMap { [$0.label, $0.description] })
                    .map(normalizedSignatureText)
                    .filter { !$0.isEmpty }
                    .joined(separator: "|")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "||")
        }
        return normalizedSignatureText(inputJSON.isEmpty ? fallback : inputJSON)
    }

    private static func normalizedSignatureText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}

private enum RawTranscriptDisplayItem {
    case message(ChatMessage)
    case question(TranscriptQuestionItem)
    case todo(TranscriptTodoItem)
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
        toolCalls(fromDisplayItems: TranscriptDisplayBuilder.displayItems(messages: messages), sessionID: sessionID)
    }

    static func toolCalls(fromDisplayItems displayItems: [TranscriptDisplayItem], sessionID: String) -> [ToolCall] {
        let items = displayItems.flatMap { item -> [TranscriptToolItem] in
            switch item {
            case .tool(let tool): [tool]
            case .toolRun(let tools): tools
            case .message,
                 .question,
                 .todo,
                 .interaction: []
            }
        }
        var toolNamesByMessageID: [String: String] = [:]
        var toolNamesByToolUseID: [String: String] = [:]
        for item in items where item.kind == .use {
            toolNamesByMessageID[item.sourceMessage.id] = item.summaryName
            if let toolUseID = item.toolUseID {
                toolNamesByToolUseID[toolUseID] = item.summaryName
            }
        }
        return items.enumerated().map { index, item in
            let resolvedName = item.kind == .result
                ? (item.toolUseID.flatMap { toolNamesByToolUseID[$0] } ?? item.sourceMessage.parentID.flatMap { toolNamesByMessageID[$0] } ?? item.toolName)
                : item.summaryName
            let call = ToolCall(
                id: item.toolUseID ?? "\(item.sourceMessage.id)_agent_\(index)",
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
        return role == .tool ? L("Tool result") : L("Tool use")
    }
}

func chatFindTargets(in messages: [ChatMessage], query: String) -> [ChatFindTarget] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return []
    }
    return messages.flatMap { message in
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
        "Native SwiftUI/AppKit shell with a sidebar-chat-secondary layout.",
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
