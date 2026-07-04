import XCTest
@testable import LiquidCode

@MainActor
final class FeatureModelRegressionTests: XCTestCase {
    func testChatFindOccurrenceRangesAreCaseDiacriticInsensitive() {
        let text = "Résumé resume RESUME resumé"

        let matches = chatFindOccurrenceRanges(in: text, query: "resume")
            .map { String(text[$0]) }

        XCTAssertEqual(matches, ["Résumé", "resume", "RESUME", "resumé"])
    }

    func testChatFindOccurrenceRangesDoNotOverlap() {
        let text = "aaaa"

        let matches = chatFindOccurrenceRanges(in: text, query: "aa")
            .map { String(text[$0]) }

        XCTAssertEqual(matches, ["aa", "aa"])
    }

    func testChatFindTargetsCountEveryOccurrenceWithinMessages() {
        let messages = [
            ChatMessage(id: "first", role: .user, content: "needle before needle after"),
            ChatMessage(id: "second", role: .assistant, content: "no match here"),
            ChatMessage(id: "third", role: .assistant, content: "NEEDLE")
        ]

        let targets = chatFindTargets(in: messages, query: "needle")

        XCTAssertEqual(targets, [
            ChatFindTarget(itemID: "first", occurrenceIndex: 0),
            ChatFindTarget(itemID: "first", occurrenceIndex: 1),
            ChatFindTarget(itemID: "third", occurrenceIndex: 0)
        ])
    }

    func testSlashCommandParserClosesAfterCommandTokenIsAccepted() {
        XCTAssertEqual(SlashCommandParser.query(from: "/"), "")
        XCTAssertEqual(SlashCommandParser.query(from: "/liquid-glass-review"), "liquid-glass-review")
        XCTAssertNil(SlashCommandParser.query(from: "/liquid-glass-review "))
        XCTAssertNil(SlashCommandParser.query(from: "/compact summarize this turn"))
        XCTAssertNil(SlashCommandParser.query(from: "Ask Claude"))
    }

    func testProjectSkillsAppearInSlashCommandPalette() {
        let model = AppModel()
        model.skills = [
            SkillInfo(
                name: "liquid-glass-review",
                description: "Review LiquidCode screens for TOKENICODE layout parity.",
                path: "/tmp/liquid-glass-review/SKILL.md",
                scope: "project",
                disabled: false
            )
        ]

        let matches = model.filteredPaletteCommands("liquid-glass")
            .filter { $0.title.hasPrefix("/") }
            .map(\.title)

        XCTAssertEqual(matches, ["/liquid-glass-review"])
    }

