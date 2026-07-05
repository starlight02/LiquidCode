import AppKit
import Foundation

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
}
