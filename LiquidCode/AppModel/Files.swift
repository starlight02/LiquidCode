import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    func reloadFileTree() {
        guard !workingDirectory.isEmpty else {
            fileTree = []; return
        }
        guard let root = existingDirectoryPath(workingDirectory) else {
            fileTree = []; return
        }
        do { fileTree = try fileSystem.loadTree(root: URL(fileURLWithPath: root), sessionID: selectedSessionID) } catch { fileTree = []; showError(
            "Load files failed",
            error.localizedDescription
        ) }
    }

    func openFile(_ path: String) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext) {
            let info = try? fileSystem.imageInfo(path, sessionID: selectedSessionID)
            let size = info?.size ?? L("unknown size")
            let dimensions = info?.dimensions ?? L("unknown dimensions")
            let preview = LF("Image preview\n\nPath: %@\nSize: %@\nDimensions: %@\n\nUse Open or Reveal for the native image viewer.", path, size, dimensions)
            selectedFilePath = path
            filePreview = preview
            filePreviewCleanContent = preview
            fileEditDirty = false
            filePreviewMode = .preview
            secondaryTab = .files
            return
        }
        do {
            let text = try fileSystem.readText(path, sessionID: selectedSessionID)
            selectedFilePath = path
            filePreview = text
            filePreviewCleanContent = text
            fileEditDirty = false
            if ext == "html" || ext == "htm" || ext == "xhtml" {
                filePreviewMode = .html
            } else if ext == "md" || ext == "mdx" {
                filePreviewMode = .preview
            } else {
                filePreviewMode = .source
            }
            secondaryTab = .files
        } catch { showError("Read file failed", error.localizedDescription) }
    }

    func markFilePreviewEdited() {
        guard selectedFilePath != nil else {
            fileEditDirty = false; return
        }
        fileEditDirty = filePreview != filePreviewCleanContent
    }

    func saveSelectedFile() {
        guard let path = selectedFilePath else {
            return
        }
        do {
            try fileSystem.writeText(path, text: filePreview, sessionID: selectedSessionID)
            changedFiles.insert(path)
            fileChangeBadges[path] = fileChangeBadges[path] == "A" ? "A" : "M"
            filePreviewCleanContent = filePreview
            fileEditDirty = false
            reloadFileTree()
            if URL(fileURLWithPath: path).lastPathComponent == "SKILL.md" {
                reloadMCPAndSkills()
                selectedSkill = skills.first { sameFilePath($0.path, path) }
            }
        } catch { showError("Save file failed", error.localizedDescription) }
    }

    func reloadSelectedFile() {
        guard let path = selectedFilePath else {
            return
        }
        guard resolveDirtyFileChange() else {
            return
        }
        openFile(path)
    }

    @discardableResult func resolveDirtyFileChange() -> Bool {
        guard fileEditDirty else {
            return true
        }
        let alert = NSAlert()
        alert.messageText = L("Unsaved file changes")
        alert.informativeText = L("Save the current file before changing the preview selection?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveSelectedFile()
            return !fileEditDirty
        case .alertSecondButtonReturn:
            filePreview = filePreviewCleanContent
            fileEditDirty = false
            return true
        default:
            return false
        }
    }

    @discardableResult func requestOpenFile(_ path: String) -> Bool {
        if sameFilePath(selectedFilePath, path) {
            secondaryTab = .files; return true
        }
        guard resolveDirtyFileChange() else {
            return false
        }
        openFile(path)
        return sameFilePath(selectedFilePath, path)
    }

    func requestCloseFilePreview() {
        guard resolveDirtyFileChange() else {
            return
        }
        selectedFilePath = nil
        filePreview = ""
        filePreviewCleanContent = ""
        fileEditDirty = false
    }

    @discardableResult func requestSelectFilePath(_ path: String) -> Bool {
        if !sameFilePath(selectedFilePath, path) {
            guard resolveDirtyFileChange() else {
                return false
            }
            selectedFilePath = path
            filePreview = ""
            filePreviewCleanContent = ""
            fileEditDirty = false
        }
        return true
    }

    func requestRenameSelectedFile(to newName: String) {
        guard resolveDirtyFileChange() else {
            return
        }
        renameSelectedFile(to: newName)
    }

    func requestDeleteSelectedFile() {
        guard resolveDirtyFileChange() else {
            return
        }
        deleteSelectedFile()
    }

    func requestRenameFile(_ path: String, to newName: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        requestRenameSelectedFile(to: newName)
    }

    func requestDeleteFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        requestDeleteSelectedFile()
    }

    func requestRevealFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        revealSelectedFile()
    }

    func requestOpenExternalFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        openSelectedFile()
    }

    func requestCopyFilePath(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        copySelectedPath()
    }

    func requestInsertFilePath(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        insertSelectedPathIntoChat()
    }

    func requestShareFile(_ path: String) {
        guard requestSelectFilePath(path) else {
            return
        }
        shareSelectedFile()
    }

    func requestInsertFileContent(_ path: String) {
        if !sameFilePath(selectedFilePath, path) {
            guard resolveDirtyFileChange() else {
                return
            }
            openFile(path)
        }
        guard sameFilePath(selectedFilePath, path) else {
            return
        }
        insertSelectedContentIntoChat()
    }

    func revealSelectedFile() {
        if let path = selectedFilePath {
            do { try fileSystem.reveal(path, sessionID: selectedSessionID) } catch { showError(
                "Reveal failed",
                error.localizedDescription
            ) } } }

    func openSelectedFile() {
        if let path = selectedFilePath {
            do { try fileSystem.open(path, sessionID: selectedSessionID) } catch { showError(
                "Open failed",
                error.localizedDescription
            ) } } }

    func openSelectedInVSCode() {
        if let path = selectedFilePath {
            do { try fileSystem.openInVSCode(path, sessionID: selectedSessionID) } catch { showError(
                "Open in VS Code failed",
                error.localizedDescription
            ) } } }

    private func availablePath(in directory: URL, name: String) -> URL {
        let base = directory.appendingPathComponent(name)
        guard (try? fileSystem.exists(base.path, sessionID: selectedSessionID)) == true else {
            return base
        }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        for index in 2 ... 999 {
            let candidate = directory.appendingPathComponent("\(stem) \(index)").appendingPathExtension(ext)
            if (try? fileSystem.exists(candidate.path, sessionID: selectedSessionID)) != true {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(6))").appendingPathExtension(ext)
    }

    func createFile(inDirectory directory: String, named name: String = "untitled.txt") {
        let url = availablePath(in: URL(fileURLWithPath: directory), name: name)
        do {
            try fileSystem.writeText(url.path, text: "", sessionID: selectedSessionID); changedFiles
                .insert(url.path); fileChangeBadges[url.path] = "A"; reloadFileTree(); toastSuccess(
                    "Created file",
                    url.lastPathComponent
                ) } catch { showError("Create file failed", error.localizedDescription) }
    }

    func createFolder(inDirectory directory: String, named name: String) {
        let url = availablePath(in: URL(fileURLWithPath: directory), name: name)
        do {
            try fileSystem.createDirectory(url.path, sessionID: selectedSessionID); changedFiles.insert(url.path); fileChangeBadges[url.path] = "A"; reloadFileTree(); toastSuccess(
                "Created folder",
                url.lastPathComponent
            ) } catch { showError("Create folder failed", error.localizedDescription) }
    }

    func renameSelectedFile(to newName: String) {
        guard let path = selectedFilePath else {
            return
        }
        let dest = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(newName).path
        do {
            try fileSystem.rename(path, to: dest, sessionID: selectedSessionID); changedFiles.insert(path); changedFiles
                .insert(dest); fileChangeBadges[path] = "D"; fileChangeBadges[dest] = "A"; selectedFilePath = dest; filePreviewCleanContent = filePreview; fileEditDirty =
                false; reloadFileTree(); toastSuccess(
                    "Renamed",
                    newName
                ) } catch { showError("Rename failed", error.localizedDescription) }
    }

    func deleteSelectedFile() {
        guard let path = selectedFilePath else {
            return
        }
        do {
            try fileSystem.delete(path, sessionID: selectedSessionID); changedFiles
                .insert(path); fileChangeBadges[path] = "D"; selectedFilePath = nil; filePreview = ""; filePreviewCleanContent = ""; fileEditDirty =
                false; reloadFileTree(); toastSuccess(
                    "Deleted",
                    URL(fileURLWithPath: path).lastPathComponent
                ) } catch { showError("Delete failed", error.localizedDescription) }
    }

    func copySelectedPath() {
        guard let path = selectedFilePath else {
            return
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string); toastSuccess("Copied path", path)
    }

    func insertSelectedPathIntoChat() {
        if let path = selectedFilePath {
            appendToComposer(" @\(path)")
        } }

    func insertSelectedContentIntoChat() {
        if !filePreview.isEmpty {
            appendToComposer("\n\n```\n\(filePreview)\n```")
        } }

    func shareSelectedFile() {
        if let path = selectedFilePath {
            shareService.share(path: path, from: nil)
        } }

    func attachFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            attachURLs(panel.urls)
        }
    }

    func attachURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        var next = attachments
        for url in urls {
            if let id = selectedSessionID {
                fileSystem.addGrant(sessionID: id, path: url.path)
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            next.append(AttachmentChip(
                name: url.lastPathComponent,
                path: url.path,
                size: Int64(values?.fileSize ?? 0),
                isImage: MessageImageReference.isImagePath(url.path)
            ))
        }
        setAttachments(next)
    }

    func attachImagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        if
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageURLs = urls.filter { MessageImageReference.isImagePath($0.path) }
            if !imageURLs.isEmpty {
                attachURLs(imageURLs)
                return true
            }
        }
        if
            let png = pasteboard.data(forType: .png),
            let url = saveComposerImageData(png, preferredExtension: "png") {
            attachURLs([url])
            return true
        }
        if
            let tiff = pasteboard.data(forType: .tiff),
            let image = NSImage(data: tiff),
            let png = MessageImageReference.pngData(from: image),
            let url = saveComposerImageData(png, preferredExtension: "png") {
            attachURLs([url])
            return true
        }
        if
            let image = NSImage(pasteboard: pasteboard),
            let png = MessageImageReference.pngData(from: image),
            let url = saveComposerImageData(png, preferredExtension: "png") {
            attachURLs([url])
            return true
        }
        return false
    }

    func attachDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard
                        let data,
                        let string = String(data: data, encoding: .utf8),
                        let url = URL(string: string)
                    else {
                        return
                    }
                    Task { @MainActor in self.attachURLs([url]) }
                }
                continue
            }
            for type in [UTType.png, UTType.jpeg, UTType.tiff, UTType.gif, UTType.webP] {
                guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
                    continue
                }
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else {
                        return
                    }
                    let ext = type.preferredFilenameExtension ?? "png"
                    Task { @MainActor in
                        if let url = self.saveComposerImageData(data, preferredExtension: ext) {
                            self.attachURLs([url])
                        }
                    }
                }
                break
            }
        }
        return handled
    }

    private func saveComposerImageData(_ data: Data, preferredExtension: String) -> URL? {
        let directory = AppPaths.shared.appSupport.appendingPathComponent("ComposerImages", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let cleanExt = preferredExtension.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty ? "png" : preferredExtension
            let url = directory.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).\(cleanExt)")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            toastWarning("Image unavailable", error.localizedDescription)
            return nil
        }
    }

    func removeAttachment(_ attachment: AttachmentChip) {
        setAttachments(attachments.filter { $0.id != attachment.id })
    }
}
