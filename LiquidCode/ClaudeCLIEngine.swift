import Foundation

protocol ClaudeEngine: Sendable {
    func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws
    func sendMessage(sessionID: String, text: String) throws
    func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String?
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
        if !request.prompt.isEmpty {
            try sendUserJSON(sessionID: request.sessionID, text: request.prompt)
        }
    }

    func sendMessage(sessionID: String, text: String) throws {
        try sendUserJSON(sessionID: sessionID, text: text)
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

    private func sendUserJSON(sessionID: String, text: String) throws {
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
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

        let dir = home.appendingPathComponent(".tokenicode", isDirectory: true)
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
        cleanupMCPScratchConfig(at: home.appendingPathComponent(".tokenicode/mcp-session-\(safeSessionIDForPath(sessionID)).json"))
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
        let type = obj["type"] as? String ?? ""
        if type == "control_request" {
            return controlEvents(from: obj, sessionID: sessionID)
        }
        if type == "system" {
            let cliSessionID = obj["session_id"] as? String ?? obj["sessionId"] as? String
            return [.sessionStarted(sessionID: sessionID, cliSessionID: cliSessionID)]
        }
        if type == "result" {
            return [.turnCompleted(sessionID: sessionID)]
        }
        if type == "assistant" || type == "user" || type == "human" {
            if let message = messageFromJSONObject(obj, fallbackID: UUID().uuidString) {
                return [.message(sessionID: sessionID, message)]
            }
        }
        if let delta = textDelta(in: obj), !delta.isEmpty {
            return [.textDelta(sessionID: sessionID, text: delta)]
        }
        if let tool = toolCall(in: obj, sessionID: sessionID) {
            return [.toolStarted(sessionID: sessionID, tool)]
        }
        return []
    }

    static func messageFromJSONObject(_ obj: [String: Any], fallbackID: String) -> ChatMessage? {
        let type = obj["type"] as? String ?? ""
        let message = obj["message"] as? [String: Any]
        let roleRaw = message?["role"] as? String ?? obj["role"] as? String ?? type
        let role: ChatMessage.Role = (roleRaw == "user" || roleRaw == "human") ? .user : roleRaw == "system" ? .system : roleRaw == "tool" ? .tool : .assistant
        let id = obj["uuid"] as? String ?? obj["id"] as? String ?? fallbackID
        let contentAny = message?["content"] ?? obj["content"]
        let content = renderContent(contentAny)
        let toolName = firstToolName(in: contentAny)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, toolName == nil {
            return nil
        }
        let raw = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])).map { String(data: $0, encoding: .utf8) ?? "" }
        let checkpoint = (role == .user && !containsToolResult(contentAny)) ? id : nil
        let parentID = obj["parent_uuid"] as? String ?? obj["parentUuid"] as? String ?? obj["parent_id"] as? String ?? obj["parentId"] as? String
        return ChatMessage(id: id, role: role, content: content, timestamp: Date(), toolName: toolName, rawJSON: raw, parentID: parentID, checkpointUuid: checkpoint)
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
        let toolName = req["tool_name"] as? String ?? req["toolName"] as? String ?? subtype
        let input = req["input"] ?? [:]
        let inputJSON = jsonString(input)
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

    private static func toolCall(in obj: [String: Any], sessionID: String) -> ToolCall? {
        let content = (obj["message"] as? [String: Any])?["content"] ?? obj["content"]
        guard let items = content as? [[String: Any]] else {
            return nil
        }
        for item in items where item["type"] as? String == "tool_use" {
            let id = item["id"] as? String ?? UUID().uuidString
            let name = item["name"] as? String ?? "Tool"
            return ToolCall(id: id, sessionID: sessionID, name: name, inputPreview: jsonString(item["input"] ?? [:]), status: .running)
        }
        return nil
    }

    private static func renderContent(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { item in
                let type = item["type"] as? String ?? ""
                if type == "text" {
                    return item["text"] as? String
                }
                if type == "thinking" {
                    return item["thinking"] as? String
                }
                if type == "tool_use" {
                    return "[tool_use: \(item["name"] as? String ?? "Tool")]\n\(jsonString(item["input"] ?? [:]))"
                }
                if type == "tool_result" {
                    return "[tool_result]\n\(renderContent(item["content"]))"
                }
                return nil
            }
            .joined(separator: "\n")
        }
        if let value {
            return jsonString(value)
        }
        return ""
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
    private static let partialOverrideKey = "TOKENICODE_INCLUDE_PARTIAL_MESSAGES"

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
            env["CLAUDE_CODE_EFFORT_LEVEL"] = thinkingLevel.rawValue
        } else {
            env.removeValue(forKey: "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING")
            env.removeValue(forKey: "CLAUDE_CODE_MAX_OUTPUT_TOKENS")
            env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
        }
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
