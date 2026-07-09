@testable import LiquidCode
import XCTest

@MainActor
final class PermissionRememberRegressionTests: XCTestCase {
    // MARK: - Pattern extraction

    func testBashPatternNormalizesWhitespace() {
        let permission = bashPermission(command: "  npm   test  ")
        XCTAssertEqual(SessionPermissionRemember.pattern(for: permission), "npm test")
    }

    func testEditPatternUsesFilePath() {
        let permission = pathPermission(tool: "Edit", path: "/tmp/a.swift", risk: .write)
        XCTAssertEqual(SessionPermissionRemember.pattern(for: permission), "/tmp/a.swift")
    }

    func testUnknownToolHasNoPattern() {
        let permission = PermissionRequest(
            id: "p1",
            sessionID: "s1",
            requestID: "r1",
            toolName: "Glob",
            title: "Claude wants to use Glob",
            summary: "find files",
            inputJSON: #"{"pattern":"**/*.swift"}"#,
            risk: .readOnly
        )
        XCTAssertNil(SessionPermissionRemember.pattern(for: permission))
        XCTAssertFalse(SessionPermissionRemember.isRememberable(permission))
    }

    // MARK: - Eligibility

    func testDestructiveIsNeverRememberable() {
        let permission = bashPermission(command: "rm -rf /", risk: .destructive)
        XCTAssertFalse(SessionPermissionRemember.isRememberable(permission))
        XCTAssertNil(SessionPermissionRemember.makeRule(from: permission))
    }

    func testNetworkAndExternalMcpNeverRememberable() {
        let network = PermissionRequest(
            id: "n1", sessionID: "s1", requestID: "r1",
            toolName: "WebFetch", title: "fetch", summary: "https://example.com",
            inputJSON: #"{"url":"https://example.com"}"#, risk: .network
        )
        let mcp = PermissionRequest(
            id: "m1", sessionID: "s1", requestID: "r1",
            toolName: "mcp__server__tool", title: "mcp", summary: "tool",
            inputJSON: #"{"arg":"1"}"#, risk: .externalMcp
        )
        XCTAssertFalse(SessionPermissionRemember.isRememberable(network))
        XCTAssertFalse(SessionPermissionRemember.isRememberable(mcp))
    }

    func testPlanReviewAndQuestionNeverRememberable() {
        let plan = PermissionRequest(
            id: "plan1", sessionID: "s1", requestID: "r1",
            toolName: "ExitPlanMode", title: "plan", summary: "plan body",
            inputJSON: #"{"plan":"1. Do the thing"}"#, risk: .readOnly
        )
        let question = PermissionRequest(
            id: "q1", sessionID: "s1", requestID: "r1",
            toolName: "AskUserQuestion", title: "question", summary: "pick one",
            inputJSON: #"{"questions":[{"question":"A or B?","options":[{"label":"A"},{"label":"B"}]}]}"#,
            risk: .readOnly
        )
        XCTAssertEqual(InteractionAdapter(permission: plan).kind, .planReview)
        XCTAssertEqual(InteractionAdapter(permission: question).kind, .question)
        XCTAssertFalse(SessionPermissionRemember.isRememberable(plan))
        XCTAssertFalse(SessionPermissionRemember.isRememberable(question))
    }

    // MARK: - Matching

    func testSameBashCommandMatches() throws {
        let first = bashPermission(command: "npm test")
        let second = bashPermission(command: "npm  test", id: "p2", requestID: "r2")
        let rule = try XCTUnwrap(SessionPermissionRemember.makeRule(from: first))
        XCTAssertNotNil(SessionPermissionRemember.findMatch(in: [rule], permission: second))
    }

    func testDifferentBashCommandDoesNotMatch() throws {
        let first = bashPermission(command: "npm test")
        let second = bashPermission(command: "npm run build", id: "p2", requestID: "r2")
        let rule = try XCTUnwrap(SessionPermissionRemember.makeRule(from: first))
        XCTAssertNil(SessionPermissionRemember.findMatch(in: [rule], permission: second))
    }

    func testPathMatchIsExactAndToolScoped() throws {
        let edit = pathPermission(tool: "Edit", path: "/tmp/a.swift", risk: .write)
        let read = pathPermission(tool: "Read", path: "/tmp/a.swift", risk: .readOnly, id: "p2", requestID: "r2")
        let otherPath = pathPermission(tool: "Edit", path: "/tmp/b.swift", risk: .write, id: "p3", requestID: "r3")
        let rule = try XCTUnwrap(SessionPermissionRemember.makeRule(from: edit))
        XCTAssertNil(SessionPermissionRemember.findMatch(in: [rule], permission: read), "Read must not reuse an Edit rule")
        XCTAssertNil(SessionPermissionRemember.findMatch(in: [rule], permission: otherPath))
        XCTAssertNotNil(SessionPermissionRemember.findMatch(in: [rule], permission: edit))
    }

    func testAppendRuleDedupes() throws {
        let permission = bashPermission(command: "ls")
        let rule = try XCTUnwrap(SessionPermissionRemember.makeRule(from: permission))
        var rules: [SessionPermissionRule] = []
        SessionPermissionRemember.appendRule(rule, to: &rules)
        SessionPermissionRemember.appendRule(rule, to: &rules)
        XCTAssertEqual(rules.count, 1)
    }

    // MARK: - Runtime: Allow for Session + auto-allow

