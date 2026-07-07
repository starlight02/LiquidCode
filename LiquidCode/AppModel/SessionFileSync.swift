import Foundation

extension AppModel {
    /// Watches the selected session's transcript `.jsonl` so writes from another process
    /// — a `claude --resume <id>` in the user's terminal, or a second app window — appear
    /// live instead of only after a manual reload. The GUI and any external `claude` are
    /// separate processes that share only the on-disk transcript, so tailing that file is
    /// the one reliable sync channel.
    ///
    /// The reverse direction (a *running* external `claude` reflecting messages the GUI
    /// just sent) is not achievable here: Claude Code reads the transcript once at resume
    /// and does not tail it, so that is a limitation of the CLI's session model.
    func startWatchingSessionFile(path: String) {
        let canonical = PathAccessManager.canonicalPath(path)
        // Already watching this exact file — nothing to do.
        if watchedSessionFilePath == canonical, sessionFileWatchTask != nil {
            return
        }
        stopWatchingSessionFile()

        let directory = (canonical as NSString).deletingLastPathComponent
        guard existingDirectoryPath(directory) != nil else {
            return
        }
        watchedSessionFilePath = canonical
        sessionFileWatchGeneration &+= 1
        let generation = sessionFileWatchGeneration
        let sessionID = selectedSessionID
        let watcher = sessionFileWatcher
        let token = DirectoryWatchManager.WatchToken()
        watcher.requestWatchDirectory(directory, token: token)
        sessionFileWatchTask = Task.detached(priority: .utility) { [weak self, watcher] in
            guard !Task.isCancelled else {
                watcher.cancelRequestedWatch(directory, token: token)
                return
            }
            do {
                try watcher.watchRequestedDirectory(directory, token: token) { [weak self] paths in
                    // FSEvents reports the directory; only react when our file changed.
                    guard paths.contains(where: { PathAccessManager.canonicalPath($0) == canonical }) else {
                        return
                    }
                    Task { @MainActor [weak self] in
                        self?.handleSessionFileChange(
                            path: canonical,
                            sessionID: sessionID,
                            generation: generation
                        )
                    }
                }
            } catch {
                watcher.cancelRequestedWatch(directory, token: token)
            }
        }
    }

    func stopWatchingSessionFile() {
        sessionFileWatchGeneration &+= 1
        sessionFileWatchTask?.cancel()
        sessionFileWatchTask = nil
        sessionFileWatcher.unwatchAll()
        watchedSessionFilePath = nil
    }

    private func handleSessionFileChange(path: String, sessionID: String?, generation: Int) {
        // Stale callback from a superseded watch (session switched, rewatch started).
        guard generation == sessionFileWatchGeneration, sessionID == selectedSessionID, let sessionID else {
            return
        }
        // Don't disturb an in-flight turn: the GUI is actively streaming into this
        // transcript and reconciling mid-turn would fight the live render. turnCompleted
        // already reloads, so external appends land right after the turn settles.
        guard !hasActiveTurn(for: sessionID) else {
            return
        }
        // Messages not yet loaded — the normal select path will read the full file.
        guard messagesBySession[sessionID] != nil else {
            return
        }
        let index = sessionIndex
        Task.detached(priority: .utility) { [weak self] in
            let latest = index.loadMessages(path: path)
            await MainActor.run { [weak self] in
                guard
                    let self,
                    generation == sessionFileWatchGeneration,
                    sessionID == selectedSessionID,
                    !hasActiveTurn(for: sessionID)
                else {
                    return
                }
                mergeExternalMessages(latest, sessionID: sessionID)
            }
        }
    }

    /// Reconciles the on-disk transcript into the in-memory one, appending only records
    /// the GUI hasn't already rendered. Matching by id keeps messages the GUI itself sent
    /// (already present) from duplicating, and preserves scroll/expansion state for the
    /// existing rows instead of rebuilding the whole transcript. Internal (not private)
    /// so the reconciliation can be exercised directly in tests.
    func mergeExternalMessages(_ latest: [ChatMessage], sessionID: String) {
        let existing = messagesBySession[sessionID] ?? []
        var seen = Set(existing.map(\.id))
        let appended = latest.filter { seen.insert($0.id).inserted }
        guard !appended.isEmpty else {
            return
        }
        let merged = existing + appended
        setMessages(merged, for: sessionID)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }), let last = merged.last {
            sessions[idx].preview = String(last.transcriptPreview.prefix(120))
            sessions[idx].modifiedAt = Date()
        }
    }
}
