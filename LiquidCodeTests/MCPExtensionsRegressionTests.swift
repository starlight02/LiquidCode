@testable import LiquidCode
import XCTest

@MainActor
final class MCPExtensionsRegressionTests: XCTestCase {
    // MARK: - MCPRuntimeProbe

    func testStdioProbeAcceptsExistingBinary() async {
        let server = MCPServer(
            name: "echo-server",
            transport: "stdio",
            command: "/bin/echo",
            url: nil,
            args: ["hello"],
            source: "LiquidCode"
        )
        let result = await MCPRuntimeProbe.evaluate(server)
        // First-pass probe only checks command reachability, not a full MCP handshake.
        XCTAssertEqual(result.status, .ok)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.detail.contains("echo-server"))
    }

    func testStdioProbeFailsMissingCommand() async {
        let server = MCPServer(
            name: "missing",
            transport: "stdio",
            command: "definitely-not-a-real-mcp-binary-\(UUID().uuidString)",
            url: nil,
            args: [],
            source: "LiquidCode"
        )
        let result = await MCPRuntimeProbe.evaluate(server)
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.error)
    }

    func testHTTPProbeRejectsInvalidURL() async {
        let server = MCPServer(
            name: "bad",
            transport: "http",
            command: nil,
            url: "not a url",
            args: [],
            source: "LiquidCode"
        )
        let result = await MCPRuntimeProbe.evaluate(server)
        XCTAssertEqual(result.status, .failed)
    }

    func testHTTPProbeRejectsUnsupportedSchemeWithoutNetwork() async {
        let server = MCPServer(
            name: "file-url",
            transport: "http",
            command: nil,
            url: "file:///tmp/not-mcp",
            args: [],
            source: "Test"
        )
        let result = await MCPRuntimeProbe.evaluate(server)
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.error)
    }

    func testTestMCPServerWritesRuntimeStatus() async {
        let model = AppModel(engine: ExtensionsStubEngine())
        model.mcpServers = [
            MCPServer(
                name: "which-echo",
                transport: "stdio",
                command: "/bin/echo",
                url: nil,
                args: [],
                source: "LiquidCode"
            )
        ]
        XCTAssertEqual(model.mcpServers[0].runtimeStatus, .idle)
        model.testMCPServer(model.mcpServers[0])
        XCTAssertEqual(model.mcpServers[0].runtimeStatus, .testing)

        let deadline = Date().addingTimeInterval(3)
        while model.mcpServers[0].runtimeStatus == .testing, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.mcpServers[0].runtimeStatus, .ok)
        XCTAssertNotNil(model.mcpServers[0].lastTestedAt)
        XCTAssertNil(model.mcpServers[0].lastError)
    }

    func testTestMCPServerRecordsFailure() async {
        let model = AppModel(engine: ExtensionsStubEngine())
        model.mcpServers = [
            MCPServer(
                name: "gone",
                transport: "stdio",
                command: "no-such-cmd-\(UUID().uuidString)",
                url: nil,
                args: [],
                source: "LiquidCode"
            )
        ]
        model.testMCPServer(model.mcpServers[0])
        XCTAssertEqual(model.mcpServers[0].runtimeStatus, .testing)
        let deadline = Date().addingTimeInterval(3)
        while model.mcpServers[0].runtimeStatus == .testing, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.mcpServers[0].runtimeStatus, .failed)
        XCTAssertNotNil(model.mcpServers[0].lastError)
    }

    // MARK: - Hooks / plugins parsers

    func testParseHooksFromSettingsFixture() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "echo pre", "async": false }
                ]
              }
            ],
            "SessionStart": [
              {
                "matcher": "startup",
                "hooks": [
                  { "type": "command", "command": "echo start", "async": true }
                ]
              }
            ]
          }
        }
        """
        let project = root.appendingPathComponent("proj", isDirectory: true)
        let claude = project.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try json.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let hooks = ClaudeExtensionsService.loadHooks(projectPath: project.path)
        let projectHooks = hooks.filter { $0.source.contains("Project") }
        XCTAssertFalse(projectHooks.isEmpty, "expected project fixture hooks, got: \(hooks.map(\.source))")
        let events = Set(projectHooks.map(\.event))
        XCTAssertTrue(events.contains("PreToolUse"))
        XCTAssertTrue(events.contains("SessionStart"))
        XCTAssertTrue(projectHooks.contains { $0.command.contains("echo pre") })
        XCTAssertTrue(projectHooks.contains { $0.isAsync && $0.command.contains("echo start") })
    }

    func testParsePluginsFromInstalledRegistry() throws {
        let plugins = ClaudeExtensionsService.loadPlugins()
        let ids = plugins.map(\.id)
        XCTAssertEqual(ids, ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        for plugin in plugins {
            XCTAssertFalse(plugin.id.isEmpty)
            XCTAssertFalse(plugin.name.isEmpty)
        }
    }

    func testParsePluginHooksJsonNestedAndBare() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("p", isDirectory: true)
        let claude = project.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let bareSettings = """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  { "type": "command", "command": "notify-send hi" }
                ]
              }
            ]
          }
        }
        """
        try bareSettings.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let hooks = ClaudeExtensionsService.loadHooks(projectPath: project.path)
        XCTAssertTrue(hooks.contains { $0.event == "Notification" && $0.command.contains("notify-send") })
    }

    // MARK: - UI structure

    func testMCPAndExtensionsSurfaceInSettings() throws {
        let models = try Self.source("LiquidCode/Models.swift")
        XCTAssertTrue(models.contains("case extensions = \"Hooks & Plugins\""))
        XCTAssertTrue(models.contains("enum MCPRuntimeStatus"))
        XCTAssertTrue(models.contains("runtimeStatus"))
        XCTAssertTrue(models.contains("toolCount"))

        let settings = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        XCTAssertTrue(settings.contains("case .extensions: ExtensionsSettingsContent()"))
        XCTAssertTrue(settings.contains("MCPRuntimeBadge(server: server)"))

        let probe = try Self.source("LiquidCode/MCPRuntime.swift")
        XCTAssertTrue(probe.contains("enum MCPRuntimeProbe"))

        let ext = try Self.source("LiquidCode/ClaudeExtensionsService.swift")
        XCTAssertTrue(ext.contains("loadHooks"))
        XCTAssertTrue(ext.contains("loadPlugins"))
        XCTAssertTrue(ext.contains("HookCallback") == false)

        let views = try Self.source("LiquidCode/ClaudeExtensionsViews.swift")
        XCTAssertTrue(views.contains("HookCallback"))
        XCTAssertTrue(views.contains("ExtensionsSettingsContent"))

        let icons = try Self.source("LiquidCode/ViewOverlays.swift")
        XCTAssertTrue(icons.contains("case .extensions:"))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lc-mcp-ext-\(UUID().uuidString)")
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

    private final class ExtensionsStubEngine: ClaudeEngine, @unchecked Sendable {
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
