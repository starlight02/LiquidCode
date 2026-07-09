import AppKit
import Foundation

extension AppModel {
    var selectedSession: SessionRecord? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selectedMessages: [ChatMessage] {
        messagesBySession[selectedSessionID ?? ""] ?? []
    }

    var isLoadingSelectedMessages: Bool {
        guard let selectedSessionID else {
            return false
        }
        return loadingMessageSessionIDs.contains(selectedSessionID) && messagesBySession[selectedSessionID] == nil
    }

    var selectedTranscriptDisplayItems: [TranscriptDisplayItem] {
        guard let selectedSessionID else {
            return []
        }
        let pending = pendingPermissionsForSelectedSession
        if pending.isEmpty, let cached = displayItemsBySession[selectedSessionID] {
            return cached
        }
        return TranscriptDisplayBuilder.displayItems(
            messages: selectedMessages,
            pendingPermissions: pending,
            subagentActivities: subagentActivityMap(for: selectedSessionID)
        )
    }

    /// Keys the session's built subagent activities by their spawn toolUseID so the
    /// display builder can enrich each `.subagent` shell with its children and status.
    func subagentActivityMap(for sessionID: String) -> [String: SubagentActivity] {
        guard let activities = subagentActivitiesBySession[sessionID] else {
            return [:]
        }
        return Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var selectedStreamingMessage: ChatMessage? {
        guard let selectedSessionID else {
            return nil
        }
        if let message = streamingMessagesBySession[selectedSessionID] {
            return message
        }
        guard let text = streamingTextBySession[selectedSessionID], !text.isEmpty else {
            return nil
        }
        return ChatMessage(role: .assistant, content: text)
    }

    var selectedStreamingText: String {
        guard let selectedSessionID else {
            return ""
        }
        if let message = streamingMessagesBySession[selectedSessionID] {
            let preview = message.transcriptPreview
            if !preview.isEmpty {
                return preview
            }
            if !message.blocks.isEmpty {
                return message.blocks.map { "\($0.kind.rawValue):\($0.text)\($0.inputJSON ?? "")" }.joined(separator: "|")
            }
        }
        return streamingTextBySession[selectedSessionID] ?? ""
    }

    var selectedToolCalls: [ToolCall] {
        toolCallsBySession[selectedSessionID ?? ""] ?? []
    }

    var selectedSubagentActivities: [SubagentActivity] {
        subagentActivitiesBySession[selectedSessionID ?? ""] ?? []
    }

    var selectedTurnPhase: TurnPhase? {
        turnPhaseBySession[selectedSessionID ?? ""]
    }

    var selectedTodoState: SessionTodoState? {
        guard let selectedSessionID else {
            return nil
        }
        return todosBySession[selectedSessionID]
    }

    var activeProvider: ProviderRecord? {
        nil
    }

    var hasActiveTurn: Bool {
        !pendingPermissions.isEmpty ||
            streamingTextBySession.values.contains { !$0.isEmpty } ||
            streamingMessagesBySession.values.contains { !$0.blocks.isEmpty || !$0.content.isEmpty || !$0.displayImages.isEmpty } ||
            !activeTurnSnapshots.isEmpty
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

    func hasActiveTurn(for sessionID: String) -> Bool {
        pendingPermissions.contains { $0.sessionID == sessionID } ||
            !(streamingTextBySession[sessionID] ?? "").isEmpty ||
            streamingMessagesBySession[sessionID] != nil ||
            activeTurnSnapshots[sessionID] != nil
    }

    var activeSessionIDs: Set<String> {
        var ids = Set(activeTurnSnapshots.keys)
        ids.formUnion(streamingMessagesBySession.keys)
        ids.formUnion(streamingTextBySession.compactMap { id, text in text.isEmpty ? nil : id })
        ids.formUnion(pendingPermissions.map(\.sessionID))
        return ids
    }

    func rebuildTranscriptDisplayItems(sessionID: String) {
        let messages = messagesBySession[sessionID] ?? []
        displayItemsBySession[sessionID] = TranscriptDisplayBuilder.displayItems(
            messages: messages,
            subagentActivities: subagentActivityMap(for: sessionID)
        )
        refreshTodoState(sessionID: sessionID, messages: messages)
    }

    func setMessages(_ messages: [ChatMessage], for sessionID: String, displayItems: [TranscriptDisplayItem]? = nil) {
        messagesBySession[sessionID] = messages
        displayItemsBySession[sessionID] = displayItems ?? TranscriptDisplayBuilder.displayItems(
            messages: messages,
            subagentActivities: subagentActivityMap(for: sessionID)
        )
        refreshTodoState(sessionID: sessionID, messages: messages)
    }

    /// Recomputes the session's current TodoWrite checklist from message history so
    /// reloads and live appends stay in sync without depending on streaming alone.
    func refreshTodoState(sessionID: String, messages: [ChatMessage]? = nil) {
        let source = messages ?? messagesBySession[sessionID] ?? []
        if let state = SessionTodoStateBuilder.latest(from: source) {
            todosBySession[sessionID] = state
        } else {
            todosBySession.removeValue(forKey: sessionID)
        }
    }
}
