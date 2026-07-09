@testable import LiquidCode
import XCTest

@MainActor
final class AttentionNotificationsRegressionTests: XCTestCase {
    // MARK: - Pure helpers

    func testShouldNotifyOnlyWhenInactive() {
        XCTAssertTrue(AttentionNotifications.shouldNotifyWhileInactive(isAppActive: false))
        XCTAssertFalse(AttentionNotifications.shouldNotifyWhileInactive(isAppActive: true))
    }

    func testPermissionTitlesAndCategoriesByKind() {
        let bash = permission(tool: "Bash", summary: "npm test", risk: .shell)
        XCTAssertEqual(AttentionNotifications.title(for: bash), "Permission needed")
        XCTAssertEqual(AttentionNotifications.category(for: bash), AttentionNotifications.categoryPermission)
        XCTAssertTrue(AttentionNotifications.body(for: bash).contains("Bash"))
        XCTAssertTrue(AttentionNotifications.body(for: bash).contains("npm test"))

        let question = permission(
            tool: "AskUserQuestion",
            summary: "pick one",
            risk: .readOnly,
            input: #"{"questions":[{"question":"A or B?","options":[{"label":"A"},{"label":"B"}]}]}"#
        )
        XCTAssertEqual(InteractionAdapter(permission: question).kind, .question)
        XCTAssertEqual(AttentionNotifications.title(for: question), "Answer needed")
        XCTAssertEqual(AttentionNotifications.category(for: question), AttentionNotifications.categoryQuestion)

        let plan = permission(
            tool: "ExitPlanMode",
            summary: "plan body",
            risk: .readOnly,
            input: #"{"plan":"1. Do the thing"}"#
        )
        XCTAssertEqual(InteractionAdapter(permission: plan).kind, .planReview)
        XCTAssertEqual(AttentionNotifications.title(for: plan), "Plan ready for review")
        XCTAssertEqual(AttentionNotifications.category(for: plan), AttentionNotifications.categoryPlan)
    }

    func testTurnCompletedCopy() {
        XCTAssertEqual(AttentionNotifications.turnCompletedTitle(), "Turn completed")
        XCTAssertEqual(AttentionNotifications.turnCompletedBody(sessionTitle: "Build feature"), "Build feature")
        XCTAssertEqual(AttentionNotifications.turnCompletedBody(sessionTitle: nil), "Claude finished a turn")
        XCTAssertEqual(AttentionNotifications.turnCompletedBody(sessionTitle: ""), "Claude finished a turn")
    }

    // MARK: - Runtime attention state

    func testActiveSessionIDsIncludeEngineRunningSessions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AttentionRecordingEngine()
        engine.runningSessionIDs.insert("warm")
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "warm", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "w"),
            SessionRecord(id: "idle", path: nil, project: "B", projectDir: root.path, modifiedAt: Date(), preview: "i")
        ]
        XCTAssertTrue(model.activeSessionIDs.contains("warm"))
        XCTAssertFalse(model.activeSessionIDs.contains("idle"))
    }

    func testPendingAttentionCountTracksPermissions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: AttentionRecordingEngine())
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a")
        ]
        XCTAssertEqual(model.pendingAttentionCount, 0)
        model.pendingPermissions = [
            permission(tool: "Bash", summary: "ls", risk: .shell, sessionID: "s1")
        ]
        XCTAssertEqual(model.pendingAttentionCount, 1)
        model.refreshDockBadge()
        // badgeLabel is written for the live dock; just ensure the helper is callable.
        XCTAssertEqual(model.pendingAttentionCount, 1)
    }

    func testPermissionHandlerRefreshesAttentionWithoutAutoAllow() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: AttentionRecordingEngine())
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a")
        ]
        model.selectedSessionID = "s1"
        model.settings.notificationsEnabled = false // still surfaces pending; just skips system post
        model.handle(.permissionRequested(permission(tool: "Bash", summary: "npm test", risk: .shell, sessionID: "s1")))
        XCTAssertEqual(model.pendingPermissions.count, 1)
        XCTAssertEqual(model.pendingAttentionCount, 1)
        XCTAssertEqual(model.turnPhaseBySession["s1"], .waitingPermission)
    }

    // MARK: - Settings + view structure

    func testNotificationsDefaultEnabledAndSettingsSurface() throws {
        XCTAssertTrue(AppSettings().notificationsEnabled)
        let settings = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(settings.contains("notificationsEnabled"))
        XCTAssertTrue(settings.contains("Background notifications") || settings.contains("L(\"Background notifications\")"))
        let service = try Self.source("LiquidCode/AttentionNotifications.swift")
        XCTAssertTrue(service.contains("UserNotifications"))
        XCTAssertTrue(service.contains("postPermission"))
        XCTAssertTrue(service.contains("postTurnCompleted"))
        let row = try Self.source("LiquidCode/ViewComponents.swift")
        XCTAssertTrue(row.contains("pulsing: running"))
    }

    // MARK: - Helpers

    private func permission(
        tool: String,
        summary: String,
        risk: PermissionRequest.Risk,
        sessionID: String = "s1",
        input: String? = nil
    ) -> PermissionRequest {
        PermissionRequest(
            id: UUID().uuidString,
            sessionID: sessionID,
            requestID: UUID().uuidString,
            toolName: tool,
            title: "Claude wants to use \(tool)",
            summary: summary,
            inputJSON: input ?? #"{"command":"\#(summary)"}"#,
            risk: risk
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-attn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    private final class AttentionRecordingEngine: ClaudeEngine, @unchecked Sendable {
        var runningSessionIDs: Set<String> = []

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
            runningSessionIDs.insert(request.sessionID)
        }

        func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {}

        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? { nil }

        func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {}

        func isSessionRunning(sessionID: String) -> Bool { runningSessionIDs.contains(sessionID) }

        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {}

        func interrupt(sessionID: String) throws {}

        func kill(sessionID: String) { runningSessionIDs.remove(sessionID) }

        func killAll() { runningSessionIDs.removeAll() }
    }
}