    func testAgentActivityBuilderDerivesHistoricalToolCallsForAgentsPopover() {
        let messages = [
            ChatMessage(id: "assistant-tool", role: .assistant, content: """
            [tool_use: Task]
            {
              "description": "Review TOKENICODE visual parity"
            }
            """),
            ChatMessage(id: "tool-result", role: .tool, content: "Finished visual review", toolName: "Task", parentID: "assistant-tool")
        ]

        let calls = AgentActivityBuilder.toolCalls(from: messages, sessionID: "session")

        XCTAssertEqual(calls.map(\.name), ["Task", "Task"])
        XCTAssertEqual(calls.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(calls[0].inputPreview.contains("Review TOKENICODE visual parity"), true)
        XCTAssertEqual(calls[1].resultPreview, "Finished visual review")
        XCTAssertEqual(calls[1].parentID, "assistant-tool")
    }

    func testMarkdownImageReferenceParsesImageLinesAndRejectsNonImagesOrEmptySources() {
        XCTAssertEqual(
            markdownImageReference(from: "  ![Architecture diagram]( images/flow chart.png )  "),
            MarkdownImageReference(alt: "Architecture diagram", source: "images/flow chart.png")
        )

        XCTAssertNil(markdownImageReference(from: "[Architecture diagram](images/flow chart.png)"))
        XCTAssertNil(markdownImageReference(from: "![Architecture diagram]()"))
        XCTAssertNil(markdownImageReference(from: "![Architecture diagram](   )"))
    }

    func testMarkdownParserPreservesGFMTasksTablesRulesAndFencedCode() {
        let blocks = parseMarkdown("""
        # Plan

        - [x] inspect TOKENICODE
        - [ ] ship LiquidCode

        | Area | Status |
        | --- | --- |
        | UI | PASS |
        | Runtime | PARTIAL |

        ---

        ```swift
        print("ok")
        ```
        """)

        XCTAssertEqual(blocks, [
            .heading(1, "Plan"),
            .task(checked: true, "inspect TOKENICODE"),
            .task(checked: false, "ship LiquidCode"),
            .table(headers: ["Area", "Status"], rows: [["UI", "PASS"], ["Runtime", "PARTIAL"]]),
            .horizontalRule,
            .code("swift", #"print("ok")"#)
        ])
    }

    func testSelectingSessionsRestoresComposerAndAttachmentDraftsPerSession() throws {
        let alphaRoot = try temporaryDirectory(prefix: "lc-draft-alpha")
        let betaRoot = try temporaryDirectory(prefix: "lc-draft-beta")
        defer {
            try? FileManager.default.removeItem(at: alphaRoot)
            try? FileManager.default.removeItem(at: betaRoot)
        }

        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: alphaRoot.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
            SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: betaRoot.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
        ]

        let alphaAttachment = AttachmentChip(id: "alpha-attachment", name: "alpha.png", path: alphaRoot.appendingPathComponent("alpha.png").path, size: 11, isImage: true)
        let betaAttachment = AttachmentChip(id: "beta-attachment", name: "beta.txt", path: betaRoot.appendingPathComponent("beta.txt").path, size: 7, isImage: false)

        model.selectSession("alpha")
        model.updateComposerText("alpha draft")
        model.attachments = [alphaAttachment]

        model.selectSession("beta")
        XCTAssertEqual(model.composerText, "")
        XCTAssertEqual(model.attachments, [])
        model.updateComposerText("beta draft")
        model.attachments = [betaAttachment]

        model.selectSession("alpha")
        XCTAssertEqual(model.composerText, "alpha draft")
        XCTAssertEqual(model.attachments, [alphaAttachment])

        model.selectSession("beta")
        XCTAssertEqual(model.composerText, "beta draft")
        XCTAssertEqual(model.attachments, [betaAttachment])
    }

    func testSendingDuringActiveTurnQueuesAttachmentPayloadAndClearsSelectedDraft() throws {
        let root = try temporaryDirectory(prefix: "lc-active-turn")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true)
        ]
        let attachment = AttachmentChip(id: "payload", name: "diagram.png", path: root.appendingPathComponent("diagram.png").path, size: 42, isImage: true)

        model.selectSession("alpha")
        model.updateComposerText("  send with attachment  ")
        model.attachments = [attachment]
        model.activeTurnSnapshots["alpha"] = ActiveTurnSnapshot(messageID: "in-flight", content: "previous", attachments: [])

        model.sendComposer()

