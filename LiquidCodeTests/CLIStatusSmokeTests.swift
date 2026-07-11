@testable import LiquidCode
import XCTest

final class CLIStatusSmokeTests: XCTestCase {
    func testCLIServiceFindsLocalClaudeWithoutNetwork() throws {
        let home = try temporaryDirectory(prefix: "lc-cli-smoke")
        defer { try? FileManager.default.removeItem(at: home) }

        let cli = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'Claude Code 2.1.0'\n".write(to: cli, atomically: true, encoding: .utf8)
        chmod(cli.path, 0o755)

        let service = CLIService(home: home, environment: ["PATH": "/usr/bin:/bin"], releaseBases: [])
        let status = service.status(checkForUpdates: false)

        XCTAssertTrue(status.installed, "path=\(status.path ?? "nil") version=\(status.version ?? "nil")")
        XCTAssertEqual(status.path, cli.path)
        XCTAssertEqual(status.version, "2.1.0")
        XCTAssertNil(status.latestVersion)
        XCTAssertFalse(status.updateAvailable)
    }

    @MainActor
    func testRefreshCLIStatusPublishesLocalDiscoverySynchronously() throws {
        let home = try temporaryDirectory(prefix: "lc-cli-refresh")
        defer { try? FileManager.default.removeItem(at: home) }

        let cli = home.appendingPathComponent(".claude/local/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'Claude Code 3.0.0'\n".write(to: cli, atomically: true, encoding: .utf8)
        chmod(cli.path, 0o755)

        let service = CLIService(home: home, environment: ["PATH": "/usr/bin:/bin"], releaseBases: [])
        let model = AppModel(cliService: service)
        let expected = service.status(checkForUpdates: false)
        XCTAssertTrue(expected.installed)

        // Local discovery must publish immediately; overlapping refresh must not leave false missing.
        model.refreshCLIStatus()
        XCTAssertTrue(
            model.cliStatus.installed,
            "local discovery must publish before network probe; path=\(model.cliStatus.path ?? "nil")"
        )
        XCTAssertEqual(model.cliStatus.path, expected.path)
        XCTAssertEqual(model.cliStatus.version, expected.version)

        model.refreshCLIStatus()
        XCTAssertTrue(model.cliStatus.installed)
        XCTAssertEqual(model.cliStatus.path, expected.path)
    }

    func testRootViewDoesNotIdentityResetShellOnTheme() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("LiquidCode/LiquidCodeApp.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains(".id(model.settings.theme)"),
            "Theme identity reset re-runs AppShellView.onAppear/bootstrap and falsely reports CLI missing"
        )
        XCTAssertTrue(source.contains(".preferredColorScheme(model.settings.theme.preferredColorScheme)"))
    }

    func testBootstrapIsOneShotInSource() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("LiquidCode/AppModel/ModelConfig.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("hasCompletedBootstrap"), "bootstrap must be one-shot guarded")
        XCTAssertTrue(source.contains("if hasCompletedBootstrap"), "bootstrap early-return required")
    }

    func testRefreshCLIStatusNoLongerDropsOverlappingCalls() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("LiquidCode/AppModel/Setup.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("guard !cliStatusRefreshing else"),
            "overlapping refreshCLIStatus must not be dropped"
        )
        XCTAssertTrue(source.contains("cliStatusRefreshGeneration"))
        XCTAssertTrue(source.contains("checkForUpdates: false"))
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
