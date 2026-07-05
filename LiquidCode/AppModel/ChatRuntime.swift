import AppKit
import Foundation

extension AppModel {
    private func finishTurn(sessionID: String, shouldDrainQueue: Bool) {
        activeTurnSnapshots.removeValue(forKey: sessionID)
        guard shouldDrainQueue, let queued = pendingUserMessagesBySession[sessionID], !queued.isEmpty else {
            return
        }
        pendingUserMessagesBySession[sessionID] = []
        let merged = queued.map(\.content).joined(separator: "\n\n")
        let mergedAttachments = queued.flatMap(\.attachments)
        let previousSelection = selectedSessionID
        selectedSessionID = sessionID
        send(merged, attachments: mergedAttachments)
        selectedSessionID = previousSelection
    }

    private func restoreActiveTurnToDraft(sessionID: String) {
        let stopped = activeTurnSnapshots.removeValue(forKey: sessionID)
        let queued = pendingUserMessagesBySession.removeValue(forKey: sessionID) ?? []
        let existingDraft = sessionID == selectedSessionID ? composerText : composerTextBySession[sessionID] ?? ""
        let parts = ([stopped?.content, existingDraft] + queued.map(\.content)).compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            setComposerText(parts.joined(separator: "\n\n"), for: sessionID)
        }
        let restoredAttachments = (stopped?.attachments ?? []) + (sessionID == selectedSessionID ? attachments : attachmentsBySession[sessionID] ?? []) + queued
            .flatMap(\.attachments)
        setAttachments(restoredAttachments, for: sessionID)
        if let stopped {
            messagesBySession[sessionID]?.removeAll { $0.id == stopped.messageID }
        }
    }

    func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Auto-create session if none selected
        if selectedSessionID == nil {
            let hasExplicitWorkingDirectory = !workingDirectory.isEmpty
            let projectDir = hasExplicitWorkingDirectory
                ? workingDirectory
                : FileManager.default.homeDirectoryForCurrentUser.path
            let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
            let session = SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: L("New chat"), cliResumeID: nil, isDraft: true)
            sessions.insert(session, at: 0)
            messagesBySession[id] = []
            selectedSessionID = id
            composerTextBySession[id] = ""
            attachmentsBySession[id] = []
            workingDirectory = projectDir
            resetWorkspaceChangeState()
            fileSystem.registerWorkspace(projectDir)
            if hasExplicitWorkingDirectory {
                rememberProject(projectDir)
            }
            startWatchingWorkspace()
            reloadFileTree()
            reloadMCPAndSkills()
        }

        guard let id = selectedSessionID else { return }
        let currentAttachments = attachments
        setComposerText("", for: id)
        setAttachments([], for: id)
        if hasActiveTurn(for: id) {
            pendingUserMessagesBySession[id, default: []].append(PendingUserMessage(content: text, attachments: currentAttachments))
            return
        }
        send(text, attachments: currentAttachments)
    }

    func send(_ text: String, attachments: [AttachmentChip] = []) {
        guard let id = selectedSessionID else {
            newChat(); return
        }
        let session = sessions.first(where: { $0.id == id })
        let fallbackCWD = workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : workingDirectory
        let preferredCWD: String
        if let projectDir = session?.projectDir, !projectDir.isEmpty {
            preferredCWD = projectDir
        } else {
            preferredCWD = fallbackCWD
        }
        guard let cwd = existingDirectoryPath(preferredCWD) ?? existingDirectoryPath(fallbackCWD) else {
            setComposerText(text, for: id)
            setAttachments(attachments, for: id)
            showError("Project unavailable", LF("%@ no longer exists. Reopen the project folder before sending.", preferredCWD))
            return
        }
        do {
            let resolvedModel = try resolvedModelForActiveProvider()
            let configuration = ComposerSendConfiguration(model: resolvedModel, mode: settings.sessionMode, thinkingLevel: settings.thinkingLevel)
            let payload = composerPayloadText(text, attachments: attachments)
            let message = ChatMessage(role: .user, content: text, attachments: attachments)
            messagesBySession[id, default: []].append(message)
            activeTurnSnapshots[id] = ActiveTurnSnapshot(messageID: message.id, content: text, attachments: attachments)
            if toolCallsBySession[id] == nil {
                toolCallsBySession[id] = []
            }
            if streamingTextBySession[id] == nil {
                streamingTextBySession[id] = ""
            }
            if shouldStartSession(session, sessionID: id, configuration: configuration) {
                fileSystem.registerWorkspace(cwd)
                try engine.startSession(ClaudeSessionStartRequest(
                    prompt: payload,
                    cwd: cwd,
                    model: resolvedModel,
                    sessionID: id,
                    resumeSessionID: session?.cliResumeID,
                    thinkingLevel: configuration.thinkingLevel,
                    mode: configuration.mode,
                    provider: activeProvider,
                    providerAPIKey: activeProviderID.flatMap { providerVault.apiKey(providerID: $0) }
                ), eventSink: { [weak self] event in Task { @MainActor in self?.handle(event) } })
            } else {
                try engine.sendMessage(sessionID: id, text: payload)
            }
            sendConfigurationBySession[id] = configuration
        } catch {
            activeTurnSnapshots.removeValue(forKey: id)
            setComposerText(text, for: id)
            setAttachments(attachments, for: id)
            showError("Failed to send", error.localizedDescription)
        }
    }

    private func shouldStartSession(_ session: SessionRecord?, sessionID: String, configuration: ComposerSendConfiguration) -> Bool {
        guard let session, !session.isDraft, session.path != nil else {
            return true
        }
        guard engine.isSessionRunning(sessionID: sessionID) else {
            return true
        }
        guard let previous = sendConfigurationBySession[sessionID] else {
            return true
        }
        return previous != configuration
    }

    func interrupt() {
        guard let id = selectedSessionID else {
            return
        }
        do { try engine.interrupt(sessionID: id) } catch { showError("Failed to interrupt", error.localizedDescription) }
    }

    func respondPermission(_ permission: PermissionRequest, allow: Bool, editedInput: String? = nil) {
        do {
            try engine.respondPermission(permission, allow: allow, updatedInputJSON: editedInput, message: allow ? nil : L("User denied this operation"))
            pendingPermissions.removeAll { $0.id == permission.id }
            let state = allow ? L("Allowed") : L("Denied")
            appendMessage(ChatMessage(role: .system, content: "\(state) \(permission.toolName): \(permission.summary)"), sessionID: permission.sessionID)
        } catch { showError("Permission response failed", error.localizedDescription) }
    }

    func handle(_ event: ClaudeEvent) {
        switch event {
        case .sessionStarted(let sessionID, let cliID):
            if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
                if let cliID, !cliID.hasPrefix("desk_") {
                    sessionIndex.trackSession(cliID, projectDir: sessions[idx].projectDir)
                }
                sessions[idx].cliResumeID = cliID ?? sessions[idx].cliResumeID
                sessions[idx].isDraft = false
            }
        case .textDelta(let sessionID, let text):
            streamingTextBySession[sessionID, default: ""] += text
        case .message(let sessionID, let message):
            if message.role == .user, let checkpoint = message.checkpointUuid {
                backfillCheckpoint(checkpoint, echo: message, sessionID: sessionID)
                return
            }
            if !streamingTextBySession[sessionID, default: ""].isEmpty, message.role == .assistant {
                streamingTextBySession[sessionID] = ""
            }
            appendMessage(message, sessionID: sessionID)
        case .toolStarted(let sessionID, let tool),
             .toolUpdated(let sessionID, let tool):
            upsertTool(tool, sessionID: sessionID)
        case .permissionRequested(let permission):
            pendingPermissions.append(permission)
            var tool = ToolCall(
                id: permission.toolUseID ?? permission.requestID,
                sessionID: permission.sessionID,
                name: permission.toolName,
                inputPreview: permission.inputJSON,
                status: .waitingForPermission,
                parentID: permission.parentToolUseID
            )
            tool.resultPreview = permission.summary
            upsertTool(tool, sessionID: permission.sessionID)
        case .turnCompleted(let sessionID):
            if let text = streamingTextBySession[sessionID], !text.isEmpty {
                appendMessage(ChatMessage(role: .assistant, content: text), sessionID: sessionID)
                streamingTextBySession[sessionID] = ""
            }
            finishTurn(sessionID: sessionID, shouldDrainQueue: true)
            reloadSessions()
        case .stderr(let sessionID, let text):
            if text.lowercased().contains("error") {
                appendMessage(ChatMessage(role: .error, content: text), sessionID: sessionID)
            }
        case .exited(let sessionID):
            if let text = streamingTextBySession[sessionID], !text.isEmpty {
                appendMessage(ChatMessage(role: .assistant, content: text), sessionID: sessionID)
                streamingTextBySession[sessionID] = ""
            }
            restoreActiveTurnToDraft(sessionID: sessionID)
            reloadSessions()
        case .failed(let sessionID, let text):
            appendMessage(ChatMessage(role: .error, content: text), sessionID: sessionID)
            restoreActiveTurnToDraft(sessionID: sessionID)
        }
    }

    private func backfillCheckpoint(_ checkpoint: String, echo: ChatMessage, sessionID: String) {
        var messages = messagesBySession[sessionID] ?? []
        if let idx = messages.indices.reversed().first(where: { messages[$0].role == .user && messages[$0].checkpointUuid == nil }) {
            messages[idx].checkpointUuid = checkpoint
            messagesBySession[sessionID] = messages
        } else if !messages.contains(where: { $0.id == echo.id }) {
            messagesBySession[sessionID, default: []].append(echo)
        }
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].lastCheckpointUUID = checkpoint
        }
    }

    func startWatchingWorkspace() {
        guard !workingDirectory.isEmpty else {
            return
        }
        guard let root = existingDirectoryPath(workingDirectory) else {
            directoryWatcher.unwatchAll()
            fileTree = []
            toastWarning("Project unavailable", LF("%@ no longer exists. File watching is paused.", workingDirectory))
            return
        }
        workingDirectory = root
        do {
            directoryWatcher.unwatchAll()
            try directoryWatcher.watchDirectory(root) { [weak self] paths in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    for path in paths {
                        self.changedFiles.insert(path)
                        self.fileChangeBadges[path] = self.fileChangeBadges[path] ?? "M"
                    }
                    self.reloadFileTree()
                }
            }
        } catch { showError("Watch failed", error.localizedDescription) }
    }

    func resetWorkspaceChangeState() {
        changedFiles.removeAll()
        fileChangeBadges.removeAll()
    }

    private func appendMessage(_ message: ChatMessage, sessionID: String) {
        messagesBySession[sessionID, default: []].append(message)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].preview = String(message.content.prefix(120))
            sessions[idx].modifiedAt = Date()
        }
    }

    private func upsertTool(_ tool: ToolCall, sessionID: String) {
        var tools = toolCallsBySession[sessionID] ?? []
        if let idx = tools.firstIndex(where: { $0.id == tool.id }) {
            var merged = tool
            let existing = tools[idx]
            if merged.name == "Tool", existing.name != "Tool" {
                merged.name = existing.name
            }
            if merged.inputPreview.isEmpty {
                merged.inputPreview = existing.inputPreview
            }
            if merged.resultPreview.isEmpty {
                merged.resultPreview = existing.resultPreview
            }
            merged.startedAt = existing.startedAt
            if merged.parentID == nil {
                merged.parentID = existing.parentID
            }
            tools[idx] = merged
        } else {
            tools.append(tool)
        }
        toolCallsBySession[sessionID] = tools
    }
}
