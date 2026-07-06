import CryptoKit
@testable import LiquidCode
import XCTest

final class RuntimeParityTests: XCTestCase {
    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

    func testPathAccessFixedRootGrantAndRevocation() throws {
        let root = try temporaryDirectory(prefix: "lc-root")
        let outside = try temporaryDirectory(prefix: "lc-outside")
        let allowed = root.appendingPathComponent("allowed.txt")
        let secret = outside.appendingPathComponent("secret.txt")
        try "ok".write(to: allowed, atomically: true, encoding: .utf8)
        try "shh".write(to: secret, atomically: true, encoding: .utf8)

        let access = PathAccessManager.emptyForTests()
        let fs = FileSystemService(access: access)
        access.registerCWD(root.path)
        XCTAssertEqual(try fs.readText(allowed.path, sessionID: "tab-a"), "ok")
        XCTAssertThrowsError(try fs.readText(secret.path, sessionID: "tab-a"))

        access.addGrant(sessionID: "tab-a", path: secret.path)
        XCTAssertEqual(try fs.readText(secret.path, sessionID: "tab-a"), "shh")
        XCTAssertThrowsError(try fs.readText(secret.path, sessionID: "tab-b"))
        access.clearGrants(sessionID: "tab-a")
        XCTAssertThrowsError(try access.validate(secret.path, sessionID: "tab-a", capability: .read))
    }

    func testPathGrantDoesNotAuthorizeNilOrOtherSessions() throws {
        let root = try temporaryDirectory(prefix: "lc-root")
        let outside = try temporaryDirectory(prefix: "lc-outside")
        let workspaceFile = root.appendingPathComponent("workspace.txt")
        let grantedFile = outside.appendingPathComponent("granted.txt")
        try "workspace".write(to: workspaceFile, atomically: true, encoding: .utf8)
        try "secret".write(to: grantedFile, atomically: true, encoding: .utf8)

        let access = PathAccessManager.emptyForTests()
        let fs = FileSystemService(access: access)
        access.registerCWD(root.path)
        access.addGrant(sessionID: "tab-a", path: grantedFile.path)

        XCTAssertEqual(try fs.readText(workspaceFile.path, sessionID: nil), "workspace")
        XCTAssertEqual(try fs.readText(grantedFile.path, sessionID: "tab-a"), "secret")
        XCTAssertThrowsError(try fs.readText(grantedFile.path, sessionID: "tab-b"))
        XCTAssertThrowsError(try fs.readText(grantedFile.path, sessionID: nil))
    }