    func testAllowForSessionStoresRuleAndAutoAllowsNextMatch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RememberRecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "Demo", projectDir: root.path, modifiedAt: Date(), preview: "demo")
        ]
        model.selectedSessionID = "s1"
        model.activeTurnSnapshots["s1"] = ActiveTurnSnapshot(messageID: "turn", content: "go", attachments: [])

        let first = bashPermission(command: "npm test", sessionID: "s1")
        model.handle(.permissionRequested(first))
        XCTAssertEqual(model.pendingPermissions.count, 1, "first request must surface")
        XCTAssertTrue(engine.permissionResponses.isEmpty)

        model.respondPermission(first, allow: true, rememberForSession: true)
        XCTAssertTrue(model.pendingPermissions.isEmpty)
        XCTAssertEqual(engine.permissionResponses.map(\.allow), [true])
        XCTAssertEqual(model.permissionRulesBySession["s1"]?.count, 1)
        XCTAssertEqual(model.permissionRulesBySession["s1"]?.first?.pattern, "npm test")

        engine.permissionResponses.removeAll()
        let second = bashPermission(command: "npm   test", sessionID: "s1", id: "p2", requestID: "r2")
        model.handle(.permissionRequested(second))
        XCTAssertTrue(model.pendingPermissions.isEmpty, "matching request must auto-allow")
        XCTAssertEqual(engine.permissionResponses.map(\.allow), [true])
        XCTAssertEqual(model.turnPhaseBySession["s1"], .thinking)
    }

    func testAllowOnceDoesNotStoreRule() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RememberRecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "Demo", projectDir: root.path, modifiedAt: Date(), preview: "demo")
        ]
        model.selectedSessionID = "s1"

        let first = bashPermission(command: "npm test", sessionID: "s1")
        model.handle(.permissionRequested(first))
        model.respondPermission(first, allow: true)
        XCTAssertTrue(model.permissionRulesBySession["s1"]?.isEmpty ?? true)

        let second = bashPermission(command: "npm test", sessionID: "s1", id: "p2", requestID: "r2")
        model.handle(.permissionRequested(second))
        XCTAssertEqual(model.pendingPermissions.count, 1, "Allow Once must not auto-allow later")
    }

    func testDestructiveStillPromptsEvenWithRuleSeeded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: RememberRecordingEngine())
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "Demo", projectDir: root.path, modifiedAt: Date(), preview: "demo")
        ]
        // Seed a shell rule that would match the command text, but risk is destructive.
        model.permissionRulesBySession["s1"] = [
            SessionPermissionRule(
                id: "rule",
                toolName: "Bash",
                pattern: "rm -rf tmp",
                risk: .shell,
                createdAt: Date()
            )
        ]
        let destructive = bashPermission(command: "rm -rf tmp", sessionID: "s1", risk: .destructive)
        model.handle(.permissionRequested(destructive))
        XCTAssertEqual(model.pendingPermissions.count, 1, "destructive must never auto-allow")
    }

    func testRulesAreIsolatedPerSession() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RememberRecordingEngine()
        let model = AppModel(engine: engine)
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a"),
            SessionRecord(id: "s2", path: nil, project: "B", projectDir: root.path, modifiedAt: Date(), preview: "b")
        ]
        let first = bashPermission(command: "npm test", sessionID: "s1")
        model.handle(.permissionRequested(first))
        model.respondPermission(first, allow: true, rememberForSession: true)

        let other = bashPermission(command: "npm test", sessionID: "s2", id: "p2", requestID: "r2")
        model.handle(.permissionRequested(other))
        XCTAssertEqual(model.pendingPermissions.map(\.sessionID), ["s2"], "rules must not leak across sessions")
    }

    func testDeleteSessionClearsRules() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: RememberRecordingEngine())
        let session = SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a")
        model.sessions = [session]
        model.permissionRulesBySession["s1"] = [
            SessionPermissionRule(id: "r", toolName: "Bash", pattern: "ls", risk: .shell, createdAt: Date())
        ]
        model.deleteSession(session)
        XCTAssertNil(model.permissionRulesBySession["s1"])
    }

    // MARK: - View structure

    func testPermissionCardsExposeAllowForSession() throws {
        let source = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        let inline = try XCTUnwrap(Self.typeBody(named: "PermissionInlineCardView", in: source))
        XCTAssertTrue(inline.contains("Allow for Session"), "inline card must offer session remember")
        XCTAssertTrue(inline.contains("rememberForSession: true"))
        XCTAssertTrue(inline.contains("SessionPermissionRemember.isRememberable"))
    }

    // MARK: - Helpers

    private func bashPermission(
        command: String,
        sessionID: String = "s1",
        risk: PermissionRequest.Risk = .shell,
        id: String = "p1",
        requestID: String = "r1"
    ) -> PermissionRequest {
        PermissionRequest(
            id: id,
            sessionID: sessionID,
            requestID: requestID,
            toolName: "Bash",
            title: "Claude wants to use Bash",
            summary: command,
            inputJSON: #"{"command":"\#(command)"}"#,
            risk: risk
        )
    }

    private func pathPermission(
        tool: String,
        path: String,
        risk: PermissionRequest.Risk,
        id: String = "p1",
        requestID: String = "r1"
    ) -> PermissionRequest {
        PermissionRequest(
            id: id,
            sessionID: "s1",
            requestID: requestID,
            toolName: tool,
            title: "Claude wants to use \(tool)",
            summary: path,
            inputJSON: #"{"file_path":"\#(path)"}"#,
            risk: risk
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-perm-\(UUID().uuidString)")
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

    private final class RememberRecordingEngine: ClaudeEngine, @unchecked Sendable {
        var permissionResponses: [(allow: Bool, message: String?)] = []
        var runningSessionIDs: Set<String> = []

        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
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
