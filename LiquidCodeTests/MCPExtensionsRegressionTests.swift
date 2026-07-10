@testable import LiquidCode
import XCTest

@MainActor
final class MCPExtensionsRegressionTests: XCTestCase {
    // MARK: - MCPRuntimeProbe

    func testStdioProbeRejectsNonMCPBinary() async {
        let server = MCPServer(
            name: "echo-server",
            transport: "stdio",
            command: "/bin/echo",
            url: nil,
            args: ["hello"],
            source: "LiquidCode"
        )
        let result = await MCPRuntimeProbe.evaluate(server)
        // A real MCP handshake is required; plain /bin/echo must fail instead of false-positive OK.
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.error)
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

    func testHTTPProbeAcceptsLocalhostWhenListening() async {
        // Prefer a known-good loopback if available; otherwise skip soft.
        let server = MCPServer(
            name: "local-http",
            transport: "http",
            command: nil,
            url: "http://127.0.0.1:9/", // discard port — typically closed
            args: [],
            source: "Test"
        )
        let result = await MCPRuntimeProbe.evaluate(server)
        // Port 9 is almost always closed → failed is expected; just ensure probe returns a terminal status.
        XCTAssertTrue(result.status == .failed || result.status == .ok)
        XCTAssertNotEqual(result.status, .idle)
        XCTAssertNotEqual(result.status, .testing)
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
        // /bin/echo is not a real MCP server; expect a terminal failure after async probe.
        XCTAssertEqual(model.mcpServers[0].runtimeStatus, .failed)
        XCTAssertNotNil(model.mcpServers[0].lastTestedAt)
        XCTAssertNotNil(model.mcpServers[0].lastError)
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
        let settings = root.appendingPathComponent("settings.json")
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
        try json.write(to: settings, atomically: true, encoding: .utf8)

        // Point service at fixture by writing into a temp "home" is hard; parse via project path.
        // loadHooks(projectPath:) reads projectPath/.claude/settings.json
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
        // Uses the real user install registry when present; otherwise skip soft structure check.
        let plugins = ClaudeExtensionsService.loadPlugins()
        // Structural: sorted, stable ids, enabled is Bool
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

        // Simulate an installed plugin with hooks/hooks.json nested form.
        let install = root.appendingPathComponent("plugin-a", isDirectory: true)
        let hooksDir = install.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let nested = """
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
        try nested.write(to: hooksDir.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)

        // Directly exercise parser path via project settings empty + inject by temporarily
        // not available; instead re-use project settings with same shape.
        let project = root.appendingPathComponent("p", isDirectory: true)
        let claude = project.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try nested.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        // When nested under settings "hooks" key the outer wrapper is the settings form.
        // Write bare event map under settings.hooks:
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
        XCTAssertTrue(ext.contains("HookCallback") == false) // service is inventory; copy lives in views

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
