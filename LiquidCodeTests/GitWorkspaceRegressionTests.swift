@testable import LiquidCode
import XCTest

@MainActor
final class GitWorkspaceRegressionTests: XCTestCase {
    // MARK: - GitStatusService

    func testCurrentBranchDetectsNamedBranch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init"], in: root)
        try runGit(["config", "user.email", "test@example.com"], in: root)
        try runGit(["config", "user.name", "Test"], in: root)
        try "hello\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], in: root)
        try runGit(["commit", "-m", "init"], in: root)
        try runGit(["checkout", "-b", "feature/agent-gui"], in: root)

        let branch = try XCTUnwrap(GitStatusService.currentBranch(at: root.path))
        XCTAssertEqual(branch, "feature/agent-gui")
        XCTAssertTrue(GitStatusService.isRepository(at: root.path))
    }

    func testNonGitDirectoryReturnsNilQuietly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(GitStatusService.currentBranch(at: root.path))
        XCTAssertFalse(GitStatusService.isRepository(at: root.path))
        XCTAssertNil(GitStatusService.currentBranch(at: ""))
        XCTAssertNil(GitStatusService.currentBranch(at: "/path/that/does/not/exist-\(UUID().uuidString)"))
    }

    // MARK: - AppModel refresh

    func testRefreshGitBranchSetsPublishedBranch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init"], in: root)
        try runGit(["config", "user.email", "test@example.com"], in: root)
        try runGit(["config", "user.name", "Test"], in: root)
        try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "a.txt"], in: root)
        try runGit(["commit", "-m", "init"], in: root)
        try runGit(["branch", "-M", "main"], in: root)

        let model = AppModel(engine: GitStubEngine())
        model.workingDirectory = root.path
        model.refreshGitBranch()
        XCTAssertEqual(model.gitBranch, "main")

        model.workingDirectory = ""
        model.refreshGitBranch()
        XCTAssertNil(model.gitBranch)
    }

    func testRefreshGitBranchSilentOnNonGit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(engine: GitStubEngine())
        model.workingDirectory = root.path
        model.refreshGitBranch()
        XCTAssertNil(model.gitBranch)
    }

    // MARK: - Phase K external sync tip

    func testExternalMergeShowsOneShotSyncTip() {
        UserDefaults.standard.removeObject(forKey: "liquidcode.shownExternalSessionSyncTip")
        let model = AppModel(engine: GitStubEngine())
        model.hasShownExternalSessionSyncTip = false
        let sessionID = "sync-k"
        model.sessions = [
            SessionRecord(id: sessionID, path: "/tmp/sync.jsonl", project: "P", projectDir: "/tmp", modifiedAt: Date(), preview: "old", isDraft: false)
        ]
        model.selectedSessionID = sessionID
        let existing = ChatMessage(id: "m1", role: .user, content: "gui")
        model.setMessages([existing], for: sessionID)

        model.mergeExternalMessages(
            [existing, ChatMessage(id: "m2", role: .assistant, content: "from terminal")],
            sessionID: sessionID
        )

        XCTAssertTrue(model.hasShownExternalSessionSyncTip)
        // showToast runs titles through L(); accept en or zh-Hans.
        let tipTitle = model.toast?.title ?? ""
        XCTAssertTrue(
            tipTitle == "Following external Claude" || tipTitle == "正在跟随外部 Claude",
            "unexpected tip title: \(tipTitle)"
        )
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "liquidcode.shownExternalSessionSyncTip"))

        // Second external merge must not re-toast.
        model.toast = nil
        model.mergeExternalMessages(
            [
                existing,
                ChatMessage(id: "m2", role: .assistant, content: "from terminal"),
                ChatMessage(id: "m3", role: .user, content: "again")
            ],
            sessionID: sessionID
        )
        XCTAssertNil(model.toast)
    }

    func testShowCLISessionSyncHelpAlwaysToasts() {
        let model = AppModel(engine: GitStubEngine())
        model.hasShownExternalSessionSyncTip = true
        model.showCLISessionSyncHelp()
        let helpTitle = model.toast?.title ?? ""
        XCTAssertTrue(
            helpTitle == "CLI Session Sync Limits" || helpTitle == "CLI 会话同步限制",
            "unexpected help title: \(helpTitle)"
        )
        let message = model.toast?.message ?? ""
        XCTAssertTrue(
            message.contains("do not reverse-sync") ||
                message.contains("claude --resume") ||
                message.contains("反向同步"),
            "unexpected help message: \(message)"
        )
    }

    // MARK: - View structure

    func testGitBranchSurfacesInHeaderSidebarAndFiles() throws {
        let components = try Self.source("LiquidCode/ViewComponents.swift")
        XCTAssertTrue(components.contains("struct GitBranchBadgeView"), "branch capsule view must exist")
        XCTAssertTrue(components.contains("model.gitBranch"), "header/sidebar must bind gitBranch")
        XCTAssertTrue(components.contains("GitBranchBadgeView(branch: branch)"))

        let files = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(files.contains("thisTurnSummary"), "Files inspector must show This turn summary")
        XCTAssertTrue(files.contains("gitBranchRow"), "Files inspector must show branch row")
        XCTAssertTrue(files.contains("L(\"This turn\")") || files.contains("This turn"))

        let app = try Self.source("LiquidCode/LiquidCodeApp.swift")
        XCTAssertTrue(app.contains("CLI Session Sync"), "menu must expose hard-limit help")
        XCTAssertTrue(app.contains("showCLISessionSyncHelp"))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runGit(_ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.environment = [
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": directory.path
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "GitWorkspaceTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(message)"
            ])
        }
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

    private final class GitStubEngine: ClaudeEngine, @unchecked Sendable {
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
