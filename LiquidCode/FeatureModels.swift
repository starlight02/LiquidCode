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

/// Latest authoritative TodoWrite payload for a session. Transcript history keeps every
/// TodoWrite card; this state only tracks the most recent list so the Plan inspector
/// can show "what the agent is working on now" without scanning the timeline.
struct SessionTodoState: Equatable, Sendable {
    var items: [TodoItem]
    var updatedAt: Date
    var sourceMessageID: String?

    var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }
}

/// Walks messages newest-first and returns the latest recognizable `TodoWrite` payload.
/// An empty `todos` array is a valid clear and still becomes a state (with no items).
enum SessionTodoStateBuilder {
    static func latest(from messages: [ChatMessage]) -> SessionTodoState? {
        for message in messages.reversed() {
            for block in message.blocks.reversed() where block.kind == .toolUse && block.toolName == "TodoWrite" {
                guard let items = TodoPayloadParser.parse(inputJSON: block.inputJSON ?? "") else {
                    continue
                }
                return SessionTodoState(items: items, updatedAt: message.timestamp, sourceMessageID: message.id)
            }
            // Legacy transcript lines may only expose TodoWrite via toolName + content.
            if message.toolName == "TodoWrite", let items = TodoPayloadParser.parse(inputJSON: cleanLegacyTodoPayload(message.content)) {
                return SessionTodoState(items: items, updatedAt: message.timestamp, sourceMessageID: message.id)
            }
        }
        return nil
    }

