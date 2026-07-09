import Foundation

protocol ClaudeEngine: Sendable {
    func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws
    func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws
    func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String?
    func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws
    func isSessionRunning(sessionID: String) -> Bool
    func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws
    func interrupt(sessionID: String) throws
    func kill(sessionID: String)
    func killAll()
}

struct ClaudeLaunchConfiguration: Equatable, Sendable {
    var prefixArgs: [String] = []
    var mcpConfigPath: String?
    var resumeSessionID: String?
    var model: String?
    var mode: SessionMode
    var thinkingLevel: ThinkingLevel
    var capabilities: ProviderRuntimeCapabilities

}

final class ClaudeCLIEngine: ClaudeEngine, @unchecked Sendable {
    private let home: URL
    private let baseEnvironment: [String: String]
    private let executableOverride: (String, [String])?

    private final class Runtime: @unchecked Sendable {
        let sessionID: String
        let process: Process
        let stdin: FileHandle
        var stdoutBuffer = Data()
        var stderrBuffer = Data()
        let eventSink: @Sendable (ClaudeEvent) -> Void
        let mcpScratch: URL?
        var didExit = false
        init(sessionID: String, process: Process, stdin: FileHandle, eventSink: @escaping @Sendable (ClaudeEvent) -> Void, mcpScratch: URL?) {
            self.sessionID = sessionID; self.process = process; self.stdin = stdin; self.eventSink = eventSink; self.mcpScratch = mcpScratch
        }
    }

