@testable import LiquidCode
import XCTest

@MainActor
final class SessionFileSyncRegressionTests: XCTestCase {
    func testMergeExternalMessagesAppendsOnlyUnseenRecords() {
        let model = AppModel()
        let sessionID = "sync-session"
        model.sessions = [
            SessionRecord(id: sessionID, path: "/tmp/sync.jsonl", project: "P", projectDir: "/tmp", modifiedAt: Date(), preview: "old", isDraft: false)
        ]
        model.selectedSessionID = sessionID

        let first = ChatMessage(id: "m1", role: .user, content: "hello from GUI")
        let second = ChatMessage(id: "m2", role: .assistant, content: "hi back")
        model.setMessages([first, second], for: sessionID)

        // Disk now holds the two GUI-sent messages plus one appended by an external
        // `claude --resume` in the terminal. Only the new record must be added.
        let external = ChatMessage(id: "m3", role: .user, content: "typed in terminal")
        model.mergeExternalMessages([first, second, external], sessionID: sessionID)

        XCTAssertEqual(model.selectedMessages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(model.selectedMessages.map(\.content), ["hello from GUI", "hi back", "typed in terminal"])
    }

    func testMergeExternalMessagesIsIdempotentWhenNothingNew() {
        let model = AppModel()
        let sessionID = "sync-session"
        model.sessions = [
            SessionRecord(id: sessionID, path: "/tmp/sync.jsonl", project: "P", projectDir: "/tmp", modifiedAt: Date(), preview: "old", isDraft: false)
        ]
        model.selectedSessionID = sessionID
        let messages = [
            ChatMessage(id: "m1", role: .user, content: "one"),
            ChatMessage(id: "m2", role: .assistant, content: "two")
        ]
        model.setMessages(messages, for: sessionID)

        // A file event that carries no records the GUI hasn't already rendered (e.g. the
        // GUI's own turn landing on disk) must not duplicate anything.
        model.mergeExternalMessages(messages, sessionID: sessionID)

        XCTAssertEqual(model.selectedMessages.map(\.id), ["m1", "m2"])
    }

    func testMergeExternalMessagesRefreshesTranscriptDisplayItems() {
        let model = AppModel()
        let sessionID = "sync-session"
        model.sessions = [
            SessionRecord(id: sessionID, path: "/tmp/sync.jsonl", project: "P", projectDir: "/tmp", modifiedAt: Date(), preview: "old", isDraft: false)
        ]
        model.selectedSessionID = sessionID
        let existing = ChatMessage(id: "m1", role: .user, content: "first")
        model.setMessages([existing], for: sessionID)
        let beforeCount = model.selectedTranscriptDisplayItems.count

        model.mergeExternalMessages(
            [existing, ChatMessage(id: "m2", role: .assistant, content: "appended externally")],
            sessionID: sessionID
        )

        // The double-dictionary cache (messages + displayItems) must stay in lockstep;
        // updating messages without rebuilding display items would render a blank tail.
        XCTAssertGreaterThan(model.selectedTranscriptDisplayItems.count, beforeCount)
        XCTAssertTrue(model.selectedMessages.contains { $0.content == "appended externally" })
    }
}
