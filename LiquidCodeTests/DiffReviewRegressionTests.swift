@testable import LiquidCode
import XCTest

@MainActor
final class DiffReviewRegressionTests: XCTestCase {
    func testBuilderExtractsEditAndWriteAndGroupsByPath() {
        let editJSON = #"{"file_path":"/tmp/a.swift","old_string":"foo","new_string":"bar"}"#
        let writeJSON = #"{"file_path":"/tmp/b.swift","content":"hello\nworld"}"#
        let secondEdit = #"{"file_path":"/tmp/a.swift","old_string":"bar","new_string":"baz"}"#
        let messages = [
            ChatMessage(
                id: "m1",
                role: .assistant,
                content: "",
                blocks: [ChatContentBlock(kind: .toolUse, toolName: "Edit", inputJSON: editJSON)]
            ),
            ChatMessage(
                id: "m2",
                role: .assistant,
                content: "",
                blocks: [ChatContentBlock(kind: .toolUse, toolName: "Write", inputJSON: writeJSON)]
            ),
            ChatMessage(
                id: "m3",
                role: .assistant,
                content: "",
                blocks: [ChatContentBlock(kind: .toolUse, toolName: "Edit", inputJSON: secondEdit)]
            ),
            ChatMessage(
                id: "m4",
                role: .assistant,
                content: "",
                blocks: [ChatContentBlock(kind: .toolUse, toolName: "Read", inputJSON: #"{"file_path":"/tmp/a.swift"}"#)]
            )
        ]

        let entries = SessionDiffBuilder.entries(from: messages)
        XCTAssertEqual(entries.count, 3, "Read must not produce a diff entry")
        XCTAssertEqual(entries.map(\.toolName), ["Edit", "Write", "Edit"])
        XCTAssertEqual(entries.map(\.path), ["/tmp/a.swift", "/tmp/b.swift", "/tmp/a.swift"])
        XCTAssertTrue(entries[0].diff.contains("-foo"))
        XCTAssertTrue(entries[0].diff.contains("+bar"))
        XCTAssertTrue(entries[1].diff.contains("+hello"))

        let groups = SessionDiffBuilder.groupedByPath(entries)
        XCTAssertEqual(groups.map(\.path), ["/tmp/a.swift", "/tmp/b.swift"])
        XCTAssertEqual(groups[0].entries.count, 2)
        XCTAssertEqual(groups[1].entries.count, 1)
    }

    func testBuilderIgnoresMessagesWithoutDiffPayload() {
        let messages = [
            ChatMessage(id: "m1", role: .user, content: "hello"),
            ChatMessage(
                id: "m2",
                role: .assistant,
                content: "",
                blocks: [ChatContentBlock(kind: .text, text: "thinking out loud")]
            )
        ]
        XCTAssertTrue(SessionDiffBuilder.entries(from: messages).isEmpty)
    }

    func testFilePathHelperReadsCommonKeys() {
        XCTAssertEqual(
            SessionDiffBuilder.filePath(in: #"{"file_path":"/tmp/x.swift"}"#),
            "/tmp/x.swift"
        )
        XCTAssertEqual(
            SessionDiffBuilder.filePath(in: #"{"path":"/tmp/y.swift"}"#),
            "/tmp/y.swift"
        )
        XCTAssertNil(SessionDiffBuilder.filePath(in: #"{"command":"ls"}"#))
    }

    func testOpenDiffReviewSetsTabAndFocus() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: DiffStubEngine())
        model.sessions = [
            SessionRecord(id: "s1", path: nil, project: "A", projectDir: root.path, modifiedAt: Date(), preview: "a")
        ]
        model.selectedSessionID = "s1"
        model.secondaryOpen = false
        model.secondaryTab = .files

        model.openDiffReview(path: "/tmp/a.swift")
        XCTAssertEqual(model.secondaryTab, .diffs)
        XCTAssertTrue(model.secondaryOpen)
        XCTAssertEqual(model.focusedDiffPath, "/tmp/a.swift")
    }

    func testDiffReviewSurfacesInUI() throws {
        let panels = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(panels.contains("case .diffs: SessionDiffReviewView()"))
        XCTAssertTrue(panels.contains("Open Full Diff") || panels.contains("L(\"Open Full Diff\")"))
        let review = try Self.source("LiquidCode/DiffReviewViews.swift")
        XCTAssertTrue(review.contains("struct SessionDiffReviewView"))
        XCTAssertTrue(review.contains("SessionDiffBuilder"))
        XCTAssertTrue(review.contains("truncatedDiff"))
        let models = try Self.source("LiquidCode/Models.swift")
        XCTAssertTrue(models.contains("case diffs"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-diff-\(UUID().uuidString)")
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

    private final class DiffStubEngine: ClaudeEngine, @unchecked Sendable {
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