    private var runtimes: [String: Runtime] = [:]
    private let queue = DispatchQueue(label: "LiquidCode.ClaudeCLIEngine")

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableOverride: (String, [String])? = nil
    ) {
        self.home = home
        baseEnvironment = environment
        self.executableOverride = executableOverride
    }

    func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
        kill(sessionID: request.sessionID)
        let (executable, prefixArgs) = resolveClaudeExecutable()
        let scratch = Self.buildMCPScratchConfig(sessionID: request.sessionID, home: home)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        let envPlan = ClaudeChildEnvironmentBuilder.build(
            base: baseEnvironment,
            provider: request.provider,
            apiKey: request.providerAPIKey,
            thinkingLevel: request.thinkingLevel,
            enrichedPath: enrichedPath()
        )
        var args = Self.buildLaunchArguments(.init(
            prefixArgs: prefixArgs,
            mcpConfigPath: scratch?.path,
            resumeSessionID: request.resumeSessionID,
            model: request.model,
            mode: request.mode,
            thinkingLevel: request.thinkingLevel,
            capabilities: envPlan.capabilities
        ))
        args += envPlan.extraArgs
        process.arguments = args
        process.environment = envPlan.environment

        let stdinPipe = Pipe(); let stdoutPipe = Pipe(); let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            Self.cleanupMCPScratchConfig(at: scratch)
            throw error
        }

        let runtime = Runtime(sessionID: request.sessionID, process: process, stdin: stdinPipe.fileHandleForWriting, eventSink: eventSink, mcpScratch: scratch)
        queue.sync { runtimes[request.sessionID] = runtime }
        attachReaders(runtime: runtime, stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading)
        eventSink(.sessionStarted(sessionID: request.sessionID, cliSessionID: request.resumeSessionID))
        if !request.userMessageContent.isEmpty {
            try sendUserJSON(sessionID: request.sessionID, content: request.userMessageContent)
        }
    }

    func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {
        try sendUserJSON(sessionID: sessionID, content: content)
    }

    private func sendRaw(sessionID: String, jsonLine: String) throws {
        guard let runtime = queue.sync(execute: { runtimes[sessionID] }) else {
            throw NSError(
                domain: "LiquidCode",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Session is not running"]
            ) }
        guard let data = (jsonLine + "\n").data(using: .utf8) else {
            return
        }
        try runtime.stdin.write(contentsOf: data)
    }

    func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? {
        if isSessionRunning(sessionID: sessionID) {
            try sendRaw(sessionID: sessionID, jsonLine: ClaudeControlProtocol.rewindControlJSON(checkpointUUID: checkpointUUID))
            return nil
        }
        guard let cliSessionID, !cliSessionID.isEmpty else {
            throw NSError(
                domain: "LiquidCode",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Missing Claude CLI session id for rewind fallback"]
            ) }
        guard Self.isUUIDLike(checkpointUUID) else {
            throw NSError(
                domain: "LiquidCode",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid checkpoint UUID: \(checkpointUUID)"]
            ) }
        let (executable, prefixArgs) = resolveClaudeExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = prefixArgs + ["--resume", cliSessionID, "--rewind-files", checkpointUUID]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ClaudeChildEnvironmentBuilder.buildNative(base: baseEnvironment, enrichedPath: enrichedPath()).environment
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run(); process.waitUntilExit()
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return stdout
        }
        throw NSError(domain: "LiquidCode", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "rewind_files failed" : stderr])
    }

    func listActiveProcesses() -> [String] {
        queue.sync { Array(runtimes.keys).sorted() }
    }

    func isSessionRunning(sessionID: String) -> Bool {
        queue.sync { runtimes[sessionID] != nil }
    }

    func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {
        var inner: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if allow {
            inner["updatedInput"] = parseJSONObject(updatedInputJSON ?? permission.inputJSON) ?? [:]
            if let toolUseID = permission.toolUseID {
                inner["toolUseID"] = toolUseID
            }
        } else {
            inner["message"] = message ?? "User denied this operation"
        }
        try sendRaw(sessionID: permission.sessionID, jsonLine: ClaudeControlProtocol.permissionResponseJSON(requestID: permission.requestID, response: inner))
    }

    func interrupt(sessionID: String) throws {
        try sendControl(sessionID: sessionID, subtype: "interrupt", payload: [:])
    }

    func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {
        if let mode {
            try sendControl(sessionID: sessionID, subtype: "set_permission_mode", payload: ["mode": mode.permissionMode])
        }
        if let model, !model.isEmpty {
            try sendControl(sessionID: sessionID, subtype: "set_model", payload: ["model": cliModelName(model)])
        }
        if let thinkingLevel {
            try sendControl(sessionID: sessionID, subtype: "set_max_thinking_tokens", payload: [
                "max_thinking_tokens": thinkingLevel.maxThinkingTokens,
                "thinking_display": thinkingLevel == .off ? "hidden" : "visible"
            ])
        }
    }

    func kill(sessionID: String) {
        let runtime = queue.sync { runtimes.removeValue(forKey: sessionID) }
        guard let runtime else {
            return
        }
        runtime.process.terminate()
        waitForExit(runtime.process, timeout: 2)
        try? runtime.stdin.close()
        Self.cleanupMCPScratchConfig(at: runtime.mcpScratch)
    }

    func killAll() {
        let ids = queue.sync { Array(runtimes.keys) }
        ids.forEach { kill(sessionID: $0) }
    }

    private func sendUserJSON(sessionID: String, content: ClaudeUserMessageContent) throws {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": try content.jsonContent()]]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try sendRaw(sessionID: sessionID, jsonLine: String(data: data, encoding: .utf8) ?? "")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) {
        guard process.isRunning else {
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.interrupt()
        }
    }

    private func cliModelName(_ model: String) -> String {
        [
            "claude-fable-5-1m": "claude-fable-5[1m]",
            "claude-opus-4-8-1m": "claude-opus-4-8[1m]",
            "claude-opus-4-6-1m": "claude-opus-4-6[1m]"
        ][model] ?? model
    }

    private func sendControl(sessionID: String, subtype: String, payload: [String: Any]) throws {
        let obj: [String: Any] = ["type": "control_request", "request_id": UUID().uuidString, "request": payload.merging(["subtype": subtype]) { lhs, _ in lhs }]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try sendRaw(sessionID: sessionID, jsonLine: String(data: data, encoding: .utf8) ?? "")
    }

    private func attachReaders(runtime: Runtime, stdout: FileHandle, stderr: FileHandle) {
        stdout.readabilityHandler = { [weak self, weak runtime] handle in
            guard let self, let runtime else {
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                handleExit(runtime)
                return
            }
            queue.async {
                runtime.stdoutBuffer.append(data)
                for line in Self.consumeLines(&runtime.stdoutBuffer) {
                    self.handleStdout(line, runtime: runtime)
                }
            }
        }
        stderr.readabilityHandler = { [weak self, weak runtime] handle in
            guard let self, let runtime else {
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            queue.async {
                runtime.stderrBuffer.append(data)
                for line in Self.consumeLines(&runtime.stderrBuffer) {
                    runtime.eventSink(.stderr(sessionID: runtime.sessionID, line))
                }
            }
        }
        processTermination(runtime)
    }

    private func processTermination(_ runtime: Runtime) {
        runtime.process.terminationHandler = { [weak self, weak runtime] _ in
            guard let self, let runtime else {
                return
            }
            handleExit(runtime)
        }
    }

    private func handleStdout(_ line: String, runtime: Runtime) {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let events = StreamEventParser.events(from: obj, sessionID: runtime.sessionID)
        if events.isEmpty {
            return
        }
        for event in events {
            if case .permissionRequested(let req) = event, req.toolName == "HookCallback" {
                continue
            }
            runtime.eventSink(event)
        }
    }

    private func handleExit(_ runtime: Runtime) {
        let shouldEmit = queue.sync { () -> Bool in
            if runtime.didExit {
                return false
            }
            runtime.didExit = true
            return runtimes.removeValue(forKey: runtime.sessionID) != nil
        }
        if shouldEmit {
            try? runtime.stdin.close()
            Self.cleanupMCPScratchConfig(at: runtime.mcpScratch)
            runtime.eventSink(.exited(sessionID: runtime.sessionID))
        }
    }

    private static func consumeLines(_ data: inout Data) -> [String] {
        var lines: [String] = []
        while let range = data.firstRange(of: Data([0x0A])) {
            let lineData = data.subdata(in: data.startIndex ..< range.lowerBound)
            data.removeSubrange(data.startIndex ... range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .newlines))
            }
        }
        return lines
    }

    private static func removeArgumentPair(_ flag: String, from args: inout [String]) {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
            return
        }
        args.removeSubrange(index ... (index + 1))
    }

    static func buildLaunchArguments(_ configuration: ClaudeLaunchConfiguration) -> [String] {
        var args = configuration.prefixArgs
        args += [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages",
            "--strict-mcp-config"
        ]
        if let mcpConfigPath = configuration.mcpConfigPath {
            args += ["--mcp-config", mcpConfigPath]
        }
        if let resumeSessionID = configuration.resumeSessionID {
            args += ["--resume", resumeSessionID]
        }
        if let model = configuration.model, !model.isEmpty {
            args += ["--model", model]
        }
        args += ["--permission-mode", configuration.mode.permissionMode, "--permission-prompt-tool", "stdio"]
        args += ["--settings", configuration.thinkingLevel == .off ? "{\"alwaysThinkingEnabled\":false}" : "{\"alwaysThinkingEnabled\":true}"]
        if configuration.thinkingLevel != .off {
            args += ["--effort", configuration.thinkingLevel.rawValue]
        }
        if !configuration.capabilities.supportsPartialMessages {
            args.removeAll { $0 == "--include-partial-messages" }
        }
        if !configuration.capabilities.supportsThinkingEffort {
            removeArgumentPair("--settings", from: &args)
            removeArgumentPair("--effort", from: &args)
        }
        return args
    }

    private func resolveClaudeExecutable() -> (String, [String]) {
        if let executableOverride {
            return executableOverride
        }
        let candidates = [
            home.appendingPathComponent(".claude/local/claude").path,
            home.appendingPathComponent(".npm-global/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (hit, [])
        }
        if let which = Self.findExecutable("claude", in: baseEnvironment["PATH"]), !which.isEmpty {
            return (which, [])
        }
        if let which = Shell.capture("/usr/bin/env", ["which", "claude"]), !which.isEmpty {
            return (which, [])
        }
        return ("/usr/bin/env", ["claude"])
    }

    private func enrichedPath() -> String {
        let home = home.path
        var parts = [
            "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        if let existing = baseEnvironment["PATH"] {
            parts.append(existing)
        }
        return parts.joined(separator: ":")
    }

    private static func findExecutable(_ name: String, in path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func buildMCPScratchConfig(sessionID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let claude = home.appendingPathComponent(".claude.json")
        guard
            let data = try? Data(contentsOf: claude),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var servers = root["mcpServers"] else {
            return nil
        }
        if let outer = servers as? [String: Any], let inner = outer["mcpServers"] as? [String: Any] {
            servers = inner
        }
        guard let serverMap = servers as? [String: Any], !serverMap.isEmpty else {
            return nil
        }

        let dir = home.appendingPathComponent(".liquidcode", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let path = dir.appendingPathComponent("mcp-session-\(safeSessionIDForPath(sessionID)).json")
        let payload = ["mcpServers": serverMap]
        guard let out = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        do {
            try out.write(to: path, options: [.atomic])
            return path
        } catch {
            return nil
        }
    }

    static func cleanupMCPScratchConfig(sessionID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cleanupMCPScratchConfig(at: home.appendingPathComponent(".liquidcode/mcp-session-\(safeSessionIDForPath(sessionID)).json"))
    }

    static func cleanupMCPScratchConfig(at url: URL?) {
        guard let url else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    static func safeSessionIDForPath(_ id: String) -> String {
        String(id.map { ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")) ? $0 : "_" })
    }

    private static func isUUIDLike(_ value: String) -> Bool {
        value.count >= 32 && value.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private func parseJSONObject(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

enum ClaudeControlProtocol {
    static func rewindControlJSON(checkpointUUID: String) throws -> String {
        let payload: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "rewind_files", "checkpoint_uuid": checkpointUUID, "checkpointUuid": checkpointUUID]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func permissionResponseJSON(requestID: String, response: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": response]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum StreamEventParser {
    static func events(from obj: [String: Any], sessionID: String) -> [ClaudeEvent] {
        // `isMeta` records are companion noise (image sources, etc.) and never shown.
        // `isSidechain` records are a subagent's own internal transcript — we no longer
        // drop them, but they are handled specially below so they never reach the main
        // transcript's message/tool stores.
        if obj["isMeta"] as? Bool == true {
            return []
        }
        let type = obj["type"] as? String ?? ""
        // Claude Code wraps partial-message records in a `stream_event` envelope
        // (`{"type":"stream_event","event":{"type":"content_block_delta",...}}`) when
        // launched with --include-partial-messages. The block start/delta matchers key
        // off the top-level `type`, so without unwrapping they never see the inner
        // `content_block_*` events and tool-use input never streams — the whole tool
        // card only appears once the completed `.message` lands. (Assistant text streams
        // regardless only because `textDelta` recurses into the envelope by luck.) Lift
        // the inner event to the top level, preserving envelope keys it lacks, and reparse.
        if type == "stream_event", let inner = obj["event"] as? [String: Any] {
            var merged = inner
            for (key, value) in obj where key != "event" && key != "type" && merged[key] == nil {
                merged[key] = value
            }
            return events(from: merged, sessionID: sessionID)
        }
        // A subagent's internal record: surface it only as an agentID-tagged `.message`
        // so ChatRuntime routes it into the subagent bucket. We deliberately skip the
        // tool/stream events here so the subagent's internal tool calls never land in
        // the main transcript's tool store — they are reconstructed from these messages
        // by SubagentActivityBuilder instead.
        if obj["isSidechain"] as? Bool == true {
            guard let message = messageFromJSONObject(obj, fallbackID: UUID().uuidString) else {
                return []
            }
            return [.message(sessionID: sessionID, message)]
        }
        if type == "control_request" {
            return controlEvents(from: obj, sessionID: sessionID)
        }
        if
            type == "system",
            !(obj["subtype"] as? String == "local_command" && claudeControlTranscriptEvent(from: obj["content"]) != nil) {
            let cliSessionID = obj["session_id"] as? String ?? obj["sessionId"] as? String
            // The CLI's system-init line is the reliable signal that Claude Code has
            // received the request and is now working — distinct from the process merely
            // having spawned. `.cliReady` promotes the thinking indicator to its second phase.
            return [.sessionStarted(sessionID: sessionID, cliSessionID: cliSessionID), .cliReady(sessionID: sessionID)]
        }
        if type == "result" {
            return [.turnCompleted(sessionID: sessionID)]
        }
        var output: [ClaudeEvent] = []
        if let started = streamBlockStart(in: obj) {
            output.append(.streamBlockStarted(sessionID: sessionID, index: started.index, started.block))
        }
        if let delta = streamBlockDelta(in: obj), !delta.text.isEmpty {
            output.append(.streamBlockDelta(sessionID: sessionID, index: delta.index, kind: delta.kind, text: delta.text))
        } else if let delta = textDelta(in: obj), !delta.isEmpty {
            output.append(.textDelta(sessionID: sessionID, text: delta))
        }
        if let message = messageFromJSONObject(obj, fallbackID: UUID().uuidString) {
            output.append(.message(sessionID: sessionID, message))
        }
        if let tool = toolCall(in: obj, sessionID: sessionID) {
            output.append(.toolStarted(sessionID: sessionID, tool))
        }
        output.append(contentsOf: toolResults(in: obj, sessionID: sessionID).map { .toolUpdated(sessionID: sessionID, $0) })
        return output
    }

    static func messageFromJSONObject(_ obj: [String: Any], fallbackID: String) -> ChatMessage? {
        if obj["isMeta"] as? Bool == true {
            return nil
        }
        let type = obj["type"] as? String ?? ""
        guard isTranscriptMessageType(type, object: obj) else {
            return nil
        }
        let message = obj["message"] as? [String: Any]
        let roleRaw = message?["role"] as? String ?? obj["role"] as? String ?? type
        let rawRole = chatRole(from: roleRaw)
        let id = obj["uuid"] as? String ?? obj["id"] as? String ?? fallbackID
        let contentAny = message?["content"] ?? obj["content"]
        let raw = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])).map { String(data: $0, encoding: .utf8) ?? "" }
        let parentID = obj["parent_uuid"] as? String ?? obj["parentUuid"] as? String ?? obj["parent_id"] as? String ?? obj["parentId"] as? String
        // A subagent's internal records carry `agentId`; the field tags the message so
        // ChatRuntime can route it into the subagent bucket rather than the main transcript.
        let agentID = (obj["agentId"] as? String ?? obj["agent_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = SessionJSONLCodec.parseTimestamp(obj["timestamp"]) ?? Date()
        if let control = claudeControlTranscriptEvent(from: contentAny) {
            let role: ChatMessage.Role = control.kind == .taskFailure ? .error : .system
            // A task-notification carries the parent spawn block's toolUseID. We keep it
            // on the message (as `toolName`/block metadata) so ChatRuntime can intercept
            // it and merge the completion status into the SubagentActivity card instead of
            // rendering an orphan system/error bubble.
            let isTaskNotification = control.kind == .taskNotification || control.kind == .taskFailure
            return ChatMessage(
                id: id,
                role: role,
                content: control.body,
                timestamp: timestamp,
                toolName: control.title,
                rawJSON: raw,
                parentID: isTaskNotification ? (control.toolUseID ?? parentID) : parentID,
                checkpointUuid: nil,
                blocks: [ChatContentBlock(
                    kind: .text,
                    text: control.body,
                    toolUseID: isTaskNotification ? control.toolUseID : nil,
                    rawType: control.kind.rawValue
                )],
                agentID: isTaskNotification ? (control.taskID ?? agentID) : agentID
            )
        }
        if obj["isCompactSummary"] as? Bool == true {
            let rendered = renderMessageContent(contentAny)
            let summary = rendered.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                return nil
            }
            return ChatMessage(
                id: id,
                role: .system,
                content: summary,
                timestamp: timestamp,
                toolName: "Context summary",
                rawJSON: raw,
                parentID: parentID,
                checkpointUuid: nil,
                blocks: [ChatContentBlock(kind: .text, text: summary, rawType: "compact_summary")]
            )
        }
        let rendered = renderMessageContent(contentAny)
        let content = rendered.text
        let role = transcriptRole(rawRole: rawRole, content: content, rendered: rendered)
        let toolName = firstToolName(in: contentAny)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, toolName == nil, rendered.images.isEmpty, rendered.blocks.isEmpty {
            return nil
        }
        let checkpoint = (role == .user && !containsToolResult(contentAny)) ? id : nil
        // Assistant records carry `message.model` (e.g. "claude-sonnet-4-6"). Capture it so
        // the GUI can re-align the composer picker when a session was continued from CLI.
        let reportedModel = (message?["model"] as? String ?? obj["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (reportedModel?.isEmpty == false && reportedModel != "<synthetic>") ? reportedModel : nil
        return ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            toolName: toolName,
            rawJSON: raw,
            parentID: parentID,
            checkpointUuid: checkpoint,
            images: rendered.images,
            blocks: rendered.blocks,
            agentID: agentID,
            model: model
        )
    }

    private static func isTranscriptMessageType(_ type: String, object: [String: Any]) -> Bool {
        if type == "assistant" || type == "user" || type == "human" || type == "tool" {
            return true
        }
        if
            type == "system",
            object["subtype"] as? String == "local_command",
            claudeControlTranscriptEvent(from: object["content"]) != nil {
            return true
        }
        guard type.isEmpty else {
            return false
        }
        if object["message"] != nil {
            return true
        }
        if let role = object["role"] as? String {
            return role == "assistant" || role == "user" || role == "human" || role == "tool"
        }
        return false
    }

    private static func firstToolName(in value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if dict["type"] as? String == "tool_use" {
                return dict["name"] as? String ?? "Tool"
            }
            if dict["type"] as? String == "tool_result" {
                return "tool_result"
            }
            for child in dict.values {
                if let found = firstToolName(in: child) {
                    return found
                } }
        }
        if let arr = value as? [Any] {
            for child in arr {
                if let found = firstToolName(in: child) {
                    return found
                } }
        }
        return nil
    }

    private static func containsToolResult(_ value: Any?) -> Bool {
        if let dict = value as? [String: Any] {
            if dict["type"] as? String == "tool_result" {
                return true
            }
            return dict.values.contains { containsToolResult($0) }
        }
        if let arr = value as? [Any] {
            return arr.contains { containsToolResult($0) }
        }
        return false
    }

    private static func chatRole(from raw: String) -> ChatMessage.Role {
        switch raw {
        case "user", "human":
            return .user
        case "system":
            return .system
        case "tool":
            return .tool
        default:
            return .assistant
        }
    }

    private static func transcriptRole(
        rawRole: ChatMessage.Role,
        content: String,
        rendered: RenderedMessageContent
    ) -> ChatMessage.Role {
        if rawRole == .assistant, isProviderErrorTranscript(content) {
            return .error
        }
        if rawRole == .user, isToolOnlyTranscript(rendered) {
            return .tool
        }
        return rawRole
    }

    private static func isToolOnlyTranscript(_ rendered: RenderedMessageContent) -> Bool {
        guard !rendered.blocks.isEmpty, rendered.images.isEmpty else {
            return false
        }
        guard rendered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return rendered.blocks.allSatisfy { $0.kind == .toolResult }
    }

    private static func isProviderErrorTranscript(_ content: String) -> Bool {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = firstLine.lowercased()
        let fullLower = content.lowercased()
        return lower.hasPrefix("api error") ||
            lower.hasPrefix("provider error") ||
            lower.hasPrefix("anthropic error") ||
            lower.hasPrefix("openai error") ||
            fullLower.contains("type=new_api_error") ||
            fullLower.contains("overloaded_error") ||
            fullLower.contains("rate_limit_error") ||
            fullLower.contains("authentication_error") ||
            fullLower.contains("invalid token")
    }

    private static func controlEvents(from obj: [String: Any], sessionID: String) -> [ClaudeEvent] {
        let requestID = obj["request_id"] as? String ?? obj["requestId"] as? String ?? UUID().uuidString
        guard let req = obj["request"] as? [String: Any] else {
            return []
        }
        let subtype = req["subtype"] as? String ?? ""
        if subtype == "hook_callback" {
            return []
        }
        if subtype == "oauth_token_refresh" {
            return [.permissionRequested(PermissionRequest(
                id: requestID,
                sessionID: sessionID,
                requestID: requestID,
                toolName: "OAuth token refresh",
                title: "Claude wants to refresh OAuth",
                summary: "Denied by default for provider safety.",
                inputJSON: "{}",
                toolUseID: nil,
                parentToolUseID: nil,
                agentID: nil,
                risk: .network
            ))]
        }
        let rawToolName = req["tool_name"] as? String ?? req["toolName"] as? String ?? subtype
        let input = req["input"] ?? [:]
        let inputJSON = jsonString(input)
        let toolName = displayToolName(rawToolName: rawToolName, input: input)
        let risk = classify(toolName: toolName, inputJSON: inputJSON)
        let title = toolName == "AskUserQuestion" ? "Claude asks a question" : "Claude wants to use \(toolName)"
        let summary = req["description"] as? String ?? inputJSON
        let perm = PermissionRequest(
            id: requestID,
            sessionID: sessionID,
            requestID: requestID,
            toolName: toolName,
            title: title,
            summary: summary,
            inputJSON: inputJSON,
            toolUseID: req["tool_use_id"] as? String ?? req["toolUseId"] as? String,
            parentToolUseID: req["parent_tool_use_id"] as? String ?? req["parentToolUseId"] as? String,
            agentID: req["agent_id"] as? String ?? req["agentId"] as? String,
            risk: risk
        )
        return [.permissionRequested(perm)]
    }

    private static func displayToolName(rawToolName: String, input: Any) -> String {
        guard
            SubagentSpawnParser.isSpawnTool(rawToolName),
            let object = input as? [String: Any],
            let subagentName = object["subagent_type"] as? String
        else {
            return rawToolName
        }
        let clean = subagentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? rawToolName : clean
    }

    private static func classify(toolName: String, inputJSON: String) -> PermissionRequest.Risk {
        let lower = (toolName + " " + inputJSON).lowercased()
        if
            lower.contains("rm ") || lower.contains("sudo") || lower.contains("chmod") || lower.contains("chown") || lower.contains("curl") && lower
                .contains("| sh") {
            return .destructive
        }
        if toolName == "Bash" {
            return .shell
        }
        if toolName == "Edit" || toolName == "Write" || lower.contains("write") || lower.contains("delete") {
            return .write
        }
        if lower.contains("http") || lower.contains("browser") || lower.contains("fetch") {
            return .network
        }
        if toolName.lowercased().contains("mcp") {
            return .externalMcp
        }
        return .readOnly
    }

    private static func textDelta(in obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            if dict["type"] as? String == "content_block_delta", let delta = dict["delta"] as? [String: Any] {
                return delta["text"] as? String ?? delta["thinking"] as? String
            }
            if dict["type"] as? String == "text_delta" {
                return dict["text"] as? String
            }
            for value in dict.values {
                if let found = textDelta(in: value) {
                    return found
                } }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if let found = textDelta(in: value) {
                    return found
                } }
        }
        return nil
    }

    private struct StreamingBlockStart {
        var index: Int?
        var block: ChatContentBlock
    }

    private struct StreamingBlockDelta {
        var index: Int?
        var kind: ChatContentBlockKind
        var text: String
    }

    private static func streamBlockStart(in obj: [String: Any]) -> StreamingBlockStart? {
        let type = obj["type"] as? String ?? ""
        guard type == "content_block_start" || type == "agent.tool_use" || type == "agent.thinking" || type == "agent.message" else {
            return nil
        }
        let index = obj["index"] as? Int ?? obj["content_block_index"] as? Int ?? obj["contentBlockIndex"] as? Int
        if
            let contentBlock = obj["content_block"] as? [String: Any] ?? obj["contentBlock"] as? [String: Any],
            let block = streamingChatContentBlock(from: contentBlock) {
            return StreamingBlockStart(index: index, block: block)
        }
        if type == "agent.thinking" {
            return StreamingBlockStart(index: index, block: ChatContentBlock(kind: .thinking, text: obj["thinking"] as? String ?? obj["text"] as? String ?? ""))
        }
        if type == "agent.message" {
            return StreamingBlockStart(index: index, block: ChatContentBlock(kind: .text, text: obj["text"] as? String ?? ""))
        }
        if type == "agent.tool_use" {
            let id = obj["id"] as? String ?? obj["tool_use_id"] as? String ?? obj["toolUseId"] as? String ?? UUID().uuidString
            let name = obj["name"] as? String ?? obj["tool_name"] as? String ?? obj["toolName"] as? String ?? "Tool"
            return StreamingBlockStart(index: index, block: ChatContentBlock(
                id: id,
                kind: .toolUse,
                toolUseID: id,
                toolName: name,
                inputJSON: streamingToolInputJSON(from: obj["input"]),
                rawType: type,
                rawJSON: jsonString(obj)
            ))
        }
        return nil
    }

    private static func streamBlockDelta(in obj: [String: Any]) -> StreamingBlockDelta? {
        let type = obj["type"] as? String ?? ""
        let index = obj["index"] as? Int ?? obj["content_block_index"] as? Int ?? obj["contentBlockIndex"] as? Int
        if type == "content_block_delta", let delta = obj["delta"] as? [String: Any] {
            if let text = delta["text"] as? String {
                return StreamingBlockDelta(index: index, kind: .text, text: text)
            }
            if let thinking = delta["thinking"] as? String {
                return StreamingBlockDelta(index: index, kind: .thinking, text: thinking)
            }
            if let partialJSON = delta["partial_json"] as? String ?? delta["partialJson"] as? String {
                return StreamingBlockDelta(index: index, kind: .toolUse, text: partialJSON)
            }
            if let content = delta["content"] as? String {
                return StreamingBlockDelta(index: index, kind: .toolResult, text: content)
            }
        }
        if type == "text_delta", let text = obj["text"] as? String {
            return StreamingBlockDelta(index: index, kind: .text, text: text)
        }
        if type == "thinking_delta", let thinking = obj["thinking"] as? String ?? obj["text"] as? String {
            return StreamingBlockDelta(index: index, kind: .thinking, text: thinking)
        }
        if type == "input_json_delta", let partialJSON = obj["partial_json"] as? String ?? obj["partialJson"] as? String {
            return StreamingBlockDelta(index: index, kind: .toolUse, text: partialJSON)
        }
        return nil
    }

    private static func toolCall(in obj: [String: Any], sessionID: String) -> ToolCall? {
        let items = contentBlocks(in: obj)
        for item in items where item["type"] as? String == "tool_use" {
            let id = item["id"] as? String ?? UUID().uuidString
            let name = item["name"] as? String ?? "Tool"
            return ToolCall(id: id, sessionID: sessionID, name: name, inputPreview: jsonString(item["input"] ?? [:]), status: .running)
        }
        return nil
    }

    private static func toolResults(in obj: [String: Any], sessionID: String) -> [ToolCall] {
        let items = contentBlocks(in: obj)
        return items.compactMap { item -> ToolCall? in
            guard item["type"] as? String == "tool_result" else {
                return nil
            }
            let id = item["tool_use_id"] as? String ?? item["toolUseId"] as? String ?? item["id"] as? String ?? UUID().uuidString
            let isError = item["is_error"] as? Bool ?? item["isError"] as? Bool ?? false
            var tool = ToolCall(
                id: id,
                sessionID: sessionID,
                name: "Tool",
                inputPreview: "",
                resultPreview: renderContent(item["content"]),
                status: isError ? .failed : .succeeded
            )
            tool.completedAt = Date()
            return tool
        }
    }

    private static func contentBlocks(in obj: [String: Any]) -> [[String: Any]] {
        if let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            return content
        }
        if let content = obj["content"] as? [[String: Any]] {
            return content
        }
        if let block = obj["content_block"] as? [String: Any] {
            return [block]
        }
        if let block = obj["contentBlock"] as? [String: Any] {
            return [block]
        }
        if let type = obj["type"] as? String, type == "tool_use" || type == "tool_result" {
            return [obj]
        }
        return []
    }

    private static func renderContent(_ value: Any?) -> String {
        renderMessageContent(value).text
    }

    private struct RenderedMessageContent {
        var text: String
        var images: [MessageImageReference]
        var blocks: [ChatContentBlock]
    }

    private static func renderMessageContent(_ value: Any?) -> RenderedMessageContent {
        if let text = value as? String {
            let cleaned = cleanedTextAndInlineImages(from: text)
            var blocks: [ChatContentBlock] = []
            if !cleaned.text.isEmpty {
                blocks.append(ChatContentBlock(kind: .text, text: cleaned.text))
            }
            blocks.append(contentsOf: cleaned.images.map { ChatContentBlock(kind: .image, image: $0) })
            return RenderedMessageContent(text: cleaned.text, images: cleaned.images, blocks: blocks)
        }
        var images: [MessageImageReference] = []
        var blocks: [ChatContentBlock] = []
        var textSegments: [String] = []
        if let arr = value as? [[String: Any]] {
            for item in arr {
                let type = item["type"] as? String ?? ""
                if type == "text" {
                    if let text = item["text"] as? String {
                        let cleaned = cleanedTextAndInlineImages(from: text)
                        images.append(contentsOf: cleaned.images)
                        if !cleaned.text.isEmpty {
                            textSegments.append(cleaned.text)
                            blocks.append(ChatContentBlock(
                                id: item["id"] as? String ?? UUID().uuidString,
                                kind: .text,
                                text: cleaned.text,
                                rawType: type,
                                rawJSON: jsonString(item)
                            ))
                        }
                        blocks.append(contentsOf: cleaned.images.map { ChatContentBlock(kind: .image, image: $0, rawType: "image") })
                    }
                    continue
                } else if type == "thinking" {
                    let thinking = item["thinking"] as? String ?? item["text"] as? String ?? ""
                    if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(ChatContentBlock(
                            id: item["id"] as? String ?? UUID().uuidString,
                            kind: .thinking,
                            text: thinking,
                            rawType: type,
                            rawJSON: jsonString(item)
                        ))
                    }
                    continue
                } else if type == "image" {
                    if let image = MessageImageReference.fromContentBlock(item) {
                        images.append(image)
                        blocks.append(ChatContentBlock(
                            id: item["id"] as? String ?? image.id,
                            kind: .image,
                            image: image,
                            rawType: type,
                            rawJSON: jsonString(item)
                        ))
                    }
                    continue
                } else if type == "tool_use" {
                    let id = item["id"] as? String ?? UUID().uuidString
                    let name = item["name"] as? String ?? "Tool"
                    blocks.append(ChatContentBlock(
                        id: id,
                        kind: .toolUse,
                        toolUseID: id,
                        toolName: name,
                        inputJSON: jsonString(item["input"] ?? [:]),
                        rawType: type,
                        rawJSON: jsonString(item)
                    ))
                    continue
                } else if type == "tool_result" {
                    let toolUseID = item["tool_use_id"] as? String ?? item["toolUseId"] as? String ?? item["id"] as? String
                    let resultText = renderContent(item["content"])
                    blocks.append(ChatContentBlock(
                        id: toolUseID ?? UUID().uuidString,
                        kind: .toolResult,
                        text: resultText,
                        toolUseID: toolUseID,
                        isError: item["is_error"] as? Bool ?? item["isError"] as? Bool ?? false,
                        rawType: type,
                        rawJSON: jsonString(item)
                    ))
                    continue
                }
            }
            let text = textSegments
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return RenderedMessageContent(text: text, images: deduplicatedImages(images), blocks: blocks)
        }
        if let value {
            let text = jsonString(value)
            return RenderedMessageContent(
                text: text,
                images: [],
                blocks: [ChatContentBlock(kind: .unknown, text: text, rawJSON: text)]
            )
        }
        return RenderedMessageContent(text: "", images: [], blocks: [])
    }

    private static func streamingChatContentBlock(from item: [String: Any]) -> ChatContentBlock? {
        guard (item["type"] as? String ?? "") == "tool_use" else {
            return chatContentBlock(from: item)
        }
        let id = item["id"] as? String ?? UUID().uuidString
        let name = item["name"] as? String ?? "Tool"
        return ChatContentBlock(
            id: id,
            kind: .toolUse,
            toolUseID: id,
            toolName: name,
            inputJSON: streamingToolInputJSON(from: item["input"]),
            rawType: "tool_use",
            rawJSON: jsonString(item)
        )
    }

    private static func streamingToolInputJSON(from value: Any?) -> String {
        guard let value else {
            return ""
        }
        if let input = value as? [String: Any], input.isEmpty {
            return ""
        }
        return jsonString(value)
    }

    private static func chatContentBlock(from item: [String: Any]) -> ChatContentBlock? {
        let type = item["type"] as? String ?? ""
        if type == "text" {
            let text = item["text"] as? String ?? ""
            return ChatContentBlock(
                id: item["id"] as? String ?? UUID().uuidString,
                kind: .text,
                text: text,
                rawType: type,
                rawJSON: jsonString(item)
            )
        }
        if type == "thinking" {
            let thinking = item["thinking"] as? String ?? item["text"] as? String ?? ""
            return ChatContentBlock(
                id: item["id"] as? String ?? UUID().uuidString,
                kind: .thinking,
                text: thinking,
                rawType: type,
                rawJSON: jsonString(item)
            )
        }
        if type == "image", let image = MessageImageReference.fromContentBlock(item) {
            return ChatContentBlock(
                id: item["id"] as? String ?? image.id,
                kind: .image,
                image: image,
                rawType: type,
                rawJSON: jsonString(item)
            )
        }
        if type == "tool_use" {
            let id = item["id"] as? String ?? UUID().uuidString
            let name = item["name"] as? String ?? "Tool"
            return ChatContentBlock(
                id: id,
                kind: .toolUse,
                toolUseID: id,
                toolName: name,
                inputJSON: jsonString(item["input"] ?? [:]),
                rawType: type,
                rawJSON: jsonString(item)
            )
        }
        if type == "tool_result" {
            let toolUseID = item["tool_use_id"] as? String ?? item["toolUseId"] as? String ?? item["id"] as? String
            return ChatContentBlock(
                id: toolUseID ?? UUID().uuidString,
                kind: .toolResult,
                text: renderContent(item["content"]),
                toolUseID: toolUseID,
                isError: item["is_error"] as? Bool ?? item["isError"] as? Bool ?? false,
                rawType: type,
                rawJSON: jsonString(item)
            )
        }
        return nil
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct ProviderRuntimeCapabilities: Equatable, Sendable {
    var isNativeAnthropic: Bool
    var supportsPartialMessages: Bool
    var supportsThinkingEffort: Bool
    static let nativeAnthropic = ProviderRuntimeCapabilities(isNativeAnthropic: true, supportsPartialMessages: true, supportsThinkingEffort: true)
}

struct ClaudeEnvironmentPlan: Equatable, Sendable {
    var environment: [String: String]
    var removedKeys: [String]
    var extraArgs: [String]
    var capabilities: ProviderRuntimeCapabilities
}

enum ClaudeChildEnvironmentBuilder {
    /// Claude Code tags every transcript record with `entrypoint`. Interactive `/resume`
    /// deliberately hides sessions whose entrypoint is in `{sdk-cli, sdk-ts, sdk-py}`
    /// (see Claude 2.1.x `uTr` / `jPi`). LiquidCode launches with `--input-format stream-json`,
    /// which Claude treats as non-interactive and would auto-stamp `sdk-cli` when the env
    /// var is unset — making GUI chats invisible in the terminal resume picker. Force a
    /// desktop entrypoint that is accepted by Claude and NOT in that filter set.
    static let transcriptEntrypoint = "claude-desktop"

    static let envRemoveList = [
        "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDECODE", "CLAUDE_CODE_ENTRY", "ANTHROPIC_MODEL", "ANTHROPIC_BASE_URL"
    ]
    static let nonNativeRemoveList = [
        "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_ENTRYPOINT"
    ]
    private static let partialOverrideKey = "LIQUIDCODE_INCLUDE_PARTIAL_MESSAGES"

    static func buildNative(base: [String: String], enrichedPath: String) -> ClaudeEnvironmentPlan {
        build(base: base, provider: nil, apiKey: nil, thinkingLevel: .high, enrichedPath: enrichedPath)
    }

    static func build(base: [String: String], provider: ProviderRecord?, apiKey: String?, thinkingLevel: ThinkingLevel, enrichedPath: String) -> ClaudeEnvironmentPlan {
        var env = base
        var removed = envRemoveList
        for key in envRemoveList {
            env.removeValue(forKey: key)
        }
        env["PATH"] = enrichedPath
        let isNative = provider.map(isNativeAnthropic) ?? true
        let capabilities = provider.map { capabilities(for: $0, isNative: isNative) } ?? .nativeAnthropic

        if let provider {
            if !isNative {
                for key in nonNativeRemoveList {
                    env.removeValue(forKey: key)
                }
                removed += nonNativeRemoveList
                env["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] = env["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] ?? "1"
            }
            if !provider.baseURL.isEmpty {
                switch provider.apiFormat {
                case .anthropic: env["ANTHROPIC_BASE_URL"] = provider.baseURL
                case .openai: env["OPENAI_BASE_URL"] = provider.baseURL
                }
            }
            if let apiKey, !apiKey.isEmpty {
                switch provider.apiFormat {
                case .anthropic: env["ANTHROPIC_API_KEY"] = apiKey
                case .openai: env["OPENAI_API_KEY"] = apiKey
                }
            }
            for (key, value) in provider.extraEnv where key != partialOverrideKey {
                if value.isEmpty {
                    env.removeValue(forKey: key); removed.append(key)
                } else {
                    env[key] = value
                }
            }
            if let proxy = provider.proxyURL, !proxy.isEmpty {
                inject(proxy: proxy, into: &env)
            }
        }

        if capabilities.isNativeAnthropic {
            env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] ?? "64000"
            env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
            if thinkingLevel == .off {
                env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
            } else {
                env["CLAUDE_CODE_EFFORT_LEVEL"] = thinkingLevel.rawValue
            }
        } else {
            env.removeValue(forKey: "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING")
            env.removeValue(forKey: "CLAUDE_CODE_MAX_OUTPUT_TOKENS")
            env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
        }
        // Always last: survive host env strips and provider extraEnv overrides that might
        // try to reintroduce an SDK entrypoint and hide the session from CLI /resume.
        env["CLAUDE_CODE_ENTRYPOINT"] = transcriptEntrypoint
        removed = Array(Set(removed)).sorted()
        return ClaudeEnvironmentPlan(environment: env, removedKeys: removed, extraArgs: [], capabilities: capabilities)
    }

    private static func isNativeAnthropic(_ provider: ProviderRecord) -> Bool {
        provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || provider.baseURL.lowercased().contains("api.anthropic.com")
    }

    private static func capabilities(for provider: ProviderRecord, isNative: Bool) -> ProviderRuntimeCapabilities {
        if isNative {
            return .nativeAnthropic
        }
        let override = provider.extraEnv[partialOverrideKey].flatMap(parseBoolOverride)
        return ProviderRuntimeCapabilities(
            isNativeAnthropic: false,
            supportsPartialMessages: override ?? (provider.apiFormat == .anthropic),
            supportsThinkingEffort: provider.apiFormat == .anthropic
        )
    }

    private static func parseBoolOverride(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1",
             "true",
             "yes",
             "on": return true
        case "0",
             "false",
             "no",
             "off": return false
        default: return nil
        }
    }

    private static func inject(proxy: String, into env: inout [String: String]) {
        for key in ["https_proxy", "http_proxy", "HTTPS_PROXY", "HTTP_PROXY"] {
            env[key] = proxy
        }
        if proxy.lowercased().hasPrefix("socks") {
            env["all_proxy"] = proxy; env["ALL_PROXY"] = proxy
        }
    }
}
