import AppKit
import CryptoKit
import Darwin
import Foundation

final class CLIService: @unchecked Sendable {
    static let gcsBase = URL(string: "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases")!
    static let mirrorBase = URL(string: "https://herear.cn:8443/releases/claude-code")!

    private let home: URL
    private let environment: [String: String]
    private let releaseBases: [URL]
    private let fileManager: FileManager

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        releaseBases: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.environment = environment
        self.releaseBases = releaseBases ?? [Self.gcsBase, Self.mirrorBase]
        self.fileManager = fileManager
    }

    func status(checkForUpdates: Bool = true) -> CLIStatus {
        let candidates = diagnose()
        let candidate = resolveCandidate(from: candidates)
        let node = findInPath("node")
        let npm = findInPath("npm")
        let latest = checkForUpdates ? latestVersion(from: releaseBases) : nil
        return CLIStatus(
            installed: candidate != nil,
            path: candidate?.path,
            version: candidate?.version,
            updateAvailable: latest.map { Self.versionGreater($0, than: candidate?.version ?? "0") } ?? false,
            latestVersion: latest,
            nodeAvailable: node != nil,
            npmAvailable: npm != nil,
            authStatus: checkAuth()
        )
    }

    func diagnose() -> [CLICandidate] {
        candidatePaths().map { path, source in
            let url = URL(fileURLWithPath: path)
            let exists = fileManager.fileExists(atPath: path)
            let symlinkExists = (try? fileManager.attributesOfItem(atPath: path)[.type]) != nil
            let native = isNativeBinary(url)
            let valid = exists && fileManager.isExecutableFile(atPath: path)
            var issues: [String] = []
            if symlinkExists && !exists {
                issues.append("broken symlink (target no longer exists)")
            } else if !valid {
                issues.append("not a valid executable")
            }
            if valid && !native {
                issues += shebangIssues(url)
            }
            let version = issues.isEmpty ? runVersion(path) : nil
            return CLICandidate(path: path, source: source, isNative: native, version: version, issues: issues)
        }
    }

    func checkCLIUpdate(releaseBases bases: [URL]? = nil) -> CLIUpdateCheck {
        let current = resolveCandidate(from: diagnose())?.version
        let latest = latestVersion(from: bases ?? releaseBases)
        return CLIUpdateCheck(current: current, latest: latest, updateAvailable: latest.map { Self.versionGreater($0, than: current ?? "0") } ?? false)
    }

    func installOrUpdate(
        preferChina: Bool = false,
        releaseBases bases: [URL]? = nil,
        allowNPMFallback: Bool = true,
        progress: @escaping @Sendable (CLIProgressEvent) -> Void
    ) -> CLIActionResult {
        let orderedBases = bases ?? (preferChina ? [Self.mirrorBase, Self.gcsBase] : releaseBases)
        progress(CLIProgressEvent(phase: .checking, percent: 0.05, message: "Checking Claude CLI release sources"))
        do {
            let version = try installNative(from: orderedBases, progress: progress)
            progress(CLIProgressEvent(phase: .complete, percent: 1, message: "Claude CLI native install complete: \(version)"))
            return CLIActionResult(ok: true, version: version, source: "native", message: "Installed Claude CLI \(version)")
        } catch {
            guard allowNPMFallback else {
                progress(CLIProgressEvent(phase: .failed, percent: 1, message: error.localizedDescription))
                return CLIActionResult(ok: false, version: nil, source: "native", message: error.localizedDescription)
            }
            progress(CLIProgressEvent(phase: .npmFallback, percent: 0.7, message: "Native download failed; trying npm fallback"))
            do {
                let version = try installViaNPM()
                progress(CLIProgressEvent(phase: .complete, percent: 1, message: "Claude CLI npm install complete: \(version ?? "unknown")"))
                return CLIActionResult(ok: true, version: version, source: "npm", message: "Installed Claude CLI via npm")
            } catch let npmError {
                let message = "Native download failed: \(error.localizedDescription). npm fallback failed: \(npmError.localizedDescription)"
                progress(CLIProgressEvent(phase: .failed, percent: 1, message: message))
                return CLIActionResult(ok: false, version: nil, source: "none", message: message)
            }
        }
    }

    func selectNativeSources(releaseBases bases: [URL]? = nil) throws -> [(base: URL, version: String)] {
        let versions = (bases ?? releaseBases).compactMap { base -> (URL, String)? in latestVersion(from: [base]).map { (base, $0) } }
        guard !versions.isEmpty else {
            throw NSError(domain: "LiquidCode.CLI", code: 404, userInfo: [NSLocalizedDescriptionKey: "No native release source reachable"])
        }
        return versions.sorted { lhs, rhs in Self.versionGreater(lhs.1, than: rhs.1) }
    }

    func cleanupCLI(targets: [String]) -> CLICleanupResult {
        var result = CLICleanupResult()
        for target in targets {
            guard isAppLocalPath(target) else {
                result.skipped.append(CLICleanupSkipped(path: target, reason: "Not in LiquidCode app-local CLI directory — will not auto-delete"))
                continue
            }
            do {
                if fileManager.fileExists(atPath: target) || (try? fileManager.attributesOfItem(atPath: target)[.type]) != nil {
                    try fileManager.removeItem(atPath: target)
                    result.removed.append(target)
                }
            } catch {
                result.skipped.append(CLICleanupSkipped(path: target, reason: "delete failed: \(error.localizedDescription)"))
            }
        }
        return result
    }

    func repairCLI() -> CLIRepairReport {
        var report = CLIRepairReport()
        for candidate in diagnose() {
            report.scanned.append(candidate.path)
            guard !candidate.issues.isEmpty else {
                continue
            }
            if isAppLocalPath(candidate.path) {
                let cleanup = cleanupCLI(targets: [candidate.path])
                report.removed += cleanup.removed
                report.notes += cleanup.skipped.map { "\($0.path): \($0.reason)" }
            } else {
                report.notes.append("Skipped non-app-local CLI \(candidate.path): \(candidate.issues.joined(separator: ", "))")
            }
        }
        if report.removed.isEmpty && report.notes.isEmpty {
            report.notes.append("No repairable CLI issues found")
        }
        return report
    }

    func openTerminalLogin() {
        let cli = resolveCandidate(from: diagnose())?.path ?? "claude"
        let script = "tell application \"Terminal\"\ndo script \"\(shellQuote(cli)) login\"\nactivate\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private func installNative(from bases: [URL], progress: @escaping @Sendable (CLIProgressEvent) -> Void) throws -> String {
        let sources = try selectNativeSources(releaseBases: bases)
        let version = sources[0].version
        let platform = nativePlatformKey()
        var checksum = ""
        var binaryName = defaultBinaryName()
        var manifestFound = false
        for source in sources where source.version == version {
            let manifestURL = source.base.appendingPathComponent(version).appendingPathComponent("manifest.json")
            guard
                let manifestData = try? fetchData(manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                let platforms = manifest["platforms"] as? [String: Any],
                let info = platforms[platform] as? [String: Any] else {
                continue
            }
            checksum = info["checksum"] as? String ?? ""
            binaryName = info["binary"] as? String ?? binaryName
            manifestFound = true
            break
        }
        guard manifestFound
        else {
            throw NSError(domain: "LiquidCode.CLI", code: 404, userInfo: [NSLocalizedDescriptionKey: "Cannot fetch manifest for \(version) on \(platform)"])
        }

        let installDir = home.appendingPathComponent(".claude/local", isDirectory: true)
        try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
        let tmp = installDir.appendingPathComponent("\(binaryName).tmp")
        let dest = installDir.appendingPathComponent(binaryName)
        var downloaded = false
        for source in sources where source.version == version {
            let url = source.base.appendingPathComponent(version).appendingPathComponent(platform).appendingPathComponent(binaryName)
            progress(CLIProgressEvent(phase: .downloading, percent: 0.2, message: "Downloading \(url.absoluteString)"))
            guard let data = try? fetchData(url) else {
                continue
            }
            if !checksum.isEmpty && sha256Hex(data) != checksum {
                continue
            }
            try data.write(to: tmp, options: [.atomic])
            downloaded = true
            break
        }
        guard downloaded else {
            throw NSError(domain: "LiquidCode.CLI", code: 502, userInfo: [NSLocalizedDescriptionKey: "All native download sources failed"])
        }
        chmod(tmp.path, 0o755)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: tmp, to: dest)
        progress(CLIProgressEvent(phase: .installing, percent: 0.9, message: "Installed \(dest.path)"))
        return version
    }

    private func installViaNPM() throws -> String? {
        guard let npm = findInPath("npm") else {
            throw NSError(domain: "LiquidCode.CLI", code: 127, userInfo: [NSLocalizedDescriptionKey: "npm not found for fallback install"])
        }
        let prefix = npmPrefixDir()
        let cache = home.appendingPathComponent(".liquidcode/npm-cache", isDirectory: true)
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let args = ["install", "-g", "@anthropic-ai/claude-code@latest", "--prefix=\(prefix.path)", "--cache=\(cache.path)"]
        let result = Shell.run(npm, args, environment: environmentWithEnrichedPath())
        guard result.status == 0 else {
            throw NSError(
                domain: "LiquidCode.CLI",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "npm install failed" : result.stderr]
            ) }
        return runVersion(resolveCandidate(from: diagnose())?.path ?? home.appendingPathComponent(".claude/local/claude").path)
    }

    private func latestVersion(from bases: [URL]) -> String? {
        bases.compactMap { base -> String? in
            guard
                let data = try? fetchData(base.appendingPathComponent("latest")), let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                !value.isEmpty else {
                return nil
            }
            return value
        }
        .max { lhs, rhs in Self.versionGreater(rhs, than: lhs) }
    }

    private func candidatePaths() -> [(String, CLISource)] {
        var out: [(String, CLISource)] = []
        var seen = Set<String>()
        func add(_ path: String, _ source: CLISource) {
            guard seen.insert(path).inserted else {
                return
            }
            out.append((path, source))
        }
        if let pinned = pinnedCLIPath() {
            add(pinned, .dynamic)
        }
        add(home.appendingPathComponent(".claude/local/claude").path, .official)
        add(home.appendingPathComponent(".npm-global/bin/claude").path, .system)
        add(home.appendingPathComponent(".local/bin/claude").path, .system)
        add("/opt/homebrew/bin/claude", .system)
        add("/usr/local/bin/claude", .system)
        add(appLocalCLIDir().appendingPathComponent("claude").path, .appLocal)
        add(npmPrefixDir().appendingPathComponent("bin/claude").path, .appLocal)
        add(home.appendingPathComponent(".volta/bin/claude").path, .versionManager)
        add(home.appendingPathComponent(".bun/bin/claude").path, .versionManager)
        for entry in (environment["PATH"] ?? "").split(separator: ":") where !entry.isEmpty {
            add(
                URL(fileURLWithPath: String(entry)).appendingPathComponent("claude").path,
                .dynamic
            ) }
        return out
    }

    private func resolveCandidate(from candidates: [CLICandidate]) -> CLICandidate? {
        candidates.first { $0.issues.isEmpty }
    }

    private func runVersion(_ path: String) -> String? {
        Shell.capture(path, ["--version"], environment: environmentWithEnrichedPath()).flatMap(Self.extractSemver)
    }

    private func findInPath(_ name: String) -> String? {
        for entry in enrichedPath().split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isNativeBinary(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url).prefix(4) else {
            return false
        }
        let bytes = Array(data)
        return bytes.starts(with: [0x7f, 0x45, 0x4c, 0x46]) || bytes.starts(with: [0x4d, 0x5a]) || bytes.starts(with: [0xcf, 0xfa, 0xed, 0xfe]) || bytes.starts(with: [
            0xca,
            0xfe,
            0xba,
            0xbe
        ]) || bytes.starts(with: [0xfe, 0xed, 0xfa, 0xcf])
    }

    private func shebangIssues(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url).prefix(256), let text = String(data: data, encoding: .utf8), text.hasPrefix("#!") else {
            return []
        }
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.dropFirst(2).split(separator: " ").map(String.init)
        guard parts.first == "/usr/bin/env", let tool = parts.dropFirst().first, findInPath(tool) == nil else {
            return []
        }
        return ["shebang interpreter '\(tool)' not found"]
    }

    private func fetchData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func appLocalCLIDir() -> URL {
        home.appendingPathComponent("Library/Application Support/LiquidCode/cli", isDirectory: true)
    }

    private func npmPrefixDir() -> URL {
        home.appendingPathComponent(".liquidcode/npm", isDirectory: true)
    }

    private func pinPath() -> URL {
        home.appendingPathComponent(".liquidcode/cli-pin.json")
    }

    private func legacyPinPath() -> URL {
        home.appendingPathComponent(".her/cli-pin.json")
    }

    private func isAppLocalPath(_ path: String) -> Bool {
        path.hasPrefix(appLocalCLIDir().path) || path.hasPrefix(npmPrefixDir().path)
    }

    private func pinnedCLIPath() -> String? {
        for url in [pinPath(), legacyPinPath()] {
            guard
                let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = obj["path"] as? String,
                !path.isEmpty else {
                continue
            }
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func enrichedPath() -> String {
        var parts = [
            home.appendingPathComponent(".claude/local").path,
            npmPrefixDir().appendingPathComponent("bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        if let existing = environment["PATH"] {
            parts.append(existing)
        }
        return parts.joined(separator: ":")
    }

    private func environmentWithEnrichedPath() -> [String: String] {
        var env = environment
        env["PATH"] = enrichedPath()
        return env
    }

    private func checkAuth() -> String {
        if fileManager.fileExists(atPath: home.appendingPathComponent(".claude/credentials.json").path) {
            return "authenticated"
        }
        if fileManager.fileExists(atPath: home.appendingPathComponent(".claude.json").path) {
            return "configured"
        }
        return "not authenticated"
    }

    private func nativePlatformKey() -> String {
        #if os(macOS) && arch(arm64)
            return "darwin-arm64"
        #elseif os(macOS) && arch(x86_64)
            return "darwin-x64"
        #elseif os(Linux) && arch(x86_64)
            return "linux-x64"
        #else
            return "unsupported"
        #endif
    }

    private func defaultBinaryName() -> String {
        "claude"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func extractSemver(_ raw: String) -> String? {
        let pattern = #"\d+(?:\.\d+){1,3}"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), let range = Range(
                match.range,
                in: raw
            ) else {
            return raw.split(separator: " ").first.map(String.init)
        }
        return String(raw[range])
    }

    static func versionGreater(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart {
                return leftPart > rightPart
            }
        }
        return false
    }
}

struct ProviderConnectionProbeResult: Equatable, Sendable {
    var statusCode: Int
    var latencyMilliseconds: Int
    var preview: String
}

enum ProviderConnectionProbe {
    static func makeRequest(provider: ProviderRecord, apiKey: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL(for: provider))
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch provider.apiFormat {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "Return only OK."]]
            ])
        case .openai:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "Return only OK."]]
            ])
        }
        return request
    }

    static func probe(provider: ProviderRecord, apiKey: String, model: String) async throws -> ProviderConnectionProbeResult {
        let request = try makeRequest(provider: provider, apiKey: apiKey, model: model)
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError(title: "Provider check failed", message: "No HTTP response from \(provider.name)")
        }
        let preview = responsePreview(from: data)
        let elapsed = max(0, Int(Date().timeIntervalSince(start) * 1000))
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AppError(title: "Provider check failed", message: "\(provider.name) returned HTTP \(http.statusCode): \(preview)")
        }
        return ProviderConnectionProbeResult(statusCode: http.statusCode, latencyMilliseconds: elapsed, preview: preview)
    }

    private static func endpointURL(for provider: ProviderRecord) throws -> URL {
        switch provider.apiFormat {
        case .anthropic:
            return try endpointURL(baseURL: provider.baseURL, apiRoot: "v1", leaf: "messages")
        case .openai:
            return try endpointURL(baseURL: provider.baseURL, apiRoot: "v1", leaf: "chat/completions")
        }
    }

    private static func endpointURL(baseURL: String, apiRoot: String, leaf: String) throws -> URL {
        let clean = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var components = URLComponents(string: clean), components.scheme != nil, components.host != nil else {
            throw AppError(title: "Provider URL invalid", message: "Base URL is not a valid HTTP URL: \(baseURL)")
        }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathLower = path.lowercased()
        let leafLower = leaf.lowercased()
        if pathLower == leafLower || pathLower.hasSuffix("/\(leafLower)") {
            // Already points at the concrete endpoint.
        } else if pathLower == apiRoot.lowercased() || pathLower.hasSuffix("/\(apiRoot.lowercased())") {
            path = [path, leaf].filter { !$0.isEmpty }.joined(separator: "/")
        } else {
            path = [path, apiRoot, leaf].filter { !$0.isEmpty }.joined(separator: "/")
        }
        components.path = "/\(path)"
        guard let url = components.url else {
            throw AppError(title: "Provider URL invalid", message: "Cannot construct provider endpoint from \(baseURL)")
        }
        return url
    }

    private static func responsePreview(from data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 240 {
            return collapsed
        }
        return String(collapsed.prefix(240)) + "…"
    }
}

final class ShareService {
    func share(path: String, from view: NSView?) {
        let url = URL(fileURLWithPath: path)
        let picker = NSSharingServicePicker(items: [url])
        if let view {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

}
