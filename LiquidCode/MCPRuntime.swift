import Darwin
import Foundation

/// Performs the same MCP handshake a client uses before it exposes a server's
/// tools. A successful TCP connection or an executable on PATH is not enough.
enum MCPRuntimeProbe {
    struct Result: Equatable, Sendable {
        var status: MCPRuntimeStatus
        var toolCount: Int?
        var error: String?
        var detail: String
    }

    private enum ProbeError: LocalizedError {
        case invalidConfiguration(String)
        case unsupportedTransport(String)
        case timedOut
        case processFailed(String)
        case invalidResponse(String)
        case serverError(String)
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message),
                 .processFailed(let message),
                 .invalidResponse(let message),
                 .serverError(let message):
                return message
            case .unsupportedTransport(let transport):
                return "Unsupported MCP transport: \(transport)"
            case .timedOut:
                return "MCP handshake timed out"
            case .httpError(let status, let detail):
                return detail.isEmpty ? "MCP endpoint returned HTTP \(status)" : "HTTP \(status): \(detail)"
            }
        }
    }

    private static let protocolVersion = "2025-06-18"
    private static let defaultTimeout: TimeInterval = 10

    static func evaluate(
        _ server: MCPServer,
        timeout: TimeInterval = defaultTimeout,
        urlSession: URLSession = .shared
    ) async -> Result {
        let transport = normalizedTransport(for: server)
        do {
            let toolCount = try await withTimeout(seconds: timeout) {
                switch transport {
                case "stdio":
                    return try await StdioProbe(server: server).run()
                case "http", "streamable-http":
                    return try await HTTPProbe(server: server, session: urlSession).run()
                default:
                    throw ProbeError.unsupportedTransport(server.transport.isEmpty ? "unknown" : server.transport)
                }
            }
            return Result(
                status: .ok,
                toolCount: toolCount,
                error: nil,
                detail: "\(server.name): \(transport) · \(toolCount) tools"
            )
        } catch is CancellationError {
            return Result(status: .failed, toolCount: nil, error: "MCP test cancelled", detail: server.name)
        } catch let error as ProbeError {
            let status: MCPRuntimeStatus
            if case .unsupportedTransport = error {
                status = .unsupported
            } else {
                status = .failed
            }
            return Result(
                status: status,
                toolCount: nil,
                error: error.localizedDescription,
                detail: "\(server.name): \(transport)"
            )
        } catch {
            return Result(
                status: .failed,
                toolCount: nil,
                error: error.localizedDescription,
                detail: "\(server.name): \(transport)"
            )
        }
    }

    private static func normalizedTransport(for server: MCPServer) -> String {
        let configured = server.transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !configured.isEmpty {
            return configured
        }
        return server.url == nil ? "stdio" : "http"
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else {
            throw ProbeError.timedOut
        }
        let nanoseconds = UInt64(min(seconds, 3_600) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ProbeError.timedOut
            }
            guard let first = try await group.next() else {
                throw ProbeError.invalidResponse("MCP probe ended without a result")
            }
            return first
        }
    }

    private static func initializeRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [:],
                "clientInfo": [
                    "name": "LiquidCode",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                ]
            ]
        ]
    }

    private static var initializedNotification: [String: Any] {
        ["jsonrpc": "2.0", "method": "notifications/initialized"]
    }

    private static func toolsListRequest(id: Int, cursor: String?) -> [String: Any] {
        var params: [String: Any] = [:]
        if let cursor {
            params["cursor"] = cursor
        }
        return ["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": params]
    }

    private static func validateInitializeResult(_ response: [String: Any], id: Int) throws {
        let result = try responseResult(response, id: id)
        guard
            result["protocolVersion"] is String,
            result["capabilities"] is [String: Any],
            result["serverInfo"] is [String: Any] else {
            throw ProbeError.invalidResponse("MCP initialize response is missing protocolVersion, capabilities, or serverInfo")
        }
    }

    private static func toolsPage(_ response: [String: Any], id: Int) throws -> (count: Int, nextCursor: String?) {
        let result = try responseResult(response, id: id)
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw ProbeError.invalidResponse("MCP tools/list response is missing a tools array")
        }
        return (tools.count, result["nextCursor"] as? String)
    }

    private static func responseResult(_ response: [String: Any], id: Int) throws -> [String: Any] {
        guard response["jsonrpc"] as? String == "2.0", responseID(response["id"]) == id else {
            throw ProbeError.invalidResponse("MCP returned an invalid JSON-RPC response for request \(id)")
        }
        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue
            let message = error["message"] as? String ?? "Unknown MCP server error"
            throw ProbeError.serverError(code.map { "MCP error \($0): \(message)" } ?? message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw ProbeError.invalidResponse("MCP response \(id) is missing a result object")
        }
        return result
    }

    private static func responseID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private final class StdioProbe: @unchecked Sendable {
        private let server: MCPServer
        private let lock = NSLock()
        private let process = Process()
        private let stdinPipe = Pipe()
        private let stdoutPipe = Pipe()
        private let stderrPipe = Pipe()
        private var stdoutBuffer = Data()
        private var stderrBuffer = Data()
        private var cancelled = false

        init(server: MCPServer) {
            self.server = server
        }

        func run() async throws -> Int {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try self.runBlocking()
                }.value
            } onCancel: {
                self.stop()
            }
        }

        private func runBlocking() throws -> Int {
            let environment = ProcessInfo.processInfo.environment.merging(server.environment) { _, configured in configured }
            guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                throw ProbeError.invalidConfiguration("No command configured for \(server.name)")
            }
            guard let executable = resolveExecutable(command, path: environment["PATH"]) else {
                throw ProbeError.invalidConfiguration("Command not found: \(command)")
            }

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = server.args
            process.environment = environment
            if let workingDirectory = server.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !workingDirectory.isEmpty {
                guard FileManager.default.fileExists(atPath: workingDirectory) else {
                    throw ProbeError.invalidConfiguration("Working directory not found: \(workingDirectory)")
                }
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                self?.appendStderr(data)
            }

            do {
                try process.run()
            } catch {
                throw ProbeError.processFailed("Failed to launch \(command): \(error.localizedDescription)")
            }
            defer { stop() }
            try throwIfCancelled()

            try write(MCPRuntimeProbe.initializeRequest(id: 1))
            let initialize = try readResponse(id: 1)
            try MCPRuntimeProbe.validateInitializeResult(initialize, id: 1)
            try write(MCPRuntimeProbe.initializedNotification)

            var requestID = 2
            var cursor: String?
            var seenCursors = Set<String>()
            var toolCount = 0
            repeat {
                try write(MCPRuntimeProbe.toolsListRequest(id: requestID, cursor: cursor))
                let response = try readResponse(id: requestID)
                let page = try MCPRuntimeProbe.toolsPage(response, id: requestID)
                toolCount += page.count
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw ProbeError.invalidResponse("MCP tools/list returned a repeated pagination cursor")
                }
                requestID += 1
                if requestID > 102 {
                    throw ProbeError.invalidResponse("MCP tools/list exceeded 100 pages")
                }
            } while cursor != nil
            return toolCount
        }

        private func resolveExecutable(_ command: String, path: String?) -> String? {
            if command.contains("/") {
                let expanded = NSString(string: command).expandingTildeInPath
                return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
            }
            for directory in (path ?? "").split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(command).path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }

        private func write(_ object: [String: Any]) throws {
            try throwIfCancelled()
            let data = try JSONSerialization.data(withJSONObject: object)
            var line = data
            line.append(0x0A)
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                throw ProbeError.processFailed(processFailure(fallback: "MCP server closed stdin"))
            }
        }

        private func readResponse(id: Int) throws -> [String: Any] {
            var messagesRead = 0
            while messagesRead < 1_000 {
                try throwIfCancelled()
                guard let line = try readLine() else {
                    throw ProbeError.processFailed(processFailure(fallback: "MCP server exited before responding to request \(id)"))
                }
                guard !line.isEmpty else {
                    continue
                }
                messagesRead += 1
                guard
                    let object = try? JSONSerialization.jsonObject(with: line),
                    let message = object as? [String: Any] else {
                    throw ProbeError.invalidResponse("MCP stdio server returned invalid JSON")
                }
                if MCPRuntimeProbe.responseID(message["id"]) == id {
                    return message
                }
            }
            throw ProbeError.invalidResponse("MCP server sent too many messages without answering request \(id)")
        }

        private func readLine() throws -> Data? {
            while true {
                if let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = stdoutBuffer.prefix(upTo: newline)
                    stdoutBuffer.removeSubrange(...newline)
                    return Data(line).trimmingTrailingCarriageReturn()
                }
                let chunk: Data
                do {
                    chunk = try stdoutPipe.fileHandleForReading.read(upToCount: 8_192) ?? Data()
                } catch {
                    try throwIfCancelled()
                    throw ProbeError.processFailed(processFailure(fallback: "Failed reading MCP server output"))
                }
                if chunk.isEmpty {
                    if stdoutBuffer.isEmpty {
                        return nil
                    }
                    defer { stdoutBuffer.removeAll(keepingCapacity: false) }
                    return stdoutBuffer.trimmingTrailingCarriageReturn()
                }
                stdoutBuffer.append(chunk)
                if stdoutBuffer.count > 8 * 1_024 * 1_024 {
                    throw ProbeError.invalidResponse("MCP stdio response exceeded 8 MB")
                }
            }
        }

        private func appendStderr(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, 32_768 - stderrBuffer.count)
            if remaining > 0 {
                stderrBuffer.append(data.prefix(remaining))
            }
        }

        private func processFailure(fallback: String) -> String {
            lock.lock()
            let data = stderrBuffer
            lock.unlock()
            let stderr = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stderr, !stderr.isEmpty {
                return stderr
            }
            return fallback
        }

        private func throwIfCancelled() throws {
            lock.lock()
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel || Task.isCancelled {
                throw CancellationError()
            }
        }

        private func stop() {
            lock.lock()
            let wasCancelled = cancelled
            cancelled = true
            lock.unlock()
            guard !wasCancelled else {
                return
            }

            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            guard process.isRunning else {
                return
            }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                if self.process.isRunning {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }
    }

    private struct HTTPProbe: Sendable {
        let server: MCPServer
        let session: URLSession

        func run() async throws -> Int {
            guard
                let urlString = server.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                let url = URL(string: urlString),
                let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                url.host != nil else {
                throw ProbeError.invalidConfiguration("Invalid MCP URL")
            }

            let initialize = try await send(MCPRuntimeProbe.initializeRequest(id: 1), to: url, sessionID: nil, expectsResponse: true)
            guard let initializeMessage = initialize.message else {
                throw ProbeError.invalidResponse("MCP initialize returned no JSON-RPC response")
            }
            try MCPRuntimeProbe.validateInitializeResult(initializeMessage, id: 1)

            _ = try await send(MCPRuntimeProbe.initializedNotification, to: url, sessionID: initialize.sessionID, expectsResponse: false)

            var requestID = 2
            var cursor: String?
            var seenCursors = Set<String>()
            var toolCount = 0
            repeat {
                let response = try await send(
                    MCPRuntimeProbe.toolsListRequest(id: requestID, cursor: cursor),
                    to: url,
                    sessionID: initialize.sessionID,
                    expectsResponse: true
                )
                guard let message = response.message else {
                    throw ProbeError.invalidResponse("MCP tools/list returned no JSON-RPC response")
                }
                let page = try MCPRuntimeProbe.toolsPage(message, id: requestID)
                toolCount += page.count
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw ProbeError.invalidResponse("MCP tools/list returned a repeated pagination cursor")
                }
                requestID += 1
                if requestID > 102 {
                    throw ProbeError.invalidResponse("MCP tools/list exceeded 100 pages")
                }
            } while cursor != nil
            return toolCount
        }

        private func send(
            _ object: [String: Any],
            to url: URL,
            sessionID: String?,
            expectsResponse: Bool
        ) async throws -> (message: [String: Any]?, sessionID: String?) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            for (field, value) in server.headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(MCPRuntimeProbe.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID {
                request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProbeError.invalidResponse("MCP endpoint returned a non-HTTP response")
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw ProbeError.httpError(http.statusCode, responseSnippet(data))
            }
            let returnedSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
            guard expectsResponse else {
                return (nil, returnedSessionID)
            }
            guard !data.isEmpty else {
                throw ProbeError.invalidResponse("MCP endpoint returned an empty response")
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let messages: [[String: Any]]
            if contentType.contains("text/event-stream") {
                messages = sseMessages(data)
            } else {
                messages = jsonMessages(data)
            }
            let requestedID = MCPRuntimeProbe.responseID(object["id"])
            let message = messages.first { MCPRuntimeProbe.responseID($0["id"]) == requestedID }
            guard let message else {
                throw ProbeError.invalidResponse("MCP endpoint did not return the requested JSON-RPC response")
            }
            return (message, returnedSessionID)
        }

        private func jsonMessages(_ data: Data) -> [[String: Any]] {
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                return []
            }
            if let message = object as? [String: Any] {
                return [message]
            }
            return object as? [[String: Any]] ?? []
        }

        private func sseMessages(_ data: Data) -> [[String: Any]] {
            guard let text = String(data: data, encoding: .utf8) else {
                return []
            }
            var messages: [[String: Any]] = []
            var dataLines: [String] = []
            func flush() {
                guard !dataLines.isEmpty else {
                    return
                }
                let payload = dataLines.joined(separator: "\n")
                if
                    let data = payload.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data),
                    let message = object as? [String: Any] {
                    messages.append(message)
                }
                dataLines.removeAll(keepingCapacity: true)
            }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
                if line.isEmpty {
                    flush()
                } else if line.hasPrefix("data:") {
                    var value = line.dropFirst(5)
                    if value.first == " " {
                        value = value.dropFirst()
                    }
                    dataLines.append(String(value))
                }
            }
            flush()
            return messages
        }

        private func responseSnippet(_ data: Data) -> String {
            String(data: data.prefix(512), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}

private extension Data {
    func trimmingTrailingCarriageReturn() -> Data {
        guard last == 0x0D else {
            return self
        }
        return Data(dropLast())
    }
}
