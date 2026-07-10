import AppKit
import Foundation

extension AppModel {
    private func canonicalFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func existingDirectoryPath(_ path: String) -> String? {
        let canonical = PathAccessManager.canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return canonical
    }

    func forgetRecentProject(_ path: String) {
        let canonical = PathAccessManager.canonicalPath(path)
        recentProjects.removeAll { project in
            project.path == path || PathAccessManager.canonicalPath(project.path) == canonical
        }
        try? JSONFile.save(recentProjects, to: AppPaths.shared.recentProjectsFile)
    }

    func sameFilePath(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }
        return canonicalFilePath(lhs) == canonicalFilePath(rhs)
    }

    func snapshotComposerState(for sessionID: String?) {
        guard let sessionID else {
            persistComposerDraftsSoon()
            return
        }
        composerTextBySession[sessionID] = composerText
        attachmentsBySession[sessionID] = attachments
        persistComposerDraftsSoon()
    }

    func restoreComposerState(for sessionID: String?) {
        guard let sessionID else {
            composerText = ""
            attachments = []
            return
        }
        composerText = composerTextBySession[sessionID] ?? ""
        attachments = attachmentsBySession[sessionID] ?? []
    }

    func updateComposerText(_ text: String) {
        composerText = text
        if let selectedSessionID {
            composerTextBySession[selectedSessionID] = text
        }
        persistComposerDraftsSoon()
    }

    func setComposerText(_ text: String, for sessionID: String? = nil) {
        let target = sessionID ?? selectedSessionID
        if target == selectedSessionID {
            composerText = text
        }
        if let target {
            composerTextBySession[target] = text
        }
        persistComposerDraftsSoon()
    }

    func setAttachments(_ next: [AttachmentChip], for sessionID: String? = nil) {
        let target = sessionID ?? selectedSessionID
        if target == selectedSessionID {
            attachments = next
        }
        if let target {
            attachmentsBySession[target] = next
        }
        persistComposerDraftsSoon()
    }

    func appendToComposer(_ suffix: String) {
        setComposerText(composerText + suffix)
    }

    func restorePersistedComposerDrafts() {
        guard let stored = JSONFile.load(ComposerDraftStore.self, from: AppPaths.shared.composerDraftsFile) else {
            return
        }
        composerText = stored.defaultText
        attachments = stored.defaultAttachments
        composerTextBySession = stored.textBySession
        attachmentsBySession = stored.attachmentsBySession
        pendingUserMessagesBySession = stored.queuedMessagesBySession
    }

    func persistComposerDraftsSoon() {
        let snapshot = composerDraftSnapshot()
        let url = AppPaths.shared.composerDraftsFile
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try JSONFile.save(snapshot, to: url)
            } catch {
                return
            }
        }
    }

    @discardableResult
    func persistComposerDraftsNow() -> Bool {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        do {
            try JSONFile.save(composerDraftSnapshot(), to: AppPaths.shared.composerDraftsFile)
            return true
        } catch {
            showError("Save drafts failed", error.localizedDescription)
            return false
        }
    }

    private func composerDraftSnapshot() -> ComposerDraftStore {
        var textBySession = composerTextBySession
        var storedAttachmentsBySession = attachmentsBySession
        if let selectedSessionID {
            textBySession[selectedSessionID] = composerText
            storedAttachmentsBySession[selectedSessionID] = attachments
        }
        return ComposerDraftStore(
            defaultText: selectedSessionID == nil ? composerText : "",
            defaultAttachments: selectedSessionID == nil ? attachments : [],
            textBySession: textBySession,
            attachmentsBySession: storedAttachmentsBySession,
            queuedMessagesBySession: pendingUserMessagesBySession
        )
    }

    func resetChatFindIndex() {
        chatFindIndex = 0
    }

    func searchChatNext(direction: Int = 1) {
        let targets = selectedChatFindTargets
        guard !targets.isEmpty else {
            if !chatFindText.isEmpty {
                toastWarning("No matches", chatFindText)
            }
            chatFindIndex = 0
            return
        }
        let step = direction < 0 ? -1 : 1
        chatFindIndex = (chatFindIndex + step + targets.count) % targets.count
    }

    func resolveMarkdownImageURL(_ source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }
        let url: URL
        if trimmed.lowercased().hasPrefix("file://"), let parsed = URL(string: trimmed) {
            url = parsed
        } else if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            guard !workingDirectory.isEmpty else {
                return nil
            }
            url = URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let allowed = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
        guard allowed.contains(resolved.pathExtension.lowercased()) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    func openImageLightbox(source: String, alt: String? = nil) {
        guard let url = resolveMarkdownImageURL(source), let data = try? Data(contentsOf: url) else {
            toastWarning("Image unavailable", source)
            return
        }
        imageLightbox = ImageLightboxContent(imageData: data, filePath: url.path, alt: alt)
    }

    func openImageLightbox(_ image: MessageImageReference) {
        guard let data = image.imageData else {
            toastWarning("Image unavailable", image.sourceDescription ?? image.displayName)
            return
        }
        imageLightbox = ImageLightboxContent(imageData: data, filePath: image.filePath, alt: image.displayName)
    }
}
