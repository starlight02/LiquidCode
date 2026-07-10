import AppKit
import Foundation

extension AppModel {
    func requestRewindToLastUserMessage() {
        performRewind(.restoreAll)
    }

    func performRewind(_ action: RewindAction) {
        guard
            let id = selectedSessionID,
            let turn = lastUserMessage(in: id) else {
            showError("Rewind unavailable", "No user turn is available to rewind.")
            return
        }
        performRewind(toMessageID: turn.id, action: action)
    }

    /// Rewinds to a specific user turn (timeline / bubble entry points).
    func performRewind(toMessageID messageID: String, action: RewindAction) {
        guard
            let id = selectedSessionID,
            let session = sessions.first(where: { $0.id == id }),
            let turn = (messagesBySession[id] ?? []).first(where: { $0.id == messageID && $0.role == .user }) else {
            showError("Rewind unavailable", "That user turn is no longer available.")
            return
        }

        switch action {
        case .restoreAll:
            guard
                confirmDestructiveRewind(
                    title: L("Restore conversation and files?"),
                    message: L("Messages after this turn will be removed and workspace files will be restored to the Claude checkpoint. This cannot be undone.")
                ) else {
                return
            }
            guard let output = restoreCodeToCheckpoint(session: session, turn: turn) else {
                return
            }
            rewindConversation(sessionID: id, toMessageID: turn.id)
            toastInfo("Rewind restored", output.isEmpty ? "Conversation and files restored to the selected user turn." : output)
        case .restoreCode:
            guard let output = restoreCodeToCheckpoint(session: session, turn: turn) else {
                return
            }
            toastInfo("Code restored", output.isEmpty ? "Files restored to the selected Claude checkpoint." : output)
        case .restoreConversation:
            guard
                confirmDestructiveRewind(
                    title: L("Restore conversation?"),
                    message: L("Messages after this turn will be removed. Code files will not be changed.")
                ) else {
                return
            }
            rewindConversation(sessionID: id, toMessageID: turn.id)
            toastInfo("Conversation restored", "Messages after the selected user turn were removed; code files were left unchanged.")
        case .summarize:
            setComposerText("/compact Summarize the conversation from this point and preserve open tasks.")
            toastInfo("Summary command ready", "Review and send the /compact command when ready.")
        }
    }

    /// Conversation-only fork: new desk draft with messages up to the chosen user turn.
    /// Does not copy `cliResumeID` (CLI fork is unstable / out of scope for v1).
    /// The forked transcript is UI-only — the next send starts a fresh Claude session without history.
    func forkSession(fromMessageID messageID: String) {
        guard
            let sourceID = selectedSessionID,
            let source = sessions.first(where: { $0.id == sourceID }) else {
            showError("Fork unavailable", "No session is selected.")
            return
        }
        let sourceMessages = messagesBySession[sourceID] ?? []
        guard let index = sourceMessages.firstIndex(where: { $0.id == messageID && $0.role == .user }) else {
            showError("Fork unavailable", "That user turn is no longer available.")
            return
        }

        let forkedMessages = Array(sourceMessages.prefix(index + 1))
        let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
        let preview = forkedMessages.last?.transcriptPreview ?? L("Forked chat")
        var session = SessionRecord(
            id: id,
            path: nil,
            project: source.project,
            projectDir: source.projectDir,
            modifiedAt: Date(),
            preview: preview,
            cliResumeID: nil,
            isDraft: true
        )
        session.createdAt = Date()
        // Keep last known checkpoint metadata for display only; code restore needs a live CLI session.
        session.lastCheckpointUUID = forkedMessages.last(where: { $0.checkpointUuid != nil })?.checkpointUuid

        snapshotComposerState(for: selectedSessionID)
        snapshotComposerConfiguration(for: selectedSessionID)
        sessions.insert(session, at: 0)
        setMessages(forkedMessages, for: id)
        selectedSessionID = id
        composerTextBySession[id] = ""
        attachmentsBySession[id] = []
        restoreComposerState(for: id)
        restoreComposerConfiguration(for: id)
        if workingDirectory != source.projectDir {
            workingDirectory = source.projectDir
            fileSystem.registerWorkspace(source.projectDir)
            startWatchingWorkspaceDeferred()
            refreshGitBranch()
            reloadFileTreeDeferred()
        }
        saveSessionMeta()
        toastWarning(
            "Forked session",
            "UI-only branch with the selected history. The next message starts a fresh Claude session without that context."
        )
        openCheckpointTimeline(messageID: messageID)
    }

    func lastUserMessage(in sessionID: String) -> ChatMessage? {
        (messagesBySession[sessionID] ?? []).last { $0.role == .user }
    }

    private func confirmDestructiveRewind(title: String, message: String) -> Bool {
        // XCTest has no interactive alert session; auto-confirm so rewind logic stays unit-testable.
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Restore"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Restores files only when the selected turn itself carries a Claude checkpoint UUID.
    /// Does not fall back to `session.lastCheckpointUUID` (that can be newer than the turn).
    private func restoreCodeToCheckpoint(session: SessionRecord, turn: ChatMessage) -> String? {
        guard let checkpoint = turn.checkpointUuid, !checkpoint.isEmpty else {
            showError("Rewind unavailable", "This turn has no Claude checkpoint UUID for file restore.")
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
        setMessages(Array((messagesBySession[sessionID] ?? []).prefix(index + 1)), for: sessionID)
        streamingTextBySession[sessionID] = ""
        streamingMessagesBySession.removeValue(forKey: sessionID)
        pendingUserMessagesBySession[sessionID] = []
        persistComposerDraftsSoon()
        pendingPermissions.removeAll { $0.sessionID == sessionID }
        permissionRulesBySession.removeValue(forKey: sessionID)
        toolCallsBySession[sessionID] = []
        activeTurnSnapshots.removeValue(forKey: sessionID)
        turnPhaseBySession.removeValue(forKey: sessionID)
        usageBySession.removeValue(forKey: sessionID)
        engine.kill(sessionID: sessionID)
        if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[sessionIndex].preview = messagesBySession[sessionID]?.last?.transcriptPreview ?? sessions[sessionIndex].preview
            sessions[sessionIndex].modifiedAt = Date()
            sessions[sessionIndex].isDraft = false
        }
        resetChatFindIndex()
        saveSessionMeta()
    }
}
