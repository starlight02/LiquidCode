import AppKit
import Foundation

extension AppModel {
    func togglePin(_ session: SessionRecord) {
        mutateSession(session.id) { $0.pinned.toggle() }
    }

    func toggleArchive(_ session: SessionRecord) {
        mutateSession(session.id) { $0.archived.toggle() }
    }

    func rename(_ session: SessionRecord, to title: String) {
        mutateSession(session.id) { $0.customTitle = title }
    }

    func toggleSessionSelection(_ session: SessionRecord) {
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
        sessionSelectionMode = !selectedSessionIDs.isEmpty
    }

    func clearSessionSelection() {
        selectedSessionIDs.removeAll()
        sessionSelectionMode = false
    }

    func toggleSessionSelectionMode() {
        sessionSelectionMode.toggle()
        if !sessionSelectionMode {
            selectedSessionIDs.removeAll()
        }
    }

    func archiveSelectedSessions() {
        for id in selectedSessionIDs {
            mutateSession(id) { $0.archived = true }
        }
        toastSuccess("Archived sessions", LF("%d session(s)", selectedSessionIDs.count))
        clearSessionSelection()
    }

    func deleteSelectedSessions() {
        let ids = selectedSessionIDs
        let targets = sessions.filter { ids.contains($0.id) }
        targets.forEach(deleteSession)
        clearSessionSelection()
    }

    func generateSessionTitle(_ session: SessionRecord) {
        let source = (messagesBySession[session.id] ?? []).first { !$0.transcriptPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.transcriptPreview ?? session
            .preview
        let compact = source
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = compact.isEmpty ? L("New Chat") : String(compact.prefix(42))
        mutateSession(session.id) { $0.customTitle = title }
        toastSuccess("Generated title", title)
    }

    func deleteSession(_ session: SessionRecord) {
        engine.kill(sessionID: session.id)
        fileSystem.clearGrants(sessionID: session.id)
        let backupPath = backupSessionForUndo(session)
        recentlyDeletedSession = DeletedSessionSnapshot(
            session: session,
            messages: messagesBySession[session.id] ?? [],
            backupPath: backupPath,
            originalPath: session.path,
            deletedAt: Date()
        )
        do {
            try sessionIndex.deleteSessionRecord(session)
        } catch {
            toastWarning("Claude session delete failed", error.localizedDescription)
        }
        sessions.removeAll { $0.id == session.id }
        messagesBySession.removeValue(forKey: session.id)
        displayItemsBySession.removeValue(forKey: session.id)
        streamingTextBySession.removeValue(forKey: session.id)
        streamingMessagesBySession.removeValue(forKey: session.id)
        toolCallsBySession.removeValue(forKey: session.id)
        pendingPermissions.removeAll { $0.sessionID == session.id }
        permissionRulesBySession.removeValue(forKey: session.id)
        composerTextBySession.removeValue(forKey: session.id)
        attachmentsBySession.removeValue(forKey: session.id)
        pendingUserMessagesBySession.removeValue(forKey: session.id)
        activeTurnSnapshots.removeValue(forKey: session.id)
        sendConfigurationBySession.removeValue(forKey: session.id)
        selectedSessionIDs.remove(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
        persistSettings()
        saveSessionMeta()
        toastWarning("Deleted session", LF("Undo is available for %@", session.title))
    }

    private func backupSessionForUndo(_ session: SessionRecord) -> String? {
        guard let path = session.path, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let backupDir = AppPaths.shared.appSupport.appendingPathComponent("Trash/Sessions", isDirectory: true)
        let backup = backupDir.appendingPathComponent("\(session.id)-\(Int(Date().timeIntervalSince1970)).jsonl")
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(atPath: path, toPath: backup.path)
            return backup.path
        } catch {
            toastWarning("Undo backup failed", error.localizedDescription)
            return nil
        }
    }

    func undoLastSessionDelete() {
        guard let snapshot = recentlyDeletedSession else {
            return
        }
        if
            let original = snapshot.originalPath, let backup = snapshot.backupPath, FileManager.default.fileExists(atPath: backup),
            !FileManager.default.fileExists(atPath: original) {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: original).deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: backup, toPath: original)
            } catch {
                showError("Undo delete failed", error.localizedDescription)
                return
            }
        }
        if let cliID = snapshot.session.cliResumeID ?? (snapshot.session.id.hasPrefix("desk_") ? nil : snapshot.session.id) {
            sessionIndex.trackSession(cliID, projectDir: snapshot.session.projectDir)
        }
        sessions.insert(snapshot.session, at: 0)
        setMessages(snapshot.messages, for: snapshot.session.id)
        selectedSessionID = snapshot.session.id
        workingDirectory = snapshot.session.projectDir
        recentlyDeletedSession = nil
        saveSessionMeta()
        reloadMCPAndSkills()
        reloadFileTree()
        toastSuccess("Restored session", snapshot.session.title)
    }

    private func mutateSession(_ id: String, _ body: (inout SessionRecord) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        body(&sessions[idx]); saveSessionMeta()
    }
}
