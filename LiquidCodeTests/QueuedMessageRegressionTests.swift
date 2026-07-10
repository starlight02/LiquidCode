@testable import LiquidCode
import XCTest

@MainActor
final class QueuedMessageRegressionTests: XCTestCase {
    func testCancelEditAndReorderQueuedMessages() {
        let model = AppModel(engine: QueueStubEngine())
        model.selectedSessionID = "s1"
        model.pendingUserMessagesBySession["s1"] = [
            PendingUserMessage(id: "a", content: "first"),
            PendingUserMessage(id: "b", content: "second"),
            PendingUserMessage(id: "c", content: "third")
        ]

        model.moveQueuedUserMessage("c", offset: -1)
        XCTAssertEqual(model.pendingUserMessagesBySession["s1"]?.map(\.id), ["a", "c", "b"])

        model.cancelQueuedUserMessage("a")
        XCTAssertEqual(model.pendingUserMessagesBySession["s1"]?.map(\.id), ["c", "b"])

        model.editQueuedUserMessage("b")
        XCTAssertEqual(model.composerText, "second")
        XCTAssertEqual(model.pendingUserMessagesBySession["s1"]?.map(\.id), ["c"])

        model.clearQueuedUserMessages()
        XCTAssertNil(model.pendingUserMessagesBySession["s1"])
    }

    private final class QueueStubEngine: ClaudeEngine, @unchecked Sendable {
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
