import AppKit
import Foundation

extension AppModel {
    func reloadSessions() {
        reloadSessionsGeneration &+= 1
        let generation = reloadSessionsGeneration
        let index = sessionIndex
        let pinnedArchived = JSONFile.load([String: SessionRecord].self, from: AppPaths.shared.sessionMetaFile) ?? [:]
        let drafts = sessions.filter { $0.isDraft }
        Task.detached(priority: .utility) {
            let discovered = index.discoverAllSessions()
            await MainActor.run {
                // A newer reload started while this scan was running — drop stale results.
                guard generation == self.reloadSessionsGeneration else {
                    return
                }
                self.applyDiscoveredSessions(discovered, meta: pinnedArchived, drafts: drafts)
            }
        }
    }

    private func applyDiscoveredSessions(_ discovered: [SessionRecord], meta: [String: SessionRecord], drafts: [SessionRecord]) {
        var seen = Set<String>()
        var loaded: [SessionRecord] = []
        for var item in discovered where seen.insert(item.id).inserted {
            if let record = meta[item.id] {
                item.customTitle = record.customTitle
                item.pinned = record.pinned
                item.archived = record.archived
            }
            loaded.append(item)
        }
        for draft in drafts where seen.insert(draft.id).inserted {
            loaded.insert(draft, at: 0)
        }
        sessions = loaded.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            if lhs.archived != rhs.archived {
                return !lhs.archived && rhs.archived
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
    }

    func saveSessionMeta() {
        let dict = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        try? JSONFile.save(dict, to: AppPaths.shared.sessionMetaFile)
    }

    func selectSession(_ id: String?) {
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = id
        guard let id, let session = sessions.first(where: { $0.id == id }) else {
            workingDirectory = ""
            fileTree = []
            selectedFilePath = nil
            filePreview = ""
            filePreviewCleanContent = ""
            fileEditDirty = false
            resetWorkspaceChangeState()
            directoryWatcher.unwatchAll()
            restoreComposerState(for: nil)
            reloadMCPAndSkills()
            return
        }
        restoreComposerState(for: id)
        resetWorkspaceChangeState()
        if messagesBySession[id] == nil, let path = session.path {
            let loadedMessages = sessionIndex.loadMessages(path: path)
            messagesBySession[id] = loadedMessages
            toolCallsBySession[id] = AgentActivityBuilder.toolCalls(from: loadedMessages, sessionID: id)
        }
        guard let projectDir = existingDirectoryPath(session.projectDir) else {
            workingDirectory = session.projectDir
            fileTree = []
            selectedFilePath = nil
            filePreview = ""
            filePreviewCleanContent = ""
            fileEditDirty = false
            directoryWatcher.unwatchAll()
            toastWarning("Project unavailable", LF("%@ no longer exists. Reopen the project folder to continue editing files.", session.projectDir))
            reloadMCPAndSkills()
            return
        }
        workingDirectory = projectDir
        fileSystem.registerWorkspace(projectDir)
        startWatchingWorkspace()
        reloadFileTree()
        reloadMCPAndSkills()
    }

    func selectNextSession() {
        guard !sessions.isEmpty else {
            return
        }
        let current = selectedSessionID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? -1
        selectSession(sessions[(current + 1 + sessions.count) % sessions.count].id)
    }

    func selectPreviousSession() {
        guard !sessions.isEmpty else {
            return
        }
        let current = selectedSessionID.flatMap { id in sessions.firstIndex { $0.id == id } } ?? 0
        selectSession(sessions[(current - 1 + sessions.count) % sessions.count].id)
    }

    func adjustFontSize(_ delta: Double) {
        settings.fontSize = min(22, max(11, settings.fontSize + delta))
        persistSettings()
    }

    func newChat() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = L("Open Project")
        if panel.runModal() == .OK, let url = panel.url {
            let projectDir = existingDirectoryPath(url.path) ?? url.path
            let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
            let session = SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: L("New chat"), cliResumeID: nil, isDraft: true)
            sessions.insert(session, at: 0)
            messagesBySession[id] = []
            snapshotComposerState(for: selectedSessionID)
            selectedSessionID = id
            composerTextBySession[id] = ""
            attachmentsBySession[id] = []
            restoreComposerState(for: id)
            workingDirectory = projectDir
            resetWorkspaceChangeState()
            fileSystem.registerWorkspace(projectDir)
            rememberProject(projectDir)
            startWatchingWorkspace()
            reloadFileTree()
            reloadMCPAndSkills()
        }
    }

    func loadProject(_ path: String) {
        guard let projectDir = existingDirectoryPath(path) else {
            forgetRecentProject(path)
            toastWarning("Project unavailable", LF("%@ no longer exists and was removed from Recent Projects.", path))
            return
        }
        let id = "desk_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
        sessions.insert(SessionRecord(id: id, path: nil, project: projectDir, projectDir: projectDir, modifiedAt: Date(), preview: L("New chat"), isDraft: true), at: 0)
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = id
        composerTextBySession[id] = ""
        attachmentsBySession[id] = []
        restoreComposerState(for: id)
        workingDirectory = projectDir
        resetWorkspaceChangeState()
        fileSystem.registerWorkspace(projectDir)
        rememberProject(projectDir)
        startWatchingWorkspace()
        reloadFileTree()
        reloadMCPAndSkills()
    }

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose Project")
        if !workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        } else if let recent = sessionIndex.mostRecentProjectDirectory() {
            panel.directoryURL = URL(fileURLWithPath: recent, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        setStartWorkingDirectory(url.path, remember: true, showToast: true)
    }

    @discardableResult
    func selectMostRecentClaudeProject(showToast: Bool = true) -> Bool {
        guard let path = sessionIndex.mostRecentProjectDirectory() else {
            if showToast {
                toastWarning("No Claude Code project found", "Choose a project folder manually.")
            }
            return false
        }
        return setStartWorkingDirectory(path, remember: false, showToast: showToast)
    }

    func clearWorkingDirectory() {
        let preservedText = composerText
        let preservedAttachments = attachments
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = nil
        restoreComposerState(for: nil)
        composerText = preservedText
        attachments = preservedAttachments
        workingDirectory = ""
        fileTree = []
        selectedFilePath = nil
        filePreview = ""
        filePreviewCleanContent = ""
        fileEditDirty = false
        resetWorkspaceChangeState()
        directoryWatcher.unwatchAll()
        reloadMCPAndSkills()
    }

    func returnToStartScreen() {
        selectSession(nil)
        syncComposerDefaultsFromClaudeUserSettings()
        autoSelectClaudeRecentProjectIfNeeded()
    }

    func autoSelectClaudeRecentProjectIfNeeded() {
        guard selectedSessionID == nil, workingDirectory.isEmpty else {
            return
        }
        if !selectMostRecentClaudeProject(showToast: false), let lastProject = recentProjects.first {
            setStartWorkingDirectory(lastProject.path, remember: false, showToast: false)
        }
    }

    @discardableResult
    private func setStartWorkingDirectory(_ path: String, remember: Bool, showToast: Bool) -> Bool {
        guard let projectDir = existingDirectoryPath(path) else {
            forgetRecentProject(path)
            if showToast {
                toastWarning("Project unavailable", LF("%@ no longer exists.", path))
            }
            return false
        }
        let preservedText = composerText
        let preservedAttachments = attachments
        snapshotComposerState(for: selectedSessionID)
        selectedSessionID = nil
        restoreComposerState(for: nil)
        composerText = preservedText
        attachments = preservedAttachments
        workingDirectory = projectDir
        selectedFilePath = nil
        filePreview = ""
        filePreviewCleanContent = ""
        fileEditDirty = false
        resetWorkspaceChangeState()
        fileSystem.registerWorkspace(projectDir)
        if remember {
            rememberProject(projectDir)
        }
        startWatchingWorkspace()
        reloadFileTree()
        reloadMCPAndSkills()
        if showToast {
            toastSuccess("Project selected", URL(fileURLWithPath: projectDir).lastPathComponent)
        }
        return true
    }
}
