@testable import LiquidCode
import XCTest

@MainActor
final class CheckpointTimelineRegressionTests: XCTestCase {
    func testBuilderCollectsUserTurnsWithCheckpointFlags() {
        let messages = [
            ChatMessage(id: "u1", role: .user, content: "first turn"),
            ChatMessage(id: "a1", role: .assistant, content: "ok"),
            ChatMessage(id: "u2", role: .user, content: "second\n  turn  with   spaces", checkpointUuid: "cp-2"),
            ChatMessage(id: "a2", role: .assistant, content: "done")
        ]
        let points = SessionCheckpointBuilder.checkpoints(from: messages)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].messageID, "u1")
        XCTAssertEqual(points[0].turnIndex, 1)
        XCTAssertFalse(points[0].hasClaudeCheckpoint)
        XCTAssertEqual(points[1].messageID, "u2")
        XCTAssertEqual(points[1].turnIndex, 2)
        XCTAssertTrue(points[1].hasClaudeCheckpoint)
        XCTAssertEqual(points[1].checkpointUuid, "cp-2")
        XCTAssertEqual(points[1].preview, "second turn with spaces")
    }

    func testBuilderIgnoresNonUserMessagesAndEmptyWhitespacePreviewFallback() {
        let messages = [
            ChatMessage(id: "s1", role: .system, content: "sys"),
            ChatMessage(id: "u1", role: .user, content: "   \n\t  "),
            ChatMessage(id: "t1", role: .tool, content: "tool")
        ]
        let points = SessionCheckpointBuilder.checkpoints(from: messages)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].preview, L("User turn"))
    }

    func testOpenCheckpointTimelineSetsTabAndFocus() {
        let model = AppModel(engine: TimelineStubEngine())
        model.openCheckpointTimeline(messageID: "msg-42")
        XCTAssertEqual(model.secondaryTab, .timeline)
        XCTAssertTrue(model.secondaryOpen)
        XCTAssertEqual(model.focusedCheckpointMessageID, "msg-42")
    }

    func testForkSessionCreatesConversationOnlyDraftWithoutCliResume() {
        let model = AppModel(engine: TimelineStubEngine())
        let sourceID = "source-sess"
        model.sessions = [
            SessionRecord(
                id: sourceID,
                path: "/tmp/proj/session.jsonl",
                project: "/tmp/proj",
                projectDir: "/tmp/proj",
                modifiedAt: Date(),
                preview: "source",
                cliResumeID: "cli-abc-123",
                lastCheckpointUUID: "cp-root",
                isDraft: false
            )
        ]
        model.selectedSessionID = sourceID
        model.workingDirectory = "/tmp/proj"
        model.setMessages(
            [
                ChatMessage(id: "u1", role: .user, content: "start", checkpointUuid: "cp-1"),
                ChatMessage(id: "a1", role: .assistant, content: "mid"),
                ChatMessage(id: "u2", role: .user, content: "later"),
                ChatMessage(id: "a2", role: .assistant, content: "tail")
            ],
            for: sourceID
        )

        model.forkSession(fromMessageID: "u1")

        XCTAssertEqual(model.sessions.count, 2)
        let forked = model.sessions[0]
        XCTAssertTrue(forked.id.hasPrefix("desk_"))
        XCTAssertNotEqual(forked.id, sourceID)
        XCTAssertNil(forked.cliResumeID, "fork must not copy CLI resume id")
        XCTAssertTrue(forked.isDraft)
        XCTAssertEqual(forked.projectDir, "/tmp/proj")
        XCTAssertEqual(forked.lastCheckpointUUID, "cp-1")
        XCTAssertEqual(model.selectedSessionID, forked.id)

        let forkedMessages = model.messagesBySession[forked.id] ?? []
        XCTAssertEqual(forkedMessages.map(\.id), ["u1"])

        // Original untouched
        let sourceMessages = model.messagesBySession[sourceID] ?? []
        XCTAssertEqual(sourceMessages.map(\.id), ["u1", "a1", "u2", "a2"])
        XCTAssertEqual(model.sessions.first(where: { $0.id == sourceID })?.cliResumeID, "cli-abc-123")

        XCTAssertEqual(model.secondaryTab, .timeline)
        XCTAssertEqual(model.focusedCheckpointMessageID, "u1")
    }

    func testRestoreCodeWithoutTurnCheckpointDoesNotFallBackToSessionUUID() {
        let engine = TimelineStubEngine()
        let model = AppModel(engine: engine)
        let sessionID = "sess-code"
        model.sessions = [
            SessionRecord(
                id: sessionID,
                path: nil,
                project: "/tmp/proj",
                projectDir: "/tmp/proj",
                modifiedAt: Date(),
                preview: "p",
                lastCheckpointUUID: "session-level-cp",
                isDraft: false
            )
        ]
        model.selectedSessionID = sessionID
        model.setMessages(
            [
                ChatMessage(id: "u1", role: .user, content: "no turn checkpoint")
            ],
            for: sessionID
        )

        model.performRewind(toMessageID: "u1", action: .restoreCode)

        XCTAssertEqual(engine.rewindCallCount, 0, "must not rewind using session-level checkpoint")
    }

    func testRestoreCodeUsesTurnCheckpointOnly() {
        let engine = TimelineStubEngine()
        let model = AppModel(engine: engine)
        let sessionID = "sess-code-2"
        model.sessions = [
            SessionRecord(
                id: sessionID,
                path: nil,
                project: "/tmp/proj",
                projectDir: "/tmp/proj",
                modifiedAt: Date(),
                preview: "p",
                cliResumeID: "cli-1",
                lastCheckpointUUID: "session-level-cp",
                isDraft: false
            )
        ]
        model.selectedSessionID = sessionID
        model.workingDirectory = "/tmp/proj"
        model.setMessages(
            [
                ChatMessage(id: "u1", role: .user, content: "with cp", checkpointUuid: "turn-cp")
            ],
            for: sessionID
        )

        model.performRewind(toMessageID: "u1", action: .restoreCode)

        XCTAssertEqual(engine.rewindCallCount, 1)
        XCTAssertEqual(engine.lastCheckpointUUID, "turn-cp")
    }

    func testTimelineSurfaceIsWired() throws {
        let models = try Self.source("LiquidCode/Models.swift")
        XCTAssertTrue(models.contains("case timeline = \"Timeline\""))
        XCTAssertTrue(models.contains("clock.arrow.circlepath"))

        let appModel = try Self.source("LiquidCode/AppModel/AppModel.swift")
        XCTAssertTrue(appModel.contains("focusedCheckpointMessageID"))

        let state = try Self.source("LiquidCode/AppModel/State.swift")
        XCTAssertTrue(state.contains("openCheckpointTimeline"))

        let rewind = try Self.source("LiquidCode/AppModel/Rewind.swift")
        XCTAssertTrue(rewind.contains("func forkSession(fromMessageID"))
        XCTAssertTrue(rewind.contains("func performRewind(toMessageID"))
        XCTAssertTrue(rewind.contains("cliResumeID: nil"))
        XCTAssertTrue(rewind.contains("confirmDestructiveRewind"))
        XCTAssertTrue(rewind.contains("usageBySession.removeValue"))
        // Strict binding: turn checkpoint only
        XCTAssertFalse(rewind.contains("turn.checkpointUuid ?? session.lastCheckpointUUID"))

        let views = try Self.source("LiquidCode/CheckpointTimelineViews.swift")
        XCTAssertTrue(views.contains("struct CheckpointTimelineView"))
        XCTAssertTrue(views.contains("SessionCheckpointBuilder"))
        XCTAssertTrue(views.contains("UI-only"))

        let panels = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(panels.contains("case .timeline: CheckpointTimelineView()"))
        // Icon-only secondary tabs via ToolbarIconButton (no Label title+icon capsules)
        XCTAssertTrue(panels.contains("ToolbarIconButton("))
        XCTAssertTrue(panels.contains("active: model.secondaryTab == tab"))

        let app = try Self.source("LiquidCode/LiquidCodeApp.swift")
        XCTAssertTrue(app.contains("openCheckpointTimeline()"))

        let bubble = try Self.source("LiquidCode/ViewComponents.swift")
        // Bubble marker only when a Claude checkpoint exists
        XCTAssertTrue(bubble.contains("if let checkpoint = message.checkpointUuid"))
        XCTAssertTrue(bubble.contains("openCheckpointTimeline(messageID: message.id)"))
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

    private final class TimelineStubEngine: ClaudeEngine, @unchecked Sendable {
        var rewindCallCount = 0
        var lastCheckpointUUID: String?

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {}
        func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {}
        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? {
            rewindCallCount += 1
            lastCheckpointUUID = checkpointUUID
            return "rewound"
        }

        func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {}
        func isSessionRunning(sessionID: String) -> Bool { false }
        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {}
        func interrupt(sessionID: String) throws {}
        func kill(sessionID: String) {}
        func killAll() {}
    }
}