    private static func cleanLegacyTodoPayload(_ content: String) -> String {
        if let jsonStart = content.firstIndex(of: "{") {
            return String(content[jsonStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content
    }
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

/// One subagent Claude spawned via the `Agent`/`Task` tool. The `id` is the parent
/// spawn block's toolUseID — stable and available the moment the spawn card appears,
/// so we can build a `.running` shell immediately and later fill in `agentID`,
/// `childToolCalls`, and the completion `status`/`summary` as those sources arrive.
struct SubagentActivity: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case running, succeeded, failed }
    let id: String
    var agentID: String?
    var subagentType: String
    var description: String
    var status: Status
    var childToolCalls: [TranscriptToolItem]
    var summary: String?
    var startedAt: Date
    var finishedAt: Date?

    init(
        id: String,
        agentID: String? = nil,
        subagentType: String,
        description: String = "",
        status: Status = .running,
        childToolCalls: [TranscriptToolItem] = [],
        summary: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.subagentType = subagentType
        self.description = description
        self.status = status
        self.childToolCalls = childToolCalls
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var childToolUseCount: Int {
        childToolCalls.filter { $0.kind == .use }.count
    }
}

/// A subagent's completion, parsed from a `<task-notification>` and keyed by the
/// parent spawn block's toolUseID. Merged into the matching `SubagentActivity` so the
/// inline card shows the final status instead of leaving an orphan system bubble.
struct SubagentCompletion: Equatable, Sendable {
    let status: SubagentActivity.Status
    let summary: String?
}

/// Recognizes the tool the CLI uses to spawn a subagent and extracts its type and
/// description. Real payloads name the tool `Agent`; older code matched only `Task`,
/// so both are accepted here to keep the subagent card working across CLI versions.
enum SubagentSpawnParser {
    static let spawnToolNames: Set<String> = ["Agent", "Task"]

    static func isSpawnTool(_ toolName: String?) -> Bool {
        guard let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return spawnToolNames.contains(toolName)
    }

    /// Returns `nil` when the payload carries neither a `subagent_type` nor a
    /// description/prompt, so a mislabeled tool falls back to the generic card.
    static func parse(inputJSON: String) -> (subagentType: String, description: String)? {
        let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let data = trimmed.data(using: .utf8),
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
        var subagentType = ""
        var description = ""
        for object in candidates {
            if
                subagentType.isEmpty,
                let value = (object["subagent_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty {
                subagentType = value
            }
            if description.isEmpty {
                for key in ["description", "prompt"] {
                    if
                        let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !value.isEmpty {
                        description = value
                        break
                    }
                }
            }
        }
        guard !subagentType.isEmpty || !description.isEmpty else {
            return nil
        }
        return (subagentType.isEmpty ? "Subagent" : subagentType, description)
    }
}

/// Parsed `<agentId>.meta.json` companion for a persisted subagent transcript.
/// `toolUseID` links the subagent file back to the parent spawn block in the main
/// transcript, which is the reliable anchor for attribution.
struct SubagentMeta: Equatable, Sendable {
    let agentID: String
    let agentType: String
    let description: String
    let toolUseID: String
    let spawnDepth: Int

    static func parse(agentID: String, metaJSON: String) -> SubagentMeta? {
        guard
            let data = metaJSON.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        let toolUseID = (object["toolUseId"] as? String ?? object["toolUseID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !toolUseID.isEmpty else {
            return nil
        }
        let agentType = (object["agentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let spawnDepth = (object["spawnDepth"] as? Int) ?? 1
        return SubagentMeta(
            agentID: agentID,
            agentType: agentType,
            description: description,
            toolUseID: toolUseID,
            spawnDepth: spawnDepth
        )
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
        if SubagentSpawnParser.isSpawnTool(toolName), let subagentName = taskSubagentType(in: content) {
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
    case subagent(SubagentActivity)
    case tool(TranscriptToolItem)
    case toolRun([TranscriptToolItem])

    var id: String {
        switch self {
        case .message(let message): message.id
        case .interaction(let permission): "interaction_\(permission.id)"
        case .question(let question): question.id
        case .todo(let item): item.id
        case .subagent(let activity): "subagent_\(activity.id)"
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
             .todo,
             .subagent:
            return .collapsed
        }
    }
}

enum TranscriptDisplayBuilder {
    static func displayItems(
        messages: [ChatMessage],
        pendingPermissions: [PermissionRequest] = [],
        subagentActivities: [String: SubagentActivity] = [:]
    ) -> [TranscriptDisplayItem] {
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
        let subagentToolUseIDs = Set(rawItems.compactMap { item -> String? in
            guard case .subagent(let activity) = item else {
                return nil
            }
            return activity.id
        })
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
            case .subagent(let activity):
                // A spawn card is standalone like .todo/.question — it must never be
                // swept into an adjacent tool run. Enrich it below with the built activity.
                output.append(.subagent(enrichedActivity(activity, using: subagentActivities)))
                index += 1
            case .tool(let first):
                if first.kind == .result, first.toolUseID.map(subagentToolUseIDs.contains) == true {
                    index += 1
                    continue
                }
                var run = [first]
                index += 1
                while index < rawItems.count {
                    guard case .tool(let next) = rawItems[index] else {
                        break
                    }
                    if next.kind == .result, next.toolUseID.map(subagentToolUseIDs.contains) == true {
                        index += 1
                        continue
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

    /// Replaces the empty spawn shell produced by `items(for:)` with the fully built
    /// activity (children, status, summary) when the builder has one for this
    /// toolUseID; otherwise keeps the shell so the card still renders while running.
    private static func enrichedActivity(
        _ shell: SubagentActivity,
        using activities: [String: SubagentActivity]
    ) -> SubagentActivity {
        activities[shell.id] ?? shell
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
                } else if SubagentSpawnParser.isSpawnTool(toolName), let parsed = SubagentSpawnParser.parse(inputJSON: block.inputJSON ?? "") {
                    // A spawn tool becomes a `.subagent` shell keyed by its toolUseID.
                    // Children/status are empty here — displayItems enriches the shell
                    // from the session's built SubagentActivity in a post-pass, since
                    // this per-message step cannot see cross-message sidechain records.
                    output.append(.subagent(SubagentActivity(
                        id: toolUseID,
                        subagentType: parsed.subagentType,
                        description: parsed.description,
                        startedAt: message.timestamp
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
    case subagent(SubagentActivity)
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
                 .subagent,
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

/// Builds the session's `SubagentActivity` list by joining three sources on the
/// parent spawn block's toolUseID: the main transcript's spawn blocks (the
/// authoritative list — one card per spawn), the subagent's own sidechain messages
/// (live-routed or history-loaded, grouped by agentID → toolUseID via metas), and
/// the completion notifications (status + summary). The main transcript is never
/// touched, so subagent-internal tool calls stay out of it.
enum SubagentActivityBuilder {
    /// Extracts terminal status from a single message when it is a task-notification
    /// control event. Live and history paths share this so reload does not leave
    /// subagents stuck on `.running`.
    static func completion(from message: ChatMessage) -> (toolUseID: String, completion: SubagentCompletion)? {
        guard
            let block = message.blocks.first,
            let rawType = block.rawType,
            rawType == ClaudeControlTranscriptEvent.Kind.taskNotification.rawValue
            || rawType == ClaudeControlTranscriptEvent.Kind.taskFailure.rawValue,
            let toolUseID = block.toolUseID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !toolUseID.isEmpty
        else {
            return nil
        }
        let status: SubagentActivity.Status =
            rawType == ClaudeControlTranscriptEvent.Kind.taskFailure.rawValue ? .failed : .succeeded
        let summary = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (toolUseID, SubagentCompletion(status: status, summary: summary.isEmpty ? nil : summary))
    }

    /// Rebuilds completions from the main transcript: task-notifications first, then
    /// Agent/Task tool_result blocks as a fallback when the notification was lost.
    static func completions(from messages: [ChatMessage]) -> [String: SubagentCompletion] {
        let spawnIDs = spawnToolUseIDs(in: messages)
        var result: [String: SubagentCompletion] = [:]
        for message in messages {
            if let parsed = completion(from: message) {
                result[parsed.toolUseID] = parsed.completion
                continue
            }
            applyToolResultFallback(message: message, spawnIDs: spawnIDs, into: &result)
        }
        return result
    }

    static func activities(
        mainMessages: [ChatMessage],
        sidechainMessages: [ChatMessage],
        metas: [SubagentMeta],
        agentLinks: [String: String] = [:],
        childCallsByAgentID: [String: [TranscriptToolItem]],
        completions: [String: SubagentCompletion]
    ) -> [SubagentActivity] {
        var shells = spawnShells(from: mainMessages)
        let indexByToolUseID = Dictionary(uniqueKeysWithValues: shells.enumerated().map { ($0.element.id, $0.offset) })
        let toolUseIDByAgentID = attributeAgentIDs(
            shells: &shells,
            indexByToolUseID: indexByToolUseID,
            metas: metas,
            agentLinks: agentLinks,
            mainMessages: mainMessages
        )
        attachChildToolCalls(
            shells: &shells,
            indexByToolUseID: indexByToolUseID,
            toolUseIDByAgentID: toolUseIDByAgentID,
            sidechainMessages: sidechainMessages,
            childCallsByAgentID: childCallsByAgentID
        )
        applyCompletions(
            shells: &shells,
            indexByToolUseID: indexByToolUseID,
            mainMessages: mainMessages,
            liveCompletions: completions
        )
        return shells
    }

    // MARK: - Private helpers

    private static func spawnToolUseIDs(in messages: [ChatMessage]) -> Set<String> {
        var spawnIDs = Set<String>()
        for message in messages {
            for block in message.blocks where block.kind == .toolUse && SubagentSpawnParser.isSpawnTool(block.toolName) {
                spawnIDs.insert(block.toolUseID ?? block.id)
            }
        }
        return spawnIDs
    }

    private static func applyToolResultFallback(
        message: ChatMessage,
        spawnIDs: Set<String>,
        into result: inout [String: SubagentCompletion]
    ) {
        for block in message.blocks where block.kind == .toolResult {
            guard
                let toolUseID = block.toolUseID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !toolUseID.isEmpty,
                spawnIDs.contains(toolUseID),
                result[toolUseID] == nil
            else {
                continue
            }
            let summary = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result[toolUseID] = SubagentCompletion(
                status: block.isError ? .failed : .succeeded,
                summary: summary.isEmpty ? nil : String(summary.prefix(240))
            )
        }
    }

    private static func spawnShells(from mainMessages: [ChatMessage]) -> [SubagentActivity] {
        var shells: [SubagentActivity] = []
        var seen = Set<String>()
        for message in mainMessages {
            for block in message.blocks where block.kind == .toolUse && SubagentSpawnParser.isSpawnTool(block.toolName) {
                let toolUseID = block.toolUseID ?? block.id
                guard seen.insert(toolUseID).inserted else {
                    continue
                }
                let parsed = SubagentSpawnParser.parse(inputJSON: block.inputJSON ?? "")
                shells.append(SubagentActivity(
                    id: toolUseID,
                    subagentType: parsed?.subagentType ?? "Subagent",
                    description: parsed?.description ?? "",
                    startedAt: message.timestamp
                ))
            }
        }
        return shells
    }

    private static func attributeAgentIDs(
        shells: inout [SubagentActivity],
        indexByToolUseID: [String: Int],
        metas: [SubagentMeta],
        agentLinks: [String: String],
        mainMessages: [ChatMessage]
    ) -> [String: String] {
        var toolUseIDByAgentID: [String: String] = [:]
        for meta in metas {
            guard let idx = indexByToolUseID[meta.toolUseID] else {
                continue
            }
            toolUseIDByAgentID[meta.agentID] = meta.toolUseID
            if shells[idx].agentID == nil {
                shells[idx].agentID = meta.agentID
            }
            if shells[idx].subagentType == "Subagent", !meta.agentType.isEmpty {
                shells[idx].subagentType = meta.agentType
            }
            if shells[idx].description.isEmpty, !meta.description.isEmpty {
                shells[idx].description = meta.description
            }
        }
        for (agentID, toolUseID) in agentLinks {
            guard let idx = indexByToolUseID[toolUseID] else {
                continue
            }
            if toolUseIDByAgentID[agentID] == nil {
                toolUseIDByAgentID[agentID] = toolUseID
            }
            if shells[idx].agentID == nil {
                shells[idx].agentID = agentID
            }
        }
        for message in mainMessages {
            guard
                let parsed = completion(from: message),
                let agentID = message.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !agentID.isEmpty,
                let idx = indexByToolUseID[parsed.toolUseID]
            else {
                continue
            }
            if toolUseIDByAgentID[agentID] == nil {
                toolUseIDByAgentID[agentID] = parsed.toolUseID
            }
            if shells[idx].agentID == nil {
                shells[idx].agentID = agentID
            }
        }
        return toolUseIDByAgentID
    }

    private static func attachChildToolCalls(
        shells: inout [SubagentActivity],
        indexByToolUseID: [String: Int],
        toolUseIDByAgentID: [String: String],
        sidechainMessages: [ChatMessage],
        childCallsByAgentID: [String: [TranscriptToolItem]]
    ) {
        var messagesByAgentID: [String: [ChatMessage]] = [:]
        for message in sidechainMessages {
            guard let agentID = message.agentID, !agentID.isEmpty else {
                continue
            }
            messagesByAgentID[agentID, default: []].append(message)
        }
        for (agentID, group) in messagesByAgentID {
            guard let toolUseID = toolUseIDByAgentID[agentID], let idx = indexByToolUseID[toolUseID] else {
                continue
            }
            let toolItems = TranscriptDisplayBuilder.displayItems(messages: group).flatMap { item -> [TranscriptToolItem] in
                switch item {
                case .tool(let tool): [tool]
                case .toolRun(let tools): tools
                default: []
                }
            }
            shells[idx].childToolCalls.append(contentsOf: toolItems)
            if shells[idx].agentID == nil {
                shells[idx].agentID = agentID
            }
        }
        for (agentID, calls) in childCallsByAgentID {
            guard let toolUseID = toolUseIDByAgentID[agentID], let idx = indexByToolUseID[toolUseID] else {
                continue
            }
            shells[idx].childToolCalls.append(contentsOf: calls)
        }
        // Live sidechain + on-demand history load can both contribute the same child;
        // keep the first occurrence so the tool badge does not double-count.
        for index in shells.indices {
            var seen = Set<String>()
            shells[index].childToolCalls = shells[index].childToolCalls.filter { seen.insert($0.id).inserted }
        }
    }

    private static func applyCompletions(
        shells: inout [SubagentActivity],
        indexByToolUseID: [String: Int],
        mainMessages: [ChatMessage],
        liveCompletions: [String: SubagentCompletion]
    ) {
        // Transcript-derived completions fill history/reload; explicit live completions win.
        var merged = completions(from: mainMessages)
        for (toolUseID, completion) in liveCompletions {
            merged[toolUseID] = completion
        }
        for (toolUseID, completion) in merged {
            guard let idx = indexByToolUseID[toolUseID] else {
                continue
            }
            shells[idx].status = completion.status
            if let summary = completion.summary, !summary.isEmpty {
                shells[idx].summary = summary
            }
            if shells[idx].finishedAt == nil {
                shells[idx].finishedAt = Date()
            }
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
