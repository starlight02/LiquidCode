import AppKit
import Foundation

extension AppModel {
    private func finishTurn(sessionID: String, shouldDrainQueue: Bool) {
        activeTurnSnapshots.removeValue(forKey: sessionID)
        turnPhaseBySession.removeValue(forKey: sessionID)
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
        turnPhaseBySession.removeValue(forKey: sessionID)
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
            rebuildTranscriptDisplayItems(sessionID: sessionID)
        }
    }

    func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        // Auto-create session if none selected
        if selectedSessionID == nil {
            let hasExplicitWorkingDirectory = !workingDirectory.isEmpty
            let projectDir = hasExplicitWorkingDirectory
                ? workingDirectory
                : FileManager.default.homeDirectoryForCurrentUser.path
            let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
            let session = SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: L("New chat"), cliResumeID: nil, isDraft: true)
            sessions.insert(session, at: 0)
            setMessages([], for: id, displayItems: [])
            selectedSessionID = id
            composerTextBySession[id] = ""
            attachmentsBySession[id] = []
            workingDirectory = projectDir
            resetWorkspaceChangeState()
            fileSystem.registerWorkspace(projectDir)
            if hasExplicitWorkingDirectory {
                rememberProject(projectDir)
            }
            startWatchingWorkspaceDeferred()
            reloadFileTreeDeferred()
            reloadMCPAndSkillsDeferred()
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
            let payload = try composerUserMessageContent(text, attachments: attachments)
            let message = ChatMessage(role: .user, content: text, attachments: attachments, images: payload.images)
            messagesBySession[id, default: []].append(message)
            rebuildTranscriptDisplayItems(sessionID: id)
            activeTurnSnapshots[id] = ActiveTurnSnapshot(messageID: message.id, content: text, attachments: attachments)
            if toolCallsBySession[id] == nil {
                toolCallsBySession[id] = []
            }
            if streamingTextBySession[id] == nil {
                streamingTextBySession[id] = ""
            }
            if shouldStartSession(session, sessionID: id, configuration: configuration) {
                // Cold start: the request first has to spawn/connect the Claude Code
                // subprocess, so begin in the connecting phase; `.cliReady` promotes it.
                turnPhaseBySession[id] = .connecting
                fileSystem.registerWorkspace(cwd)
                try engine.startSession(ClaudeSessionStartRequest(
                    prompt: payload.text,
                    content: payload,
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
                // Warm turn: the subprocess is already running, so the model is thinking
                // immediately — no connecting phase.
                turnPhaseBySession[id] = .thinking
                try engine.sendMessage(sessionID: id, content: payload)
            }
            sendConfigurationBySession[id] = configuration
            persistSettings()
        } catch {
            activeTurnSnapshots.removeValue(forKey: id)
            turnPhaseBySession.removeValue(forKey: id)
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

    func respondPermission(_ permission: PermissionRequest, allow: Bool, editedInput: String? = nil, rememberForSession: Bool = false) {
        do {
            try engine.respondPermission(permission, allow: allow, updatedInputJSON: editedInput, message: allow ? nil : L("User denied this operation"))
            pendingPermissions.removeAll { $0.id == permission.id }
            if allow, rememberForSession, let rule = SessionPermissionRemember.makeRule(from: permission) {
                var rules = permissionRulesBySession[permission.sessionID] ?? []
                SessionPermissionRemember.appendRule(rule, to: &rules)
                permissionRulesBySession[permission.sessionID] = rules
                let state = L("Allowed for session")
                appendMessage(ChatMessage(role: .system, content: "\(state) \(permission.toolName): \(permission.summary)"), sessionID: permission.sessionID)
            } else {
                let state = allow ? L("Allowed") : L("Denied")
                appendMessage(ChatMessage(role: .system, content: "\(state) \(permission.toolName): \(permission.summary)"), sessionID: permission.sessionID)
            }
            // After answering, drop waiting phase unless another permission is still open.
            if pendingPermissions.contains(where: { $0.sessionID == permission.sessionID }) {
                turnPhaseBySession[permission.sessionID] = permissionPhase(for: permission.sessionID)
            } else if hasActiveTurn(for: permission.sessionID) {
                turnPhaseBySession[permission.sessionID] = .thinking
            } else {
                turnPhaseBySession.removeValue(forKey: permission.sessionID)
            }
        } catch { showError("Permission response failed", error.localizedDescription) }
    }

    /// Rejects the pending plan and sends the user's revision note back to Claude so it
    /// re-plans. Staying in plan mode keeps the next turn a plan (not an execution). The
    /// note is queued when a turn is already active, mirroring how `sendComposer` defers.
    func submitPlanRevision(_ permission: PermissionRequest, note: String) {
        respondPermission(permission, allow: false)
        setComposerMode(.plan)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = trimmed.isEmpty ? L("Please revise the plan before execution.") : trimmed
        if hasActiveTurn(for: permission.sessionID) {
            pendingUserMessagesBySession[permission.sessionID, default: []].append(PendingUserMessage(content: payload))
        } else {
            send(payload)
        }
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
        case .cliReady(let sessionID):
            // Claude Code has received the request and is now working. Promote the
            // indicator from connecting to thinking (only while still pre-first-token).
            if turnPhaseBySession[sessionID] == .connecting {
                turnPhaseBySession[sessionID] = .thinking
            }
        case .textDelta(let sessionID, let text):
            appendStreamingBlockDelta(sessionID: sessionID, index: nil, kind: .text, text: text)
        case .streamBlockStarted(let sessionID, let index, let block):
            upsertStreamingBlock(sessionID: sessionID, index: index, block: block)
        case .streamBlockDelta(let sessionID, let index, let kind, let text):
            appendStreamingBlockDelta(sessionID: sessionID, index: index, kind: kind, text: text)
        case .message(let sessionID, let message):
            // A task-notification is intercepted into the completion bucket and merged
            // into the matching SubagentActivity card — it never renders as an orphan
            // system/error bubble in the main transcript.
            if let completion = subagentCompletion(from: message) {
                // The completion carries `<task-id>` (== agentId) and `<tool-use-id>`, so
                // it also links sidechain records to the spawn card even when no permission
                // request surfaced the mapping live.
                if let agentID = message.agentID, !agentID.isEmpty {
                    subagentAgentLinksBySession[sessionID, default: [:]][agentID] = completion.toolUseID
                }
                recordSubagentCompletion(completion.toolUseID, completion.completion, sessionID: sessionID)
                return
            }
            // A subagent's own sidechain message routes into the subagent bucket so the
            // main transcript stays clean; its internal tool calls are reconstructed by
            // SubagentActivityBuilder rather than shown inline.
            if let agentID = message.agentID, !agentID.isEmpty {
                appendSubagentMessage(message, sessionID: sessionID)
                return
            }
            if message.role == .user, let checkpoint = message.checkpointUuid {
                backfillCheckpoint(checkpoint, echo: message, sessionID: sessionID)
                return
            }
            if message.role == .assistant || message.role == .error {
                // First visible assistant/error content ends the pre-token thinking phase.
                turnPhaseBySession.removeValue(forKey: sessionID)
                clearStreamingMessage(sessionID: sessionID)
            }
            appendMessage(message, sessionID: sessionID)
        case .toolStarted(let sessionID, let tool),
             .toolUpdated(let sessionID, let tool):
            // Tools are visible activity. Keep a live "tool running" phase so the
            // activity pill can show the tool name; the pre-token thinking indicator
            // stays hidden because streaming/permission gates own that surface.
            if tool.status == .waitingForPermission {
                turnPhaseBySession[sessionID] = .waitingPermission
            } else if tool.status == .streamingInput || tool.status == .running {
                turnPhaseBySession[sessionID] = .toolRunning(name: tool.name)
            } else {
                // Succeeded/failed/denied: prefer waiting on any remaining permission,
                // otherwise stay in a generic thinking phase until turnCompleted.
                if pendingPermissions.contains(where: { $0.sessionID == sessionID }) {
                    turnPhaseBySession[sessionID] = permissionPhase(for: sessionID)
                } else if hasActiveTurn(for: sessionID) {
                    turnPhaseBySession[sessionID] = .thinking
                } else {
                    turnPhaseBySession.removeValue(forKey: sessionID)
                }
            }
            upsertTool(tool, sessionID: sessionID)
        case .permissionRequested(let permission):
            handlePermissionRequested(permission)
        case .turnCompleted(let sessionID):
            flushStreamingMessage(sessionID: sessionID)
            finishTurn(sessionID: sessionID, shouldDrainQueue: true)
            reloadSessions()
        case .stderr(let sessionID, let text):
            if text.lowercased().contains("error") {
                appendMessage(ChatMessage(role: .error, content: text), sessionID: sessionID)
            }
        case .exited(let sessionID):
            flushStreamingMessage(sessionID: sessionID)
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
            setMessages(messages, for: sessionID)
        } else if !messages.contains(where: { $0.id == echo.id }) {
            messagesBySession[sessionID, default: []].append(echo)
            rebuildTranscriptDisplayItems(sessionID: sessionID)
        }
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].lastCheckpointUUID = checkpoint
        }
    }

    func startWatchingWorkspaceDeferred() {
        guard !workingDirectory.isEmpty else {
            cancelDeferredWorkspaceWatch()
            return
        }
        guard let root = existingDirectoryPath(workingDirectory) else {
            cancelDeferredWorkspaceWatch()
            fileTree = []
            toastWarning("Project unavailable", LF("%@ no longer exists. File watching is paused.", workingDirectory))
            return
        }
        workingDirectory = root
        workspaceWatchGeneration &+= 1
        let generation = workspaceWatchGeneration
        let token = DirectoryWatchManager.WatchToken()
        directoryWatcher.requestWatchDirectory(root, token: token)
        workspaceWatchTask?.cancel()
        workspaceWatchTask = Task.detached(priority: .utility) { [weak self, directoryWatcher] in
            guard !Task.isCancelled else {
                directoryWatcher.cancelRequestedWatch(root, token: token)
                return
            }
            do {
                try directoryWatcher.watchRequestedDirectory(root, token: token) { [weak self] paths in
                    Task { @MainActor [weak self] in
                        self?.handleWorkspaceChange(paths, root: root, generation: generation)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else {
                        directoryWatcher.cancelRequestedWatch(root, token: token)
                        return
                    }
                    guard
                        generation == workspaceWatchGeneration,
                        (existingDirectoryPath(workingDirectory) ?? workingDirectory) == root else {
                        directoryWatcher.cancelRequestedWatch(root, token: token)
                        return
                    }
                    self.directoryWatcher.cancelRequestedWatch(root, token: token)
                    showError("Watch failed", error.localizedDescription)
                }
            }
        }
    }

    func cancelDeferredWorkspaceWatch() {
        workspaceWatchGeneration &+= 1
        workspaceWatchTask?.cancel()
        workspaceWatchTask = nil
        directoryWatcher.unwatchAll()
    }

    private func handleWorkspaceChange(_ paths: [String], root: String, generation: Int) {
        guard
            generation == workspaceWatchGeneration,
            (existingDirectoryPath(workingDirectory) ?? workingDirectory) == root else {
            return
        }
        for path in paths {
            changedFiles.insert(path)
            fileChangeBadges[path] = fileChangeBadges[path] ?? "M"
        }
        reloadFileTreeDeferred(debounceNanoseconds: 80_000_000)
    }

    func resetWorkspaceChangeState() {
        changedFiles.removeAll()
        fileChangeBadges.removeAll()
    }

    private func appendMessage(_ message: ChatMessage, sessionID: String) {
        messagesBySession[sessionID, default: []].append(message)
        rebuildTranscriptDisplayItems(sessionID: sessionID)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].preview = String(message.transcriptPreview.prefix(120))
            sessions[idx].modifiedAt = Date()
        }
        // Live assistant records also carry message.model — keep the composer picker honest.
        if let model = message.model, !model.isEmpty, model != "<synthetic>" {
            syncComposerModelFromMessages(messagesBySession[sessionID] ?? [], sessionID: sessionID)
        }
    }

    /// A task-notification message carries the parent spawn block's toolUseID (stamped
    /// onto the first block by the parser). Returns that id plus the parsed completion,
    /// or nil when the message is not a subagent completion.
    private func subagentCompletion(from message: ChatMessage) -> (toolUseID: String, completion: SubagentCompletion)? {
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
        let status: SubagentActivity.Status = rawType == ClaudeControlTranscriptEvent.Kind.taskFailure.rawValue ? .failed : .succeeded
        let summary = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (toolUseID, SubagentCompletion(status: status, summary: summary.isEmpty ? nil : summary))
    }

    private func recordSubagentCompletion(_ toolUseID: String, _ completion: SubagentCompletion, sessionID: String) {
        subagentCompletionsBySession[sessionID, default: [:]][toolUseID] = completion
        rebuildSubagentActivities(sessionID: sessionID)
    }

    /// Records an agentID → parent spawn toolUseID link harvested from a live source
    /// (permission request or completion notification) so routed sidechain records can
    /// attribute to the right card. No-op unless both ids are present.
    private func recordSubagentAgentLink(agentID: String?, toolUseID: String?, sessionID: String) {
        guard
            let agentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines), !agentID.isEmpty,
            let toolUseID = toolUseID?.trimmingCharacters(in: .whitespacesAndNewlines), !toolUseID.isEmpty
        else {
            return
        }
        guard subagentAgentLinksBySession[sessionID]?[agentID] != toolUseID else {
            return
        }
        subagentAgentLinksBySession[sessionID, default: [:]][agentID] = toolUseID
        rebuildSubagentActivities(sessionID: sessionID)
    }

    private func appendSubagentMessage(_ message: ChatMessage, sessionID: String) {
        subagentMessagesBySession[sessionID, default: []].append(message)
        rebuildSubagentActivities(sessionID: sessionID)
    }

    /// Rebuilds the session's `SubagentActivity` list from the main transcript's spawn
    /// blocks, the routed sidechain messages, and the recorded completions, then triggers
    /// a transcript rebuild so the inline `.subagent` cards pick up fresh status/children.
    func rebuildSubagentActivities(sessionID: String) {
        let activities = SubagentActivityBuilder.activities(
            mainMessages: messagesBySession[sessionID] ?? [],
            sidechainMessages: subagentMessagesBySession[sessionID] ?? [],
            metas: subagentMetasBySession[sessionID] ?? [],
            agentLinks: subagentAgentLinksBySession[sessionID] ?? [:],
            childCallsByAgentID: subagentChildCallsByAgentID[sessionID] ?? [:],
            completions: subagentCompletionsBySession[sessionID] ?? [:]
        )
        subagentActivitiesBySession[sessionID] = activities
        rebuildTranscriptDisplayItems(sessionID: sessionID)
    }

    /// Lazily loads a persisted subagent's internal tool calls from its own jsonl
    /// (which can reach ~800KB), reading each file at most once. Called when the user
    /// expands a subagent card or opens the agent inspector, so history sessions build
    /// their shells from lightweight metas up front and only pay the big read on demand.
    func loadSubagentChildCallsIfNeeded(sessionID: String, agentID: String) {
        let trimmed = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, subagentChildCallsByAgentID[sessionID]?[trimmed] == nil else {
            return
        }
        guard let path = sessions.first(where: { $0.id == sessionID })?.path else {
            return
        }
        // Mark as loaded (empty) immediately so a slow or empty read is not retried.
        subagentChildCallsByAgentID[sessionID, default: [:]][trimmed] = []
        let index = sessionIndex
        Task.detached(priority: .userInitiated) {
            let calls = index.loadSubagentChildCalls(mainPath: path, agentID: trimmed)
            guard !calls.isEmpty else {
                return
            }
            await MainActor.run {
                guard self.sessions.contains(where: { $0.id == sessionID && $0.path == path }) else {
                    return
                }
                self.subagentChildCallsByAgentID[sessionID, default: [:]][trimmed] = calls
                self.rebuildSubagentActivities(sessionID: sessionID)
            }
        }
    }

    private func upsertStreamingBlock(sessionID: String, index: Int?, block: ChatContentBlock) {
        // First streamed block is the first visible token — clear the pre-token phase.
        turnPhaseBySession.removeValue(forKey: sessionID)
        var message = streamingMessagesBySession[sessionID] ?? ChatMessage(
            id: "streaming_\(sessionID)",
            role: .assistant,
            content: "",
            blocks: []
        )
        var blocks = message.blocks
        let targetIndex = index ?? blocks.count
        if targetIndex < blocks.count {
            blocks[targetIndex] = mergeStreamingBlock(existing: blocks[targetIndex], incoming: block)
        } else {
            while blocks.count < targetIndex {
                blocks.append(ChatContentBlock(kind: .unknown))
            }
            blocks.append(block)
        }
        message.blocks = blocks
        refreshStreamingContent(&message)
        streamingMessagesBySession[sessionID] = message
        streamingTextBySession[sessionID] = message.content
        upsertStreamingToolIfNeeded(block, sessionID: sessionID)
    }

    private func appendStreamingBlockDelta(sessionID: String, index: Int?, kind: ChatContentBlockKind, text: String) {
        guard !text.isEmpty else {
            return
        }
        // First non-empty delta is the first visible token — clear the pre-token phase.
        turnPhaseBySession.removeValue(forKey: sessionID)
        var message = streamingMessagesBySession[sessionID] ?? ChatMessage(
            id: "streaming_\(sessionID)",
            role: .assistant,
            content: "",
            blocks: []
        )
        var blocks = message.blocks
        let targetIndex: Int
        if let index {
            targetIndex = index
        } else if let existing = blocks.indices.reversed().first(where: { blocks[$0].kind == kind || (kind == .toolUse && blocks[$0].kind == .toolUse) }) {
            targetIndex = existing
        } else {
            targetIndex = blocks.count
        }
        while blocks.count <= targetIndex {
            blocks.append(ChatContentBlock(kind: kind))
        }
        var block = blocks[targetIndex]
        if block.kind == .unknown {
            block.kind = kind
        }
        switch kind {
        case .toolUse:
            block.kind = .toolUse
            block.inputJSON = (block.inputJSON ?? "") + text
        case .image:
            break
        case .toolResult:
            block.kind = .toolResult
            block.text += text
        case .thinking:
            block.kind = .thinking
            block.text += text
        case .text,
             .unknown:
            block.kind = .text
            block.text += text
        }
        blocks[targetIndex] = block
        message.blocks = blocks
        refreshStreamingContent(&message)
        streamingMessagesBySession[sessionID] = message
        streamingTextBySession[sessionID] = message.content
        upsertStreamingToolIfNeeded(block, sessionID: sessionID)
    }

    private func mergeStreamingBlock(existing: ChatContentBlock, incoming: ChatContentBlock) -> ChatContentBlock {
        var merged = incoming
        if merged.text.isEmpty {
            merged.text = existing.text
        }
        if merged.toolUseID == nil {
            merged.toolUseID = existing.toolUseID
        }
        if merged.toolName == nil {
            merged.toolName = existing.toolName
        }
        if merged.inputJSON == nil || merged.inputJSON?.isEmpty == true {
            merged.inputJSON = existing.inputJSON
        }
        if merged.image == nil {
            merged.image = existing.image
        }
        if merged.rawJSON == nil {
            merged.rawJSON = existing.rawJSON
        }
        if merged.rawType == nil {
            merged.rawType = existing.rawType
        }
        return merged
    }

    private func refreshStreamingContent(_ message: inout ChatMessage) {
        message.content = message.blocks
            .filter { $0.kind == .text }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        message.images = message.blocks.compactMap(\.image)
    }

    private func upsertStreamingToolIfNeeded(_ block: ChatContentBlock, sessionID: String) {
        guard block.kind == .toolUse || block.kind == .toolResult else {
            return
        }
        let id = block.toolUseID ?? block.id
        var tool = ToolCall(
            id: id,
            sessionID: sessionID,
            name: block.toolName ?? (block.kind == .toolResult ? "Tool" : "Tool"),
            inputPreview: block.kind == .toolUse ? (block.inputJSON ?? "") : "",
            resultPreview: block.kind == .toolResult ? block.text : "",
            status: block.kind == .toolResult ? (block.isError ? .failed : .succeeded) : .streamingInput
        )
        if block.kind == .toolResult {
            tool.completedAt = Date()
        }
        upsertTool(tool, sessionID: sessionID)
    }

    private func clearStreamingMessage(sessionID: String) {
        streamingMessagesBySession.removeValue(forKey: sessionID)
        streamingTextBySession[sessionID] = ""
    }

    private func flushStreamingMessage(sessionID: String) {
        if
            let message = streamingMessagesBySession.removeValue(forKey: sessionID),
            !message.blocks.isEmpty || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.displayImages.isEmpty {
            appendMessage(message, sessionID: sessionID)
        } else if let text = streamingTextBySession[sessionID], !text.isEmpty {
            appendMessage(ChatMessage(role: .assistant, content: text), sessionID: sessionID)
        }
        streamingTextBySession[sessionID] = ""
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

    /// Surfaces a permission card, or silently auto-allows when a session rule matches.
    private func handlePermissionRequested(_ permission: PermissionRequest) {
        // Session remember: identical Bash/Edit/Write/Read permissions auto-allow
        // without surfacing a card. Destructive/network/MCP/questions never match.
        if tryAutoAllowRememberedPermission(permission) {
            recordSubagentAgentLink(agentID: permission.agentID, toolUseID: permission.parentToolUseID, sessionID: permission.sessionID)
            return
        }
        upsertPendingPermission(permission)
        // A subagent's permission request carries its agentID plus the parent spawn
        // block's toolUseID. Harvest that link so live sidechain records attribute to
        // the right card while the turn is still running.
        recordSubagentAgentLink(agentID: permission.agentID, toolUseID: permission.parentToolUseID, sessionID: permission.sessionID)
        turnPhaseBySession[permission.sessionID] = permissionPhase(for: permission)
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
    }

    /// Auto-allows a permission when a session rule matches. Returns true when the
    /// request was answered and must not enter `pendingPermissions`.
    @discardableResult
    private func tryAutoAllowRememberedPermission(_ permission: PermissionRequest) -> Bool {
        let rules = permissionRulesBySession[permission.sessionID] ?? []
        guard SessionPermissionRemember.findMatch(in: rules, permission: permission) != nil else {
            return false
        }
        do {
            try engine.respondPermission(permission, allow: true, updatedInputJSON: nil, message: nil)
            let state = L("Allowed for session")
            appendMessage(
                ChatMessage(role: .system, content: "\(state) \(permission.toolName): \(permission.summary)"),
                sessionID: permission.sessionID
            )
            if hasActiveTurn(for: permission.sessionID) {
                turnPhaseBySession[permission.sessionID] = .thinking
            } else {
                turnPhaseBySession.removeValue(forKey: permission.sessionID)
            }
            return true
        } catch {
            // Fall through to the normal pending card if the engine rejects the response.
            return false
        }
    }

    private func upsertPendingPermission(_ permission: PermissionRequest) {
        if
            let idx = pendingPermissions.firstIndex(where: { existing in
                existing.sessionID == permission.sessionID &&
                    (existing.id == permission.id ||
                        existing.requestID == permission.requestID ||
                        (existing.toolUseID != nil && existing.toolUseID == permission.toolUseID))
            }) {
            pendingPermissions[idx] = permission
        } else {
            pendingPermissions.append(permission)
        }
    }

    /// Maps a pending permission to the right wait phase: questions/plan reviews need a
    /// human answer (waitingUser); ordinary tool approvals are waitingPermission.
    private func permissionPhase(for permission: PermissionRequest) -> TurnPhase {
        switch InteractionAdapter(permission: permission).kind {
        case .question, .planReview:
            return .waitingUser
        case .permission:
            return .waitingPermission
        }
    }

    private func permissionPhase(for sessionID: String) -> TurnPhase {
        guard let permission = pendingPermissions.first(where: { $0.sessionID == sessionID }) else {
            return .waitingPermission
        }
        return permissionPhase(for: permission)
    }
}
