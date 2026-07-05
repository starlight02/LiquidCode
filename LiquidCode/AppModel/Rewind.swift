import AppKit
import Foundation

extension AppModel {
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

    func lastUserMessage(in sessionID: String) -> ChatMessage? {
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
