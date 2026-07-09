import AppKit
import Foundation

extension AppModel {
    func reloadMCPAndSkills() {
        cancelDeferredMCPAndSkillsReload()
        mcpServers = mcpService.loadServers(projectPath: workingDirectory.isEmpty ? nil : workingDirectory)
        skills = skillService.loadSkills(projectPath: workingDirectory.isEmpty ? nil : workingDirectory)
        reloadClaudeExtensions()
    }

    func reloadMCPAndSkillsDeferred(debounceNanoseconds: UInt64 = 0) {
        let projectPath = workingDirectory.isEmpty ? nil : workingDirectory
        mcpSkillsReloadGeneration &+= 1
        let generation = mcpSkillsReloadGeneration
        mcpSkillsReloadTask?.cancel()
        mcpSkillsReloadTask = Task.detached(priority: .utility) {
            if debounceNanoseconds > 0 {
                do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            }
            guard !Task.isCancelled else {
                return
            }
            let servers = MCPService().loadServers(projectPath: projectPath)
            let loadedSkills = SkillService().loadSkills(projectPath: projectPath)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard
                    generation == self.mcpSkillsReloadGeneration,
                    self.deferredReloadProjectKey == Self.projectKey(projectPath) else {
                    return
                }
                self.mcpServers = servers
                self.skills = loadedSkills
            }
        }
    }

    private func cancelDeferredMCPAndSkillsReload() {
        mcpSkillsReloadGeneration &+= 1
        mcpSkillsReloadTask?.cancel()
        mcpSkillsReloadTask = nil
    }

    var deferredReloadProjectKey: String? {
        Self.projectKey(workingDirectory.isEmpty ? nil : workingDirectory)
    }

    static func projectKey(_ path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }
        return PathAccessManager.canonicalPath(path)
    }

    func useSkillInComposer(_ skill: SkillInfo) {
        let command = "/\(skill.name) "
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setComposerText(command)
        } else {
            let separator = composerText.hasSuffix(" ") || composerText.hasSuffix("\n") ? "" : "\n"
            setComposerText(composerText + separator + command)
        }
        toastSuccess("Inserted skill command", command)
    }

    func duplicateSkill(_ skill: SkillInfo) {
        if sameFilePath(selectedFilePath, skill.path) {
            guard resolveDirtyFileChange() else {
                return
            }
        }
        let originalURL = URL(fileURLWithPath: skill.path)
        let parent = originalURL.deletingLastPathComponent().deletingLastPathComponent()
        let baseName = "\(skill.name)-copy"
        var candidateName = baseName
        var suffix = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidateName, isDirectory: true).path) {
            candidateName = "\(baseName)-\(suffix)"
            suffix += 1
        }
        let targetDir = parent.appendingPathComponent(candidateName, isDirectory: true)
        let targetFile = targetDir.appendingPathComponent("SKILL.md")
        do {
            if !workingDirectory.isEmpty {
                fileSystem.registerWorkspace(workingDirectory)
            }
            try fileSystem.createDirectory(targetDir.path, sessionID: selectedSessionID)
            try fileSystem.writeText(targetFile.path, text: skillContent(skill.content, settingName: candidateName), sessionID: selectedSessionID)
            reloadMCPAndSkills()
            if requestOpenFile(targetFile.path) {
                selectedSkill = skills.first { sameFilePath($0.path, targetFile.path) }
            }
            toastSuccess("Duplicated skill", candidateName)
        } catch {
            showError("Duplicate skill failed", error.localizedDescription)
        }
    }

    func createSkill(name: String, projectScoped: Bool) {
        let root = projectScoped && !workingDirectory.isEmpty
            ? URL(fileURLWithPath: workingDirectory).appendingPathComponent(".claude/skills/\(name)")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/\(name)")
        do {
            try fileSystem.createDirectory(root.path, sessionID: selectedSessionID)
            let file = root.appendingPathComponent("SKILL.md")
            let content = "---\nname: \(name)\ndescription: Use this skill when its project-specific instructions apply.\n---\n\n# \(name)\n\nAdd concrete instructions, examples, and boundaries for this skill.\n"
            try fileSystem.writeText(file.path, text: content, sessionID: selectedSessionID)
            reloadMCPAndSkills()
            if requestOpenFile(file.path) {
                selectedSkill = skills.first { sameFilePath($0.path, file.path) }
            }
            toastSuccess("Created skill", name)
        } catch { showError("Create skill failed", error.localizedDescription) }
    }

    func deleteSelectedSkill() {
        guard let skill = selectedSkill else {
            return
        }
        if sameFilePath(selectedFilePath, skill.path) {
            guard resolveDirtyFileChange() else {
                return
            }
        }
        do {
            try skillService.deleteSkill(skill)
            if sameFilePath(selectedFilePath, skill.path) {
                requestCloseFilePreview()
            }
            selectedSkill = nil
            reloadMCPAndSkills()
            toastSuccess("Deleted skill", skill.name)
        } catch { showError("Delete skill failed", error.localizedDescription) }
    }

    func toggleSelectedSkillEnabled() {
        guard var skill = selectedSkill else {
            return
        }
        skill.disabled.toggle()
        let previewMatchesSkill = sameFilePath(selectedFilePath, skill.path)
        let previewContentMatchesSkill = filePreviewContentPath.map { sameFilePath($0, skill.path) } == true
        let source = previewMatchesSkill && (fileEditDirty || previewContentMatchesSkill) ? filePreview : skill.content
        skill.content = skillContent(source, settingDisabled: skill.disabled)

        do {
            try skillService.writeSkill(skill)
            if sameFilePath(selectedFilePath, skill.path) {
                cancelFilePreviewLoad()
                filePreview = skill.content
                filePreviewCleanContent = skill.content
                filePreviewContentPath = skill.path
                fileEditDirty = false
            }
            selectedSkill = skill
            reloadMCPAndSkills()
            selectedSkill = skills.first { sameFilePath($0.path, skill.path) } ?? skill
            toastSuccess(skill.disabled ? "Disabled skill" : "Enabled skill", skill.name)
        } catch { showError("Save skill failed", error.localizedDescription) }
    }

    private func skillContent(_ content: String, settingDisabled disabled: Bool) -> String {
        let canonicalKey = "disable_model_invocation"
        let legacyKey = "disable-model-invocation"
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var frontmatter = Array(lines[1 ..< end])
            var wroteCanonical = false
            frontmatter = frontmatter.compactMap { line in
                if line.hasPrefix("\(canonicalKey):") {
                    wroteCanonical = true
                    return "\(canonicalKey): \(disabled)"
                }
                if line.hasPrefix("\(legacyKey):") {
                    return nil
                }
                return line
            }
            if !wroteCanonical {
                frontmatter.insert("\(canonicalKey): \(disabled)", at: 0)
            }
            lines = ["---"] + frontmatter + Array(lines[end...])
            return lines.joined(separator: "\n")
        }
        return "---\n\(canonicalKey): \(disabled)\n---\n\n" + content
    }

    private func skillContent(_ content: String, settingName name: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var frontmatter = Array(lines[1 ..< end])
            var wroteName = false
            frontmatter = frontmatter.map { line in
                if line.hasPrefix("name:") {
                    wroteName = true
                    return "name: \(name)"
                }
                return line
            }
            if !wroteName {
                frontmatter.insert("name: \(name)", at: 0)
            }
            lines = ["---"] + frontmatter + Array(lines[end...])
            return lines.joined(separator: "\n")
        }
        return "---\nname: \(name)\n---\n\n" + content
    }

    func addMCPServer(name: String, command: String) {
        let server = appLocalMCPServer(name: name, commandLine: command)
        mcpServers.removeAll { $0.source == "LiquidCode" && $0.name == server.name }
        mcpServers.append(server)
        saveAppMCPServers()
    }

    func updateMCPServer(_ server: MCPServer, name: String, command: String) {
        guard server.source == "LiquidCode" else {
            toastWarning("MCP is read-only", LF("%@ is managed by %@.", server.name, server.source))
            return
        }
        let next = appLocalMCPServer(name: name, commandLine: command)
        mcpServers.removeAll { $0.source == "LiquidCode" && ($0.name == server.name || $0.name == next.name) }
        mcpServers.append(next)
        saveAppMCPServers()
    }

    func deleteMCPServer(_ server: MCPServer) {
        guard server.source == "LiquidCode" else {
            toastWarning("MCP is read-only", LF("%@ is managed by %@.", server.name, server.source))
            return
        }
        mcpServers.removeAll { $0.name == server.name && $0.source == "LiquidCode" }
        saveAppMCPServers()
    }

    func testMCPServer(_ server: MCPServer) {
        guard let index = mcpServers.firstIndex(where: { $0.name == server.name && $0.source == server.source }) else {
            return
        }
        mcpServers[index].runtimeStatus = .testing
        mcpServers[index].lastError = nil

        let result = MCPRuntimeProbe.evaluate(mcpServers[index])
        mcpServers[index].runtimeStatus = result.status
        mcpServers[index].toolCount = result.toolCount
        mcpServers[index].lastError = result.error
        mcpServers[index].lastTestedAt = Date()

        if result.status == .ok {
            let tools = result.toolCount.map { LF("%d tools", $0) }
            let message = tools.map { "\(result.detail) · \($0)" } ?? result.detail
            toastSuccess("MCP OK", message)
        } else {
            toastWarning("MCP failed", result.error ?? result.detail)
        }
    }

    func reloadClaudeExtensions() {
        let projectPath = workingDirectory.isEmpty ? nil : workingDirectory
        claudePlugins = ClaudeExtensionsService.loadPlugins()
        claudeHooks = ClaudeExtensionsService.loadHooks(projectPath: projectPath)
    }

    private func saveAppMCPServers() {
        do { try mcpService.saveAppServers(mcpServers.filter { $0.source == "LiquidCode" }); reloadMCPAndSkills(); toastSuccess("Saved MCP", "App-local MCP profile updated")
        } catch { showError(
            "Save MCP failed",
            error.localizedDescription
        ) }
    }

    private func appLocalMCPServer(name: String, commandLine: String) -> MCPServer {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommand = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: cleanCommand), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return MCPServer(name: cleanName, transport: "http", command: nil, url: cleanCommand, args: [], enabled: true, source: "LiquidCode")
        }
        let parts = shellWords(cleanCommand)
        return MCPServer(
            name: cleanName,
            transport: "stdio",
            command: parts.first ?? cleanCommand,
            url: nil,
            args: Array(parts.dropFirst()),
            enabled: true,
            source: "LiquidCode"
        )
    }

    private func shellWords(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for char in input {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if char == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            if char.isWhitespace {
                if !current.isEmpty {
                    words.append(current); current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }
}
