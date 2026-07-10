import AppKit
import Foundation

extension AppModel {
    func loadSessionGroups() {
        sessionGroups = JSONFile.load([SessionTaskGroup].self, from: AppPaths.shared.appSupport.appendingPathComponent("groups.json")) ?? []
    }

    func saveSessionGroups() {
        try? JSONFile.save(sessionGroups, to: AppPaths.shared.appSupport.appendingPathComponent("groups.json"))
    }

    func createGroup(name: String) {
        guard !workingDirectory.isEmpty else {
            return
        }
        sessionGroups.append(SessionTaskGroup(name: name, projectPath: workingDirectory, sessionIDs: [])); saveSessionGroups()
    }

    func addSession(_ session: SessionRecord, to group: SessionTaskGroup) {
        guard let idx = sessionGroups.firstIndex(where: { $0.id == group.id }) else {
            return
        }
        guard session.projectDir == sessionGroups[idx].projectPath else {
            return
        }
        if !sessionGroups[idx].sessionIDs.contains(session.id) {
            sessionGroups[idx].sessionIDs.append(session.id); sessionGroups[idx].updatedAt = Date(); saveSessionGroups()
        }
    }

    func removeSession(_ session: SessionRecord, from group: SessionTaskGroup) {
        guard let idx = sessionGroups.firstIndex(where: { $0.id == group.id }) else {
            return
        }
        sessionGroups[idx].sessionIDs.removeAll { $0 == session.id }; sessionGroups[idx].updatedAt = Date(); saveSessionGroups()
    }

    func deleteGroup(_ group: SessionTaskGroup) {
        sessionGroups.removeAll { $0.id == group.id }; saveSessionGroups()
    }

    func exportMarkdown(session: SessionRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(session.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if let path = session.path {
                    try sessionIndex.exportMarkdown(path: path, outputPath: url.path)
                } else {
                    let messages = messagesBySession[session.id] ?? []
                    let markdown = messages.map { "### \($0.role.rawValue)\n\n\($0.content)" }.joined(separator: "\n\n")
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch { showError("Export Markdown failed", error.localizedDescription) }
        }
    }

    func exportJSON(session: SessionRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(session.title).json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if let path = session.path {
                    try sessionIndex.exportJSON(path: path, outputPath: url.path)
                } else {
                    try JSONEncoder.liquid.encode(messagesBySession[session.id] ?? []).write(to: url)
                }
            } catch { showError("Export JSON failed", error.localizedDescription) }
        }
    }

    func runCommand(_ command: PaletteCommand) {
        commandPaletteOpen = false
        switch command.kind {
        case .newChat: newChat()
        case .settings: settingsOpen = true
        case .mcpSettings: settingsTab = .mcp; settingsOpen = true
        case .panel(let tab): secondaryTab = tab; secondaryOpen = true
        case .mode(let mode): setComposerMode(mode)
        case .model(let model): setComposerModel(model)
        case .sendSlash(let slash): setComposerText(slash + " ")
        case .installCLI: installOrUpdateCLI()
        case .loginCLI: openClaudeLogin()
        case .exportCurrent: if let selectedSession {
                exportMarkdown(session: selectedSession)
            }
        case .rewind: requestRewindToLastUserMessage()
        case .changelog: showChangelog()
        }
    }

    var paletteCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = [
            .init(title: L("New Chat"), subtitle: L("Open a project and start a draft"), kind: .newChat),
            .init(title: L("Settings"), subtitle: L("CLI, MCP, appearance"), kind: .settings),
            .init(title: L("Files Panel"), subtitle: L("Show project files"), kind: .panel(.files)),
            .init(title: L("Plan Panel"), subtitle: L("Review plan drafts and approvals"), kind: .panel(.plan)),
            .init(title: L("Agents Panel"), subtitle: L("Show subagent activity"), kind: .panel(.agent)),
            .init(title: L("Skills Panel"), subtitle: L("Show Claude skills"), kind: .panel(.skills)),
            .init(title: L("MCP Settings"), subtitle: L("Show MCP servers in Settings"), kind: .mcpSettings),
            .init(title: L("Install or Update Claude CLI"), subtitle: cliStatus.version ?? "Claude CLI", kind: .installCLI),
            .init(title: L("Claude Login"), subtitle: cliStatus.authStatus, kind: .loginCLI),
            .init(title: L("Export Current Session"), subtitle: L("Markdown export"), kind: .exportCurrent),
            .init(title: L("Rewind to Last User Turn"), subtitle: L("Request Claude checkpoint restore"), kind: .rewind),
            .init(title: L("What's New"), subtitle: L("Open changelog"), kind: .changelog)
        ]
        commands += SessionMode.allCases.map { .init(title: LF("Mode: %@", $0.label), subtitle: $0.permissionMode, kind: .mode($0)) }
        commands += defaultModels.map { .init(title: LF("Model: %@", modelMenuDisplayName($0)), subtitle: L("Switch Claude model"), kind: .model($0)) }
        commands += ["/compact", "/cost", "/doctor", "/help", "/init", "/memory", "/mcp", "/permissions", "/pr_comments", "/review"].map { .init(
            title: $0,
            subtitle: L("Insert slash command"),
            kind: .sendSlash($0)
        ) }
        commands += skills.map { .init(title: "/\($0.name)", subtitle: $0.description, kind: .sendSlash("/\($0.name)")) }
        return commands
    }

    func filteredPaletteCommands(_ query: String) -> [PaletteCommand] {
        guard !query.isEmpty else {
            return paletteCommands
        }
        return paletteCommands.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    func rememberProject(_ path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        recentProjects.removeAll { $0.path == path }
        recentProjects.insert(RecentProject(name: name, path: path, lastUsed: Date()), at: 0)
        recentProjects = Array(recentProjects.prefix(20))
        try? JSONFile.save(recentProjects, to: AppPaths.shared.recentProjectsFile)
    }

    func showError(_ title: String, _ message: String) {
        currentError = AppError(title: L(title), message: L(message))
    }
}

struct PaletteCommand: Identifiable, Hashable {
    enum Kind: Hashable { case newChat, settings, panel(SecondaryTab), mcpSettings, mode(SessionMode), model(String), sendSlash(String), installCLI, loginCLI,
                               exportCurrent, rewind, changelog }

    let title: String
    let subtitle: String
    let kind: Kind

    var id: String {
        switch kind {
        case .newChat: "new-chat"
        case .settings: "settings"
        case .panel(let tab): "panel-\(tab.rawValue)"
        case .mcpSettings: "mcp-settings"
        case .mode(let mode): "mode-\(mode.rawValue)"
        case .model(let model): "model-\(model)"
        case .sendSlash(let slash): "slash-\(slash)"
        case .installCLI: "install-cli"
        case .loginCLI: "login-cli"
        case .exportCurrent: "export-current"
        case .rewind: "rewind"
        case .changelog: "changelog"
        }
    }
}