    func testProviderEnvironmentRemovesOAuthAndUsesApiKeyForThirdParty() throws {
        let provider = ProviderRecord(
            id: "third-party",
            name: "Third Party",
            baseURL: "https://provider.example/v1",
            apiFormat: .anthropic,
            modelMappings: [:],
            extraEnv: ["EMPTY_ME": "", "KEEP_ME": "1"],
            preset: nil,
            proxyURL: "socks5://127.0.0.1:1080"
        )
        let base = [
            "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
            "ANTHROPIC_AUTH_TOKEN": "bearer",
            "ANTHROPIC_API_KEY": "host-key",
            "ANTHROPIC_MODEL": "host-model",
            "EMPTY_ME": "remove-me"
        ]
        let plan = ClaudeChildEnvironmentBuilder.build(base: base, provider: provider, apiKey: "provider-key", thinkingLevel: .high, enrichedPath: "/bin")

        XCTAssertNil(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(plan.environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(plan.environment["ANTHROPIC_MODEL"])
        XCTAssertNil(plan.environment["EMPTY_ME"])
        XCTAssertEqual(plan.environment["ANTHROPIC_API_KEY"], "provider-key")
        XCTAssertEqual(plan.environment["ANTHROPIC_BASE_URL"], "https://provider.example/v1")
        XCTAssertEqual(plan.environment["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"], "1")
        XCTAssertNil(plan.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"])
        XCTAssertNil(plan.environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"])
        XCTAssertEqual(plan.environment["all_proxy"], "socks5://127.0.0.1:1080")
        XCTAssertFalse(plan.capabilities.isNativeAnthropic)
    }

    func testOpenAICompatibleProviderDoesNotLeakNativeOnlySettings() throws {
        let provider = ProviderRecord(
            id: "openai-compatible",
            name: "OpenAI Compatible",
            baseURL: "https://openai-compatible.example/v1",
            apiFormat: .openai,
            modelMappings: [:],
            extraEnv: [
                "CLAUDE_CODE_EFFORT_LEVEL": "ultra",
                "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "1",
                "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1",
                "LIQUIDCODE_INCLUDE_PARTIAL_MESSAGES": "1",
                "KEEP_ME": "kept"
            ],
            preset: nil,
            proxyURL: nil
        )
        let base = [
            "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
            "ANTHROPIC_AUTH_TOKEN": "bearer",
            "ANTHROPIC_API_KEY": "host-key",
            "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST": "host"
        ]

        let plan = ClaudeChildEnvironmentBuilder.build(base: base, provider: provider, apiKey: "provider-key", thinkingLevel: .high, enrichedPath: "/bin")

        XCTAssertEqual(plan.environment["OPENAI_API_KEY"], "provider-key")
        XCTAssertEqual(plan.environment["OPENAI_BASE_URL"], "https://openai-compatible.example/v1")
        XCTAssertEqual(plan.environment["KEEP_ME"], "kept")
        XCTAssertNil(plan.environment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(plan.environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(plan.environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(plan.environment["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"])
        XCTAssertNil(plan.environment["CLAUDE_CODE_EFFORT_LEVEL"])
        XCTAssertNil(plan.environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"])
        XCTAssertNil(plan.environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"])
        XCTAssertNil(plan.environment["LIQUIDCODE_INCLUDE_PARTIAL_MESSAGES"])
        XCTAssertFalse(plan.capabilities.isNativeAnthropic)
        XCTAssertFalse(plan.capabilities.supportsThinkingEffort)
        XCTAssertEqual(plan.extraArgs, [])
    }

    func testOpenAICompatibleProviderLaunchArgsDropThinkingSettingsAndPartialMessages() throws {
        let capabilities = ProviderRuntimeCapabilities(
            isNativeAnthropic: false,
            supportsPartialMessages: false,
            supportsThinkingEffort: false
        )

        let args = ClaudeCLIEngine.buildLaunchArguments(.init(
            mcpConfigPath: "/tmp/mcp.json",
            resumeSessionID: "resume-1",
            model: "provider-model",
            mode: .plan,
            thinkingLevel: .high,
            capabilities: capabilities
        ))

        XCTAssertFalse(args.contains("--include-partial-messages"))
        XCTAssertFalse(args.contains("--settings"))
        XCTAssertFalse(args.contains("--effort"))
        XCTAssertEqual(argumentValue(after: "--permission-mode", in: args), "plan")
        XCTAssertEqual(argumentValue(after: "--model", in: args), "provider-model")
        XCTAssertEqual(argumentValue(after: "--resume", in: args), "resume-1")
        XCTAssertEqual(argumentValue(after: "--mcp-config", in: args), "/tmp/mcp.json")
    }

    func testCLIStatusReportsLatestVersionAndUpdateAvailability() throws {
        let home = try temporaryDirectory(prefix: "lc-cli-status")
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = home.appendingPathComponent(".claude/local/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'Claude Code 1.0.0'\n".write(to: cli, atomically: true, encoding: .utf8)
        chmod(cli.path, 0o755)
        let releases = home.appendingPathComponent("releases", isDirectory: true)
        try FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true)
        try "1.2.0\n".write(to: releases.appendingPathComponent("latest"), atomically: true, encoding: .utf8)

        let service = CLIService(home: home, environment: ["PATH": "/usr/bin:/bin"], releaseBases: [releases])
        let status = service.status(checkForUpdates: true)

        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.path, cli.path)
        XCTAssertEqual(status.version, "1.0.0")
        XCTAssertEqual(status.latestVersion, "1.2.0")
        XCTAssertTrue(status.updateAvailable)
    }

    func testHumanEchoCapturesCheckpointUuidButToolResultDoesNot() throws {
        let checkpoint = "123e4567-e89b-12d3-a456-426614174000"
        let echo: [String: Any] = [
            "type": "human",
            "uuid": checkpoint,
            "message": ["role": "user", "content": [["type": "text", "text": "change file"]]]
        ]
        let events = StreamEventParser.events(from: echo, sessionID: "s1")
        guard case .message(_, let message) = try XCTUnwrap(events.first) else {
            return XCTFail("expected message")
        }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.checkpointUuid, checkpoint)

        let toolResult: [String: Any] = [
            "type": "user",
            "uuid": "not-a-checkpoint",
            "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]
        ]
        let toolEvents = StreamEventParser.events(from: toolResult, sessionID: "s1")
        guard case .message(_, let toolMessage) = try XCTUnwrap(toolEvents.first) else {
            return XCTFail("expected tool result message")
        }
        XCTAssertNil(toolMessage.checkpointUuid)
    }

    func testPermissionAndRewindPayloadsUseControlProtocolShape() throws {
        let permission = try ClaudeControlProtocol.permissionResponseJSON(
            requestID: "req-1",
            response: ["behavior": "allow", "updatedInput": ["file_path": "a.txt"], "toolUseID": "tool-1"]
        )
        XCTAssertTrue(permission.contains("\"type\":\"control_response\""))
        XCTAssertTrue(permission.contains("\"request_id\":\"req-1\""))
        XCTAssertTrue(permission.contains("\"toolUseID\":\"tool-1\""))

        let checkpoint = "123e4567-e89b-12d3-a456-426614174000"
        let rewind = try ClaudeControlProtocol.rewindControlJSON(checkpointUUID: checkpoint)
        XCTAssertTrue(rewind.contains("\"subtype\":\"rewind_files\""))
        XCTAssertTrue(rewind.contains("\"checkpoint_uuid\":\"\(checkpoint)\""))
        XCTAssertTrue(rewind.contains("\"checkpointUuid\":\"\(checkpoint)\""))
        XCTAssertFalse(rewind.contains("user_message_id"))
    }

    func testDirectoryWatcherDetectsRootFileCreation() throws {
        let root = try temporaryDirectory(prefix: "lc-watch")
        let watcher = DirectoryWatchManager()
        let exp = expectation(description: "watcher emits change")
        exp.assertForOverFulfill = false
        try watcher.watchDirectory(root.path) { paths in
            if paths.contains(where: { $0 == root.path || $0.hasSuffix("created.txt") }) {
                exp.fulfill()
            }
        }
        try "hello".write(to: root.appendingPathComponent("created.txt"), atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 1.5)
        watcher.unwatchAll()
    }

    func testDirectoryWatcherEmitsRecursiveNestedFileChanges() throws {
        let root = try temporaryDirectory(prefix: "lc-watch-recursive")
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let watchedFile = nested.appendingPathComponent("Nested.swift")
        let watcher = DirectoryWatchManager()
        let createExp = expectation(description: "watcher emits nested create")
        let modifyExp = expectation(description: "watcher emits nested modify")
        let deleteExp = expectation(description: "watcher emits nested delete")
        createExp.assertForOverFulfill = false
        modifyExp.assertForOverFulfill = false
        deleteExp.assertForOverFulfill = false
        let events = PathEventRecorder()

        try watcher.watchDirectory(root.path) { paths in
            events.append(paths)
            if paths.contains(where: { $0.hasSuffix("Sources/Feature/Nested.swift") }) {
                if !FileManager.default.fileExists(atPath: watchedFile.path) {
                    deleteExp.fulfill()
                } else if (try? String(contentsOf: watchedFile, encoding: .utf8)) == "modified" {
                    modifyExp.fulfill()
                } else {
                    createExp.fulfill()
                }
            } else if events.values.count >= 3, !FileManager.default.fileExists(atPath: watchedFile.path) {
                deleteExp.fulfill()
            }
        }
        try "created".write(to: watchedFile, atomically: true, encoding: .utf8)
        wait(for: [createExp], timeout: 1.5)
        try "modified".write(to: watchedFile, atomically: true, encoding: .utf8)
        wait(for: [modifyExp], timeout: 1.5)
        try FileManager.default.removeItem(at: watchedFile)
        wait(for: [deleteExp], timeout: 1.5)
        watcher.unwatchAll()
    }

    func testDirectoryWatcherSnapshotExcludesIgnoredDirectoriesFromChangeBursts() throws {
        let root = try temporaryDirectory(prefix: "lc-watch-ignore")
        let ignored = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        let visible = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        try "ignored".write(to: ignored.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let watchedFile = visible.appendingPathComponent("main.swift")

        let watcher = DirectoryWatchManager()
        let exp = expectation(description: "watcher emits visible change without ignored tree")
        exp.assertForOverFulfill = false
        try watcher.watchDirectory(root.path) { paths in
            guard paths.contains(where: { $0.hasSuffix("src/main.swift") }) else {
                return
            }
            XCTAssertFalse(paths.contains(where: { $0.contains("/node_modules/") || $0.hasSuffix("/node_modules") }), paths.joined(separator: "\n"))
            XCTAssertLessThan(paths.count, 32, "Ignored dependency trees should not flood a single visible change snapshot")
            exp.fulfill()
        }
        try "visible".write(to: watchedFile, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 1.5)
        watcher.unwatchAll()
    }

    func testDirectoryWatcherIgnoresBuildAndArtifactDirectories() throws {
        let root = try temporaryDirectory(prefix: "lc-watch-artifacts")
        let artifacts = root.appendingPathComponent(".artifacts/screenshots", isDirectory: true)
        let derived = root.appendingPathComponent(".xcode-derived/Build", isDirectory: true)
        let source = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let watchedFile = source.appendingPathComponent("Main.swift")
        let watcher = DirectoryWatchManager()
        let recorder = PathEventRecorder()
        let exp = expectation(description: "only source change is emitted")
        exp.assertForOverFulfill = false

        try watcher.watchDirectory(root.path) { paths in
            recorder.append(paths)
            guard paths.contains(where: { $0.hasSuffix("Sources/Main.swift") }) else {
                return
            }
            XCTAssertFalse(paths.contains(where: { $0.contains("/.artifacts/") || $0.contains("/.xcode-derived/") }), paths.joined(separator: "\n"))
            exp.fulfill()
        }

        try "png".write(to: artifacts.appendingPathComponent("shot.png"), atomically: true, encoding: .utf8)
        try "index".write(to: derived.appendingPathComponent("build.db"), atomically: true, encoding: .utf8)
        try "visible".write(to: watchedFile, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 1.5)
        XCTAssertFalse(recorder.values.flatMap { $0 }.contains { $0.contains("/.artifacts/") || $0.contains("/.xcode-derived/") })
        watcher.unwatchAll()
    }

    func testDirectoryWatcherSingleFileModifyDoesNotEmitWholeProjectSnapshot() throws {
        let root = try temporaryDirectory(prefix: "lc-watch-large")
        let visible = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: true)
        for index in 0 ..< 80 {
            try "seed \(index)".write(to: visible.appendingPathComponent(String(format: "file-%03d.txt", index)), atomically: true, encoding: .utf8)
        }
        let target = visible.appendingPathComponent("file-073.txt")
        let unrelated = visible.appendingPathComponent("file-001.txt").path

        let watcher = DirectoryWatchManager()
        let exp = expectation(description: "watcher emits incremental modify only")
        exp.assertForOverFulfill = false
        try watcher.watchDirectory(root.path) { paths in
            guard !paths.isEmpty else {
                return
            }
            XCTAssertLessThan(paths.count, 10, paths.joined(separator: "\n"))
            XCTAssertFalse(paths.contains(unrelated), paths.joined(separator: "\n"))
            exp.fulfill()
        }

        try "modified".write(to: target, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 1.5)
        watcher.unwatchAll()
    }

    @MainActor
    func testAppModelWatcherRefreshesVisibleTreeWithinOneSecond() async throws {
        let root = try temporaryDirectory(prefix: "lc-ui-watch")
        let source = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let model = AppModel()
        model.loadProject(root.path)
        try await Task.sleep(nanoseconds: 250_000_000)

        let newFile = source.appendingPathComponent("Live.swift")
        try "struct Live {}".write(to: newFile, atomically: true, encoding: .utf8)
        let canonicalNewFile = PathAccessManager.canonicalPath(newFile.path)

        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            if model.changedFiles.contains(canonicalNewFile), fileTreeContains(model.fileTree, path: canonicalNewFile) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("External file creation did not update changedFiles and fileTree within 1s. changed=\(model.changedFiles)")
    }

    func testMCPScratchSupportsSingleAndDoubleNestedAndCleanup() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let claude = home.appendingPathComponent(".claude.json")
        try #"{"mcpServers":{"alpha":{"command":"alpha","args":["--ok"]}}}"#.write(to: claude, atomically: true, encoding: .utf8)
        let single = try XCTUnwrap(ClaudeCLIEngine.buildMCPScratchConfig(sessionID: "desk/one", home: home))
        let singleJSON = try String(contentsOf: single, encoding: .utf8)
        XCTAssertTrue(single.path.hasSuffix(".liquidcode/mcp-session-desk_one.json"))
        XCTAssertTrue(singleJSON.contains("\"alpha\""))
        ClaudeCLIEngine.cleanupMCPScratchConfig(sessionID: "desk/one", home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: single.path))

        try #"{"mcpServers":{"mcpServers":{"beta":{"command":"beta"}}}}"#.write(to: claude, atomically: true, encoding: .utf8)
        let double = try XCTUnwrap(ClaudeCLIEngine.buildMCPScratchConfig(sessionID: "desk:two", home: home))
        let doubleJSON = try String(contentsOf: double, encoding: .utf8)
        XCTAssertTrue(double.path.hasSuffix(".liquidcode/mcp-session-desk_two.json"))
        XCTAssertTrue(doubleJSON.contains("\"beta\""))
        XCTAssertFalse(doubleJSON.contains("\"mcpServers\" : {\n    \"mcpServers\""))
        ClaudeCLIEngine.cleanupMCPScratchConfig(at: double)
        XCTAssertFalse(FileManager.default.fileExists(atPath: double.path))
    }

    func testMCPScratchRejectsEmptyOrMalformedConfigsWithoutLeavingSessionFiles() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let claude = home.appendingPathComponent(".claude.json")
        try #"{"mcpServers":{}}"#.write(to: claude, atomically: true, encoding: .utf8)
        XCTAssertNil(ClaudeCLIEngine.buildMCPScratchConfig(sessionID: "empty", home: home))

        try #"{"mcpServers":[]}"#.write(to: claude, atomically: true, encoding: .utf8)
        XCTAssertNil(ClaudeCLIEngine.buildMCPScratchConfig(sessionID: "malformed", home: home))

        let scratchDirectory = home.appendingPathComponent(".liquidcode", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratchDirectory.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("mcp-session-") }, leftovers.joined(separator: ","))
    }

    func testEngineNaturalExitEmitsOnceAndCleansMCPScratch() throws {
        let home = try temporaryDirectory(prefix: "lc-engine-home")
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"mcpServers":{"alpha":{"command":"echo","args":["ok"]}}}"#.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let fake = home.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeExecutableScript(at: fake, body: #"echo '{"type":"system","session_id":"cli-cleanup"}'"#)
        let events = ClaudeEventRecorder()
        let exitExp = expectation(description: "engine emits exit")
        let engine = ClaudeCLIEngine(home: home, environment: ["PATH": fake.deletingLastPathComponent().path, "HOME": home.path])

        try engine.startSession(.init(
            prompt: "",
            cwd: home.path,
            model: nil,
            sessionID: "desk/cleanup",
            resumeSessionID: nil,
            thinkingLevel: .off,
            mode: .ask,
            provider: nil,
            providerAPIKey: nil
        )) { event in
            events.append(event)
            if case .exited(let sessionID) = event, sessionID == "desk/cleanup" {
                exitExp.fulfill()
            }
        }

        wait(for: [exitExp], timeout: 2)
        XCTAssertEqual(events.values.compactMap { event -> String? in if case .exited(let id) = event {
            return id
        }; return nil }, ["desk/cleanup"])
        XCTAssertEqual(engine.listActiveProcesses(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".liquidcode/mcp-session-desk_cleanup.json").path))
    }

    func testEngineRestartTerminatesPreviousRuntimeBeforeReplacement() throws {
        let home = try temporaryDirectory(prefix: "lc-engine-restart")
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = home.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pids = home.appendingPathComponent("pids.txt")
        let terms = home.appendingPathComponent("terms.txt")
        try makeExecutableScript(at: fake, body: #"""
            echo "$$" >> "$LIQUID_TEST_PIDS"
            trap 'echo "$$" >> "$LIQUID_TEST_TERMS"; exit 0' TERM INT
            while true; do sleep 0.1; done
        """#)
        let env = [
            "PATH": fake.deletingLastPathComponent().path,
            "HOME": home.path,
            "LIQUID_TEST_PIDS": pids.path,
            "LIQUID_TEST_TERMS": terms.path
        ]
        let engine = ClaudeCLIEngine(home: home, environment: env)
        let request = ClaudeSessionStartRequest(
            prompt: "",
            cwd: home.path,
            model: nil,
            sessionID: "same-session",
            resumeSessionID: nil,
            thinkingLevel: .off,
            mode: .ask,
            provider: nil,
            providerAPIKey: nil
        )

        try engine.startSession(request) { _ in }
        XCTAssertTrue(waitUntil(timeout: 2) { lineCount(at: pids) == 1 })
        XCTAssertEqual(engine.listActiveProcesses(), ["same-session"])

        try engine.startSession(request) { _ in }
        XCTAssertTrue(waitUntil(timeout: 2) { lineCount(at: pids) == 2 && lineCount(at: terms) >= 1 })
        XCTAssertEqual(engine.listActiveProcesses(), ["same-session"])

        engine.killAll()
        XCTAssertTrue(waitUntil(timeout: 2) { lineCount(at: terms) >= 2 })
        XCTAssertEqual(engine.listActiveProcesses(), [])
    }

    func testRewindFallbackUsesResumeCheckpointAndRestoresFiles() throws {
        let home = try temporaryDirectory(prefix: "lc-engine-rewind")
        let cwd = try temporaryDirectory(prefix: "lc-engine-rewind-cwd")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cwd)
        }
        let fake = home.appendingPathComponent("bin/claude")
        let argsOut = home.appendingPathComponent("rewind-args.txt")
        let target = cwd.appendingPathComponent("edited.txt")
        try "broken".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeExecutableScript(at: fake, body: #"""
            printf '%s\n' "$*" > "$LIQUID_REWIND_ARGS"
            printf 'restored\n' > edited.txt
            echo 'rewind ok'
        """#)
        let env = ["PATH": fake.deletingLastPathComponent().path, "HOME": home.path, "LIQUID_REWIND_ARGS": argsOut.path]
        let engine = ClaudeCLIEngine(home: home, environment: env)
        let checkpoint = "123e4567-e89b-12d3-a456-426614174000"

        let output = try engine.rewindFiles(sessionID: "not-running", cliSessionID: "cli-session-1", checkpointUUID: checkpoint, cwd: cwd.path)

        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "rewind ok")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "restored\n")
        let args = try String(contentsOf: argsOut, encoding: .utf8)
        XCTAssertTrue(args.contains("--resume cli-session-1"), args)
        XCTAssertTrue(args.contains("--rewind-files \(checkpoint)"), args)
    }

    func testTrackedSessionListSearchLoadExportAndDecode() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let project = home.appendingPathComponent("work/my-project/has space/.dots", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let encoded = encodeClaudeProjectPath(project.path)
        let projectStore = home.appendingPathComponent(".claude/projects").appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: projectStore, withIntermediateDirectories: true)
        let trackedID = "123e4567-e89b-12d3-a456-426614174000"
        let untrackedID = "223e4567-e89b-12d3-a456-426614174000"
        let trackedFile = projectStore.appendingPathComponent(trackedID).appendingPathExtension("jsonl")
        let untrackedFile = projectStore.appendingPathComponent(untrackedID).appendingPathExtension("jsonl")
        let jsonl = [
            #"{"type":"system","cwd":"\#(project.path)"}"#,
            #"{"type":"human","uuid":"cp-1","message":{"role":"user","content":[{"type":"text","text":"please find needle in project"}]}}"#,
            #"{"type":"assistant","uuid":"a-1","parent_uuid":"cp-1","message":{"role":"assistant","content":[{"type":"text","text":"needle response"},"# +
                #"{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"a.txt"}}]}}"#
        ].joined(separator: "\n") + "\n"
        try jsonl.write(to: trackedFile, atomically: true, encoding: .utf8)
        try jsonl.write(to: untrackedFile, atomically: true, encoding: .utf8)
        let trackingDirectory = home.appendingPathComponent(".liquidcode", isDirectory: true)
        try FileManager.default.createDirectory(at: trackingDirectory, withIntermediateDirectories: true)
        try "\(trackedID)\n".write(to: trackingDirectory.appendingPathComponent("tracked_sessions.txt"), atomically: true, encoding: .utf8)

        let index = SessionIndexService(home: home)
        let sessions = index.listSessions()
        XCTAssertEqual(sessions.map(\.id), [trackedID])
        XCTAssertEqual(sessions.first?.projectDir, project.path)
        XCTAssertEqual(SessionIndexService.decodeProjectName(encoded), project.path)

        let messages = index.loadMessages(path: trackedFile.path)
        XCTAssertEqual(messages.first?.checkpointUuid, "cp-1")
        XCTAssertNotNil(messages.last?.rawJSON)
        XCTAssertEqual(messages.last?.toolName, "Read")
        XCTAssertEqual(messages.last?.parentID, "cp-1")

        let mdOut = home.appendingPathComponent("session.md")
        let jsonOut = home.appendingPathComponent("session.json")
        try index.exportMarkdown(path: trackedFile.path, outputPath: mdOut.path)
        try index.exportJSON(path: trackedFile.path, outputPath: jsonOut.path)
        XCTAssertTrue(try String(contentsOf: mdOut, encoding: .utf8).contains("**Tool: Read**"))
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonOut)) as? [[String: Any]]
        XCTAssertEqual(exported?.count, 3)
    }

    func testSessionIndexUsesClaudeGeneratedTitleForSidebarRecords() throws {
        let home = try temporaryDirectory(prefix: "lc-home-title")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("work/title-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = home.appendingPathComponent(".claude/projects").appendingPathComponent(encodeClaudeProjectPath(project.path), isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let sessionID = "123e4567-e89b-12d3-a456-426614174123"
        let file = store.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        let filler = (0 ..< 140).map { index in
            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"sessionId\":\"\(sessionID)\",\"content\":\"queued \(index)\"}"
        }
        let jsonl = ([#"{"type":"system","timestamp":"2026-07-05T00:00:00Z","cwd":"\#(project.path)"}"#] + filler + [
            #"{"type":"ai-title","sessionId":"\#(sessionID)","aiTitle":"Fix native sidebar session titles"}"#
        ]).joined(separator: "\n") + "\n"
        try jsonl.write(to: file, atomically: true, encoding: .utf8)
        let trackingDirectory = home.appendingPathComponent(".liquidcode", isDirectory: true)
        try FileManager.default.createDirectory(at: trackingDirectory, withIntermediateDirectories: true)
        try "\(sessionID)\n".write(to: trackingDirectory.appendingPathComponent("tracked_sessions.txt"), atomically: true, encoding: .utf8)

        let index = SessionIndexService(home: home)
        let listed = try XCTUnwrap(index.listSessions().first)
        XCTAssertEqual(listed.preview, "Claude session")
        XCTAssertEqual(listed.generatedTitle, "Fix native sidebar session titles")
        XCTAssertEqual(listed.title, "Fix native sidebar session titles")
        let discovered = try XCTUnwrap(index.discoverAllSessions().first { $0.id == sessionID })
        XCTAssertEqual(discovered.title, "Fix native sidebar session titles")
    }

    func testSessionIndexLoadsImageHistoryAsStructuredImages() throws {
        let home = try temporaryDirectory(prefix: "lc-home-images")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = home.appendingPathComponent(".claude/projects").appendingPathComponent(encodeClaudeProjectPath(project.path), isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let sessionID = "123e4567-e89b-12d3-a456-426614174999"
        let file = store.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        let jsonl = [
            #"{"type":"system","cwd":"\#(project.path)"}"#,
            #"{"type":"human","uuid":"cp-image","message":{"role":"user","content":[{"type":"text","text":"describe it"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(Self.tinyPNGBase64)"}}]}}"#
        ].joined(separator: "\n") + "\n"
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let messages = SessionIndexService(home: home).loadMessages(path: file.path)
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.content, "describe it")
        XCTAssertEqual(message.images.count, 1)
        XCTAssertEqual(message.images.first?.mimeType, "image/png")
        XCTAssertNotNil(message.images.first?.imageData)
    }

    func testSessionIndexSkipsClaudeQueueOperationPromptMetadata() throws {
        let home = try temporaryDirectory(prefix: "lc-home-queue-meta")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = home.appendingPathComponent(".claude/projects").appendingPathComponent(encodeClaudeProjectPath(project.path), isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let sessionID = "123e4567-e89b-12d3-a456-426614174998"
        let file = store.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        let jsonl = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-04T13:29:02.708Z","sessionId":"\#(sessionID)","content":"你好？"}"#,
            #"{"type":"user","uuid":"user-hello","message":{"role":"user","content":"你好？"}}"#,
            #"{"type":"assistant","uuid":"assistant-reply","message":{"role":"assistant","content":[{"type":"text","text":"你好呀"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"你好？","leafUuid":"assistant-reply","sessionId":"\#(sessionID)"}"#
        ].joined(separator: "\n") + "\n"
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let messages = SessionIndexService(home: home).loadMessages(path: file.path)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["你好？", "你好呀"])
        XCTAssertFalse(messages.contains { $0.role == .assistant && $0.content == "你好？" })
    }

    func testSessionIndexTurnsClaudeControlProtocolIntoReadableEventsAndSkipsPreview() throws {
        let home = try temporaryDirectory(prefix: "lc-home-control-protocol")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = home.appendingPathComponent(".claude/projects").appendingPathComponent(encodeClaudeProjectPath(project.path), isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let sessionID = "123e4567-e89b-12d3-a456-426614174997"
        let file = store.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        let command = #"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"#
        let jsonl = [
            #"{"type":"system","timestamp":"2026-07-03T10:51:31.000Z","cwd":"\#(project.path)"}"#,
            #"{"type":"user","uuid":"command-clear","message":{"role":"user","content":"\#(command)"}}"#,
            #"{"type":"user","uuid":"real-user","message":{"role":"user","content":"继续审查！"}}"#,
            #"{"type":"user","uuid":"interrupt","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        ].joined(separator: "\n") + "\n"
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let index = SessionIndexService(home: home)
        let messages = index.loadMessages(path: file.path)

        XCTAssertEqual(messages.map(\.role), [.system, .user, .system])
        XCTAssertEqual(messages[0].toolName, "Claude Code Command")
        XCTAssertEqual(messages[0].content, "`/clear`")
        XCTAssertEqual(messages[1].content, "继续审查！")
        XCTAssertEqual(messages[2].toolName, "Interrupted")
        XCTAssertEqual(messages[2].content, "User interrupted the request.")
        XCTAssertFalse(messages.contains { $0.content.contains("<command-name>") || $0.content.contains("[Request interrupted") })

        let info = SessionJSONLCodec.extractSessionInfo(file)
        XCTAssertEqual(info.preview, "继续审查！")

        let mdOut = home.appendingPathComponent("control.md")
        try index.exportMarkdown(path: file.path, outputPath: mdOut.path)
        let markdown = try String(contentsOf: mdOut, encoding: .utf8)
        XCTAssertTrue(markdown.contains("继续审查！"))
        XCTAssertFalse(markdown.contains("<command-name>"))
        XCTAssertFalse(markdown.contains("[Request interrupted"))
    }

    func testClaudeRecentProjectPrefersHistoryAndSessionCreatedAtComesFromJSONL() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let olderProject = home.appendingPathComponent("older", isDirectory: true)
        let newerProject = home.appendingPathComponent("newer", isDirectory: true)
        try FileManager.default.createDirectory(at: olderProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newerProject, withIntermediateDirectories: true)
        let projectsRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let newerStore = projectsRoot.appendingPathComponent(encodeClaudeProjectPath(newerProject.path), isDirectory: true)
        try FileManager.default.createDirectory(at: newerStore, withIntermediateDirectories: true)
        let newerFile = newerStore.appendingPathComponent("333e4567-e89b-12d3-a456-426614174000").appendingPathExtension("jsonl")
        let jsonl = [
            #"{"type":"system","timestamp":"2026-01-02T03:04:05.000Z","cwd":"\#(newerProject.path)"}"#,
            #"{"type":"human","message":{"role":"user","content":[{"type":"text","text":"newer project task"}]}}"#
        ].joined(separator: "\n") + "\n"
        try jsonl.write(to: newerFile, atomically: true, encoding: .utf8)
        let history = home.appendingPathComponent(".claude/history.jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        let historyText = [
            #"{"display":"old","timestamp":1780000000000,"project":"\#(olderProject.path)","sessionId":"old"}"#,
            #"{"display":"new","timestamp":1780000001000,"project":"\#(newerProject.path)","sessionId":"new"}"#
        ].joined(separator: "\n")
        try (historyText + "\n").write(to: history, atomically: true, encoding: .utf8)

        let index = SessionIndexService(home: home)
        XCTAssertEqual(index.mostRecentProjectDirectory(), newerProject.path)
        let session = try XCTUnwrap(index.discoverAllSessions().first)
        XCTAssertEqual(session.createdAt, ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        XCTAssertEqual(session.preview, "newer project task")
    }

    func testDeleteSessionRecordRemovesClaudeCodeJsonlAndUntracksIt() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let project = home.appendingPathComponent("work/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let encoded = encodeClaudeProjectPath(project.path)
        let projectStore = home.appendingPathComponent(".claude/projects").appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: projectStore, withIntermediateDirectories: true)
        let id = "444e4567-e89b-12d3-a456-426614174000"
        let sessionFile = projectStore.appendingPathComponent(id).appendingPathExtension("jsonl")
        try #"{"type":"system","cwd":"\#(project.path)"}"#.write(to: sessionFile, atomically: true, encoding: .utf8)
        let index = SessionIndexService(home: home)
        index.trackSession(id, projectDir: project.path, path: sessionFile.path)
        let session = try XCTUnwrap(index.listSessions().first)

        try index.deleteSessionRecord(session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
        XCTAssertTrue(index.listSessions().isEmpty)
    }

    func testCLIServiceDiagnoseNativeUpdateRepairOfflineFixture() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let fixture = try temporaryDirectory(prefix: "lc-cli-release")
        let version = "9.8.7"
        let platform = "darwin-arm64"
        let binary = "claude"
        let binaryData = Data("#!/bin/sh\necho 'Claude Code 9.8.7'\n".utf8)
        let checksum = sha256Hex(binaryData)
        try version.write(to: fixture.appendingPathComponent("latest"), atomically: true, encoding: .utf8)
        let versionDir = fixture.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: versionDir.appendingPathComponent(platform, isDirectory: true), withIntermediateDirectories: true)
        let manifest = #"{"platforms":{"\#(platform)":{"checksum":"\#(checksum)","binary":"\#(binary)"}}}"#
        try manifest.write(to: versionDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try binaryData.write(to: versionDir.appendingPathComponent(platform).appendingPathComponent(binary))

        let service = CLIService(home: home, environment: ["PATH": "/usr/bin:/bin"], releaseBases: [fixture])
        let events = EventRecorder()
        let result = service.installOrUpdate(releaseBases: [fixture], allowNPMFallback: false) { events.append($0) }
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.version, version)
        XCTAssertTrue(events.values.contains { $0.phase == .downloading })
        let status = service.status()
        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.version, version)
        XCTAssertEqual(service.checkCLIUpdate(releaseBases: [fixture]).latest, version)

        let appLocal = home.appendingPathComponent("Library/Application Support/LiquidCode/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: appLocal, withIntermediateDirectories: true)
        let broken = appLocal.appendingPathComponent("claude")
        try "not executable".write(to: broken, atomically: true, encoding: .utf8)
        let repair = service.repairCLI()
        XCTAssertTrue(repair.removed.contains(broken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
    }

    func testCLIUpdateCheckReportsNewerNativeReleaseThanInstalledCLI() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let installedDir = home.appendingPathComponent(".claude/local", isDirectory: true)
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        let installed = installedDir.appendingPathComponent("claude")
        try makeExecutableScript(at: installed, body: "echo 'Claude Code 1.2.3'")
        let release = try temporaryDirectory(prefix: "lc-cli-release")
        try "2.0.0".write(to: release.appendingPathComponent("latest"), atomically: true, encoding: .utf8)

        let service = CLIService(home: home, environment: ["PATH": ""], releaseBases: [release])
        XCTAssertEqual(service.status().version, "1.2.3")
        let update = service.checkCLIUpdate(releaseBases: [release])

        XCTAssertEqual(update.current, "1.2.3")
        XCTAssertEqual(update.latest, "2.0.0")
        XCTAssertTrue(update.updateAvailable)
    }

    func testCLIInstallFallsBackToNPMWhenNativeReleaseIsUnavailable() throws {
        let home = try temporaryDirectory(prefix: "lc-home")
        let npmBin = home.appendingPathComponent(".liquidcode/npm/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: npmBin, withIntermediateDirectories: true)
        let fakeNPM = npmBin.appendingPathComponent("npm")
        let fakeNPMBody = [
            "prefix=\"\"",
            "for arg in \"$@\"; do",
            "case \"$arg\" in",
            "--prefix=*) prefix=\"${arg#--prefix=}\" ;;",
            "esac",
            "done",
            "mkdir -p \"$prefix/bin\"",
            "cat > \"$prefix/bin/claude\" <<'EOS'",
            "#!/bin/sh",
            "echo 'Claude Code 4.5.6'",
            "EOS",
            "chmod +x \"$prefix/bin/claude\""
        ].joined(separator: "\n")
        try makeExecutableScript(at: fakeNPM, body: fakeNPMBody)
        let missingRelease = try temporaryDirectory(prefix: "lc-cli-missing-release")
        let events = EventRecorder()
        let service = CLIService(home: home, environment: ["PATH": ""], releaseBases: [missingRelease])

        let result = service.installOrUpdate(releaseBases: [missingRelease], allowNPMFallback: true) { events.append($0) }

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.source, "npm")
        XCTAssertEqual(result.version, "4.5.6")
        XCTAssertTrue(events.values.contains { $0.phase == .npmFallback })
        XCTAssertEqual(service.status().version, "4.5.6")
    }

    private func argumentValue(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    private func fileTreeContains(_ nodes: [FileNode], path: String) -> Bool {
        nodes.contains { node in
            node.path == path || fileTreeContains(node.children, path: path)
        }
    }

    private func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.025, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }

    private func lineCount(at url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return 0
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }.count
    }

    private func encodeClaudeProjectPath(_ path: String) -> String {
        String(path.map { $0 == "/" || $0 == " " || $0 == "." ? "-" : $0 })
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeExecutableScript(at url: URL, body: String) throws {
        let script = "#!/bin/sh\nset -eu\n" + body + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CLIProgressEvent] = []
        var values: [CLIProgressEvent] {
            lock.lock(); defer { lock.unlock() }; return storage
        }

        func append(_ event: CLIProgressEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }
    }

    private final class PathEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []
        var values: [[String]] {
            lock.lock(); defer { lock.unlock() }; return storage
        }

        func append(_ paths: [String]) {
            lock.lock(); storage.append(paths); lock.unlock()
        }
    }

    private final class ClaudeEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ClaudeEvent] = []
        var values: [ClaudeEvent] {
            lock.lock(); defer { lock.unlock() }; return storage
        }

        func append(_ event: ClaudeEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
