@testable import LiquidCode
import XCTest

@MainActor
final class SessionSwitchLoadingRegressionTests: XCTestCase {
    func testSelectingUncachedSessionShowsLoadingStateUntilMessagesArrive() throws {
        let root = try temporaryDirectory(prefix: "lc-loading-state")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "cached", path: nil, project: "Cached", projectDir: root.path, modifiedAt: Date(), preview: "Cached", isDraft: true),
            SessionRecord(id: "uncached", path: nil, project: "Uncached", projectDir: root.path, modifiedAt: Date(), preview: "Uncached", isDraft: true)
        ]

        // A session whose messages are still being loaded from disk must report the
        // loading state so the transcript renders a spinner instead of the empty
        // "Ready when you are" placeholder (which reads as a blank window).
        model.selectedSessionID = "uncached"
        model.loadingMessageSessionIDs = ["uncached"]
        XCTAssertTrue(model.isLoadingSelectedMessages)

        // Once messages land (even an empty transcript), loading must clear so the
        // real content — or the genuine empty state — can show.
        model.loadingMessageSessionIDs = []
        model.setMessages([ChatMessage(id: "m1", role: .user, content: "hi")], for: "uncached")
        XCTAssertFalse(model.isLoadingSelectedMessages)

        // A guard failure that clears the loading flag without backfilling messages
        // must degrade to the empty state, never latch a permanent spinner.
        model.selectedSessionID = "cached"
        model.loadingMessageSessionIDs = []
        XCTAssertFalse(model.isLoadingSelectedMessages)
        XCTAssertTrue(model.selectedMessages.isEmpty)
    }

    func testSelectSessionLoadsTranscriptFromDiskAndClearsLoadingState() async throws {
        let root = try temporaryDirectory(prefix: "lc-select-load")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello there"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hi back"}]}}"#
        ].joined(separator: "\n") + "\n"
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.sessions = [
            SessionRecord(id: "disk", path: file.path, project: "Disk", projectDir: root.path, modifiedAt: Date(), preview: "Disk", isDraft: false)
        ]

        model.selectSession("disk")
        XCTAssertTrue(model.loadingMessageSessionIDs.contains("disk"))
        XCTAssertTrue(model.isLoadingSelectedMessages)

        try await waitUntilAsync(timeout: 5, message: "session transcript never finished loading") {
            !model.isLoadingSelectedMessages
        }

        XCTAssertFalse(model.loadingMessageSessionIDs.contains("disk"))
        XCTAssertEqual(model.selectedMessages.map(\.content), ["hello there", "hi back"])
        XCTAssertFalse(model.selectedMessages.isEmpty)
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
}
