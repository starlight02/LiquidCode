@testable import LiquidCode
import SwiftUI
import XCTest

@MainActor
// swiftlint:disable:next type_body_length
final class FeatureModelRegressionTests: XCTestCase {
    private static let tinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()

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

    func testSoftWrappedTranscriptTextAddsBreaksWithoutChangingVisibleContent() {
        let text = "[Image: source: /var/folders/1p/m5hsh06x3zxcvd3m57k43ykr0000gn/T/codex-clipboard-aacf5cbf-e56b-437f-ae37-acba7cf48700.png]"
        let wrapped = softWrappedTranscriptText(text)

        XCTAssertTrue(wrapped.contains("\u{200B}"))
        XCTAssertEqual(wrapped.replacingOccurrences(of: "\u{200B}", with: ""), text)
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
                description: "Review LiquidCode screens for layout parity.",
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

    func testProviderPresetsExposeExactAdvertisedProviders() throws {
        XCTAssertEqual(providerPresets.map { "\($0.id)=\($0.name)" }, [
            "anthropic=Anthropic",
            "deepseek=DeepSeek",
            "zhipu=智谱 GLM",
            "qwen-coder=Qwen Coder",
            "kimi-k2=Kimi k2",
            "minimax=MiniMax"
        ])

        let deepSeek = try XCTUnwrap(providerPresets.first { $0.id == "deepseek" })
        XCTAssertFalse(deepSeek.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(deepSeek.apiFormat, .openai)
        for tier in ["opus", "sonnet", "haiku"] {
            let mappedModel = try XCTUnwrap(deepSeek.modelMappings[tier], "DeepSeek must map \(tier) to a concrete provider model")
            XCTAssertFalse(mappedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testProviderConnectionProbeBuildsAnthropicMessagesRequestWithoutLeakingSecrets() throws {
        let provider = ProviderRecord(
            id: "anthropic",
            name: "Anthropic",
            baseURL: "https://api.anthropic.com",
            apiFormat: .anthropic,
            modelMappings: ["sonnet": "claude-3-5-sonnet-latest"],
            extraEnv: [:],
            preset: "anthropic"
        )

        let request = try ProviderConnectionProbe.makeRequest(
            provider: provider,
            apiKey: "sk-ant-secret",
            model: "claude-3-5-sonnet-latest"
        )
        let body = try decodedJSONBody(from: request)
        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-secret")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body["model"] as? String, "claude-3-5-sonnet-latest")
        XCTAssertFalse((body["messages"] as? [[String: Any]])?.isEmpty ?? true)
        XCTAssertFalse(bodyText.contains("sk-ant-secret"))
        XCTAssertFalse(request.url?.absoluteString.contains("sk-ant-secret") ?? true)
        XCTAssertFalse(bodyText.localizedCaseInsensitiveContains("placeholder"))
    }

    func testProviderConnectionProbeBuildsOpenAICompatibleChatRequestWithoutLeakingSecrets() throws {
        let provider = ProviderRecord(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1/",
            apiFormat: .openai,
            modelMappings: ["sonnet": "deepseek-chat"],
            extraEnv: [:],
            preset: "deepseek"
        )

        let request = try ProviderConnectionProbe.makeRequest(
            provider: provider,
            apiKey: "deepseek-secret",
            model: "deepseek-chat"
        )
        let body = try decodedJSONBody(from: request)
        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.deepseek.com")
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer deepseek-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(body["model"] as? String, "deepseek-chat")
        XCTAssertFalse((body["messages"] as? [[String: Any]])?.isEmpty ?? true)
        XCTAssertFalse(bodyText.contains("deepseek-secret"))
        XCTAssertFalse(request.url?.absoluteString.contains("deepseek-secret") ?? true)
        XCTAssertFalse(bodyText.localizedCaseInsensitiveContains("placeholder"))
    }

    private struct SyntaxHighlightCase {
        var language: String
        var line: String
        var token: String
    }

    func testCodeSyntaxHighlightingStylesAdvertisedLanguages() throws {
        let cases: [SyntaxHighlightCase] = [
            SyntaxHighlightCase(language: "swift", line: "let value = try await load()", token: "let"),
            SyntaxHighlightCase(language: "python", line: "def render(value):", token: "def"),
            SyntaxHighlightCase(language: "typescript", line: "export const answer: number = 42", token: "export"),
            SyntaxHighlightCase(language: "rust", line: "fn main() { let value = true; }", token: "fn"),
            SyntaxHighlightCase(language: "go", line: "func main() { var value int }", token: "func"),
            SyntaxHighlightCase(language: "java", line: "public class Main {}", token: "public"),
            SyntaxHighlightCase(language: "c++", line: "std::vector<int> values;", token: "std"),
            SyntaxHighlightCase(language: "sql", line: "SELECT id FROM users WHERE active = TRUE", token: "SELECT"),
            SyntaxHighlightCase(language: "markdown", line: "## Release notes", token: "##"),
            SyntaxHighlightCase(language: "json", line: #""enabled": true"#, token: "true"),
            SyntaxHighlightCase(language: "yaml", line: "enabled: true", token: "enabled"),
            SyntaxHighlightCase(language: "html", line: #"<section class="hero">"#, token: "section"),
            SyntaxHighlightCase(language: "css", line: ".hero { color: red; }", token: "color"),
            SyntaxHighlightCase(language: "xml", line: #"<note priority="high">"#, token: "note")
        ]

        for testCase in cases {
            let highlighted = highlightCodeLine(testCase.line, language: testCase.language)
            XCTAssertEqual(String(highlighted.characters), testCase.line, testCase.language)
            XCTAssertTrue(
                highlightedTokenHasSyntaxAttributes(testCase.token, in: highlighted),
                "Expected \(testCase.language) token '\(testCase.token)' to receive syntax attributes"
            )
        }
    }

    func testAgentActivityBuilderUsesSubagentMetadataForHistoricalTaskCalls() throws {
        let messages = [
            ChatMessage(id: "task-tool-1", role: .assistant, content: """
            [tool_use: Task]
            {"description":"Compare reference screenshots","subagent_type":"visual-reviewer"}
            """),
            ChatMessage(id: "task-result-1", role: .tool, content: "Visual parity review finished", toolName: "Task", parentID: "task-tool-1")
        ]

        let calls = AgentActivityBuilder.toolCalls(from: messages, sessionID: "session")

        XCTAssertEqual(calls.map(\.name), ["visual-reviewer", "visual-reviewer"])
        XCTAssertEqual(calls.map(\.status), [.succeeded, .succeeded])
        XCTAssertTrue(calls[0].inputPreview.contains("Compare reference screenshots"))
        XCTAssertTrue(calls[0].inputPreview.contains("visual-reviewer"))
        XCTAssertEqual(calls[1].resultPreview, "Visual parity review finished")
        XCTAssertEqual(calls[1].parentID, "task-tool-1")
    }

    func testAgentActivityBuilderDerivesHistoricalToolCallsForAgentsPopover() {
        let messages = [
            ChatMessage(id: "assistant-tool", role: .assistant, content: """
            [tool_use: Task]
            {
              "description": "Review visual parity"
            }
            """),
            ChatMessage(id: "tool-result", role: .tool, content: "Finished visual review", toolName: "Task", parentID: "assistant-tool")
        ]

        let calls = AgentActivityBuilder.toolCalls(from: messages, sessionID: "session")

        XCTAssertEqual(calls.map(\.name), ["Task", "Task"])
        XCTAssertEqual(calls.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(calls[0].inputPreview.contains("Review visual parity"), true)
        XCTAssertEqual(calls[1].resultPreview, "Finished visual review")
        XCTAssertEqual(calls[1].parentID, "assistant-tool")
    }

    func testAgentActivityBuilderDisplayItemPathMatchesMessagePathForToolRuns() throws {
        let timestamp = Date(timeIntervalSince1970: 1_234)
        let messages = [
            ChatMessage(
                id: "assistant-structured",
                role: .assistant,
                content: "",
                timestamp: timestamp,
                blocks: [
                    ChatContentBlock(
                        id: "tool-use-1",
                        kind: .toolUse,
                        toolUseID: "tool-use-1",
                        toolName: "Task",
                        inputJSON: #"{"description":"Review perf regression","subagent_type":"perf-reviewer"}"#
                    )
                ]
            ),
            ChatMessage(
                id: "structured-result",
                role: .assistant,
                content: "",
                timestamp: timestamp.addingTimeInterval(1),
                parentID: "assistant-structured",
                blocks: [
                    ChatContentBlock(
                        id: "result-1",
                        kind: .toolResult,
                        text: "Perf review finished",
                        toolUseID: "tool-use-1"
                    )
                ]
            ),
            ChatMessage(id: "legacy-tool", role: .assistant, content: """
            [tool_use: Bash]
            {"command":"xcodebuild test"}
            """, timestamp: timestamp.addingTimeInterval(2)),
            ChatMessage(id: "legacy-result", role: .tool, content: "Tests passed", timestamp: timestamp.addingTimeInterval(3), toolName: "Bash", parentID: "legacy-tool")
        ]
        let displayItems = TranscriptDisplayBuilder.displayItems(messages: messages)

        let fromMessages = AgentActivityBuilder.toolCalls(from: messages, sessionID: "session")
        let fromDisplayItems = AgentActivityBuilder.toolCalls(fromDisplayItems: displayItems, sessionID: "session")

        XCTAssertEqual(fromDisplayItems, fromMessages)
        XCTAssertEqual(fromDisplayItems.map(\.id), ["legacy-tool_agent_0", "legacy-result_agent_1"])
        XCTAssertEqual(fromDisplayItems.map(\.name), ["Bash", "Bash"])
        XCTAssertEqual(
            fromDisplayItems.map(\.inputPreview),
            [
                "[tool_use: Bash]\n{\"command\":\"xcodebuild test\"}",
                ""
            ]
        )
        XCTAssertEqual(fromDisplayItems.map(\.resultPreview), ["", "Tests passed"])
        XCTAssertEqual(fromDisplayItems.map(\.parentID), [nil, "legacy-tool"])
    }

    func testTranscriptDisplayBuilderRendersStructuredToolResultOnlyMessageAsToolOutput() throws {
        let message = ChatMessage(
            id: "tool-result-message",
            role: .tool,
            content: "",
            blocks: [
                ChatContentBlock(
                    id: "tool-1-result",
                    kind: .toolResult,
                    text: "API Error: overloaded_error",
                    toolUseID: "tool-1",
                    isError: true
                )
            ]
        )

        let displayItems = TranscriptDisplayBuilder.displayItems(messages: [message])

        XCTAssertEqual(displayItems.count, 1)
        guard case .tool(let item) = try XCTUnwrap(displayItems.first) else {
            return XCTFail("tool_result-only protocol messages must render as tool output, not a user bubble")
        }
        XCTAssertEqual(item.kind, .result)
        XCTAssertEqual(item.toolUseID, "tool-1")
        XCTAssertEqual(item.content, "API Error: overloaded_error")
        XCTAssertTrue(item.isError)
    }

    func testTranscriptDisplayBuilderPreservesProviderFailureAsErrorMessage() throws {
        let message = ChatMessage(
            id: "assistant-provider-error",
            role: .error,
            content: "API Error: 529 overloaded_error\nUpstream provider overloaded."
        )

        let displayItems = TranscriptDisplayBuilder.displayItems(messages: [message])

        XCTAssertEqual(displayItems.count, 1)
        guard case .message(let item) = try XCTUnwrap(displayItems.first) else {
            return XCTFail("provider failures must render as transcript error messages")
        }
        XCTAssertEqual(item.role, .error)
        XCTAssertNotEqual(item.role, .assistant)
        XCTAssertTrue(item.content.contains("overloaded_error"))
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

    func testComposerImageContentBuildsClaudeImageBlockWithoutPathText() throws {
        let root = try temporaryDirectory(prefix: "lc-image-content")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("diagram.png")
        try Self.tinyPNGData.write(to: imageURL)
        let attachment = AttachmentChip(name: "diagram.png", path: imageURL.path, size: Int64(Self.tinyPNGData.count), isImage: true)

        let payload = try composerUserMessageContent("inspect this", attachments: [attachment])
        XCTAssertEqual(payload.text, "inspect this")
        XCTAssertFalse(payload.text.contains(imageURL.path))

        let blocks = try XCTUnwrap(try payload.jsonContent() as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        XCTAssertEqual(blocks.first?["text"] as? String, "inspect this")
        let imageBlock = try XCTUnwrap(blocks.last)
        XCTAssertEqual(imageBlock["type"] as? String, "image")
        let source = try XCTUnwrap(imageBlock["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertFalse((source["data"] as? String ?? "").isEmpty)
    }

    func testMarkdownParserPreservesGFMTasksTablesRulesAndFencedCode() {
        let blocks = parseMarkdown("""
        # Plan

        - [x] inspect reference app
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
            .task(checked: true, "inspect reference app"),
            .task(checked: false, "ship LiquidCode"),
            .table(headers: ["Area", "Status"], rows: [["UI", "PASS"], ["Runtime", "PARTIAL"]]),
            .horizontalRule,
            .code("swift", #"print("ok")"#)
        ])
    }

    func testToolResultPreviewIsCappedAtFiveLinesBeforeScrolling() {
        XCTAssertEqual(toolPreviewVisibleLineLimit, 5)
        XCTAssertEqual(toolPreviewLineCount("one"), 1)
        XCTAssertFalse(toolPreviewNeedsScroll("1\n2\n3\n4\n5"))
        XCTAssertTrue(toolPreviewNeedsScroll("1\n2\n3\n4\n5\n6"))
    }

    func testCodeEditingToolPayloadRendersUnifiedDiffPreview() throws {
        let payload = #"{"file_path":"Sources/App.swift","old_string":"let old = true\nprint(old)","new_string":"let new = true\nprint(new)"}"#

        let diff = try XCTUnwrap(toolPayloadDiff(payload, toolName: "Edit"))

        XCTAssertTrue(diff.contains("--- Sources/App.swift"))
        XCTAssertTrue(diff.contains("+++ Sources/App.swift"))
        XCTAssertTrue(diff.contains("-let old = true"))
        XCTAssertTrue(diff.contains("+let new = true"))
        XCTAssertNil(toolPayloadDiff(#"{"file_path":"README.md"}"#, toolName: "Read"))
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

    func testComposerDefaultsLoadFromClaudeUserSettingsOnBootstrap() throws {
        let home = try temporaryDirectory(prefix: "lc-cc-settings-bootstrap")
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "model": "opus",
          "permissions": { "defaultMode": "bypassPermissions" },
          "env": {
            "ANTHROPIC_DEFAULT_FABLE_MODEL": "claude-opus-4-8[1M]",
            "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "claude-opus-4-8",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1M]",
            "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "claude-opus-4-8",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
            "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "glm-5.2",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "claude-haiku-4-5",
            "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
            "KEEP_ME": "1"
          },
          "skipDangerousModePermissionPrompt": true
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let model = AppModel(
            engine: RecordingEngine(),
            claudeUserSettings: ClaudeUserSettingsService(home: home)
        )

        try withPreservedFile(AppPaths.shared.settingsFile) {
            try withPreservedRecentProjects {
                model.bootstrap()
            }
        }

        XCTAssertEqual(model.settings.selectedModel, "opus")
        XCTAssertEqual(model.settings.sessionMode, .bypass)
        XCTAssertEqual(model.settings.thinkingLevel, .xhigh)
        XCTAssertEqual(defaultModels, ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(defaultModels.map { model.modelMenuDisplayName($0) }, [
            "Fable · claude-opus-4-8",
            "Opus · claude-opus-4-8",
            "Sonnet · glm-5.2",
            "Haiku · claude-haiku-4-5"
        ])
        XCTAssertEqual(model.modelDisplayName("opus"), "claude-opus-4-8")
        XCTAssertEqual(model.modelDisplayName("claude-opus-4-8[1m]"), "claude-opus-4-8")
        XCTAssertEqual(model.modelDisplayName("sonnet"), "glm-5.2")
        XCTAssertEqual(model.modelDisplayName("haiku"), "claude-haiku-4-5")
        XCTAssertEqual(model.modelToolbarDisplayName("opus", compact: true), "Opus")
        XCTAssertEqual(model.modelToolbarDisplayName("opus", compact: false), "Opus · claude-opus-4-8")
        XCTAssertTrue(model.isComposerModelSelected("opus"))
        XCTAssertFalse(model.isComposerModelSelected("fable"))
    }

    func testBootstrapPreservesPerSessionComposerConfigurationsWhenSyncingClaudeDefaults() throws {
        let home = try temporaryDirectory(prefix: "lc-bootstrap-session-config")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = ClaudeUserSettingsService(home: home)
        let claudeSettingsURL = service.settingsURL
        try FileManager.default.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "model": "sonnet",
          "permissions": { "defaultMode": "bypassPermissions" },
          "env": { "CLAUDE_CODE_EFFORT_LEVEL": "low" }
        }
        """.write(to: claudeSettingsURL, atomically: true, encoding: .utf8)

        let preservedConfigurations = [
            "alpha": ComposerSendConfiguration(model: "opus", mode: .plan, thinkingLevel: .max),
            "beta": ComposerSendConfiguration(model: "haiku", mode: .ask, thinkingLevel: .off)
        ]
        var storedSettings = AppSettings()
        storedSettings.selectedModel = "old-default"
        storedSettings.sessionMode = .ask
        storedSettings.thinkingLevel = .high
        storedSettings.sessionConfigurations = preservedConfigurations

        try withPreservedFile(AppPaths.shared.settingsFile) {
            try withPreservedRecentProjects {
                try? FileManager.default.removeItem(at: AppPaths.shared.recentProjectsFile)
                try JSONFile.save(storedSettings, to: AppPaths.shared.settingsFile)

                let model = AppModel(engine: RecordingEngine(), claudeUserSettings: service)
                model.bootstrap()

                XCTAssertEqual(model.defaultComposerConfiguration, ComposerSendConfiguration(model: "sonnet", mode: .bypass, thinkingLevel: .low))
                XCTAssertEqual(model.sendConfigurationBySession, preservedConfigurations)
                let savedSettings = try XCTUnwrap(JSONFile.load(AppSettings.self, from: AppPaths.shared.settingsFile))
                XCTAssertEqual(savedSettings.sessionConfigurations, preservedConfigurations)

                model.sessions = [
                    SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: home.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
                    SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: home.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
                ]

                model.selectSession("alpha")
                XCTAssertEqual(model.settings.selectedModel, "opus")
                XCTAssertEqual(model.settings.sessionMode, .plan)
                XCTAssertEqual(model.settings.thinkingLevel, .max)

                model.selectSession("beta")
                XCTAssertEqual(model.settings.selectedModel, "haiku")
                XCTAssertEqual(model.settings.sessionMode, .ask)
                XCTAssertEqual(model.settings.thinkingLevel, .off)
            }
        }
    }

    func testComposerControlChangesWriteClaudeDefaultsOnlyOnStartScreenAndRuntimeOnlyInChat() throws {
        let home = try temporaryDirectory(prefix: "lc-cc-settings-write")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = ClaudeUserSettingsService(home: home)
        let settingsURL = service.settingsURL
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "model": "opus",
          "permissions": { "defaultMode": "bypassPermissions" },
          "env": { "CLAUDE_CODE_EFFORT_LEVEL": "max", "KEEP_ME": "1" },
          "skipDangerousModePermissionPrompt": true
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let engine = RecordingEngine()
        let model = AppModel(engine: engine, claudeUserSettings: service)
        model.settings.selectedModel = "opus"
        model.settings.sessionMode = .bypass
        model.settings.thinkingLevel = .max

        try withPreservedFile(AppPaths.shared.settingsFile) {
            model.setComposerMode(.plan)
            model.setComposerThinkingLevel(.xhigh)
            model.setComposerModel("sonnet")

            let startRaw = try decodedJSONObject(from: settingsURL)
            XCTAssertEqual(startRaw["model"] as? String, "sonnet")
            XCTAssertEqual((startRaw["permissions"] as? [String: Any])?["defaultMode"] as? String, "plan")
            XCTAssertEqual(startRaw["alwaysThinkingEnabled"] as? Bool, true)
            XCTAssertEqual((startRaw["env"] as? [String: Any])?["CLAUDE_CODE_EFFORT_LEVEL"] as? String, "xhigh")
            XCTAssertEqual((startRaw["env"] as? [String: Any])?["KEEP_ME"] as? String, "1")
            XCTAssertEqual(startRaw["skipDangerousModePermissionPrompt"] as? Bool, true)

            let defaultsAfterStartScreen = try Data(contentsOf: settingsURL)
            model.selectedSessionID = "chat-1"
            engine.runningSessionIDs.insert("chat-1")

            model.setComposerMode(.ask)
            model.setComposerThinkingLevel(.high)
            model.setComposerModel("haiku")

            XCTAssertEqual(try Data(contentsOf: settingsURL), defaultsAfterStartScreen)
            XCTAssertEqual(engine.runtimeUpdates.count, 3)
            XCTAssertEqual(engine.runtimeUpdates[0].sessionID, "chat-1")
            XCTAssertEqual(engine.runtimeUpdates[0].mode, .ask)
            XCTAssertNil(engine.runtimeUpdates[0].model)
            XCTAssertNil(engine.runtimeUpdates[0].thinkingLevel)
            XCTAssertEqual(engine.runtimeUpdates[1].sessionID, "chat-1")
            XCTAssertEqual(engine.runtimeUpdates[1].thinkingLevel, .high)
            XCTAssertNil(engine.runtimeUpdates[1].model)
            XCTAssertNil(engine.runtimeUpdates[1].mode)
            XCTAssertEqual(engine.runtimeUpdates[2].sessionID, "chat-1")
            XCTAssertEqual(engine.runtimeUpdates[2].model, "haiku")
            XCTAssertNil(engine.runtimeUpdates[2].mode)
            XCTAssertNil(engine.runtimeUpdates[2].thinkingLevel)
        }
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

    func testComposerConfigurationRestoresPerSessionWhenSwitchingConversations() throws {
        let root = try temporaryDirectory(prefix: "lc-session-config")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
            SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: root.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
        ]

        try withPreservedFile(AppPaths.shared.settingsFile) {
            model.selectSession("alpha")
            model.setComposerModel("claude-opus-4-6[1m]")
            model.setComposerMode(.plan)
            model.setComposerThinkingLevel(.max)

            model.selectSession("beta")
            model.setComposerModel("claude-sonnet-4-6")
            model.setComposerMode(.ask)
            model.setComposerThinkingLevel(.low)

            model.selectSession("alpha")
            XCTAssertEqual(model.settings.selectedModel, "claude-opus-4-6[1m]")
            XCTAssertEqual(model.settings.sessionMode, .plan)
            XCTAssertEqual(model.settings.thinkingLevel, .max)

            model.selectSession("beta")
            XCTAssertEqual(model.settings.selectedModel, "claude-sonnet-4-6")
            XCTAssertEqual(model.settings.sessionMode, .ask)
            XCTAssertEqual(model.settings.thinkingLevel, .low)
        }
    }

    func testSelectingUnconfiguredConversationRestoresDefaultComposerConfiguration() throws {
        let root = try temporaryDirectory(prefix: "lc-session-config-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.defaultComposerConfiguration = ComposerSendConfiguration(model: "sonnet", mode: .ask, thinkingLevel: .high)
        model.settings.selectedModel = "sonnet"
        model.settings.sessionMode = .ask
        model.settings.thinkingLevel = .high
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
            SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: root.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
        ]

        try withPreservedFile(AppPaths.shared.settingsFile) {
            model.selectSession("alpha")
            model.setComposerModel("opus")
            model.setComposerMode(.plan)
            model.setComposerThinkingLevel(.max)

            model.selectSession("beta")

            XCTAssertEqual(model.settings.selectedModel, "sonnet")
            XCTAssertEqual(model.settings.sessionMode, .ask)
            XCTAssertEqual(model.settings.thinkingLevel, .high)
        }
    }

    func testConversationSwitchSnapshotsDirectConfigurationMutations() throws {
        let root = try temporaryDirectory(prefix: "lc-session-config-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.defaultComposerConfiguration = ComposerSendConfiguration(model: "sonnet", mode: .ask, thinkingLevel: .high)
        model.settings.selectedModel = "sonnet"
        model.settings.sessionMode = .ask
        model.settings.thinkingLevel = .high
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
            SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: root.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
        ]

        try withPreservedFile(AppPaths.shared.settingsFile) {
            model.selectSession("alpha")
            model.settings.selectedModel = "opus"
            model.settings.sessionMode = .plan
            model.settings.thinkingLevel = .max

            model.selectSession("beta")

            XCTAssertEqual(model.sendConfigurationBySession["alpha"], ComposerSendConfiguration(model: "opus", mode: .plan, thinkingLevel: .max))
            XCTAssertEqual(model.settings.selectedModel, "sonnet")
            XCTAssertEqual(model.settings.sessionMode, .ask)
            XCTAssertEqual(model.settings.thinkingLevel, .high)

            model.selectSession("alpha")
            XCTAssertEqual(model.settings.selectedModel, "opus")
            XCTAssertEqual(model.settings.sessionMode, .plan)
            XCTAssertEqual(model.settings.thinkingLevel, .max)
        }
    }

    func testSessionLoadCachesMessagesEvenWhenSwitchingAwayBeforeLoadCompletes() async throws {
        let root = try temporaryDirectory(prefix: "lc-session-load-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let alphaLog = root.appendingPathComponent("alpha.jsonl")
        let betaLog = root.appendingPathComponent("beta.jsonl")
        try #"{"type":"user","uuid":"alpha-user","timestamp":"2026-07-05T00:00:00Z","message":{"role":"user","content":"alpha cached while away"}}"#
            .write(to: alphaLog, atomically: true, encoding: .utf8)
        try #"{"type":"user","uuid":"beta-user","timestamp":"2026-07-05T00:00:01Z","message":{"role":"user","content":"beta selected"}}"#
            .write(to: betaLog, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "alpha", path: alphaLog.path, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha"),
            SessionRecord(id: "beta", path: betaLog.path, project: "Beta", projectDir: root.path, modifiedAt: Date(), preview: "Beta")
        ]

        model.selectSession("alpha")
        model.selectSession("beta")

        try await waitUntilAsync(timeout: 4) {
            model.messagesBySession["alpha"]?.first?.content == "alpha cached while away"
        }
        XCTAssertEqual(model.selectedSessionID, "beta")
        XCTAssertEqual(model.displayItemsBySession["alpha"]?.count, 1)
        XCTAssertEqual(model.loadingMessageSessionIDs.contains("alpha"), false)
    }

    func testDeferredWorkspaceReloadsDoNotPublishStaleProjectResultsAfterSessionSwitch() async throws {
        let alphaRoot = try temporaryDirectory(prefix: "lc-stale-alpha")
        let betaRoot = try temporaryDirectory(prefix: "lc-stale-beta")
        defer {
            try? FileManager.default.removeItem(at: alphaRoot)
            try? FileManager.default.removeItem(at: betaRoot)
        }
        try writeWorkspaceReloadFixtures(
            root: alphaRoot,
            fileName: "alpha-only.txt",
            skillName: "alpha-skill",
            mcpName: "alpha-server"
        )
        try writeWorkspaceReloadFixtures(
            root: betaRoot,
            fileName: "beta-only.txt",
            skillName: "beta-skill",
            mcpName: "beta-server"
        )
        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: alphaRoot.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
            SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: betaRoot.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
        ]

        model.selectSession("alpha")
        model.reloadFileTreeDeferred(debounceNanoseconds: 250_000_000)
        model.reloadMCPAndSkillsDeferred(debounceNanoseconds: 250_000_000)
        model.selectSession("beta")
        model.reloadFileTreeDeferred()
        model.reloadMCPAndSkillsDeferred()

        try await waitUntilAsync(timeout: 4) {
            model.fileTree.contains { $0.name == "beta-only.txt" }
                && model.skills.contains { $0.name == "beta-skill" }
                && model.mcpServers.contains { $0.name == "beta-server" }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.selectedSessionID, "beta")
        XCTAssertEqual(model.workingDirectory, PathAccessManager.canonicalPath(betaRoot.path))
        XCTAssertTrue(model.fileTree.contains { $0.name == "beta-only.txt" })
        XCTAssertTrue(model.skills.contains { $0.name == "beta-skill" })
        XCTAssertTrue(model.mcpServers.contains { $0.name == "beta-server" })
        XCTAssertFalse(model.fileTree.contains { $0.name == "alpha-only.txt" })
        XCTAssertFalse(model.skills.contains { $0.name == "alpha-skill" })
        XCTAssertFalse(model.mcpServers.contains { $0.name == "alpha-server" })
    }

    func testWorkspaceWatcherIgnoresOldRootEventsAfterSessionSwitch() async throws {
        let alphaRoot = try temporaryDirectory(prefix: "lc-watch-alpha")
        let betaRoot = try temporaryDirectory(prefix: "lc-watch-beta")
        let model = AppModel()
        defer {
            model.cancelDeferredWorkspaceWatch()
            try? FileManager.default.removeItem(at: alphaRoot)
            try? FileManager.default.removeItem(at: betaRoot)
        }
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: alphaRoot.path, modifiedAt: Date(), preview: "Alpha", isDraft: true),
            SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: betaRoot.path, modifiedAt: Date(), preview: "Beta", isDraft: true)
        ]

        model.selectSession("alpha")
        model.selectSession("beta")

        let betaWatchMessage = watcherStateMessage(
            model: model,
            root: betaRoot.path,
            expectation: "Expected beta workspace watcher to become active after session switch"
        )
        try await waitUntilAsync(timeout: 4, message: betaWatchMessage) {
            model.directoryWatcher.isWatching(betaRoot.path)
        }

        let alphaLate = alphaRoot.appendingPathComponent("alpha-late.txt")
        let betaLate = betaRoot.appendingPathComponent("beta-late.txt")
        let alphaPath = PathAccessManager.canonicalPath(alphaLate.path)
        let betaPath = PathAccessManager.canonicalPath(betaLate.path)
        try "stale alpha".write(to: alphaLate, atomically: true, encoding: .utf8)
        try "current beta".write(to: betaLate, atomically: true, encoding: .utf8)

        let betaChangeMessage = watcherStateMessage(
            model: model,
            root: betaRoot.path,
            expectation: "Expected beta file change to be delivered by active workspace watcher"
        )
        try await waitUntilAsync(timeout: 4, message: betaChangeMessage) {
            model.changedFiles.contains(betaPath)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(model.selectedSessionID, "beta")
        XCTAssertEqual(model.workingDirectory, PathAccessManager.canonicalPath(betaRoot.path))
        XCTAssertTrue(model.changedFiles.contains(betaPath))
        XCTAssertFalse(
            model.changedFiles.contains(alphaPath),
            "A stale watcher startup or late old-root event must not mark the active workspace dirty after switching sessions."
        )
        XCTAssertNil(model.fileChangeBadges[alphaPath])
    }

    func testCancelledWorkspaceWatcherStartupCannotPublishOldRootEvents() async throws {
        let alphaRoot = try temporaryDirectory(prefix: "lc-cancel-watch-alpha")
        let betaRoot = try temporaryDirectory(prefix: "lc-cancel-watch-beta")
        let watcher = DirectoryWatchManager()
        let alphaEvents = PathEventRecorder()
        let betaEvents = PathEventRecorder()
        defer {
            watcher.unwatchAll()
            try? FileManager.default.removeItem(at: alphaRoot)
            try? FileManager.default.removeItem(at: betaRoot)
        }
        let alphaToken = DirectoryWatchManager.WatchToken()
        let betaToken = DirectoryWatchManager.WatchToken()
        watcher.requestWatchDirectory(alphaRoot.path, token: alphaToken)
        watcher.requestWatchDirectory(betaRoot.path, token: betaToken)

        let staleStarted = try watcher.watchRequestedDirectory(alphaRoot.path, token: alphaToken) { paths in
            alphaEvents.append(paths)
        }
        XCTAssertFalse(staleStarted)
        XCTAssertTrue(try watcher.watchRequestedDirectory(betaRoot.path, token: betaToken) { paths in
            betaEvents.append(paths)
        })

        let alphaLate = alphaRoot.appendingPathComponent("alpha-late.txt")
        let betaLate = betaRoot.appendingPathComponent("beta-late.txt")
        let betaPath = PathAccessManager.canonicalPath(betaLate.path)
        try "stale alpha".write(to: alphaLate, atomically: true, encoding: .utf8)
        try "current beta".write(to: betaLate, atomically: true, encoding: .utf8)

        try await waitUntilAsync(timeout: 4) {
            betaEvents.values.flatMap { $0 }.contains(betaPath)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(betaEvents.values.flatMap { $0 }.contains(betaPath))
        XCTAssertTrue(
            alphaEvents.values.isEmpty,
            "A cancelled watcher startup must not install an old-root stream that can publish stale file changes."
        )
    }

    func testImageOnlyComposerCanStartSessionWithImageContent() throws {
        let root = try temporaryDirectory(prefix: "lc-image-only")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("only.png")
        try Self.tinyPNGData.write(to: imageURL)
        let engine = RecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true)
        ]
        model.selectSession("alpha")
        model.attachments = [AttachmentChip(name: "only.png", path: imageURL.path, size: Int64(Self.tinyPNGData.count), isImage: true)]

        model.sendComposer()

        let request = try XCTUnwrap(engine.startRequests.first)
        XCTAssertEqual(request.prompt, "")
        let blocks = try XCTUnwrap(try request.userMessageContent.jsonContent() as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?["type"] as? String, "image")
        XCTAssertEqual(model.messagesBySession["alpha"]?.first?.images.count, 1)
        XCTAssertEqual(model.attachments, [])
    }

    func testFirstComposerSendWithoutSelectedSessionCreatesSessionWithImageAttachmentAndRestoresDraft() throws {
        try withPreservedFile(AppPaths.shared.settingsFile) {
            try withPreservedRecentProjects {
                let root = try temporaryDirectory(prefix: "lc-first-send-root")
                let otherRoot = try temporaryDirectory(prefix: "lc-first-send-other")
                defer {
                    try? FileManager.default.removeItem(at: root)
                    try? FileManager.default.removeItem(at: otherRoot)
                }
                let imageURL = root.appendingPathComponent("first.png")
                try Self.tinyPNGData.write(to: imageURL)
                let attachment = AttachmentChip(id: "first-image", name: "first.png", path: imageURL.path, size: Int64(Self.tinyPNGData.count), isImage: true)
                let engine = RecordingEngine()
                let model = AppModel(engine: engine)
                defer { model.cancelDeferredWorkspaceWatch() }
                model.workingDirectory = root.path
                model.updateComposerText("  describe this image  ")
                model.attachments = [attachment]

                XCTAssertNil(model.selectedSessionID)
                model.sendComposer()
                model.cancelDeferredWorkspaceWatch()

                let sessionID = try XCTUnwrap(model.selectedSessionID)
                XCTAssertEqual(model.sessions.count, 1)
                XCTAssertEqual(model.sessions.first?.id, sessionID)
                XCTAssertEqual(model.sessions.first?.projectDir, root.path)
                XCTAssertEqual(engine.startRequests.count, 1)
                let request = try XCTUnwrap(engine.startRequests.first)
                XCTAssertEqual(request.sessionID, sessionID)
                XCTAssertEqual(request.prompt, "describe this image")
                XCTAssertEqual(request.cwd, PathAccessManager.canonicalPath(root.path))
                let blocks = try XCTUnwrap(try request.userMessageContent.jsonContent() as? [[String: Any]])
                XCTAssertEqual(blocks.count, 2)
                XCTAssertEqual(blocks.first?["type"] as? String, "text")
                XCTAssertEqual(blocks.first?["text"] as? String, "describe this image")
                XCTAssertEqual(blocks.last?["type"] as? String, "image")
                XCTAssertEqual(model.messagesBySession[sessionID]?.first?.content, "describe this image")
                XCTAssertEqual(model.messagesBySession[sessionID]?.first?.attachments, [attachment])
                XCTAssertEqual(model.messagesBySession[sessionID]?.first?.images.count, 1)
                XCTAssertEqual(model.composerText, "")
                XCTAssertEqual(model.composerTextBySession[sessionID], "")
                XCTAssertEqual(model.attachments, [])
                XCTAssertEqual(model.attachmentsBySession[sessionID], [])

                model.sessions.append(SessionRecord(id: "other", path: nil, project: "Other", projectDir: otherRoot.path, modifiedAt: Date(), preview: "Other", isDraft: true))
                model.updateComposerText("follow-up draft")
                model.attachments = [attachment]
                model.selectSession("other")
                model.cancelDeferredWorkspaceWatch()
                XCTAssertEqual(model.composerText, "")
                XCTAssertEqual(model.attachments, [])

                model.selectSession(sessionID)
                model.cancelDeferredWorkspaceWatch()
                XCTAssertEqual(model.composerText, "follow-up draft")
                XCTAssertEqual(model.attachments, [attachment])
            }
        }
    }

    func testLegacyImageMarkersAreParsedAsImagesAndRemovedFromVisibleText() throws {
        let root = try temporaryDirectory(prefix: "lc-image-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try Self.tinyPNGData.write(to: first)
        try Self.tinyPNGData.write(to: second)

        let object: [String: Any] = [
            "type": "human",
            "uuid": "u-images",
            "message": [
                "role": "user",
                "content": """
                [Image: source: \(first.path)]
                please compare

                Attached files:
                \(second.path)
                """
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.images.count, 2)
        XCTAssertEqual(message.content, "please compare")
        XCTAssertFalse(message.content.contains("[Image: source:"))
        XCTAssertFalse(message.content.contains("Attached files:"))
        XCTAssertFalse(message.content.contains(first.path))
        XCTAssertFalse(message.content.contains(second.path))
    }

    func testDownloadedClaudeCodeCLIPathSendsApprovesPermissionAndRendersToolResult() async throws {
        let root = try temporaryDirectory(prefix: "lc-sidecar-app")
        let home = try temporaryDirectory(prefix: "lc-sidecar-home")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        let localClaudeBin = home.appendingPathComponent(".claude/local", isDirectory: true)
        let fakeTrace = home.appendingPathComponent("fake-claude-trace.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localClaudeBin, withIntermediateDirectories: true)
        let fakeClaude = localClaudeBin.appendingPathComponent("claude")
        try makeExecutablePythonScript(at: fakeClaude, body: #"""
        import json
        import os
        import sys

        trace_path = os.environ.get("LC_FAKE_CLAUDE_TRACE")

        def trace(line):
            if trace_path:
                with open(trace_path, "a", encoding="utf-8") as handle:
                    handle.write(line + "\n")

        def emit(obj):
            print(json.dumps(obj), flush=True)

        first = sys.stdin.readline()
        trace("first:" + first.strip())
        emit({"type": "system", "session_id": "cli-app-integration"})
        emit({
            "type": "assistant",
            "uuid": "assistant-tool",
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "I will run a command."},
                    {"type": "tool_use", "id": "tool-1", "name": "Bash", "input": {"command": "echo ok"}}
                ]
            }
        })
        emit({
            "type": "control_request",
            "request_id": "perm-1",
            "request": {
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "description": "Run echo ok",
                "input": {"command": "echo ok"},
                "tool_use_id": "tool-1"
            }
        })
        second = sys.stdin.readline()
        trace("second:" + second.strip())
        emit({
            "type": "user",
            "uuid": "tool-result-message",
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "tool-1", "content": "ok\\n"}
                ]
            }
        })
        emit({"type": "result", "subtype": "success", "session_id": "cli-app-integration"})
        """#)

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "\(localClaudeBin.path):\(bin.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["LIQUIDCODE_CLAUDE_EXECUTABLE"] = fakeClaude.path
        env["LIQUIDCODE_FORCE_CLI_SIDECAR"] = "1"
        env["LC_FAKE_CLAUDE_TRACE"] = fakeTrace.path
        let sidecar = try XCTUnwrap(SidecarClaudeEngine.locateSidecarScript())
        let engine = SidecarClaudeEngine(home: home, environment: env, sidecarScript: sidecar)
        let model = AppModel(engine: engine)
        defer { engine.killAll() }
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha", isDraft: true)
        ]
        model.selectSession("alpha")
        model.updateComposerText("run the integration path")

        model.sendComposer()

        try await waitUntilAsync(timeout: 4) {
            model.pendingPermissions.contains { $0.requestID == "perm-1" }
        }
        guard let permission = model.pendingPermissions.first(where: { $0.requestID == "perm-1" }) else {
            XCTFail("expected sidecar permission perm-1; \(debugState(model: model, traceFile: fakeTrace))")
            return
        }
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertEqual(permission.toolUseID, "tool-1")
        XCTAssertEqual(permission.risk, .shell)

        model.respondPermission(permission, allow: true)

        try await waitUntilAsync(timeout: 4) {
            model.selectedToolCalls.contains { $0.id == "tool-1" && $0.status == .succeeded && $0.resultPreview.contains("ok") }
        }
        guard let tool = model.selectedToolCalls.first(where: { $0.id == "tool-1" }) else {
            XCTFail("expected rendered tool result tool-1; \(debugState(model: model, traceFile: fakeTrace))")
            return
        }
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertTrue(tool.inputPreview.contains("echo ok"))
        XCTAssertTrue(model.pendingPermissions.isEmpty)
        XCTAssertTrue(model.selectedMessages.contains { $0.role == .assistant && $0.content.contains("I will run a command.") })
    }

    func testSidecarSendsImageContentBlocksToClaudeCLI() async throws {
        let home = try temporaryDirectory(prefix: "lc-sidecar-image-home")
        let root = try temporaryDirectory(prefix: "lc-sidecar-image-root")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        let fakeTrace = home.appendingPathComponent("fake-claude-image-trace.log")
        let fakeClaude = home.appendingPathComponent("claude")
        try makeExecutablePythonScript(at: fakeClaude, body: #"""
        import json
        import os
        import sys

        first = sys.stdin.readline()
        with open(os.environ["LC_FAKE_CLAUDE_TRACE"], "w", encoding="utf-8") as handle:
            handle.write(first.strip() + "\n")
        print(json.dumps({"type": "result", "subtype": "success"}), flush=True)
        """#)

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "\(home.path):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["LIQUIDCODE_CLAUDE_EXECUTABLE"] = fakeClaude.path
        env["LIQUIDCODE_FORCE_CLI_SIDECAR"] = "1"
        env["LC_FAKE_CLAUDE_TRACE"] = fakeTrace.path
        let sidecar = try XCTUnwrap(SidecarClaudeEngine.locateSidecarScript())
        let engine = SidecarClaudeEngine(home: home, environment: env, sidecarScript: sidecar)
        defer { engine.killAll() }

        let content = ClaudeUserMessageContent(images: [
            MessageImageReference(data: Self.tinyPNGData, mimeType: "image/png", displayName: "tiny.png", size: Int64(Self.tinyPNGData.count))
        ])
        try engine.startSession(ClaudeSessionStartRequest(
            prompt: "",
            content: content,
            cwd: root.path,
            model: nil,
            sessionID: "image-wire",
            resumeSessionID: nil,
            thinkingLevel: .off,
            mode: .ask,
            provider: nil,
            providerAPIKey: nil
        ), eventSink: { _ in })

        try await waitUntilAsync(timeout: 4) {
            FileManager.default.fileExists(atPath: fakeTrace.path)
        }
        let line = try String(contentsOf: fakeTrace, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?["type"] as? String, "image")
        let source = try XCTUnwrap(blocks.first?["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertFalse((source["data"] as? String ?? "").isEmpty)
        XCTAssertFalse(line.contains("Attached files:"))
        XCTAssertFalse(line.contains("/tiny.png"))
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
        model.streamingMessagesBySession["alpha"] = ChatMessage(
            role: .assistant,
            content: "still streaming",
            blocks: [ChatContentBlock(kind: .text, text: "still streaming")]
        )
        model.activeTurnSnapshots["alpha"] = ActiveTurnSnapshot(messageID: "a2", content: "second answer", attachments: [])
        engine.runningSessionIDs.insert("alpha")

        model.performRewind(.restoreAll)

        XCTAssertEqual(engine.rewindCalls.map { $0.checkpointUUID }, ["checkpoint-2"])
        XCTAssertEqual(engine.rewindCalls.first?.cliSessionID, "cli-alpha")
        XCTAssertEqual(engine.rewindCalls.first?.cwd, root.path)
        XCTAssertEqual(model.messagesBySession["alpha"]?.map(\.id), ["u1", "a1", "u2"])
        XCTAssertEqual(model.streamingTextBySession["alpha"], "")
        XCTAssertNil(model.streamingMessagesBySession["alpha"])
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
            let text = try XCTUnwrap(String(data: persisted, encoding: .utf8))
            XCTAssertTrue(text.contains("local-stdio"))
            XCTAssertFalse(text.contains("project-server"))

            model.deleteMCPServer(updated)
            let afterDelete = try XCTUnwrap(String(data: try Data(contentsOf: AppPaths.shared.mcpFile), encoding: .utf8))
            XCTAssertFalse(afterDelete.contains("local-stdio"))
        }
    }

    func testOpenFileSelectsPreviewModeByFileType() async throws {
        let root = try temporaryDirectory(prefix: "lc-file-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let html = root.appendingPathComponent("index.html")
        let swift = root.appendingPathComponent("Main.swift")
        let markdown = root.appendingPathComponent("README.md")
        let htmlContent = "<html><body>Hello</body></html>"
        let swiftContent = "import SwiftUI\nstruct Main {}"
        let markdownContent = "# Readme"
        try htmlContent.write(to: html, atomically: true, encoding: .utf8)
        try swiftContent.write(to: swift, atomically: true, encoding: .utf8)
        try markdownContent.write(to: markdown, atomically: true, encoding: .utf8)

        let model = AppModel()

        model.openFile(html.path)
        XCTAssertEqual(model.filePreviewMode, .html)
        try await waitUntilAsync(timeout: 2) { model.filePreview == htmlContent }

        model.openFile(swift.path)
        XCTAssertEqual(model.filePreviewMode, .source)
        try await waitUntilAsync(timeout: 2) { model.filePreview == swiftContent }

        model.openFile(markdown.path)
        XCTAssertEqual(model.filePreviewMode, .preview)
        try await waitUntilAsync(timeout: 2) { model.filePreview == markdownContent }
    }

    func testRequestOpenFileImmediatelySelectsPathBeforeAsyncPreviewContent() async throws {
        let root = try temporaryDirectory(prefix: "lc-file-open-immediate")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Main.swift")
        let content = "let value = 1"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()

        let opened = model.requestOpenFile(file.path)

        XCTAssertTrue(opened)
        XCTAssertEqual(model.selectedFilePath, file.path)
        XCTAssertEqual(model.secondaryTab, .files)
        XCTAssertEqual(model.filePreview, "")
        XCTAssertEqual(model.filePreviewCleanContent, "")
        XCTAssertFalse(model.fileEditDirty)

        try await waitUntilAsync(timeout: 2) { model.filePreview == content }
        XCTAssertEqual(model.filePreviewCleanContent, content)
        XCTAssertFalse(model.fileEditDirty)
    }

    func testRequestInsertFileContentReadsTargetPathWithoutChangingSelection() throws {
        let root = try temporaryDirectory(prefix: "lc-file-insert-request")
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.md")
        let target = root.appendingPathComponent("Notes.md")
        let selectedPreview = "already open preview"
        let targetContent = "line one\nline two"
        try selectedPreview.write(to: selected, atomically: true, encoding: .utf8)
        try targetContent.write(to: target, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.selectedFilePath = selected.path
        model.filePreview = selectedPreview
        model.filePreviewCleanContent = selectedPreview
        model.updateComposerText("Before")

        model.requestInsertFileContent(target.path)

        XCTAssertEqual(model.selectedFilePath, selected.path)
        XCTAssertEqual(model.filePreview, selectedPreview)
        XCTAssertEqual(model.composerText, "Before\n\n```\n\(targetContent)\n```")
    }

    func testToolbarInsertSelectedContentReadsRealContentWhenPreviewIsLoading() throws {
        let root = try temporaryDirectory(prefix: "lc-file-insert-toolbar")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Notes.md")
        let content = "toolbar line one\ntoolbar line two"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.selectedFilePath = file.path
        model.filePreview = ""
        model.filePreviewCleanContent = ""
        model.filePreviewLoadingPath = file.path
        model.fileEditDirty = false
        model.updateComposerText("Before")

        model.insertSelectedContentIntoChat()

        XCTAssertEqual(model.selectedFilePath, file.path)
        XCTAssertEqual(model.composerText, "Before\n\n```\n\(content)\n```")
        XCTAssertEqual(model.filePreview, "")
        XCTAssertEqual(model.filePreviewCleanContent, "")
        XCTAssertFalse(model.fileEditDirty)
    }

    func testToolbarInsertSelectedContentUsesDirtyPreviewInsteadOfDiskDuringPreviewLoading() throws {
        let root = try temporaryDirectory(prefix: "lc-file-insert-dirty-toolbar")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Notes.md")
        try "disk content".write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.selectedFilePath = file.path
        model.filePreview = "unsaved preview draft"
        model.filePreviewCleanContent = ""
        model.filePreviewLoadingPath = file.path
        model.markFilePreviewEdited()
        model.updateComposerText("Before")

        model.insertSelectedContentIntoChat()

        XCTAssertTrue(model.fileEditDirty)
        XCTAssertEqual(model.composerText, "Before\n\n```\nunsaved preview draft\n```")
    }

    func testSaveSelectedFileWithoutOwnedPreviewContentDoesNotTruncateSelection() throws {
        let root = try temporaryDirectory(prefix: "lc-file-save-unowned")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Notes.md")
        let original = "must survive selection-only preview"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        XCTAssertTrue(model.requestSelectFilePath(file.path))
        XCTAssertEqual(model.selectedFilePath, file.path)
        XCTAssertEqual(model.filePreview, "")
        XCTAssertNil(model.filePreviewContentPath)

        model.saveSelectedFile()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        XCTAssertFalse(model.changedFiles.contains(file.path))
    }

    func testLoadedEmptyFileCanBecomeDirtyAndSave() async throws {
        let root = try temporaryDirectory(prefix: "lc-file-save-empty-owned")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Empty.md")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.openFile(file.path)
        try await waitUntilAsync(timeout: 2) { model.sameFilePath(model.filePreviewContentPath, file.path) }
        XCTAssertEqual(model.filePreview, "")
        XCTAssertFalse(model.fileEditDirty)
        XCTAssertTrue(model.selectedFilePreviewCanSave)

        model.filePreview = "new content"
        model.markFilePreviewEdited()
        XCTAssertTrue(model.fileEditDirty)

        model.saveSelectedFile()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new content")
        XCTAssertFalse(model.fileEditDirty)
        XCTAssertTrue(model.sameFilePath(model.filePreviewContentPath, file.path))
    }

    func testReloadSelectedFileRereadsCurrentPathInsteadOfSamePathNoop() async throws {
        let root = try temporaryDirectory(prefix: "lc-file-reload")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Main.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.openFile(file.path)
        try await waitUntilAsync(timeout: 2) { model.filePreview == "let value = 1\n" }

        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        model.reloadSelectedFile()

        XCTAssertEqual(model.selectedFilePath, file.path)
        try await waitUntilAsync(timeout: 2) { model.filePreview == "let value = 2\n" }
        XCTAssertFalse(model.fileEditDirty)
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
            let missing = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("lc-missing-recent-\(UUID().uuidString)", isDirectory: true)
                .path
            let model = AppModel()
            model.recentProjects = [RecentProject(name: "Gone", path: missing, lastUsed: Date())]

            model.loadProject(missing)

            XCTAssertTrue(model.sessions.isEmpty)
            XCTAssertTrue(model.recentProjects.isEmpty)
            XCTAssertNil(model.currentError)
            XCTAssertEqual(model.toast?.title, L("Project unavailable"))
            XCTAssertTrue(model.workingDirectory.isEmpty)
        }
    }

    func testSelectingMissingProjectSessionKeepsTranscriptButDoesNotRaiseWatchModal() throws {
        let missing = FileManager.default
            .temporaryDirectory
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
        XCTAssertEqual(model.toast?.title, L("Project unavailable"))
    }

    func testSendRestoresDraftWhenSelectedProjectDirectoryDisappeared() throws {
        let missing = FileManager.default
            .temporaryDirectory
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
        XCTAssertEqual(model.currentError?.title, L("Project unavailable"))
    }

    func testSessionBatchArchiveGenerateTitleDeleteAndUndo() throws {
        let root = try temporaryDirectory(prefix: "lc-session-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha preview", isDraft: true)
        let beta = SessionRecord(id: "beta", path: nil, project: "Beta", projectDir: root.path, modifiedAt: Date(), preview: "Beta preview", isDraft: true)
        let model = AppModel()
        model.sessions = [alpha, beta]
        model.messagesBySession["alpha"] = [ChatMessage(role: .user, content: "Build a native LiquidCode parity interface with working controls.")]

        model.toggleSessionSelection(alpha)
        model.toggleSessionSelection(beta)
        model.archiveSelectedSessions()
        XCTAssertTrue(model.sessions.allSatisfy(\.archived))
        XCTAssertFalse(model.sessionSelectionMode)
        XCTAssertTrue(model.selectedSessionIDs.isEmpty)

        model.generateSessionTitle(alpha)
        XCTAssertEqual(model.sessions.first { $0.id == "alpha" }?.customTitle, "Build a native LiquidCode parity interface")

        let archivedAlpha = try XCTUnwrap(model.sessions.first { $0.id == "alpha" })
        model.selectSession("alpha")
        model.deleteSession(archivedAlpha)
        XCTAssertNil(model.sessions.first { $0.id == "alpha" })
        XCTAssertNotNil(model.recentlyDeletedSession)

        model.undoLastSessionDelete()
        XCTAssertEqual(model.selectedSessionID, "alpha")
        XCTAssertNotNil(model.sessions.first { $0.id == "alpha" })
        XCTAssertEqual(model.messagesBySession["alpha"]?.first?.content, "Build a native LiquidCode parity interface with working controls.")
    }

    func testTranscriptDisplayBuilderAppendsPendingPermissionInteractionsWithInlineMetadata() throws {
        let message = ChatMessage(id: "assistant-1", role: .assistant, content: "I need to inspect a file.")
        let permission = PermissionRequest(
            id: "permission-1",
            sessionID: "session-1",
            requestID: "request-1",
            toolName: "Read",
            title: "Read README.md",
            summary: "Read README.md before answering",
            inputJSON: #"{"file_path":"README.md"}"#,
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
        XCTAssertEqual(displayedPermission.title, "Read README.md")
        XCTAssertEqual(displayedPermission.summary, "Read README.md before answering")
        XCTAssertEqual(displayedPermission.inputJSON, #"{"file_path":"README.md"}"#)
        XCTAssertEqual(displayedPermission.toolUseID, "tool-use-1")
        XCTAssertEqual(displayedPermission.parentToolUseID, "parent-tool-1")
        XCTAssertEqual(displayedPermission.agentID, "agent-1")
        XCTAssertEqual(displayedPermission.risk, .readOnly)
    }

    func testTranscriptDisplayBuilderUsesStructuredToolBlocksWithoutRawMarkers() throws {
        let message = ChatMessage(
            id: "assistant-structured",
            role: .assistant,
            content: "I will inspect the file.",
            blocks: [
                ChatContentBlock(kind: .text, text: "I will inspect the file."),
                ChatContentBlock(kind: .toolUse, toolUseID: "tool-read", toolName: "Read", inputJSON: #"{"file_path":"README.md"}"#),
                ChatContentBlock(kind: .toolResult, text: "README contents", toolUseID: "tool-read")
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        XCTAssertEqual(items.count, 2)
        guard case .message(let textMessage) = items.first else {
            return XCTFail("expected assistant text before tool cards")
        }
        XCTAssertEqual(textMessage.content, "I will inspect the file.")
        XCTAssertFalse(textMessage.content.contains("[tool_use:"))
        guard case .toolRun(let runItems) = items.last else {
            return XCTFail("expected structured tool use/result to group into one run")
        }
        XCTAssertEqual(runItems.map(\.kind), [.use, .result])
        XCTAssertEqual(runItems.first?.toolUseID, "tool-read")
        XCTAssertEqual(runItems.first?.toolName, "Read")
        XCTAssertTrue(runItems.first?.content.contains("README.md") == true)
        XCTAssertEqual(runItems.last?.content, "README contents")
    }

    func testRuntimeStreamsThinkingToolInputAndQuestionThroughTranscript() throws {
        let model = AppModel()
        model.selectedSessionID = "session-1"

        model.handle(.streamBlockDelta(sessionID: "session-1", index: 0, kind: .thinking, text: "Need to ask a clarifying question."))
        model.handle(.streamBlockStarted(
            sessionID: "session-1",
            index: 1,
            ChatContentBlock(kind: .toolUse, toolUseID: "ask-stream-1", toolName: "AskUserQuestion", inputJSON: "")
        ))
        model.handle(.streamBlockDelta(
            sessionID: "session-1",
            index: 1,
            kind: .toolUse,
            text: #"{"questions":[{"header":"范围","question":"要先处理哪一块？","options":[{"label":"渲染","description":"先修消息渲染"},{"label":"性能","description":"先修切换卡顿"}]}]}"#
        ))

        let streaming = try XCTUnwrap(model.selectedStreamingMessage)
        XCTAssertEqual(streaming.blocks.map(\.kind), [.thinking, .toolUse])
        XCTAssertEqual(model.selectedToolCalls.first?.id, "ask-stream-1")
        XCTAssertEqual(model.selectedToolCalls.first?.status, .streamingInput)
        XCTAssertTrue(model.selectedToolCalls.first?.inputPreview.contains("要先处理哪一块") == true)

        let items = TranscriptDisplayBuilder.displayItems(messages: [streaming])
        XCTAssertEqual(items.count, 2)
        guard case .message(let thinking) = items.first else {
            return XCTFail("expected streaming thinking to render through transcript")
        }
        XCTAssertEqual(thinking.role, .thinking)
        XCTAssertEqual(thinking.content, "Need to ask a clarifying question.")
        guard case .question(let question) = items.last else {
            return XCTFail("expected streaming AskUserQuestion to render as question card")
        }
        XCTAssertEqual(question.toolUseID, "ask-stream-1")
        XCTAssertTrue(question.inputJSON.contains("先修消息渲染"))
    }

    func testSelectedTranscriptDisplayItemsUseCacheUntilPendingPermissionRequiresMerge() throws {
        let model = AppModel()
        model.selectedSessionID = "session-1"
        let source = ChatMessage(id: "source", role: .assistant, content: "source")
        let cached = ChatMessage(id: "cached-display", role: .assistant, content: "cached")
        model.setMessages([source], for: "session-1", displayItems: [.message(cached)])

        XCTAssertEqual(model.selectedTranscriptDisplayItems.map(\.id), ["cached-display"])

        model.pendingPermissions = [
            PermissionRequest(
                id: "permission-1",
                sessionID: "session-1",
                requestID: "request-1",
                toolName: "Read",
                title: "Read",
                summary: "Read a file",
                inputJSON: #"{"file_path":"README.md"}"#,
                toolUseID: "tool-1",
                parentToolUseID: nil,
                agentID: nil,
                risk: .readOnly
            )
        ]

        XCTAssertEqual(model.selectedTranscriptDisplayItems.map(\.id), ["source", "interaction_permission-1"])
    }

    func testTranscriptDisplayBuilderDeduplicatesAskUserQuestionAgainstPendingPermission() throws {
        let input = #"{"questions":[{"header":"下一步","question":"接下来你想让我做什么？","options":[{"label":"说明任务","description":"告诉我目标"},{"label":"先聊一下","description":"不动代码"}]}]}"#
        let message = ChatMessage(
            id: "assistant-question",
            role: .assistant,
            content: "",
            toolName: "AskUserQuestion",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "ask-1", toolName: "AskUserQuestion", inputJSON: input)
            ]
        )
        let permission = PermissionRequest(
            id: "permission-1",
            sessionID: "session-1",
            requestID: "request-1",
            toolName: "AskUserQuestion",
            title: "Claude asks",
            summary: "接下来你想让我做什么？",
            inputJSON: input,
            toolUseID: "ask-1",
            parentToolUseID: nil,
            agentID: nil,
            risk: .readOnly
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message], pendingPermissions: [permission, permission])

        XCTAssertEqual(items.count, 1)
        guard case .interaction(let displayedPermission) = items.first else {
            return XCTFail("expected one active question interaction, not raw tool card plus duplicates")
        }
        XCTAssertEqual(displayedPermission.toolUseID, "ask-1")
        XCTAssertEqual(displayedPermission.toolName, "AskUserQuestion")
    }

    func testTranscriptDisplayBuilderDeduplicatesAskUserQuestionByPromptSignatureWhenIDsDiffer() throws {
        let input = #"{"questions":[{"header":"下一步","question":"接下来你想让我做什么？","options":[{"label":"说明任务","description":"告诉我目标"},{"label":"先聊一下","description":"不动代码"}]}]}"#
        let message = ChatMessage(
            id: "assistant-question",
            role: .assistant,
            content: "",
            toolName: "AskUserQuestion",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "history-tool-id", toolName: "AskUserQuestion", inputJSON: input)
            ]
        )
        let permission = PermissionRequest(
            id: "permission-1",
            sessionID: "session-1",
            requestID: "runtime-request-id",
            toolName: "AskUserQuestion",
            title: "Claude asks",
            summary: "接下来你想让我做什么？",
            inputJSON: input,
            toolUseID: "runtime-tool-id",
            parentToolUseID: nil,
            agentID: nil,
            risk: .readOnly
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message], pendingPermissions: [permission])

        XCTAssertEqual(items.count, 1)
        guard case .interaction(let displayedPermission) = items.first else {
            return XCTFail("expected active question only when history and pending runtime IDs differ")
        }
        XCTAssertEqual(displayedPermission.toolUseID, "runtime-tool-id")
    }

    func testTranscriptDisplayBuilderGroupsSingleToolUseWithResult() throws {
        let message = ChatMessage(
            id: "assistant-task",
            role: .assistant,
            content: """
            [tool_use: Task]
            {"description":"Compare reference screenshots","subagent_type":"visual-reviewer"}
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
            {"file_path":"README.md"}
            [tool_use: Bash]
            {"command":"xcodebuild test -project LiquidCode.xcodeproj -scheme LiquidCode"}
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

    func testToolPayloadKeyValuesRenderScalarJSONValuesWithoutCrashing() {
        let values = toolPayloadKeyValues("""
        {
          "description": "Run tests",
          "count": 3,
          "success": true,
          "ratio": 0.75,
          "missing": null,
          "args": ["swift", "test"],
          "meta": {"retries": 1}
        }
        """)

        let dict = Dictionary(uniqueKeysWithValues: values)
        XCTAssertEqual(dict["description"], "Run tests")
        XCTAssertEqual(dict["count"], "3")
        XCTAssertEqual(dict["success"], "true")
        XCTAssertEqual(dict["ratio"], "0.75")
        XCTAssertEqual(dict["missing"], "null")
        XCTAssertEqual(dict["args"], #"["swift","test"]"#)
        XCTAssertEqual(dict["meta"], #"{"retries":1}"#)
    }

    private func decodedJSONBody(from request: URLRequest) throws -> [String: Any] {
        let bodyData = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: bodyData)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func decodedJSONObject(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func highlightedTokenHasSyntaxAttributes(_ token: String, in attributed: AttributedString) -> Bool {
        guard let tokenRange = attributed.range(of: token) else {
            return false
        }
        return attributed[tokenRange].runs.contains { run in
            run.foregroundColor != nil || run.font != nil
        }
    }

    private func writeWorkspaceReloadFixtures(root: URL, fileName: String, skillName: String, mcpName: String) throws {
        try "workspace marker".write(to: root.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        let skillDirectory = root.appendingPathComponent(".claude/skills/\(skillName)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: \(skillName)
        description: Project-scoped stale reload sentinel.
        ---

        # \(skillName)
        """.write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let mcpDirectory = root.appendingPathComponent(".liquidcode", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpDirectory, withIntermediateDirectories: true)
        try """
        {"mcpServers":{"\(mcpName)":{"command":"\(mcpName)"}}}
        """.write(to: mcpDirectory.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func watcherStateMessage(model: AppModel, root: String, expectation: String) -> String {
        let canonicalRoot = PathAccessManager.canonicalPath(root)
        let error = "\(model.currentError?.title ?? "<none>") \(model.currentError?.message ?? "")"
        return [
            expectation,
            "workingDirectory=\(model.workingDirectory)",
            "generation=\(model.workspaceWatchGeneration)",
            "isWatching=\(model.directoryWatcher.isWatching(canonicalRoot))",
            "currentError=\(error)"
        ].joined(separator: "; ")
    }

    private func waitUntilAsync(
        timeout: TimeInterval,
        interval: UInt64 = 25_000_000,
        message: @autoclosure () -> String = "Timed out waiting for async condition",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: interval)
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    private func debugState(model: AppModel, traceFile: URL) -> String {
        let trace = (try? String(contentsOf: traceFile, encoding: .utf8)) ?? "<no fake claude trace>"
        let permissions = model.pendingPermissions
            .map { "\($0.requestID):\($0.toolName):\($0.toolUseID ?? "-")" }
            .joined(separator: ",")
        let tools = model.selectedToolCalls
            .map { "\($0.id):\($0.name):\($0.status.rawValue):\($0.resultPreview)" }
            .joined(separator: "|")
        let messages = model.selectedMessages
            .map { "\($0.role.rawValue):\($0.content.prefix(80))" }
            .joined(separator: "|")
        return "error=\(model.currentError?.title ?? "<none>") \(model.currentError?.message ?? ""); permissions=[\(permissions)]; tools=[\(tools)]; messages=[\(messages)]; trace=\(trace)"
    }

    private func makeExecutablePythonScript(at url: URL, body: String) throws {
        let script = "#!/usr/bin/env python3\n" + body + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

    private final class PathEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []
        var values: [[String]] {
            lock.lock(); defer { lock.unlock() }; return storage
        }

        func append(_ paths: [String]) {
            lock.lock(); storage.append(paths); lock.unlock()
        }
    }

    private struct RewindCall {
        let sessionID: String
        let cliSessionID: String?
        let checkpointUUID: String
        let cwd: String
    }

    private struct RuntimeUpdate {
        let sessionID: String
        let model: String?
        let mode: SessionMode?
        let thinkingLevel: ThinkingLevel?
    }

    private final class RecordingEngine: ClaudeEngine, @unchecked Sendable {
        var startRequests: [ClaudeSessionStartRequest] = []
        var sentMessages: [(sessionID: String, content: ClaudeUserMessageContent)] = []
        var rewindCalls: [RewindCall] = []
        var runtimeUpdates: [RuntimeUpdate] = []
        var rewindOutput: String?
        var runningSessionIDs: Set<String> = []

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
            startRequests.append(request)
            runningSessionIDs.insert(request.sessionID)
        }

        func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {
            sentMessages.append((sessionID, content))
        }

        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? {
            rewindCalls.append(RewindCall(sessionID: sessionID, cliSessionID: cliSessionID, checkpointUUID: checkpointUUID, cwd: cwd))
            return rewindOutput
        }

        func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {
            runtimeUpdates.append(RuntimeUpdate(sessionID: sessionID, model: model, mode: mode, thinkingLevel: thinkingLevel))
        }

        func isSessionRunning(sessionID: String) -> Bool {
            runningSessionIDs.contains(sessionID)
        }

        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {}
        func interrupt(sessionID: String) throws {}
        func kill(sessionID: String) {
            runningSessionIDs.remove(sessionID)
        }

        func killAll() {
            runningSessionIDs.removeAll()
        }
    }
}
