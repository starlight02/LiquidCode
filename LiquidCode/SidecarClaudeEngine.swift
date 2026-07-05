import Foundation

final class HybridClaudeEngine: ClaudeEngine, @unchecked Sendable {
    private enum Backend { case primary, fallback }

    private let primary: ClaudeEngine
    private let fallback: ClaudeEngine
    private let queue = DispatchQueue(label: "LiquidCode.HybridClaudeEngine")
    private var backendBySession: [String: Backend] = [:]

    init(primary: ClaudeEngine, fallback: ClaudeEngine) {
        self.primary = primary
        self.fallback = fallback
    }

    func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
        do {
            try primary.startSession(request, eventSink: eventSink)
            queue.sync { backendBySession[request.sessionID] = .primary }
        } catch {
            primary.kill(sessionID: request.sessionID)
            try fallback.startSession(request, eventSink: eventSink)
            queue.sync { backendBySession[request.sessionID] = .fallback }
            eventSink(.stderr(sessionID: request.sessionID, "Sidecar unavailable; using direct Claude CLI fallback: \(error.localizedDescription)"))
        }
    }

    func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {
        try backend(for: sessionID).sendMessage(sessionID: sessionID, content: content)
    }

    func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? {
        try backend(for: sessionID).rewindFiles(sessionID: sessionID, cliSessionID: cliSessionID, checkpointUUID: checkpointUUID, cwd: cwd)
    }

    func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {
        try backend(for: sessionID).updateRuntimeConfiguration(sessionID: sessionID, model: model, mode: mode, thinkingLevel: thinkingLevel)
    }

    func isSessionRunning(sessionID: String) -> Bool {
        primary.isSessionRunning(sessionID: sessionID) || fallback.isSessionRunning(sessionID: sessionID)
    }

    func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {
        try backend(for: permission.sessionID).respondPermission(permission, allow: allow, updatedInputJSON: updatedInputJSON, message: message)
    }

    func interrupt(sessionID: String) throws {
        try backend(for: sessionID).interrupt(sessionID: sessionID)
    }

    func kill(sessionID: String) {
        primary.kill(sessionID: sessionID)
        fallback.kill(sessionID: sessionID)
        queue.sync { _ = backendBySession.removeValue(forKey: sessionID) }
    }

    func killAll() {
        primary.killAll()
        fallback.killAll()
        queue.sync { backendBySession.removeAll() }
    }

    private func backend(for sessionID: String) -> ClaudeEngine {
        let stored = queue.sync { backendBySession[sessionID] }
        switch stored {
        case .primary: return primary
        case .fallback: return fallback
        case nil:
            if primary.isSessionRunning(sessionID: sessionID) { return primary }
            return fallback
        }
    }
}

enum ClaudeEngineFactory {
    static func makeDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeEngine {
        let fallback = ClaudeCLIEngine(environment: environment)
        guard
            environment["LIQUIDCODE_DISABLE_SIDECAR"] != "1",
            SidecarClaudeEngine.locateSidecarScript() != nil,
            SidecarClaudeEngine.nodeIsAvailable(environment: environment) else {
            return fallback
        }
        return HybridClaudeEngine(primary: SidecarClaudeEngine(environment: environment), fallback: fallback)
    }
}

final class SidecarClaudeEngine: ClaudeEngine, @unchecked Sendable {
    private final class Runtime: @unchecked Sendable {
        let sessionID: String
        let eventSink: @Sendable (ClaudeEvent) -> Void
        let mcpScratch: URL?
        init(sessionID: String, eventSink: @escaping @Sendable (ClaudeEvent) -> Void, mcpScratch: URL?) {
            self.sessionID = sessionID
            self.eventSink = eventSink
            self.mcpScratch = mcpScratch
        }
    }

