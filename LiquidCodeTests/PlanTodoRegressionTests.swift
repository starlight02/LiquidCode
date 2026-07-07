@testable import LiquidCode
import XCTest

@MainActor
final class PlanTodoRegressionTests: XCTestCase {
    // MARK: - TodoPayloadParser

    func testTodoPayloadParserDecodesItemsWithStatusAndActiveForm() {
        let json = #"""
        {"todos":[
            {"content":"Write parser","activeForm":"Writing parser","status":"completed"},
            {"content":"Wire the view","activeForm":"Wiring the view","status":"in_progress"},
            {"content":"Add tests","activeForm":"Adding tests","status":"pending"}
        ]}
        """#

        let todos = TodoPayloadParser.parse(inputJSON: json)

        XCTAssertEqual(todos?.count, 3)
        XCTAssertEqual(todos?.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(todos?[1].activeForm, "Wiring the view")
        XCTAssertEqual(todos?[2].content, "Add tests")
    }

    func testTodoPayloadParserDefaultsMissingActiveFormAndStatus() {
        let todos = TodoPayloadParser.parse(inputJSON: #"{"todos":[{"content":"Only content"}]}"#)

        XCTAssertEqual(todos?.count, 1)
        XCTAssertEqual(todos?.first?.activeForm, "")
        XCTAssertEqual(todos?.first?.status, .pending)
    }

    func testTodoPayloadParserSkipsEntriesWithoutContent() {
        let todos = TodoPayloadParser.parse(inputJSON: #"{"todos":[{"content":"  "},{"content":"Keep me","status":"pending"}]}"#)

        XCTAssertEqual(todos?.map(\.content), ["Keep me"])
    }

    func testTodoPayloadParserReturnsNilForNonTodoPayload() {
        XCTAssertNil(TodoPayloadParser.parse(inputJSON: #"{"command":"echo hi"}"#))
        XCTAssertNil(TodoPayloadParser.parse(inputJSON: "not json"))
    }

    func testTodoPayloadParserReturnsEmptyArrayForClearedList() {
        // The CLI clears the list by sending an empty `todos` array; that is a valid
        // payload the card should render as "cleared", not fall back to a JSON dump.
        XCTAssertEqual(TodoPayloadParser.parse(inputJSON: #"{"todos":[]}"#)?.count, 0)
    }

    // MARK: - PlanPayloadParser

    func testPlanPayloadParserExtractsPlanFieldAndCountsSteps() {
        let json = #"""
        {"plan":"# Plan\n\n1. First step\n2. Second step\n\nDetails follow.","allowedPrompts":[]}
        """#

        let draft = PlanPayloadParser.parse(inputJSON: json, fallbackSummary: "ignored summary")

        XCTAssertTrue(draft.markdown.hasPrefix("# Plan"))
        XCTAssertFalse(draft.markdown.contains("allowedPrompts"))
        XCTAssertEqual(draft.stepCount, 2)
    }

    func testPlanPayloadParserReadsNestedInputPlan() {
        let json = #"{"input":{"plan":"1. Only step"}}"#

        let draft = PlanPayloadParser.parse(inputJSON: json, fallbackSummary: "")

        XCTAssertEqual(draft.markdown, "1. Only step")
        XCTAssertEqual(draft.stepCount, 1)
    }

    func testPlanPayloadParserFallsBackToSummaryThenRawJSON() {
        let summaryDraft = PlanPayloadParser.parse(inputJSON: #"{"unrelated":true}"#, fallbackSummary: "Plain summary")
        XCTAssertEqual(summaryDraft.markdown, "Plain summary")

        let rawDraft = PlanPayloadParser.parse(inputJSON: "raw text", fallbackSummary: "")
        XCTAssertEqual(rawDraft.markdown, "raw text")
    }

    // MARK: - TranscriptDisplayBuilder

    func testBuilderEmitsTodoItemAndKeepsItOutOfToolRuns() {
        let todoJSON = #"{"todos":[{"content":"Step one","activeForm":"Doing step one","status":"in_progress"}]}"#
        let message = ChatMessage(
            id: "assistant-todo",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "read-1", toolName: "Read", inputJSON: #"{"file_path":"a.txt"}"#),
                ChatContentBlock(kind: .toolUse, toolUseID: "todo-1", toolName: "TodoWrite", inputJSON: todoJSON),
                ChatContentBlock(kind: .toolUse, toolUseID: "read-2", toolName: "Read", inputJSON: #"{"file_path":"b.txt"}"#)
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        // The TodoWrite splits the adjacent Read tool uses so it never joins a tool run.
        let todoItems = items.compactMap { item -> TranscriptTodoItem? in
            if case .todo(let todo) = item { return todo }
            return nil
        }
        XCTAssertEqual(todoItems.count, 1)
        XCTAssertEqual(todoItems.first?.items.first?.status, .inProgress)
        for item in items {
            if case .toolRun = item {
                XCTFail("a TodoWrite between tool uses must break the run, not be swallowed by it")
            }
        }
    }

    func testBuilderFallsBackToGenericToolCardForUnparsableTodoPayload() {
        let message = ChatMessage(
            id: "assistant-bad-todo",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(kind: .toolUse, toolUseID: "todo-bad", toolName: "TodoWrite", inputJSON: "not json")
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        for item in items {
            if case .todo = item {
                XCTFail("an unparsable TodoWrite payload must not render as a checklist")
            }
        }
        guard case .tool(let tool) = items.first else {
            return XCTFail("expected the unparsable TodoWrite to fall back to a generic tool card")
        }
        XCTAssertEqual(tool.toolName, "TodoWrite")
    }

    // MARK: - submitPlanRevision

    func testSubmitPlanRevisionDeniesAndSendsWhenIdle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PlanRecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha")
        ]
        model.selectedSessionID = "alpha"
        let permission = planPermission(sessionID: "alpha")
        model.pendingPermissions = [permission]

        model.submitPlanRevision(permission, note: "Simplify step 2")

        XCTAssertEqual(engine.permissionResponses.map(\.allow), [false], "the pending plan must be denied")
        XCTAssertTrue(model.pendingPermissions.isEmpty, "the denied plan must clear from pending")
        XCTAssertEqual(engine.startRequests.map(\.prompt), ["Simplify step 2"], "the revision note must be sent")
        XCTAssertEqual(model.settings.sessionMode, .plan, "revision keeps the next turn a plan")
    }

    func testSubmitPlanRevisionQueuesNoteDuringActiveTurn() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PlanRecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "alpha", path: nil, project: "Alpha", projectDir: root.path, modifiedAt: Date(), preview: "Alpha")
        ]
        model.selectedSessionID = "alpha"
        model.activeTurnSnapshots["alpha"] = ActiveTurnSnapshot(messageID: "in-flight", content: "prev", attachments: [])
        let permission = planPermission(sessionID: "alpha")
        model.pendingPermissions = [permission]

        model.submitPlanRevision(permission, note: "Add error handling")

        XCTAssertEqual(engine.permissionResponses.map(\.allow), [false])
        XCTAssertTrue(engine.startRequests.isEmpty, "an active turn must not start a new send")
        XCTAssertEqual(
            model.pendingUserMessagesBySession["alpha"]?.map(\.content),
            ["Add error handling"],
            "the note must queue behind the active turn"
        )
    }

    // MARK: - View structure

    func testDisplayItemViewRendersTodoBranch() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let chatPanel = try XCTUnwrap(Self.typeBody(named: "ChatPanelView", in: source))

        XCTAssertTrue(
            chatPanel.contains("case .todo(let item):"),
            "Todo regression: displayItemView must route a parsed TodoWrite to its own checklist card."
        )
        XCTAssertTrue(
            chatPanel.contains("TodoListCardView(item: item)"),
            "Todo regression: the .todo branch must render TodoListCardView, not the generic tool card."
        )
    }

    func testPlanInspectorUsesStructuredParsingNotStringMatching() throws {
        let source = try Self.source("LiquidCode/PlanTodoViews.swift")
        let inspector = try XCTUnwrap(Self.typeBody(named: "PlanInspectorView", in: source))

        XCTAssertTrue(
            inspector.contains("block.toolName == \"ExitPlanMode\""),
            "Plan regression: the inspector must read plans from structured ExitPlanMode tool blocks."
        )
        XCTAssertTrue(
            inspector.contains("PlanPayloadParser.parse"),
            "Plan regression: the inspector must parse plan content structurally."
        )
        XCTAssertFalse(
            inspector.contains("lower.contains(\"todo\")"),
            "Plan regression: the old string-filter heuristic must stay removed."
        )
    }

    // MARK: - Helpers

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

    private func planPermission(sessionID: String) -> PermissionRequest {
        PermissionRequest(
            id: "plan-perm",
            sessionID: sessionID,
            requestID: "req-1",
            toolName: "ExitPlanMode",
            title: "Plan review",
            summary: "",
            inputJSON: #"{"plan":"1. Do the thing"}"#,
            toolUseID: "plan-tool",
            parentToolUseID: nil,
            agentID: nil,
            risk: .readOnly
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class PlanRecordingEngine: ClaudeEngine, @unchecked Sendable {
        var startRequests: [ClaudeSessionStartRequest] = []
        var permissionResponses: [(allow: Bool, message: String?)] = []
        var runningSessionIDs: Set<String> = []

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
            startRequests.append(request)
            runningSessionIDs.insert(request.sessionID)
        }

        func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {}
        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? { nil }
        func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {}
        func isSessionRunning(sessionID: String) -> Bool { runningSessionIDs.contains(sessionID) }
        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {
            permissionResponses.append((allow, message))
        }

        func interrupt(sessionID: String) throws {}
        func kill(sessionID: String) { runningSessionIDs.remove(sessionID) }
        func killAll() { runningSessionIDs.removeAll() }
    }
}
