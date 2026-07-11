@testable import LiquidCode
import XCTest

final class CLIStatusSmokeTests: XCTestCase {
    func testCLIServiceFindsLocalClaudeWithoutNetwork() {
        let service = CLIService()
        let status = service.status(checkForUpdates: false)
        XCTAssertTrue(
            status.installed,
            "expected ~/.local/bin/claude; path=\(status.path ?? "nil") version=\(status.version ?? "nil")"
        )
        XCTAssertNotNil(status.path)
        XCTAssertNotNil(status.version)
    }

    @MainActor
    func testRefreshCLIStatusPublishesLocalDiscoverySynchronously() {
        let model = AppModel()
        let expected = model.cliService.status(checkForUpdates: false)
        XCTAssertTrue(expected.installed, "CLI must exist for this smoke")

        // Overlapping refresh must still leave an installed local status immediately.
        model.refreshCLIStatus()
        XCTAssertTrue(
            model.cliStatus.installed,
            "local discovery must publish before network probe; path=\(model.cliStatus.path ?? "nil")"
        )
        XCTAssertEqual(model.cliStatus.path, expected.path)

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
}
