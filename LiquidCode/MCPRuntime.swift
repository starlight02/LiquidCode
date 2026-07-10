import Foundation

/// Fail-soft MCP connectivity probe used by Settings → Test.
/// First-pass goal is reachability, not a full MCP handshake. Tool count stays
/// nil unless a richer probe is reintroduced later.
enum MCPRuntimeProbe {
    struct Result: Equatable, Sendable {
        var status: MCPRuntimeStatus
        var toolCount: Int?
        var error: String?
        var detail: String
    }

    static func evaluate(
        _ server: MCPServer,
        timeout: TimeInterval = 3,
        urlSession: URLSession = .shared
    ) async -> Result {
        _ = urlSession
        if let urlString = server.url?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty {
            return evaluateHTTP(urlString, name: server.name, timeout: timeout)
        }
        guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return Result(
                status: .failed,
                toolCount: nil,
                error: "No command or URL configured",
                detail: "\(server.name) has no command or URL"
            )
        }
        return evaluateStdio(command: command, args: server.args, name: server.name)
    }

    private static func evaluateHTTP(_ urlString: String, name: String, timeout: TimeInterval) -> Result {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return Result(status: .failed, toolCount: nil, error: "Invalid URL", detail: "\(name): \(urlString)")
        }
        _ = url
        // Lightweight reachability: any HTTP response (incl. 4xx) means the endpoint is up.
        // Connection errors / timeouts fail the probe.
        let maxTime = String(max(1, Int(timeout.rounded(.up))))
        let args = [
            "-sS",
            "-o", "/dev/null",
            "-w", "%{http_code}",
            "--max-time", maxTime,
            "-L",
            urlString
        ]
        let result = Shell.run("/usr/bin/curl", args)
        if result.status == 0 {
            let code = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == "000" || code.isEmpty {
                return Result(status: .failed, toolCount: nil, error: "No HTTP response", detail: "\(name): \(urlString)")
            }
            return Result(
                status: .ok,
                toolCount: nil,
                error: nil,
                detail: "\(name): HTTP \(code) · \(urlString)"
            )
        }
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            status: .failed,
            toolCount: nil,
            error: err.isEmpty ? "Unreachable" : err,
            detail: "\(name): \(urlString)"
        )
    }

    private static func evaluateStdio(command: String, args: [String], name: String) -> Result {
        let resolved: String?
        if command.contains("/") {
            let expanded = NSString(string: command).expandingTildeInPath
            resolved = FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        } else {
            resolved = Shell.capture("/usr/bin/env", ["which", command])
        }
        guard let path = resolved, !path.isEmpty else {
            return Result(
                status: .failed,
                toolCount: nil,
                error: "Command not found: \(command)",
                detail: "\(name): \(command)"
            )
        }
        let argNote = args.isEmpty ? path : "\(path) (+\(args.count) args)"
        return Result(
            status: .ok,
            toolCount: nil,
            error: nil,
            detail: "\(name): \(argNote)"
        )
    }
}
