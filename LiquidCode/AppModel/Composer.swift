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
            return
        }
        composerTextBySession[sessionID] = composerText
        attachmentsBySession[sessionID] = attachments
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
    }

    func setComposerText(_ text: String, for sessionID: String? = nil) {
        let target = sessionID ?? selectedSessionID
        if target == selectedSessionID {
            composerText = text
        }
        if let target {
            composerTextBySession[target] = text
        }
    }

    func setAttachments(_ next: [AttachmentChip], for sessionID: String? = nil) {
        let target = sessionID ?? selectedSessionID
        if target == selectedSessionID {
            attachments = next
        }
        if let target {
            attachmentsBySession[target] = next
        }
    }

    func appendToComposer(_ suffix: String) {
        setComposerText(composerText + suffix)
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
}
