@testable import LiquidCode
import XCTest

@MainActor
final class SubagentRegressionTests: XCTestCase {
    func testSubagentSpawnParserRecognizesAgentAndTaskPayloads() {
        let json = #"{"subagent_type":"Explore","description":"Map the codebase","prompt":"Find files"}"#

        XCTAssertTrue(SubagentSpawnParser.isSpawnTool("Agent"))
        XCTAssertTrue(SubagentSpawnParser.isSpawnTool("Task"))
        XCTAssertFalse(SubagentSpawnParser.isSpawnTool("Read"))
        XCTAssertEqual(SubagentSpawnParser.parse(inputJSON: json)?.subagentType, "Explore")
        XCTAssertEqual(SubagentSpawnParser.parse(inputJSON: json)?.description, "Map the codebase")
    }

    func testTaskNotificationParsesToolUseAndTaskID() throws {
        let text = #"""
        <task-notification>
        <task-id>a123</task-id>
        <tool-use-id>tool-spawn-1</tool-use-id>
        <status>failed</status>
        <summary>Subagent failed during review.</summary>
        </task-notification>
        """#

        let event = try XCTUnwrap(claudeControlTranscriptEvent(from: text))

        XCTAssertEqual(event.kind, .taskFailure)
        XCTAssertEqual(event.toolUseID, "tool-spawn-1")
        XCTAssertEqual(event.taskID, "a123")
        XCTAssertEqual(event.body, "Subagent failed during review.")
    }

    func testBuilderEmitsSubagentItemAndKeepsItOutOfToolRuns() {
        let message = ChatMessage(
            id: "assistant-spawn",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "read-1", toolName: "Read", inputJSON: #"{"file_path":"a.txt"}"#),
                ChatContentBlock(kind: .toolUse, toolUseID: "agent-1", toolName: "Agent", inputJSON: #"{"subagent_type":"Explore","description":"Inspect rendering"}"#),
                ChatContentBlock(kind: .toolUse, toolUseID: "read-2", toolName: "Read", inputJSON: #"{"file_path":"b.txt"}"#)
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])
        let subagents = items.compactMap { item -> SubagentActivity? in
            if case .subagent(let activity) = item { return activity }
            return nil
        }

        XCTAssertEqual(subagents.count, 1)
        XCTAssertEqual(subagents.first?.id, "agent-1")
        XCTAssertEqual(subagents.first?.subagentType, "Explore")
        for item in items {
            if case .toolRun = item {
                XCTFail("an Agent spawn between tools must break the run, not be swallowed by it")
            }
        }
    }

    func testSubagentActivityBuilderAttachesSidechainToolCallsViaMeta() {
        let main = ChatMessage(
            id: "main",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "spawn-1", toolName: "Agent", inputJSON: #"{"subagent_type":"Explore","description":"Inspect files"}"#)
            ]
        )
        let sidechain = ChatMessage(
            id: "side",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "read-1", toolName: "Read", inputJSON: #"{"file_path":"README.md"}"#)
            ],
            agentID: "a1"
        )
        let meta = SubagentMeta(agentID: "a1", agentType: "Explore", description: "Inspect files", toolUseID: "spawn-1", spawnDepth: 1)
        let completion = SubagentCompletion(status: .succeeded, summary: "Done")

        let activities = SubagentActivityBuilder.activities(
            mainMessages: [main],
            sidechainMessages: [sidechain],
            metas: [meta],
            childCallsByAgentID: [:],
            completions: ["spawn-1": completion]
        )

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.agentID, "a1")
        XCTAssertEqual(activities.first?.status, .succeeded)
        XCTAssertEqual(activities.first?.summary, "Done")
        XCTAssertEqual(activities.first?.childToolUseCount, 1)
        XCTAssertEqual(activities.first?.childToolCalls.first?.toolName, "Read")
    }

    func testLoadSubagentChildCallsReadsCompanionTranscriptOnDemand() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "session-1"
        let main = root.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        FileManager.default.createFile(atPath: main.path, contents: Data(), attributes: nil)
        let subagents = root.appendingPathComponent(sessionID).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let meta = subagents.appendingPathComponent("agent-a1.meta.json")
        try #"{"agentType":"Explore","description":"Inspect files","toolUseId":"spawn-1","spawnDepth":1}"#
            .write(to: meta, atomically: true, encoding: .utf8)
        let transcript = subagents.appendingPathComponent("agent-a1.jsonl")
        let toolUse = #"[{"type":"tool_use","id":"read-1","name":"Read","input":{"file_path":"README.md"}}]"#
        let line = #"{"type":"assistant","uuid":"side-1","isSidechain":true,"agentId":"a1","message":{"role":"assistant","content":"# + toolUse + #"}}"#
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let index = SessionIndexService(home: root)

        XCTAssertEqual(index.loadSubagentMetas(mainPath: main.path).first?.toolUseID, "spawn-1")
        let calls = index.loadSubagentChildCalls(mainPath: main.path, agentID: "a1")

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.toolName, "Read")
        XCTAssertEqual(calls.first?.toolUseID, "read-1")
    }

    func testDisplayItemViewRendersSubagentBranch() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let chatPanel = try XCTUnwrap(Self.typeBody(named: "ChatPanelView", in: source))

        XCTAssertTrue(chatPanel.contains("case .subagent(let activity):"))
        XCTAssertTrue(chatPanel.contains("SubagentCardView(activity: activity)"))
    }

    func testAgentInspectorReusesToolDisplayItemView() throws {
        let source = try Self.source("LiquidCode/SubagentViews.swift")
        let inspector = try XCTUnwrap(Self.typeBody(named: "AgentInspectorView", in: source))

        XCTAssertTrue(inspector.contains("model.selectedSubagentActivities"))
        XCTAssertTrue(inspector.contains("ContentUnavailableView"))
        XCTAssertTrue(source.contains("ToolDisplayItemView(item: tool"))
    }

    func testSecondaryPanelContainsAgentTabAndOldOverlayIsRemoved() throws {
        let panels = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        let secondary = try XCTUnwrap(Self.typeBody(named: "SecondaryPanelView", in: panels))
        let views = try Self.source("LiquidCode/Views.swift")

        XCTAssertTrue(secondary.contains("case .agent: AgentInspectorView()"))
        XCTAssertFalse(views.contains("AgentFloatingOverlayView"))
    }

    private static func source(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.pathComponents.count > 1 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func typeBody(named typeName: String, in source: String) -> String? {
        let signatures = [
            "struct \(typeName)",
            "class \(typeName)",
            "final class \(typeName)",
            "private struct \(typeName)"
        ]
        guard
            let signatureRange = signatures.compactMap({ source.range(of: $0) }).first,
            let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{")
        else {
            return nil
        }
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            if source[cursor] == "{" {
                depth += 1
            } else if source[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    let bodyStart = source.index(after: openingBrace)
                    return String(source[bodyStart ..< cursor])
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-subagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
