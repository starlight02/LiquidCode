@testable import LiquidCode
import XCTest

/// Regression coverage for the in-transcript "genuinely thinking" indicator:
/// cold-start connecting → cliReady thinking → first token clears; warm continue
/// skips connecting; finish/exit/fail clear the phase; the view is mounted with a
/// streaming/permission visibility gate; system-init emits `.cliReady`.
@MainActor
final class ThinkingIndicatorRegressionTests: XCTestCase {
    // MARK: - Phase state machine

    func testColdStartBeginsConnectingAndPromotesOnCliReadyThenClearsOnFirstToken() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ThinkingRecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(
                id: "cold",
                path: nil,
                project: "Cold",
                projectDir: root.path,
                modifiedAt: Date(),
                preview: "Draft",
                isDraft: true
            )
        ]
        model.selectedSessionID = "cold"

        model.send("hello cold start")

        XCTAssertEqual(engine.startRequests.count, 1, "draft sessions must cold-start the CLI")
        XCTAssertTrue(engine.sentMessages.isEmpty)
        XCTAssertEqual(model.turnPhaseBySession["cold"], .connecting)
        XCTAssertTrue(model.hasActiveTurn(for: "cold"))

        model.handle(.cliReady(sessionID: "cold"))
        XCTAssertEqual(model.turnPhaseBySession["cold"], .thinking)

        model.handle(.streamBlockStarted(
            sessionID: "cold",
            index: 0,
            ChatContentBlock(kind: .text, text: "Hi")
        ))
        XCTAssertNil(model.turnPhaseBySession["cold"], "first streamed block must clear the phase")
        XCTAssertNotNil(model.streamingMessagesBySession["cold"])
    }

    func testWarmContinueStartsInThinkingPhase() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ThinkingRecordingEngine()
        engine.runningSessionIDs.insert("warm")
        let model = AppModel(engine: engine)
        // A non-draft session with a path whose engine is already running continues via sendMessage.
        model.sessions = [
            SessionRecord(
                id: "warm",
                path: root.appendingPathComponent("warm.jsonl").path,
                project: "Warm",
                projectDir: root.path,
                modifiedAt: Date(),
                preview: "Warm",
                cliResumeID: "cli-warm",
                isDraft: false
            )
        ]
        model.selectedSessionID = "warm"
        // Match the previous send configuration so shouldStartSession stays false.
        model.sendConfigurationBySession["warm"] = ComposerSendConfiguration(
            model: model.settings.selectedModel,
            mode: model.settings.sessionMode,
            thinkingLevel: model.settings.thinkingLevel
        )

        model.send("hello warm continue")

        XCTAssertTrue(engine.startRequests.isEmpty, "a running warm session must not re-spawn")
        XCTAssertEqual(engine.sentMessages.map(\.sessionID), ["warm"])
        XCTAssertEqual(model.turnPhaseBySession["warm"], .thinking)
    }

    func testTurnCompletedExitedAndFailedClearTurnPhase() throws {
        let model = AppModel(engine: ThinkingRecordingEngine())
        model.selectedSessionID = "session-1"
        model.activeTurnSnapshots["session-1"] = ActiveTurnSnapshot(messageID: "u1", content: "hi", attachments: [])
        model.turnPhaseBySession["session-1"] = .thinking

        model.handle(.turnCompleted(sessionID: "session-1"))
        XCTAssertNil(model.turnPhaseBySession["session-1"])
        XCTAssertNil(model.activeTurnSnapshots["session-1"])

        model.activeTurnSnapshots["session-1"] = ActiveTurnSnapshot(messageID: "u2", content: "hi", attachments: [])
        model.turnPhaseBySession["session-1"] = .connecting
        model.handle(.exited(sessionID: "session-1"))
        XCTAssertNil(model.turnPhaseBySession["session-1"])
        XCTAssertNil(model.activeTurnSnapshots["session-1"])

        model.activeTurnSnapshots["session-1"] = ActiveTurnSnapshot(messageID: "u3", content: "hi", attachments: [])
        model.turnPhaseBySession["session-1"] = .thinking
        model.handle(.failed(sessionID: "session-1", "boom"))
        XCTAssertNil(model.turnPhaseBySession["session-1"])
        XCTAssertNil(model.activeTurnSnapshots["session-1"])
    }

    func testTextDeltaAndToolStartedClearTurnPhase() throws {
        let model = AppModel(engine: ThinkingRecordingEngine())
        model.selectedSessionID = "session-1"
        model.turnPhaseBySession["session-1"] = .thinking

        model.handle(.textDelta(sessionID: "session-1", text: "partial"))
        XCTAssertNil(model.turnPhaseBySession["session-1"])

        model.turnPhaseBySession["session-1"] = .connecting
        model.handle(.toolStarted(
            sessionID: "session-1",
            ToolCall(id: "tool-1", sessionID: "session-1", name: "Read", inputPreview: "{}", status: .running)
        ))
        XCTAssertNil(model.turnPhaseBySession["session-1"])
    }

    // MARK: - StreamEventParser

    func testSystemInitEventsIncludeCliReady() {
        let object: [String: Any] = [
            "type": "system",
            "subtype": "init",
            "session_id": "cli-session-42"
        ]
        let events = StreamEventParser.events(from: object, sessionID: "desk-1")

        XCTAssertTrue(events.contains { event in
            if case .sessionStarted(let sessionID, let cliID) = event {
                return sessionID == "desk-1" && cliID == "cli-session-42"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .cliReady(let sessionID) = event {
                return sessionID == "desk-1"
            }
            return false
        })
    }

    // MARK: - View structure

    func testTranscriptMountsThinkingIndicatorBehindStreamingAndPermissionGate() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let chatPanel = try XCTUnwrap(Self.typeBody(named: "ChatPanelView", in: source))
        let indicator = try XCTUnwrap(Self.typeBody(named: "ThinkingIndicatorView", in: source))
        let bubble = try XCTUnwrap(Self.typeBody(named: "MessageBubbleView", in: source))

        XCTAssertTrue(
            chatPanel.contains("ThinkingIndicatorView(phase: model.selectedTurnPhase)"),
            "Thinking indicator must mount in the transcript LazyVStack."
        )
        XCTAssertTrue(
            chatPanel.contains("model.selectedHasActiveTurn"),
            "Visibility must require an active turn."
        )
        XCTAssertTrue(
            chatPanel.contains("streamingDisplayItems.isEmpty"),
            "Visibility must require no streamed content yet."
        )
        XCTAssertTrue(
            chatPanel.contains("model.pendingPermissionsForSelectedSession.isEmpty"),
            "Visibility must hide when a permission card is waiting."
        )
        XCTAssertTrue(
            indicator.contains("Connecting Claude Code…") || indicator.contains("L(\"Connecting Claude Code…\")"),
            "Connecting phase must use the connecting label."
        )
        XCTAssertTrue(
            indicator.contains("Claude is thinking…") || indicator.contains("L(\"Claude is thinking…\")"),
            "Thinking phase must use the thinking label."
        )
        XCTAssertTrue(
            bubble.contains("isLive ? L(\"Thinking…\") : L(\"Thought\")") || bubble.contains("isLive"),
            "Historical thinking blocks must use a past-tense label, not progressive Thinking…"
        )
        XCTAssertTrue(
            bubble.contains("L(\"Thought\")"),
            "Completed thinking blocks must render as Thought."
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-thinking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class ThinkingRecordingEngine: ClaudeEngine, @unchecked Sendable {
        var startRequests: [ClaudeSessionStartRequest] = []
        var sentMessages: [(sessionID: String, content: ClaudeUserMessageContent)] = []
        var runningSessionIDs: Set<String> = []

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
            startRequests.append(request)
            runningSessionIDs.insert(request.sessionID)
        }

        func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {
            sentMessages.append((sessionID, content))
        }

        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? { nil }
        func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {}
        func isSessionRunning(sessionID: String) -> Bool { runningSessionIDs.contains(sessionID) }
        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {}
        func interrupt(sessionID: String) throws {}
        func kill(sessionID: String) { runningSessionIDs.remove(sessionID) }
        func killAll() { runningSessionIDs.removeAll() }
    }
}