        let queued = try XCTUnwrap(model.pendingUserMessagesBySession["alpha"]?.first)
        XCTAssertEqual(model.pendingUserMessagesBySession["alpha"]?.count, 1)
        XCTAssertEqual(queued.content, "send with attachment")
        XCTAssertEqual(queued.attachments, [attachment])
        XCTAssertEqual(model.composerText, "")
        XCTAssertEqual(model.composerTextBySession["alpha"], "")
        XCTAssertEqual(model.attachments, [])
        XCTAssertEqual(model.attachmentsBySession["alpha"], [])
    }

    func testComposerControlsFeedNextStartSessionRequest() throws {
        let root = try temporaryDirectory(prefix: "lc-composer-controls")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true)
        ]
        model.settings.selectedModel = "claude-opus-4-6[1m]"
        model.settings.sessionMode = .plan
        model.settings.thinkingLevel = .max

        model.selectSession("alpha")
        model.updateComposerText("  use the selected controls  ")
        model.sendComposer()

        let request = try XCTUnwrap(engine.startRequests.first)
        XCTAssertEqual(engine.startRequests.count, 1)
        XCTAssertEqual(request.prompt, "use the selected controls")
        XCTAssertEqual(request.cwd, PathAccessManager.canonicalPath(root.path))
        XCTAssertEqual(request.model, "claude-opus-4-6[1m]")
        XCTAssertEqual(request.mode, .plan)
        XCTAssertEqual(request.thinkingLevel, .max)
        XCTAssertEqual(model.sendConfigurationBySession["alpha"], ComposerSendConfiguration(model: "claude-opus-4-6[1m]", mode: .plan, thinkingLevel: .max))
    }

    func testRewindRestoreAllRestoresCodeCheckpointAndTruncatesConversation() throws {
        let root = try temporaryDirectory(prefix: "lc-rewind-all")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine()
        engine.rewindOutput = "restored checkpoint"
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", cliResumeID: "cli-alpha")
        ]
        model.selectedSessionID = "alpha"
        model.messagesBySession["alpha"] = [
            ChatMessage(id: "u1", role: .user, content: "first"),
            ChatMessage(id: "a1", role: .assistant, content: "first answer"),
            ChatMessage(id: "u2", role: .user, content: "second", checkpointUuid: "checkpoint-2"),
            ChatMessage(id: "a2", role: .assistant, content: "second answer")
        ]
        model.streamingTextBySession["alpha"] = "still streaming"
        model.activeTurnSnapshots["alpha"] = ActiveTurnSnapshot(messageID: "a2", content: "second answer", attachments: [])
        engine.runningSessionIDs.insert("alpha")

        model.performRewind(.restoreAll)

        XCTAssertEqual(engine.rewindCalls.map { $0.checkpointUUID }, ["checkpoint-2"])
        XCTAssertEqual(engine.rewindCalls.first?.cliSessionID, "cli-alpha")
        XCTAssertEqual(engine.rewindCalls.first?.cwd, root.path)
        XCTAssertEqual(model.messagesBySession["alpha"]?.map(\.id), ["u1", "a1", "u2"])
        XCTAssertEqual(model.streamingTextBySession["alpha"], "")
        XCTAssertNil(model.activeTurnSnapshots["alpha"])
        XCTAssertFalse(engine.runningSessionIDs.contains("alpha"))
    }

    func testRewindConversationOnlyDoesNotRequireCheckpointOrRestoreFiles() throws {
        let root = try temporaryDirectory(prefix: "lc-rewind-conversation")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha")
        ]
        model.selectedSessionID = "alpha"
        model.messagesBySession["alpha"] = [
            ChatMessage(id: "u1", role: .user, content: "first"),
            ChatMessage(id: "a1", role: .assistant, content: "first answer")
        ]

        model.performRewind(.restoreConversation)

        XCTAssertTrue(engine.rewindCalls.isEmpty)
        XCTAssertEqual(model.messagesBySession["alpha"]?.map(\.id), ["u1"])
    }

    func testRewindCodeOnlyPreservesConversation() throws {
        let root = try temporaryDirectory(prefix: "lc-rewind-code")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", lastCheckpointUUID: "checkpoint-session")
        ]
        model.selectedSessionID = "alpha"
        model.messagesBySession["alpha"] = [
            ChatMessage(id: "u1", role: .user, content: "first"),
            ChatMessage(id: "a1", role: .assistant, content: "first answer")
        ]

        model.performRewind(.restoreCode)

        XCTAssertEqual(engine.rewindCalls.map { $0.checkpointUUID }, ["checkpoint-session"])
        XCTAssertEqual(model.messagesBySession["alpha"]?.map(\.id), ["u1", "a1"])
    }

    func testMCPAddUpdateDeletePersistOnlyAppLocalServers() throws {
        try withPreservedFile(AppPaths.shared.mcpFile) {
            try? FileManager.default.removeItem(at: AppPaths.shared.mcpFile)
            let model = AppModel()
            model.mcpServers = [
                MCPServer(name: "project-server", transport: "stdio", command: "node", url: nil, args: ["server.js"], source: "Project")
            ]

            model.addMCPServer(name: "local-http", command: "https://localhost:3000/mcp")
            let created = try XCTUnwrap(model.mcpServers.first { $0.name == "local-http" && $0.source == "LiquidCode" })
            XCTAssertEqual(created.transport, "http")
            XCTAssertEqual(created.url, "https://localhost:3000/mcp")

            model.updateMCPServer(created, name: "local-stdio", command: #"npx -y "server package""#)
            let updated = try XCTUnwrap(model.mcpServers.first { $0.name == "local-stdio" && $0.source == "LiquidCode" })
            XCTAssertEqual(updated.command, "npx")
            XCTAssertEqual(updated.args, ["-y", "server package"])

            let persisted = try Data(contentsOf: AppPaths.shared.mcpFile)
            let text = String(decoding: persisted, as: UTF8.self)
            XCTAssertTrue(text.contains("local-stdio"))
            XCTAssertFalse(text.contains("project-server"))

            model.deleteMCPServer(updated)
            let afterDelete = String(decoding: try Data(contentsOf: AppPaths.shared.mcpFile), as: UTF8.self)
            XCTAssertFalse(afterDelete.contains("local-stdio"))
        }
    }

    func testOpenFileSelectsPreviewModeByFileType() throws {
        try withPreservedRecentProjects {
            let root = try temporaryDirectory(prefix: "lc-file-mode")
            defer { try? FileManager.default.removeItem(at: root) }
            let html = root.appendingPathComponent("index.html")
            let swift = root.appendingPathComponent("Main.swift")
            let markdown = root.appendingPathComponent("README.md")
            try "<html><body>Hello</body></html>".write(to: html, atomically: true, encoding: .utf8)
            try "import SwiftUI\nstruct Main {}".write(to: swift, atomically: true, encoding: .utf8)
            try "# Readme".write(to: markdown, atomically: true, encoding: .utf8)

            let model = AppModel()
            model.loadProject(root.path)

            model.openFile(html.path)
            XCTAssertEqual(model.filePreviewMode, .html)
            XCTAssertEqual(model.filePreview, "<html><body>Hello</body></html>")

            model.openFile(swift.path)
            XCTAssertEqual(model.filePreviewMode, .source)

            model.openFile(markdown.path)
            XCTAssertEqual(model.filePreviewMode, .preview)
        }
    }

    func testReloadSelectedFileRereadsCurrentPathInsteadOfSamePathNoop() throws {
        try withPreservedRecentProjects {
            let root = try temporaryDirectory(prefix: "lc-file-reload")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("Main.swift")
            try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

            let model = AppModel()
            model.loadProject(root.path)
            model.openFile(file.path)
            XCTAssertEqual(model.filePreview, "let value = 1\n")

            try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
            model.reloadSelectedFile()

            XCTAssertEqual(model.selectedFilePath, file.path)
            XCTAssertEqual(model.filePreview, "let value = 2\n")
            XCTAssertFalse(model.fileEditDirty)
        }
    }

    func testLoadProjectClearsStaleWorkspaceChangeBadges() throws {
        try withPreservedRecentProjects {
            let root = try temporaryDirectory(prefix: "lc-workspace-reset")
            defer { try? FileManager.default.removeItem(at: root) }
            let stale = "/tmp/old-project/stale.txt"

            let model = AppModel()
            model.changedFiles.insert(stale)
            model.fileChangeBadges[stale] = "M"

            model.loadProject(root.path)

            XCTAssertTrue(model.changedFiles.isEmpty)
            XCTAssertTrue(model.fileChangeBadges.isEmpty)
            XCTAssertEqual(model.workingDirectory, PathAccessManager.canonicalPath(root.path))
        }
    }

    func testLoadProjectDropsMissingRecentProjectWithoutCreatingDraftOrWatchError() throws {
        try withPreservedRecentProjects {
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("lc-missing-recent-\(UUID().uuidString)", isDirectory: true)
                .path
            let model = AppModel()
            model.recentProjects = [RecentProject(name: "Gone", path: missing, lastUsed: Date())]

            model.loadProject(missing)

            XCTAssertTrue(model.sessions.isEmpty)
            XCTAssertTrue(model.recentProjects.isEmpty)
            XCTAssertNil(model.currentError)
            XCTAssertEqual(model.toast?.title, "Project unavailable")
            XCTAssertTrue(model.workingDirectory.isEmpty)
        }
    }

    func testSelectingMissingProjectSessionKeepsTranscriptButDoesNotRaiseWatchModal() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-missing-session-\(UUID().uuidString)", isDirectory: true)
            .path
        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "missing", path: nil, project: "Missing", projectDir: missing, modifiedAt: Date(), preview: "Old chat", isDraft: true)
        ]
        model.messagesBySession["missing"] = [ChatMessage(role: .assistant, content: "Old transcript remains readable.")]

        model.selectSession("missing")

        XCTAssertEqual(model.selectedSessionID, "missing")
        XCTAssertEqual(model.selectedMessages.first?.content, "Old transcript remains readable.")
        XCTAssertTrue(model.fileTree.isEmpty)
        XCTAssertNil(model.currentError)
        XCTAssertEqual(model.toast?.title, "Project unavailable")
    }

    func testSendRestoresDraftWhenSelectedProjectDirectoryDisappeared() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-missing-send-\(UUID().uuidString)", isDirectory: true)
            .path
        let engine = RecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "missing", path: nil, project: "Missing", projectDir: missing, modifiedAt: Date(), preview: "Draft", isDraft: true)
        ]

        model.selectSession("missing")
        model.updateComposerText("do not lose this")
        model.sendComposer()

        XCTAssertTrue(engine.startRequests.isEmpty)
        XCTAssertEqual(model.composerText, "do not lose this")
        XCTAssertEqual(model.currentError?.title, "Project unavailable")
    }

    func testSessionBatchArchiveGenerateTitleDeleteAndUndo() throws {
        let root = try temporaryDirectory(prefix: "lc-session-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha preview", isDraft: true)
        let beta = SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: root.path, modifiedAt: Date(), preview: "Beta preview", isDraft: true)
        let model = AppModel()
        model.sessions = [alpha, beta]
        model.messagesBySession["alpha"] = [ChatMessage(role: .user, content: "Build a native TOKENICODE parity interface with working controls.")]

        model.toggleSessionSelection(alpha)
        model.toggleSessionSelection(beta)
        model.archiveSelectedSessions()
        XCTAssertTrue(model.sessions.allSatisfy(\.archived))
        XCTAssertFalse(model.sessionSelectionMode)
        XCTAssertTrue(model.selectedSessionIDs.isEmpty)

        model.generateSessionTitle(alpha)
        XCTAssertEqual(model.sessions.first { $0.id == "alpha" }?.customTitle, "Build a native TOKENICODE parity interface")

        let archivedAlpha = try XCTUnwrap(model.sessions.first { $0.id == "alpha" })
        model.selectSession("alpha")
        model.deleteSession(archivedAlpha)
        XCTAssertNil(model.sessions.first { $0.id == "alpha" })
        XCTAssertNotNil(model.recentlyDeletedSession)

        model.undoLastSessionDelete()
        XCTAssertEqual(model.selectedSessionID, "alpha")
        XCTAssertNotNil(model.sessions.first { $0.id == "alpha" })
        XCTAssertEqual(model.messagesBySession["alpha"]?.first?.content, "Build a native TOKENICODE parity interface with working controls.")
    }

    func testTranscriptDisplayBuilderAppendsPendingPermissionInteractionsWithInlineMetadata() throws {
        let message = ChatMessage(id: "assistant-1", role: .assistant, content: "I need to inspect a file.")
        let permission = PermissionRequest(
            id: "permission-1",
            sessionID: "session-1",
            requestID: "request-1",
            toolName: "Read",
            title: "Read Package.swift",
            summary: "Read Package.swift before answering",
            inputJSON: #"{"file_path":"Package.swift"}"#,
            toolUseID: "tool-use-1",
            parentToolUseID: "parent-tool-1",
            agentID: "agent-1",
            risk: .readOnly
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message], pendingPermissions: [permission])

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.id, "assistant-1")
        XCTAssertEqual(items.last?.id, "interaction_permission-1")
        guard case .interaction(let displayedPermission) = items.last else {
            return XCTFail("expected pending permission to render as an inline interaction item")
        }
        XCTAssertEqual(displayedPermission.id, "permission-1")
        XCTAssertEqual(displayedPermission.sessionID, "session-1")
        XCTAssertEqual(displayedPermission.requestID, "request-1")
        XCTAssertEqual(displayedPermission.toolName, "Read")
        XCTAssertEqual(displayedPermission.title, "Read Package.swift")
        XCTAssertEqual(displayedPermission.summary, "Read Package.swift before answering")
        XCTAssertEqual(displayedPermission.inputJSON, #"{"file_path":"Package.swift"}"#)
        XCTAssertEqual(displayedPermission.toolUseID, "tool-use-1")
        XCTAssertEqual(displayedPermission.parentToolUseID, "parent-tool-1")
        XCTAssertEqual(displayedPermission.agentID, "agent-1")
        XCTAssertEqual(displayedPermission.risk, .readOnly)
    }

    func testTranscriptDisplayBuilderGroupsSingleToolUseWithResult() throws {
        let message = ChatMessage(
            id: "assistant-task",
            role: .assistant,
            content: """
            [tool_use: Task]
            {"description":"Compare TOKENICODE screenshots","subagent_type":"visual-reviewer"}
            [tool_result]
            Compared main-interface and settings.
            """
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        XCTAssertEqual(items.count, 1)
        guard case .toolRun(let runItems) = items.first else {
            return XCTFail("expected a single tool use and its result to render as one tool run")
        }
        XCTAssertEqual(runItems.map(\.kind), [.use, .result])
        XCTAssertEqual(runItems.first?.toolName, "Task")
        XCTAssertTrue(runItems[0].content.contains("subagent_type"))
        XCTAssertTrue(runItems[1].content.contains("Compared main-interface"))
    }

    func testTranscriptDisplayBuilderCollapsesConsecutiveToolUsesAndResultsIntoCompleteRun() throws {
        let message = ChatMessage(
            id: "assistant-tools",
            role: .assistant,
            content: """
            [tool_use: Read]
            {"file_path":"Package.swift"}
            [tool_use: Bash]
            {"command":"swift test"}
            [tool_result]
            read ok
            [tool_result]
            test ok
            """
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        XCTAssertEqual(items.count, 1)
        guard case .toolRun(let runItems) = items.first else {
            return XCTFail("expected consecutive tool items to collapse into one tool run")
        }
        XCTAssertEqual(runItems.map(\.kind), [.use, .use, .result, .result])
        XCTAssertEqual(runItems.filter { $0.kind == .use }.map(\.toolName), ["Read", "Bash"])
        XCTAssertTrue(TranscriptToolRunCompletion.isComplete(runItems))
    }

    func testTranscriptToolRunCompletionReturnsFalseWhenAGroupedRunLacksAResult() throws {
        let message = ChatMessage(
            id: "assistant-incomplete-tools",
            role: .assistant,
            content: """
            [tool_use: Read]
            {"file_path":"Package.swift"}
            [tool_use: Bash]
            {"command":"swift test"}
            [tool_result]
            read ok
            """
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        guard case .toolRun(let runItems) = items.first else {
            return XCTFail("expected two tool uses to remain represented as a grouped run")
        }
        XCTAssertEqual(runItems.map(\.kind), [.use, .use, .result])
        XCTAssertFalse(TranscriptToolRunCompletion.isComplete(runItems))
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withPreservedRecentProjects(_ body: () throws -> Void) throws {
        let url = AppPaths.shared.recentProjectsFile
        try withPreservedFile(url, body)
    }

    private func withPreservedFile(_ url: URL, _ body: () throws -> Void) throws {
        let original = try? Data(contentsOf: url)
        defer {
            if let original {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? original.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try body()
    }

    private final class RecordingEngine: ClaudeEngine, @unchecked Sendable {
        var startRequests: [ClaudeSessionStartRequest] = []
        var sentMessages: [(sessionID: String, text: String)] = []
        var rewindCalls: [(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String)] = []
        var rewindOutput: String?
        var runningSessionIDs: Set<String> = []

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
            startRequests.append(request)
            runningSessionIDs.insert(request.sessionID)
        }
        func sendMessage(sessionID: String, text: String) throws { sentMessages.append((sessionID, text)) }
        func sendRaw(sessionID: String, jsonLine: String) throws {}
        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? {
            rewindCalls.append((sessionID, cliSessionID, checkpointUUID, cwd))
            return rewindOutput
        }
        func listActiveProcesses() -> [String] { Array(runningSessionIDs).sorted() }
        func isSessionRunning(sessionID: String) -> Bool { runningSessionIDs.contains(sessionID) }
        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {}
        func interrupt(sessionID: String) throws {}
        func setPermissionMode(sessionID: String, mode: SessionMode) throws {}
        func setModel(sessionID: String, model: String?) throws {}
        func kill(sessionID: String) { runningSessionIDs.remove(sessionID) }
        func killAll() { runningSessionIDs.removeAll() }
    }
}