    private final class PendingRPC: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error>?
    }

    private let home: URL
    private let baseEnvironment: [String: String]
    private let sidecarScript: URL
    private let queue = DispatchQueue(label: "LiquidCode.SidecarClaudeEngine")
    private let directFallback: ClaudeCLIEngine

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var initialized = false
    private var pending: [String: PendingRPC] = [:]
    private var runtimes: [String: Runtime] = [:]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sidecarScript: URL? = nil
    ) {
        self.home = home
        baseEnvironment = environment
        self.sidecarScript = sidecarScript ?? Self.locateSidecarScript() ?? URL(fileURLWithPath: "LiquidCode/Resources/cc-agentd.mjs")
        directFallback = ClaudeCLIEngine(home: home, environment: environment)
    }

    static func locateSidecarScript() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "cc-agentd", withExtension: "mjs"),
            Bundle.main.resourceURL?.appendingPathComponent("cc-agentd.mjs"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/cc-agentd.mjs"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("LiquidCode/Resources/cc-agentd.mjs"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/cc-agentd.mjs")
        ]
        return candidates.compactMap { $0 }.first { fm.isReadableFile(atPath: $0.path) }
    }

    static func nodeIsAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        resolveNodeExecutable(home: FileManager.default.homeDirectoryForCurrentUser.path, base: environment) != nil
    }

    func startSession(_ request: ClaudeSessionStartRequest, eventSink: @escaping @Sendable (ClaudeEvent) -> Void) throws {
        kill(sessionID: request.sessionID)
        let scratch = ClaudeCLIEngine.buildMCPScratchConfig(sessionID: request.sessionID, home: home)
        let envPlan = ClaudeChildEnvironmentBuilder.build(
            base: baseEnvironment,
            provider: request.provider,
            apiKey: request.providerAPIKey,
            thinkingLevel: request.thinkingLevel,
            enrichedPath: enrichedPath()
        )
        var args = ClaudeCLIEngine.buildLaunchArguments(.init(
            mcpConfigPath: scratch?.path,
            resumeSessionID: request.resumeSessionID,
            model: request.model,
            mode: request.mode,
            thinkingLevel: request.thinkingLevel,
            capabilities: envPlan.capabilities
        ))
        args += envPlan.extraArgs

        var params: [String: Any] = [
            "sessionId": request.sessionID,
            "projectPath": request.cwd,
            "args": args,
            "environment": envPlan.environment,
            "executablePath": resolveClaudeExecutable(),
            "permissionMode": request.mode.permissionMode,
            "thinkingLevel": request.thinkingLevel.rawValue,
            "includePartialMessages": envPlan.capabilities.supportsPartialMessages,
            "enableFileCheckpointing": envPlan.capabilities.isNativeAnthropic,
            "preferSDK": true,
            "initialMessage": ["content": try request.userMessageContent.jsonContent()]
        ]
        if let scratchPath = scratch?.path {
            params["mcpConfigPath"] = scratchPath
        }
        if let resumeSessionID = request.resumeSessionID, !resumeSessionID.isEmpty {
            params["resumeSessionID"] = resumeSessionID
        }
        if let model = request.model, !model.isEmpty {
            params["model"] = model
        }

        queue.sync { runtimes[request.sessionID] = Runtime(sessionID: request.sessionID, eventSink: eventSink, mcpScratch: scratch) }
        do {
            _ = try rpc(method: "session.start", params: params)
            eventSink(.sessionStarted(sessionID: request.sessionID, cliSessionID: request.resumeSessionID))
        } catch {
            queue.sync { _ = runtimes.removeValue(forKey: request.sessionID) }
            ClaudeCLIEngine.cleanupMCPScratchConfig(at: scratch)
            throw error
        }
    }

    func sendMessage(sessionID: String, content: ClaudeUserMessageContent) throws {
        _ = try rpc(method: "session.send", params: ["sessionId": sessionID, "message": ["role": "user", "content": try content.jsonContent()]])
    }

    func rewindFiles(sessionID: String, cliSessionID: String?, checkpointUUID: String, cwd: String) throws -> String? {
        if isSessionRunning(sessionID: sessionID) {
            let json = try ClaudeControlProtocol.rewindControlJSON(checkpointUUID: checkpointUUID)
            let payload = try parseJSONObject(json) as? [String: Any] ?? [:]
            _ = try rpc(method: "session.control", params: ["sessionId": sessionID, "payload": payload])
            return nil
        }
        return try directFallback.rewindFiles(sessionID: sessionID, cliSessionID: cliSessionID, checkpointUUID: checkpointUUID, cwd: cwd)
    }

    func updateRuntimeConfiguration(sessionID: String, model: String?, mode: SessionMode?, thinkingLevel: ThinkingLevel?) throws {
        if !isSessionRunning(sessionID: sessionID) {
            try directFallback.updateRuntimeConfiguration(sessionID: sessionID, model: model, mode: mode, thinkingLevel: thinkingLevel)
            return
        }
        if let mode {
            _ = try rpc(method: "session.setPermissionMode", params: ["sessionId": sessionID, "mode": mode.permissionMode])
        }
        if let model, !model.isEmpty {
            _ = try rpc(method: "session.setModel", params: ["sessionId": sessionID, "model": cliModelName(model)])
        }
        if let thinkingLevel {
            _ = try rpc(method: "session.setThinkingLevel", params: [
                "sessionId": sessionID,
                "thinkingLevel": thinkingLevel.rawValue,
                "maxThinkingTokens": thinkingLevel.maxThinkingTokens
            ])
        }
    }

    func isSessionRunning(sessionID: String) -> Bool {
        queue.sync { runtimes[sessionID] != nil }
    }

    func respondPermission(_ permission: PermissionRequest, allow: Bool, updatedInputJSON: String?, message: String?) throws {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if allow {
            decision["updatedInput"] = (try? parseJSONObject(updatedInputJSON ?? permission.inputJSON)) ?? [:]
            if let toolUseID = permission.toolUseID { decision["toolUseID"] = toolUseID }
        } else {
            decision["message"] = message ?? "User denied this operation"
        }
        _ = try rpc(method: "permission.respond", params: [
            "sessionId": permission.sessionID,
            "requestId": permission.requestID,
            "decision": decision
        ])
    }

    func interrupt(sessionID: String) throws {
        _ = try rpc(method: "session.interrupt", params: ["sessionId": sessionID])
    }

    private func cliModelName(_ model: String) -> String {
        [
            "claude-fable-5-1m": "claude-fable-5[1m]",
            "claude-opus-4-8-1m": "claude-opus-4-8[1m]",
            "claude-opus-4-6-1m": "claude-opus-4-6[1m]"
        ][model] ?? model
    }

    func kill(sessionID: String) {
        let runtime = queue.sync { runtimes.removeValue(forKey: sessionID) }
        if runtime != nil, process != nil {
            _ = try? rpc(method: "session.kill", params: ["sessionId": sessionID], timeout: 2)
        }
        ClaudeCLIEngine.cleanupMCPScratchConfig(at: runtime?.mcpScratch)
    }

    func killAll() {
        let scratches = queue.sync { () -> [URL?] in
            let values = runtimes.values.map(\.mcpScratch)
            runtimes.removeAll()
            return values
        }
        if process != nil { _ = try? rpc(method: "engine.shutdown", params: [:], timeout: 2) }
        scratches.forEach { ClaudeCLIEngine.cleanupMCPScratchConfig(at: $0) }
        queue.sync {
            stdin = nil
            process = nil
            initialized = false
            pending.removeAll()
            stdoutBuffer.removeAll()
            stderrBuffer.removeAll()
        }
    }

    private func rpc(method: String, params: [String: Any], timeout: TimeInterval = 15) throws -> [String: Any] {
        try ensureReady()
        return try sendRPC(method: method, params: params, timeout: timeout)
    }

    private func ensureReady() throws {
        try startProcessIfNeeded()
        let needsInitialize = queue.sync { !initialized }
        if needsInitialize {
            _ = try sendRPC(method: "engine.initialize", params: [:], timeout: 8)
            queue.sync { initialized = true }
        }
    }

    private func startProcessIfNeeded() throws {
        let running = queue.sync { process?.isRunning == true }
        if running { return }
        guard FileManager.default.isReadableFile(atPath: sidecarScript.path) else {
            throw makeError("Sidecar script not found at \(sidecarScript.path)")
        }
        guard let nodePath = Self.resolveNodeExecutable(home: home.path, base: baseEnvironment) else {
            throw makeError("Node executable not found for sidecar runtime")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [sidecarScript.path]
        process.currentDirectoryURL = sidecarScript.deletingLastPathComponent()
        let nodeDir = URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
        var env = baseEnvironment
        env["PATH"] = "\(nodeDir):\(enrichedPath())"
        process.environment = env
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        queue.sync {
            self.process = process
            stdin = inPipe.fileHandleForWriting
            initialized = false
        }
        attachReaders(stdout: outPipe.fileHandleForReading, stderr: errPipe.fileHandleForReading)
        process.terminationHandler = { [weak self] _ in self?.handleSidecarExit() }
    }

    private func sendRPC(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let id = "req_\(UUID().uuidString)"
        let pending = PendingRPC()
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let line = data + Data([0x0A])
        let handle: FileHandle = try queue.sync {
            guard let stdin else { throw makeError("Sidecar stdin is not available") }
            self.pending[id] = pending
            return stdin
        }
        do { try handle.write(contentsOf: line) } catch {
            queue.sync { _ = self.pending.removeValue(forKey: id) }
            throw error
        }
        guard pending.semaphore.wait(timeout: .now() + timeout) == .success else {
            queue.sync { _ = self.pending.removeValue(forKey: id) }
            throw makeError("Sidecar request timed out: \(method)")
        }
        switch pending.result {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw makeError("Sidecar request completed without result: \(method)")
        }
    }

    private func attachReaders(stdout: FileHandle, stderr: FileHandle) {
        stdout.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            queue.async {
                self.stdoutBuffer.append(data)
                for line in Self.consumeLines(&self.stdoutBuffer) { self.handleStdout(line) }
            }
        }
        stderr.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            queue.async {
                self.stderrBuffer.append(data)
                for line in Self.consumeLines(&self.stderrBuffer) { self.broadcastStderr(line) }
            }
        }
    }

    private func handleStdout(_ line: String) {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = obj["id"] as? String, let pending = pending.removeValue(forKey: id) {
            if let errorObj = obj["error"] as? [String: Any] {
                let code = errorObj["code"] as? String ?? "SIDECAR_ERROR"
                let message = errorObj["message"] as? String ?? code
                pending.result = .failure(makeError("\(code): \(message)"))
            } else {
                pending.result = .success((obj["result"] as? [String: Any]) ?? [:])
            }
            pending.semaphore.signal()
            return
        }
        guard obj["method"] as? String == "event", let params = obj["params"] as? [String: Any] else { return }
        handleEvent(params)
    }

    private func handleEvent(_ params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String else { return }
        let type = params["type"] as? String ?? ""
        let payload = params["payload"]
        guard let runtime = runtimes[sessionID] else { return }
        switch type {
        case "claude.raw":
            if let raw = payload as? [String: Any] { emitParsed(raw, runtime: runtime) }
        case "permission.requested":
            if let raw = payload as? [String: Any] { emitParsed(raw, runtime: runtime) }
        case "stderr":
            let line = (payload as? [String: Any])?["line"] as? String ?? payload as? String ?? ""
            runtime.eventSink(.stderr(sessionID: sessionID, line))
        case "stdout.text":
            break
        case "session.failed":
            let message = (payload as? [String: Any])?["message"] as? String ?? "Claude sidecar session failed"
            runtime.eventSink(.failed(sessionID: sessionID, message))
        case "session.exited":
            let scratch = runtime.mcpScratch
            runtimes.removeValue(forKey: sessionID)
            ClaudeCLIEngine.cleanupMCPScratchConfig(at: scratch)
            runtime.eventSink(.exited(sessionID: sessionID))
        default:
            break
        }
    }

    private func emitParsed(_ raw: [String: Any], runtime: Runtime) {
        for event in StreamEventParser.events(from: raw, sessionID: runtime.sessionID) {
            if case .permissionRequested(let req) = event, req.toolName == "HookCallback" { continue }
            runtime.eventSink(event)
        }
    }

    private func broadcastStderr(_ line: String) {
        for runtime in runtimes.values {
            runtime.eventSink(.stderr(sessionID: runtime.sessionID, line))
        }
    }

    private func handleSidecarExit() {
        let runtimes = queue.sync { () -> [Runtime] in
            let values = Array(self.runtimes.values)
            let status = self.process?.terminationStatus
            let reason = self.process?.terminationReason
            let stderr = String(data: self.stderrBuffer.suffix(4096), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var message = "Sidecar exited"
            if let status {
                message += " status=\(status)"
            }
            if let reason {
                message += " reason=\(reason.rawValue)"
            }
            if !stderr.isEmpty {
                message += "; stderr=\(stderr)"
            }
            self.runtimes.removeAll()
            self.pending.values.forEach { pending in
                pending.result = .failure(makeError(message))
                pending.semaphore.signal()
            }
            self.pending.removeAll()
            self.process = nil
            self.stdin = nil
            self.initialized = false
            return values
        }
        for runtime in runtimes {
            ClaudeCLIEngine.cleanupMCPScratchConfig(at: runtime.mcpScratch)
            runtime.eventSink(.exited(sessionID: runtime.sessionID))
        }
    }

    private static func consumeLines(_ data: inout Data) -> [String] {
        var lines: [String] = []
        while let range = data.firstRange(of: Data([0x0A])) {
            let lineData = data.subdata(in: data.startIndex ..< range.lowerBound)
            data.removeSubrange(data.startIndex ... range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line.trimmingCharacters(in: .newlines)) }
        }
        return lines
    }

    private func resolveClaudeExecutable() -> String {
        if
            let override = baseEnvironment["LIQUIDCODE_CLAUDE_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return override
        }
        if
            let override = baseEnvironment["CLAUDE_CODE_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty {
            return override
        }
        let candidates = [
            home.appendingPathComponent(".claude/local/claude").path,
            home.appendingPathComponent(".npm-global/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        return Self.findExecutable("claude", in: enrichedPath()) ?? "claude"
    }

    private func enrichedPath() -> String {
        Self.enrichedPath(home: home.path, base: baseEnvironment)
    }

    private static func enrichedPath(home: String, base: [String: String]) -> String {
        var parts = [
            "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        if let existing = base["PATH"] { parts.append(existing) }
        return parts.joined(separator: ":")
    }

    private static func findExecutable(_ name: String, in path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func resolveNodeExecutable(home: String, base: [String: String]) -> String? {
        let path = enrichedPath(home: home, base: base)
        if let inPath = findExecutable("node", in: path) {
            return inPath
        }

        let fm = FileManager.default
        let userHome = fm.homeDirectoryForCurrentUser.path
        let homeRoots = Array(Set([home, userHome])).sorted()
        let fixedCandidates = homeRoots.map { "\($0)/.asdf/shims/node" } + [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ]
        if let fixed = fixedCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return fixed
        }

        for rootHome in homeRoots {
            let dynamicRoots: [(String, (String) -> String)] = [
                ("\(rootHome)/.local/state/fnm_multishells", { "\($0)/bin/node" }),
                ("\(rootHome)/.fnm/node-versions", { "\($0)/installation/bin/node" }),
                ("\(rootHome)/.nvm/versions/node", { "\($0)/bin/node" })
            ]
            for (root, nodePath) in dynamicRoots {
                guard let children = try? fm.contentsOfDirectory(atPath: root) else {
                    continue
                }
                for child in children.sorted(by: >) {
                    let candidate = nodePath(URL(fileURLWithPath: root).appendingPathComponent(child).path)
                    if fm.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }

        return Shell.capture("/usr/bin/env", ["which", "node"], environment: ["PATH": path])
    }

    private func parseJSONObject(_ json: String) throws -> Any {
        guard let data = json.data(using: .utf8) else { throw makeError("Invalid JSON string") }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "LiquidCode.SidecarClaudeEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
