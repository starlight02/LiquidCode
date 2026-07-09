@testable import LiquidCode
import XCTest

@MainActor
final class UsageMeterRegressionTests: XCTestCase {
    // MARK: - Parser

    func testResultEventParsesUsageAndCost() throws {
        let object: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "total_cost_usd": 0.0123,
            "usage": [
                "input_tokens": 12400,
                "output_tokens": 3100,
                "cache_read_input_tokens": 500,
                "cache_creation_input_tokens": 100
            ]
        ]

        let events = StreamEventParser.events(from: object, sessionID: "s1")
        guard case .turnCompleted(let sessionID, let usage) = try XCTUnwrap(events.first) else {
            return XCTFail("expected turnCompleted")
        }
        XCTAssertEqual(sessionID, "s1")
        let turn = try XCTUnwrap(usage)
        XCTAssertEqual(turn.inputTokens, 12400)
        XCTAssertEqual(turn.outputTokens, 3100)
        XCTAssertEqual(turn.cacheReadTokens, 500)
        XCTAssertEqual(turn.cacheWriteTokens, 100)
        XCTAssertEqual(turn.totalCostUSD ?? -1, 0.0123, accuracy: 0.00001)
    }

    func testResultEventWithoutUsageYieldsNilUsage() throws {
        let object: [String: Any] = [
            "type": "result",
            "subtype": "success"
        ]
        let events = StreamEventParser.events(from: object, sessionID: "s1")
        guard case .turnCompleted(_, let usage) = try XCTUnwrap(events.first) else {
            return XCTFail("expected turnCompleted")
        }
        XCTAssertNil(usage, "providers that omit usage must not invent zeros")
    }

    func testResultEventAcceptsAlternateCostKeys() {
        let object: [String: Any] = [
            "type": "result",
            "total_cost": 0.5,
            "usage": [
                "inputTokens": 10,
                "outputTokens": 5
            ]
        ]
        let events = StreamEventParser.events(from: object, sessionID: "s1")
        guard case .turnCompleted(_, let usage) = events.first else {
            return XCTFail("expected turnCompleted")
        }
        XCTAssertEqual(usage?.inputTokens, 10)
        XCTAssertEqual(usage?.outputTokens, 5)
        XCTAssertEqual(usage?.totalCostUSD, 0.5)
    }

    // MARK: - Session accumulation

    func testSessionUsageAccumulatesAcrossTurnsAndFormatsLabel() throws {
        var session = SessionUsage()
        session.accumulate(TurnUsage(inputTokens: 1000, outputTokens: 200, totalCostUSD: 0.01))
        session.accumulate(TurnUsage(inputTokens: 500, outputTokens: 50, totalCostUSD: 0.005))
        XCTAssertEqual(session.totalInput, 1500)
        XCTAssertEqual(session.totalOutput, 250)
        XCTAssertEqual(session.totalCostUSD, 0.015, accuracy: 0.00001)
        let label = try XCTUnwrap(session.compactLabel)
        XCTAssertTrue(label.contains("↑"), label)
        XCTAssertTrue(label.contains("↓"), label)
        XCTAssertTrue(label.contains("$"), label)
    }

    func testEmptySessionUsageHasNoLabel() {
        XCTAssertNil(SessionUsage().compactLabel)
    }

    func testRuntimeAccumulatesUsagePerSessionAndIsolates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: UsageRecordingEngine())
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a"),
            SessionRecord(id: "s2", path: nil, project: "B", projectDir: root.path, modifiedAt: Date(), preview: "b")
        ]
        model.selectedSessionID = "s1"

        model.handle(.turnCompleted(
            sessionID: "s1",
            usage: TurnUsage(inputTokens: 100, outputTokens: 20, totalCostUSD: 0.01)
        ))
        model.handle(.turnCompleted(
            sessionID: "s1",
            usage: TurnUsage(inputTokens: 50, outputTokens: 10, totalCostUSD: 0.02)
        ))
        model.handle(.turnCompleted(
            sessionID: "s2",
            usage: TurnUsage(inputTokens: 999, outputTokens: 1, totalCostUSD: 1.0)
        ))
        model.handle(.turnCompleted(sessionID: "s1", usage: nil))

        XCTAssertEqual(model.usageBySession["s1"]?.totalInput, 150)
        XCTAssertEqual(model.usageBySession["s1"]?.totalOutput, 30)
        XCTAssertEqual(model.usageBySession["s1"]?.totalCostUSD ?? 0, 0.03, accuracy: 0.00001)
        XCTAssertEqual(model.usageBySession["s2"]?.totalInput, 999)
        XCTAssertEqual(model.selectedSessionUsage?.totalInput, 150)
    }

    func testDeleteSessionClearsUsage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: UsageRecordingEngine())
        let session = SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a")
        model.sessions = [session]
        model.usageBySession["s1"] = SessionUsage(totalInput: 10, totalOutput: 1, totalCostUSD: 0.01)
        model.deleteSession(session)
        XCTAssertNil(model.usageBySession["s1"])
    }

    // MARK: - View structure

    func testChatHeaderMountsUsageMeter() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        XCTAssertTrue(source.contains("struct UsageMeterView"), "usage chip view must exist")
        XCTAssertTrue(source.contains("selectedSessionUsage?.compactLabel"), "header must bind session usage")
        XCTAssertTrue(source.contains("UsageMeterView(label: label)"))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-usage-\(UUID().uuidString)")
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

    private final class UsageRecordingEngine: ClaudeEngine, @unchecked Sendable {
        func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {}
        func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {}
        func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? { nil }
        func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {}
        func isSessionRunning(sessionID: String) -> Bool { false }
        func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {}
        func interrupt(sessionID: String) throws {}
        func kill(sessionID: String) {}
        func killAll() {}
    }
}
