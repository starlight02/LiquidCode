@testable import LiquidCode
import XCTest

final class ComposerDraftPersistenceTests: XCTestCase {
    func testComposerDraftStoreRoundTripKeepsQueuedMessagesAndAttachments() throws {
        let attachment = AttachmentChip(
            name: "example.swift",
            path: "/tmp/example.swift",
            size: 12,
            isImage: false
        )
        let queued = PendingUserMessage(
            id: "queue-1",
            content: "follow up",
            attachments: [attachment],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = ComposerDraftStore(
            defaultText: "hello",
            defaultAttachments: [attachment],
            textBySession: ["s1": "session draft"],
            attachmentsBySession: ["s1": [attachment]],
            queuedMessagesBySession: ["s1": [queued]]
        )

        let data = try JSONEncoder.liquid.encode(store)
        let decoded = try JSONDecoder.liquid.decode(ComposerDraftStore.self, from: data)

        XCTAssertEqual(decoded.defaultText, "hello")
        XCTAssertEqual(decoded.defaultAttachments, [attachment])
        XCTAssertEqual(decoded.textBySession["s1"], "session draft")
        XCTAssertEqual(decoded.attachmentsBySession["s1"], [attachment])
        XCTAssertEqual(decoded.queuedMessagesBySession["s1"], [queued])
    }

    func testJSONFileSaveLoadUsesTempDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lc-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("composer-drafts.json")
        let store = ComposerDraftStore(
            defaultText: "temp",
            defaultAttachments: [],
            textBySession: ["draft": "keep me"],
            attachmentsBySession: [:],
            queuedMessagesBySession: [:]
        )
        try JSONFile.save(store, to: url)
        let loaded = JSONFile.load(ComposerDraftStore.self, from: url)
        XCTAssertEqual(loaded?.defaultText, "temp")
        XCTAssertEqual(loaded?.textBySession["draft"], "keep me")
    }

    func testMissingDraftFileLoadsAsNil() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-drafts-\(UUID().uuidString).json")
        XCTAssertNil(JSONFile.load(ComposerDraftStore.self, from: url))
    }
}
