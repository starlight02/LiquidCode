import AppKit
import CoreServices
import Foundation
import Security

final class AppPaths: @unchecked Sendable {
    static let shared = AppPaths()
    let appSupport: URL
    let logs: URL
    let providersFile: URL
    let settingsFile: URL
    let sessionMetaFile: URL
    let mcpFile: URL
    let recentProjectsFile: URL

    private init() {
        let fm = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser
        let supportBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let libraryBase = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library", isDirectory: true)
        let logsBase = libraryBase.appendingPathComponent("Logs", isDirectory: true)
        appSupport = supportBase.appendingPathComponent("LiquidCode", isDirectory: true)
        logs = logsBase.appendingPathComponent("LiquidCode", isDirectory: true)
        providersFile = appSupport.appendingPathComponent("providers.json")
        settingsFile = appSupport.appendingPathComponent("settings.json")
        sessionMetaFile = appSupport.appendingPathComponent("sessions.json")
        recentProjectsFile = appSupport.appendingPathComponent("recent.json")
        mcpFile = appSupport.appendingPathComponent("mcp.json")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
    }
}

struct JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder.liquid.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.liquid.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

struct ClaudeUserComposerDefaults: Sendable {
    var model: String?
    var mode: SessionMode?
    var thinkingLevel: ThinkingLevel?
    var modelDisplayNames: [String: String] = [:]
}

final class ClaudeUserSettingsService: @unchecked Sendable {
    private let home: URL
    private let fileManager: FileManager

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    var settingsURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    func loadComposerDefaults() -> ClaudeUserComposerDefaults {
        let raw = loadRawSettings()
        let model = raw["model"] as? String
        let permissions = raw["permissions"] as? [String: Any]
        let mode = modeFromPermissionMode(permissions?["defaultMode"] as? String)
        let env = raw["env"] as? [String: Any]
        let effort = (env?["CLAUDE_CODE_EFFORT_LEVEL"] as? String)
            ?? (raw["effort"] as? String)
            ?? (raw["thinkingLevel"] as? String)
        let thinking: ThinkingLevel?
        if raw["alwaysThinkingEnabled"] as? Bool == false {
            thinking = .off
        } else if let effort, let parsed = ThinkingLevel(rawValue: effort) {
            thinking = parsed
        } else {
            thinking = nil
        }
        return ClaudeUserComposerDefaults(
            model: model,
            mode: mode,
            thinkingLevel: thinking,
            modelDisplayNames: modelDisplayNames(from: env)
        )
    }

    func saveComposerDefaults(model: String, mode: SessionMode, thinkingLevel: ThinkingLevel) throws {
        var raw = loadRawSettings()
        raw["model"] = model

        var permissions = raw["permissions"] as? [String: Any] ?? [:]
        permissions["defaultMode"] = mode.permissionMode
        raw["permissions"] = permissions

        raw["alwaysThinkingEnabled"] = thinkingLevel != .off
        var env = raw["env"] as? [String: Any] ?? [:]
        if thinkingLevel == .off {
            env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
        } else {
            env["CLAUDE_CODE_EFFORT_LEVEL"] = thinkingLevel.rawValue
        }
        if env.isEmpty {
            raw.removeValue(forKey: "env")
        } else {
            raw["env"] = env
        }

        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }

    private func loadRawSettings() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let raw = object as? [String: Any] else {
            return [:]
        }
        return raw
    }

    private func modeFromPermissionMode(_ raw: String?) -> SessionMode? {
        switch raw {
        case "acceptEdits", "auto": return .code
        case "plan": return .plan
        case "bypassPermissions", "dontAsk": return .bypass
        case "default", "manual", nil: return .ask
        default: return nil
        }
    }

    private func modelDisplayNames(from env: [String: Any]?) -> [String: String] {
        guard let env else {
            return [:]
        }
        var result: [String: String] = [:]
        for tier in ["FABLE", "OPUS", "SONNET", "HAIKU"] {
            guard let displayName = cleanString(env["ANTHROPIC_DEFAULT_\(tier)_MODEL_NAME"]) else {
                continue
            }
            let alias = tier.lowercased()
            result[alias] = displayName
            if let model = cleanString(env["ANTHROPIC_DEFAULT_\(tier)_MODEL"]) {
                result[model.lowercased()] = displayName
            }
        }
        return result
    }

    private func cleanString(_ value: Any?) -> String? {
        guard let raw = value as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension JSONEncoder {
    static var liquid: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var liquid: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class KeychainStore {
    static let service = "moe.aili.LiquidCode"

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"]
        )
    }
}

final class ProviderVault {
    private let keychain = KeychainStore()
    // periphery:ignore
    private let file = AppPaths.shared.providersFile

    struct ProviderFile: Codable { var activeProviderID: String?; var providers: [ProviderRecord] }

    // periphery:ignore
    func load() -> ProviderFile {
        JSONFile.load(ProviderFile.self, from: file) ?? ProviderFile(activeProviderID: nil, providers: [])
    }

    // periphery:ignore
    func save(_ data: ProviderFile) throws {
        try JSONFile.save(data, to: file)
    }

    func setAPIKey(_ key: String, providerID: String) throws {
        try keychain.set(key, account: "provider:\(providerID):api-key")
    }

    func apiKey(providerID: String) -> String? {
        try? keychain.get(account: "provider:\(providerID):api-key")
    }

    func deleteAPIKey(providerID: String) {
        keychain.delete(account: "provider:\(providerID):api-key")
    }

}

enum PathCapability: String, Sendable { case read, write, delete }

final class PathAccessManager: @unchecked Sendable {
    static let shared = PathAccessManager()
    private let lock = NSLock()
    private var fixedRoots: [URL]
    private var sessionGrants: [String: Set<String>] = [:]

    init(includeDefaultRoots: Bool = true) {
        fixedRoots = []
        guard includeDefaultRoots else {
            return
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        [
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude", isDirectory: true),
            home.appendingPathComponent(".liquidcode", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/" + "TOKEN" + "ICODE", isDirectory: true),
            AppPaths.shared.appSupport,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        ]
        .forEach { addFixedRoot($0) }
    }

    static func emptyForTests() -> PathAccessManager {
        PathAccessManager(includeDefaultRoots: false)
    }

    func registerCWD(_ path: String) {
        addFixedRoot(URL(fileURLWithPath: path, isDirectory: true))
    }

    func addFixedRoot(_ url: URL) {
        let canonical = Self.canonicalURL(url)
        lock.lock(); defer { lock.unlock() }
        if !fixedRoots.contains(where: { Self.path(canonical.path, startsWith: $0.path) }) {
            fixedRoots.append(canonical)
        }
    }

    func addGrant(sessionID: String, path: String) {
        let canonical = Self.canonicalURL(URL(fileURLWithPath: path)).path
        lock.lock(); defer { lock.unlock() }
        sessionGrants[sessionID, default: []].insert(canonical)
    }

    func clearGrants(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        sessionGrants.removeValue(forKey: sessionID)
    }

    func validate(_ path: String, sessionID: String?, capability: PathCapability) throws -> URL {
        let canonical = Self.canonicalURL(URL(fileURLWithPath: path))
        let canonicalPath = canonical.path
        lock.lock(); defer { lock.unlock() }
        if fixedRoots.contains(where: { Self.path(canonicalPath, startsWith: $0.path) }) {
            return canonical
        }
        if let sessionID, let grants = sessionGrants[sessionID], grants.contains(where: { Self.path(canonicalPath, startsWith: $0) }) {
            return canonical
        }
        throw NSError(
            domain: "LiquidCode.PathAccess",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Path '\(canonicalPath)' is outside the allowed workspace. Authorize it before \(capability.rawValue)."]
        )
    }

    static func canonicalPath(_ path: String) -> String {
        canonicalURL(URL(fileURLWithPath: path)).path
    }

    static func canonicalURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if let resolved = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return normalizedCanonicalURL(resolved)
        }
        var current = url.standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: current.path), current.path != current.deletingLastPathComponent().path {
            tail.insert(current.lastPathComponent, at: 0)
            current.deleteLastPathComponent()
        }
        let base = (try? current.resolvingSymlinksInPath().resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map {
            normalizedCanonicalURL($0)
        } ?? current.standardizedFileURL.resolvingSymlinksInPath()
        return tail.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL
    }

    private static func normalizedCanonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    fileprivate static func path(_ path: String, startsWith prefix: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: prefix).standardizedFileURL.pathComponents
        guard rootComponents.count <= pathComponents.count else {
            return false
        }
        return zip(pathComponents, rootComponents).allSatisfy(==)
    }
}

final class DirectoryWatchManager: @unchecked Sendable {
    struct WatchToken: Hashable, Sendable {
        // periphery:ignore
        fileprivate let id = UUID()
        init() {}
    }

    private struct DesiredWatch: Equatable {
        let root: String
        let token: WatchToken
    }

    private struct FileFingerprint: Equatable {
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: TimeInterval
    }

    private final class WatchContext: @unchecked Sendable {
        weak var manager: DirectoryWatchManager?
        let root: String
        let token: WatchToken
        let onChange: @Sendable ([String]) -> Void

        init(manager: DirectoryWatchManager, root: String, token: WatchToken, onChange: @escaping @Sendable ([String]) -> Void) {
            self.manager = manager
            self.root = root
            self.token = token
            self.onChange = onChange
        }
    }

    private static let retainWatchContext: CFAllocatorRetainCallBack = { info in
        guard let info else {
            return nil
        }
        _ = Unmanaged<WatchContext>.fromOpaque(info).retain()
        return info
    }

    private static let releaseWatchContext: CFAllocatorReleaseCallBack = { info in
        guard let info else {
            return
        }
        Unmanaged<WatchContext>.fromOpaque(info).release()
    }

    private final class Watch: @unchecked Sendable {
        let stream: FSEventStreamRef
        let context: WatchContext
        let pollTimer: DispatchSourceTimer
        let token: WatchToken
        private let teardownLock = NSLock()
        private var didTearDown = false

        init(stream: FSEventStreamRef, context: WatchContext, pollTimer: DispatchSourceTimer, token: WatchToken) {
            self.stream = stream
            self.context = context
            self.pollTimer = pollTimer
            self.token = token
        }

        func retire(on queue: DispatchQueue) {
            queue.async { [self] in
                tearDown()
            }
        }

        private func tearDown() {
            teardownLock.lock()
            guard !didTearDown else {
                teardownLock.unlock()
                return
            }
            didTearDown = true
            teardownLock.unlock()
            pollTimer.setEventHandler {}
            pollTimer.cancel()
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        deinit {
            tearDown()
        }
    }

    private let teardownQueue = DispatchQueue(label: "LiquidCode.DirectoryWatchManager.teardown", qos: .utility)

    private let queue = DispatchQueue(label: "LiquidCode.DirectoryWatchManager")

    private func retire(_ watches: [String: Watch]) {
        watches.values.forEach { $0.retire(on: teardownQueue) }
    }

    private var watches: [String: Watch] = [:]
    private var lastFingerprints: [String: [String: FileFingerprint]] = [:]
    private var desiredWatch: DesiredWatch?
    private let ignoredSegments: Set<String> = [
        ".claude", ".git", "node_modules", ".next", "target", "__pycache__", ".venv", "venv",
        ".DS_Store", "Thumbs.db", ".env", ".artifacts", ".build", ".build-release", ".swiftpm",
        ".xcode-derived", "DerivedData", "dist", "build", ".nuxt", ".parcel-cache", "coverage",
        ".turbo", ".svelte-kit"
    ]

    func watchDirectory(_ path: String, onChange: @escaping @Sendable ([String]) -> Void) throws {
        let token = WatchToken()
        requestWatchDirectory(path, token: token)
        _ = try watchRequestedDirectory(path, token: token, onChange: onChange)
    }

    @discardableResult
    func requestWatchDirectory(_ path: String, token: WatchToken) -> String {
        let root = PathAccessManager.canonicalPath(path)
        let old = queue.sync { () -> [String: Watch] in
            desiredWatch = DesiredWatch(root: root, token: token)
            let old = watches
            watches.removeAll()
            lastFingerprints.removeAll()
            return old
        }
        retire(old)
        return root
    }

    func cancelRequestedWatch(_ path: String? = nil, token: WatchToken? = nil) {
        let root = path.map(PathAccessManager.canonicalPath)
        let old = queue.sync { () -> [String: Watch] in
            guard let desired = desiredWatch else {
                return [:]
            }
            if let root, desired.root != root {
                return [:]
            }
            if let token, desired.token != token {
                return [:]
            }
            desiredWatch = nil
            let old = watches
            watches.removeAll()
            lastFingerprints.removeAll()
            return old
        }
        retire(old)
    }

    @discardableResult
    func watchRequestedDirectory(_ path: String, token: WatchToken, onChange: @escaping @Sendable ([String]) -> Void) throws -> Bool {
        let root = PathAccessManager.canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            cancelRequestedWatch(root, token: token)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Failed to watch \(root)"])
        }
        let initialSnapshot = snapshotFingerprints(root: root)
        let contextBox = WatchContext(manager: self, root: root, token: token, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(contextBox).toOpaque(),
            retain: Self.retainWatchContext,
            release: Self.releaseWatchContext,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else {
                return
            }
            let context = Unmanaged<WatchContext>.fromOpaque(info).takeUnretainedValue()
            guard let manager = context.manager else {
                return
            }
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            manager.handleEvents(root: context.root, token: context.token, eventPaths: Array(paths.prefix(numEvents)), onChange: context.onChange)
        }
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [root] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.15,
                flags
            ) else {
            throw NSError(domain: "LiquidCode.DirectoryWatchManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create watcher for \(root)"])
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        let shouldStart = queue.sync {
            desiredWatch == DesiredWatch(root: root, token: token)
        }
        guard shouldStart else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw NSError(domain: "LiquidCode.DirectoryWatchManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to start watcher for \(root)"])
        }
        var committed = false
        let old = queue.sync { () -> [String: Watch] in
            guard desiredWatch == DesiredWatch(root: root, token: token) else {
                return [:]
            }
            let pollTimer = DispatchSource.makeTimerSource(queue: queue)
            pollTimer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(100))
            pollTimer.setEventHandler { [weak self] in
                self?.pollChanges(root: root, token: token, onChange: onChange)
            }
            let watch = Watch(stream: stream, context: contextBox, pollTimer: pollTimer, token: token)
            let old = watches
            watches = [root: watch]
            lastFingerprints = [root: initialSnapshot]
            committed = true
            pollTimer.resume()
            return old
        }
        retire(old)
        guard committed else {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        return true
    }

    func unwatchAll() {
        let old = queue.sync { () -> [String: Watch] in
            let old = watches
            desiredWatch = nil
            watches.removeAll()
            lastFingerprints.removeAll()
            return old
        }
        retire(old)
    }

    func isWatching(_ path: String) -> Bool {
        let root = PathAccessManager.canonicalPath(path)
        return queue.sync { watches[root] != nil }
    }

    private func handleEvents(root: String, token: WatchToken, eventPaths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        guard watches[root]?.token == token else {
            return
        }
        let visibleEvents = eventPaths
            .map { PathAccessManager.canonicalPath($0) }
            .filter { PathAccessManager.path($0, startsWith: root) && !isIgnoredPath($0, root: root) }
        let previous = lastFingerprints[root] ?? snapshotFingerprints(root: root)
        let current = snapshotFingerprints(root: root)
        let diff = Set(diffPaths(previous: previous, current: current, root: root))
        lastFingerprints[root] = current
        if !eventPaths.isEmpty && visibleEvents.isEmpty && diff.isEmpty {
            return
        }
        let changed = Array(diff.union(visibleEvents)).sorted()
        if !changed.isEmpty {
            onChange(changed)
        }
    }

    private func pollChanges(root: String, token: WatchToken, onChange: @escaping @Sendable ([String]) -> Void) {
        guard watches[root]?.token == token else {
            return
        }
        let previous = lastFingerprints[root] ?? snapshotFingerprints(root: root)
        let current = snapshotFingerprints(root: root)
        let changed = diffPaths(previous: previous, current: current, root: root)
        lastFingerprints[root] = current
        if !changed.isEmpty {
            onChange(changed.sorted())
        }
    }

    private func diffPaths(previous: [String: FileFingerprint], current: [String: FileFingerprint], root: String) -> [String] {
        Set(previous.keys)
            .union(current.keys)
            .filter { previous[$0] != current[$0] }
            .filter { PathAccessManager.path($0, startsWith: root) && !isIgnoredPath($0, root: root) }
    }

    private func snapshotFingerprints(root: String) -> [String: FileFingerprint] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else {
            return [root: fingerprint(for: rootURL)]
        }
        var out: [String: FileFingerprint] = [root: fingerprint(for: rootURL)]
        for case let url as URL in enumerator {
            let path = PathAccessManager.canonicalPath(url.path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isIgnoredPath(path, root: root) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            out[path] = fingerprint(for: url)
            if out.count >= 256 {
                break
            }
        }
        return out
    }

    private func fingerprint(for url: URL) -> FileFingerprint {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey])
        return FileFingerprint(
            isDirectory: values?.isDirectory ?? false,
            size: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        )
    }

    private func isIgnoredPath(_ path: String, root: String) -> Bool {
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard pathComponents.count > rootComponents.count else {
            return false
        }
        return pathComponents.dropFirst(rootComponents.count).contains { ignoredSegments.contains($0) }
    }
}

final class FileSystemService {
    private let ignoredNames: Set<String> = [
        ".git",
        ".claude",
        "node_modules",
        "__pycache__",
        ".artifacts",
        ".build",
        ".build-release",
        ".swiftpm",
        ".xcode-derived",
        "DerivedData",
        ".venv",
        "venv",
        "target",
        ".next",
        ".nuxt",
        ".parcel-cache",
        "coverage",
        ".turbo",
        ".svelte-kit",
        "dist",
        "build"
    ]
    private let access: PathAccessManager

    init(access: PathAccessManager = .shared) {
        self.access = access
    }

    func registerWorkspace(_ path: String) {
        access.registerCWD(path)
    }

    func addGrant(sessionID: String, path: String) {
        access.addGrant(sessionID: sessionID, path: path)
    }

    func clearGrants(sessionID: String) {
        access.clearGrants(sessionID: sessionID)
    }

    func loadTree(root: URL, sessionID: String? = nil, maxDepth: Int = 4) throws -> [FileNode] {
        let allowed = try access.validate(root.path, sessionID: sessionID, capability: .read)
        return buildChildren(allowed, depth: 0, maxDepth: maxDepth)
    }

    private func buildChildren(_ url: URL, depth: Int, maxDepth: Int) -> [FileNode] {
        guard
            depth <= maxDepth,
            let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let ld = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rd = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if ld != rd {
                    return ld && !rd
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(
                    name: child.lastPathComponent,
                    path: PathAccessManager.canonicalPath(child.path),
                    isDirectory: isDir,
                    children: isDir ? buildChildren(child, depth: depth + 1, maxDepth: maxDepth) : []
                )
            }
    }

    func readText(_ path: String, sessionID: String? = nil) throws -> String {
        let url = try access.validate(path, sessionID: sessionID, capability: .read)
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(data: Data(data.prefix(512_000)), encoding: .isoLatin1) ?? ""
    }

    func imageInfo(_ path: String, sessionID: String? = nil) throws -> (size: String, dimensions: String) {
        let url = try access.validate(path, sessionID: sessionID, capability: .read)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "unknown size"
        let dimensions = NSImage(contentsOf: url).map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "unknown dimensions"
        return (size, dimensions)
    }

    func exists(_ path: String, sessionID: String? = nil) throws -> Bool {
        let url = try access.validate(path, sessionID: sessionID, capability: .read)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func writeText(_ path: String, text: String, sessionID: String? = nil) throws {
        let url = try access.validate(path, sessionID: sessionID, capability: .write)
        try text.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    func createDirectory(_ path: String, sessionID: String? = nil) throws {
        let url = try access.validate(path, sessionID: sessionID, capability: .write)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func trash(_ path: String, sessionID: String? = nil) throws {
        let url = try access.validate(path, sessionID: sessionID, capability: .delete)
        var resultingURL: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    func delete(_ path: String, sessionID: String? = nil) throws {
        try trash(path, sessionID: sessionID)
    }

    func rename(_ path: String, to newPath: String, sessionID: String? = nil) throws {
        let src = try access.validate(path, sessionID: sessionID, capability: .write)
        let dst = try access.validate(newPath, sessionID: sessionID, capability: .write)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    func reveal(_ path: String, sessionID: String? = nil) throws {
        NSWorkspace.shared.activateFileViewerSelecting([try access.validate(
            path,
            sessionID: sessionID,
            capability: .read
        )]) }

    func open(_ path: String, sessionID: String? = nil) throws {
        NSWorkspace.shared.open(try access.validate(path, sessionID: sessionID, capability: .read))
    }

    func openInVSCode(_ path: String, sessionID: String? = nil) throws {
        Process.launchedProcess(
            launchPath: "/usr/bin/env",
            arguments: ["code", try access.validate(path, sessionID: sessionID, capability: .read).path]
        ) }
}

final class MCPService {
    func loadServers(projectPath: String?) -> [MCPServer] {
        var servers: [MCPServer] = []
        servers += readMCPFile(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"), source: "Claude")
        servers += readMCPFile(AppPaths.shared.mcpFile, source: "LiquidCode")
        if let projectPath {
            servers += readMCPFile(URL(fileURLWithPath: projectPath).appendingPathComponent(".liquidcode/mcp.json"), source: "Project")
        }
        var seen = Set<String>()
        return servers.filter { seen.insert("\($0.source):\($0.name)").inserted }
    }

    func saveAppServers(_ servers: [MCPServer]) throws {
        let obj: [String: Any] = ["mcpServers": Dictionary(uniqueKeysWithValues: servers.map { server in
            var payload: [String: Any] = ["type": server.transport]
            if let command = server.command {
                payload["command"] = command
            }
            if let url = server.url {
                payload["url"] = url
            }
            if !server.args.isEmpty {
                payload["args"] = server.args
            }
            return (server.name, payload)
        })]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: AppPaths.shared.mcpFile, options: [.atomic])
    }

    private func readMCPFile(_ url: URL, source: String) -> [MCPServer] {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawServers = normalizedMCPServers(root["mcpServers"]) else {
            return []
        }
        return rawServers.compactMap { name, raw in
            guard let dict = raw as? [String: Any] else {
                return nil
            }
            let transport = dict["type"] as? String ?? (dict["url"] != nil ? "http" : "stdio")
            return MCPServer(
                name: name,
                transport: transport,
                command: dict["command"] as? String,
                url: dict["url"] as? String,
                args: dict["args"] as? [String] ?? [],
                enabled: true,
                source: source,
                lastError: nil
            )
        }
        .sorted { $0.name < $1.name }
    }

    private func normalizedMCPServers(_ value: Any?) -> [String: Any]? {
        guard let outer = value as? [String: Any] else {
            return nil
        }
        if let inner = outer["mcpServers"] as? [String: Any] {
            return inner
        }
        return outer
    }
}

final class SkillService {
    private let access: PathAccessManager
    init(access: PathAccessManager = .shared) {
        self.access = access
    }

    func loadSkills(projectPath: String?) -> [SkillInfo] {
        var roots: [(URL, String)] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append((home.appendingPathComponent(".claude/skills"), "global"))
        roots.append((home.appendingPathComponent(".config/claude/skills"), "global"))
        if let projectPath {
            roots.append((URL(fileURLWithPath: projectPath).appendingPathComponent(".claude/skills"), "project"))
        }
        var skills: [SkillInfo] = []
        for (root, scope) in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                skills.append(parseSkill(text: text, path: url.path, scope: scope))
            }
        }
        return skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func parseSkill(text: String, path: String, scope: String) -> SkillInfo {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var name = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        var description = ""
        var disabled = false
        var allowedTools: [String] = []
        var model: String?
        var context: String?
        var version: String?
        var activeListKey: String?
        if lines.first == "---" {
            for line in lines.dropFirst() {
                if line == "---" {
                    break
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-"), activeListKey == "allowed_tools" {
                    let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        allowedTools.append(Self.cleanedYAMLScalar(value))
                    }
                    continue
                }
                activeListKey = nil
                if let (key, value) = Self.yamlKeyValue(trimmed) {
                    switch key {
                    case "name":
                        name = Self.cleanedYAMLScalar(value)
                    case "description":
                        description = Self.cleanedYAMLScalar(value)
                    case "disable_model_invocation",
                         "disable-model-invocation":
                        disabled = value.localizedCaseInsensitiveContains("true")
                    case "allowed_tools",
                         "allowed-tools":
                        let parsed = Self.yamlListValue(value)
                        if parsed.isEmpty, value.trimmingCharacters(in: .whitespaces).isEmpty {
                            activeListKey = "allowed_tools"
                        } else {
                            allowedTools.append(contentsOf: parsed)
                        }
                    case "model":
                        model = Self.cleanedYAMLScalar(value)
                    case "context":
                        context = Self.cleanedYAMLScalar(value)
                    case "version":
                        version = Self.cleanedYAMLScalar(value)
                    default:
                        break
                    }
                }
            }
        }
        if description.isEmpty {
            description = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }) ?? ""
        }
        return SkillInfo(
            name: name,
            description: description,
            path: path,
            scope: scope,
            disabled: disabled,
            content: text,
            allowedTools: allowedTools.isEmpty ? nil : allowedTools,
            model: model?.isEmpty == false ? model : nil,
            context: context?.isEmpty == false ? context : nil,
            version: version?.isEmpty == false ? version : nil
        )
    }

    private static func yamlKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            return nil
        }
        return (key, value)
    }

    private static func yamlListValue(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed.dropFirst()
                .dropLast()
                .split(separator: ",")
                .map { cleanedYAMLScalar(String($0)) }
                .filter { !$0.isEmpty }
        }
        return [cleanedYAMLScalar(trimmed)].filter { !$0.isEmpty }
    }

    private static func cleanedYAMLScalar(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment = text.firstIndex(of: "#") {
            text = String(text[..<comment]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    func writeSkill(_ skill: SkillInfo) throws {
        let url = try access.validate(skill.path, sessionID: nil, capability: .write)
        try skill.content.write(to: url, atomically: true, encoding: .utf8)
    }

    func deleteSkill(_ skill: SkillInfo) throws {
        let url = try access.validate(skill.path, sessionID: nil, capability: .delete)
        try FileManager.default.removeItem(at: url)
    }
}

enum SessionJSONLCodec {
    static func parsedObjects(path: String) -> [[String: Any]] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return content.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    static func searchableText(from obj: [String: Any]) -> (role: ChatMessage.Role, text: String)? {
        if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true {
            return nil
        }
        let type = obj["type"] as? String ?? ""
        let message = obj["message"] as? [String: Any]
        let roleRaw = message?["role"] as? String ?? obj["role"] as? String ?? type
        let role: ChatMessage.Role
        if type == "human" || roleRaw == "human" || roleRaw == "user" || type == "user" {
            role = .user
        } else if roleRaw == "assistant" || type == "assistant" {
            role = .assistant
        } else {
            return nil
        }
        let text = extractPlainText(message?["content"] ?? obj["content"])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (role, text)
    }

    struct SessionInfo {
        var preview: String
        var generatedTitle: String
        var cwd: String
        var createdAt: Date?
    }

    private struct HeaderInfo {
        var mtime: TimeInterval
        var info: SessionInfo
    }

    /// Thread-safe cache of parsed session-header info keyed by file path + mtime.
    /// Discovery reads every project's `.jsonl` on a background task; caching by
    /// modification time keeps repeated `reloadSessions()` passes from re-reading
    /// unchanged files (some sessions are multi-MB).
    private final class HeaderInfoCache: @unchecked Sendable {
        private var storage: [String: HeaderInfo] = [:]
        private let lock = NSLock()

        func lookup(path: String, mtime: TimeInterval) -> SessionInfo? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = storage[path], entry.mtime == mtime else {
                return nil
            }
            return entry.info
        }

        func store(path: String, mtime: TimeInterval, info: SessionInfo) {
            lock.lock()
            defer { lock.unlock() }
            storage[path] = HeaderInfo(mtime: mtime, info: info)
        }
    }

    private static let headerCache = HeaderInfoCache()
    // Header info (cwd, timestamp, generated title, first user message) lives in the
    // first handful of records, so we scan only the head of the file rather than whole
    // multi-MB logs. This is the byte budget for that scan; the reader always finishes
    // the record straddling the budget so an oversized inline-image line is never cut.
    private static let headerByteBudget = 128 * 1024

    static func extractSessionInfo(_ url: URL) -> SessionInfo {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        if let cached = headerCache.lookup(path: url.path, mtime: mtime) {
            return cached
        }
        // Scan the head of the file — cwd lives in the first meta line and the first
        // user message is near the top, so we never load whole multi-MB logs. Reading
        // complete lines (never a fixed byte window) is essential: a user message can
        // inline a base64 image hundreds of KB long on a single line, and a mid-line cut
        // would corrupt the JSON so the preview silently falls back to the generic
        // "Claude session" placeholder.
        var preview = ""
        var generatedTitle = ""
        var cwd = ""
        var createdAt: Date?
        for line in readHeadLines(url, byteBudget: headerByteBudget) {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if createdAt == nil {
                createdAt = parseTimestamp(obj["timestamp"])
            }
            if generatedTitle.isEmpty, let title = cliGeneratedTitle(from: obj) {
                generatedTitle = title
            }
            if cwd.isEmpty, let value = obj["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
            if preview.isEmpty, let match = searchableText(from: obj), match.role == .user {
                preview = String(match.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            }
            if createdAt != nil && !generatedTitle.isEmpty && !cwd.isEmpty && !preview.isEmpty {
                break
            }
        }
        let info = SessionInfo(preview: preview, generatedTitle: generatedTitle, cwd: cwd, createdAt: createdAt)
        headerCache.store(path: url.path, mtime: mtime, info: info)
        return info
    }

    private static func cliGeneratedTitle(from obj: [String: Any]) -> String? {
        let containers = [
            obj,
            obj["metadata"] as? [String: Any],
            obj["message"] as? [String: Any]
        ].compactMap { $0 }
        for key in ["customTitle", "aiTitle", "summary", "summaryHint"] {
            for container in containers {
                if let title = cleanedSessionTitle(container[key]) {
                    return title
                }
            }
        }
        return nil
    }

    private static func cleanedSessionTitle(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let title = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(120))
    }

    /// Reads complete newline-delimited lines from the head of the file, scanning about
    /// `byteBudget` bytes. Unlike a fixed byte-window read, a line is only emitted once
    /// its terminating newline is seen, so a record is never truncated mid-way — critical
    /// because a single user message can inline a multi-hundred-KB base64 image, and a cut
    /// there would corrupt the JSON and drop the preview. The budget bounds the scan for
    /// ordinary files (matching the old fixed-window cost); when the budget boundary lands
    /// inside a record, that one straddling line is still read to completion rather than
    /// discarded, so an oversized inline-image line at the head is recovered intact.
    private static func readHeadLines(_ url: URL, byteBudget: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        var lines: [String] = []
        var pending = Data()
        var consumed = 0
        let newline = UInt8(ascii: "\n")
        // Read until the budget is met, then keep reading only until the current record's
        // newline arrives so the straddling line is completed rather than cut.
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            consumed += chunk.count
            pending.append(chunk)
            while let nlIndex = pending.firstIndex(of: newline) {
                let lineData = pending.subdata(in: pending.startIndex ..< nlIndex)
                pending.removeSubrange(pending.startIndex ... nlIndex)
                if let line = String(bytes: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
            // Budget met and the pending record is complete (nothing buffered): stop.
            if consumed >= byteBudget, pending.isEmpty {
                break
            }
        }
        // Emit any trailing unterminated line (file ended without a final newline). A line
        // still pending here is the final partial record of the whole file, not a
        // budget-truncated one, since we only exit the loop with empty pending or at EOF.
        if !pending.isEmpty, let line = String(bytes: pending, encoding: .utf8) {
            lines.append(line)
        }
        return lines
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: trimmed) {
                return date
            }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: trimmed) {
                return date
            }
            if let numeric = Double(trimmed) {
                return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1000 : numeric)
            }
        }
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    static func exportMarkdown(path: String, outputPath: String, conversationOnly: Bool = false) throws {
        var markdown = "# Claude Code Session\n\n*Exported from: \(path)*\n\n---\n\n"
        for obj in parsedObjects(path: path) {
            let type = obj["type"] as? String ?? ""
            let message = obj["message"] as? [String: Any]
            let roleRaw = message?["role"] as? String ?? obj["role"] as? String ?? type
            if type == "human" || type == "user" || roleRaw == "user" || roleRaw == "human" {
                let text = extractPlainText(message?["content"] ?? obj["content"])
                if !conversationOnly || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdown += "## User\n\n\(text)\n\n"
                }
            } else if type == "assistant" || roleRaw == "assistant" {
                let text = renderAssistantMarkdown(message?["content"] ?? obj["content"], conversationOnly: conversationOnly)
                if !conversationOnly || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdown += "## Assistant\n\n\(text)\n\n"
                }
            }
        }
        try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    static func exportJSON(path: String, outputPath: String) throws {
        let objects = parsedObjects(path: path)
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
    }

    static func decodeProjectName(_ encoded: String, fileManager: FileManager = .default) -> String {
        let scalars = Array(encoded.unicodeScalars)
        let isWindowsPath = scalars.count >= 2 && CharacterSet.letters.contains(scalars[0]) && scalars[1] == "-"
        let trimmed: String
        let root: String
        let separator: String
        if isWindowsPath {
            root = "\(String(scalars[0])):\\"
            trimmed = String(String.UnicodeScalarView(scalars.dropFirst(2)))
            separator = "\\"
        } else {
            root = "/"
            trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
            separator = "/"
        }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else {
            return encoded
        }
        var decoded: [String] = []
        var index = 0
        while index < parts.count {
            var bestLength = 1
            var bestSegment = parts[index]
            let parent = decoded.isEmpty ? root : root + decoded.joined(separator: separator)
            let upper = min(parts.count, index + 10)
            var found = false
            if index < upper {
                for end in stride(from: upper, through: index + 1, by: -1) {
                    let slice = Array(parts[index ..< end])
                    for joiner in ["-", " ", "."] {
                        let candidate = slice.joined(separator: joiner)
                        let full = parent + (parent.hasSuffix(separator) ? "" : separator) + candidate
                        if fileManager.fileExists(atPath: full) {
                            bestLength = end - index
                            bestSegment = candidate
                            found = true
                            break
                        }
                    }
                    if found {
                        break
                    }
                }
            }
            if !found && parts[index].isEmpty {
                let start = index
                while index < parts.count && parts[index].isEmpty {
                    index += 1
                }
                let prefix = String(repeating: ".", count: index - start)
                if index < parts.count {
                    var dotFound = false
                    let remainingUpper = min(parts.count, index + 10)
                    for end in stride(from: remainingUpper, through: index + 1, by: -1) {
                        for joiner in ["-", " ", "."] {
                            let candidate = prefix + Array(parts[index ..< end]).joined(separator: joiner)
                            let full = parent + (parent.hasSuffix(separator) ? "" : separator) + candidate
                            if fileManager.fileExists(atPath: full) {
                                decoded.append(candidate)
                                index = end
                                dotFound = true
                                break
                            }
                        }
                        if dotFound {
                            break
                        }
                    }
                    if !dotFound {
                        decoded.append(prefix + parts[index])
                        index += 1
                    }
                } else if var last = decoded.popLast() {
                    last += prefix
                    decoded.append(last)
                }
                continue
            }
            decoded.append(bestSegment)
            index += bestLength
        }
        return root + decoded.joined(separator: separator)
    }

    private static func extractPlainText(_ value: Any?) -> String {
        if claudeControlTranscriptEvent(from: value) != nil {
            return ""
        }
        if let text = value as? String {
            return cleanedTextAndInlineImages(from: text).text
        }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { block in
                let type = block["type"] as? String ?? ""
                if type == "tool_result" || type == "tool_use" || type == "thinking" || type == "image" {
                    return nil
                }
                if type == "text", let text = block["text"] as? String {
                    return cleanedTextAndInlineImages(from: text).text
                }
                if let nested = block["content"] {
                    return extractPlainText(nested)
                }
                return nil
            }
            .joined(separator: " ")
        }
        if let blocks = value as? [Any] {
            return blocks.map { extractPlainText($0) }.joined(separator: " ")
        }
        return ""
    }

    private static func renderAssistantMarkdown(_ value: Any?, conversationOnly: Bool) -> String {
        guard let blocks = value as? [[String: Any]] else {
            return extractPlainText(value)
        }
        return blocks.compactMap { block in
            let type = block["type"] as? String ?? ""
            if type == "text" {
                return block["text"] as? String
            }
            if conversationOnly {
                return nil
            }
            if type == "tool_use" {
                let name = block["name"] as? String ?? "Tool"
                return "**Tool: \(name)**\n\n```json\n\(prettyJSON(block["input"] ?? [:]))\n```"
            }
            return nil
        }
        .joined(separator: "\n\n")
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class SessionIndexService: @unchecked Sendable {
    private let home: URL
    private let fileManager: FileManager

    private struct HistoryProjectCandidate {
        let path: String
        let timestamp: Date
        let order: Int

        func isNewer(than other: HistoryProjectCandidate) -> Bool {
            timestamp > other.timestamp || (timestamp == other.timestamp && order > other.order)
        }
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    func trackedSessionsPath() -> URL {
        home.appendingPathComponent(".liquidcode/tracked_sessions.txt")
    }

    func loadTrackedSessionIDs() -> Set<String> {
        let path = trackedSessionsPath()
        var ids = Set<String>()
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("desk_") {
                    ids.insert(trimmed)
                }
            }
        }
        if ids.isEmpty {
            ids = migrateTrackedIDsFromSessionNames()
        }
        _ = rebuildPathIndexIfNeeded(for: ids)
        writeTrackedSessionIDs(ids)
        return ids
    }

    func trackSession(_ id: String, projectDir: String? = nil, path: String? = nil) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("desk_") else {
            return
        }
        var ids = loadTrackedSessionIDs()
        ids.insert(trimmed)
        var index = loadSessionPathIndex()
        if let path, !path.isEmpty {
            index[trimmed] = path
        } else if
            let projectDir,
            !projectDir.isEmpty {
            index[trimmed] = defaultSessionPath(id: trimmed, projectDir: projectDir).path
        }
        writeTrackedSessionIDs(ids)
        writeSessionPathIndex(index)
    }

    func untrackSession(_ id: String) {
        var ids = loadTrackedSessionIDs()
        ids.remove(id)
        writeTrackedSessionIDs(ids)
        var index = loadSessionPathIndex()
        index.removeValue(forKey: id)
        writeSessionPathIndex(index)
    }

    func listSessions() -> [SessionRecord] {
        let tracked = loadTrackedSessionIDs()
        guard !tracked.isEmpty else {
            return []
        }
        let index = rebuildPathIndexIfNeeded(for: tracked)
        let sessions = tracked.compactMap { id -> SessionRecord? in
            guard let file = sessionPath(for: id, index: index) else {
                return nil
            }
            let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let info = SessionJSONLCodec.extractSessionInfo(file)
            let encodedProject = file.deletingLastPathComponent().lastPathComponent == "sessions"
                ? file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                : file.deletingLastPathComponent().lastPathComponent
            let decodedProjectDir = SessionJSONLCodec.decodeProjectName(encodedProject, fileManager: fileManager)
            let projectDirPath = info.cwd.isEmpty ? decodedProjectDir : info.cwd
            let preview = info.preview.isEmpty ? "Claude session" : info.preview
            return SessionRecord(
                id: id,
                path: file.path,
                project: projectDirPath,
                projectDir: projectDirPath,
                createdAt: info.createdAt ?? attrs?.creationDate ?? attrs?.contentModificationDate,
                modifiedAt: attrs?.contentModificationDate ?? Date.distantPast,
                preview: preview,
                cliResumeID: id,
                generatedTitle: info.generatedTitle.isEmpty ? nil : info.generatedTitle
            )
        }
        return sessions.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.id < rhs.id
        }
    }

    /// Discovers every Claude Code session on disk by scanning `~/.claude/projects`,
    /// independent of the tracked-session allowlist that `listSessions()` uses.
    /// Safe to call off the main thread. `decodeProjectName` is memoized per encoded
    /// directory since it probes the filesystem.
    func discoverAllSessions() -> [SessionRecord] {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard
            let projectDirs = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else {
            return []
        }
        var decodeCache: [String: String] = [:]
        var records: [SessionRecord] = []
        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else {
                continue
            }
            let encoded = projectDir.lastPathComponent
            let decodedProject: String
            if let cached = decodeCache[encoded] {
                decodedProject = cached
            } else {
                decodedProject = SessionJSONLCodec.decodeProjectName(encoded, fileManager: fileManager)
                decodeCache[encoded] = decodedProject
            }
            for file in jsonlFiles(in: projectDir) {
                let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let info = SessionJSONLCodec.extractSessionInfo(file)
                let projectDirPath = info.cwd.isEmpty ? decodedProject : info.cwd
                let id = file.deletingPathExtension().lastPathComponent
                records.append(SessionRecord(
                    id: id,
                    path: file.path,
                    project: projectDirPath,
                    projectDir: projectDirPath,
                    createdAt: info.createdAt ?? attrs?.creationDate ?? attrs?.contentModificationDate,
                    modifiedAt: attrs?.contentModificationDate ?? Date.distantPast,
                    preview: info.preview.isEmpty ? "Claude session" : info.preview,
                    cliResumeID: id,
                    generatedTitle: info.generatedTitle.isEmpty ? nil : info.generatedTitle
                ))
            }
        }
        return records
    }

    func mostRecentProjectDirectory() -> String? {
        if let fromHistory = mostRecentProjectFromHistory() {
            return fromHistory
        }
        return discoverAllSessions()
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return (lhs.createdAt ?? Date.distantPast) > (rhs.createdAt ?? Date.distantPast)
            }
            .first { !$0.projectDir.isEmpty && directoryExists($0.projectDir) }?
            .projectDir
    }

    func deleteSessionRecord(_ session: SessionRecord) throws {
        let cliID = session.cliResumeID ?? (session.id.hasPrefix("desk_") ? nil : session.id)
        defer {
            if let cliID {
                untrackSession(cliID)
            }
        }
        guard let path = session.path, !path.isEmpty else {
            return
        }
        let file = URL(fileURLWithPath: path)
        guard isUnderClaudeProjects(file) else {
            return
        }
        if fileManager.fileExists(atPath: file.path) {
            try trashOrRemove(file)
        }
        let subagentDirectory = file.deletingPathExtension()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: subagentDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try? trashOrRemove(subagentDirectory)
        }
    }

    private func jsonlFiles(in projectDir: URL) -> [URL] {
        var files: [URL] = []
        if let direct = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) {
            files += direct.filter { $0.pathExtension == "jsonl" }
        }
        let sessionsDir = projectDir.appendingPathComponent("sessions", isDirectory: true)
        if let nested = try? fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            files += nested.filter { $0.pathExtension == "jsonl" }
        }
        return files
    }

    private func mostRecentProjectFromHistory() -> String? {
        let history = home.appendingPathComponent(".claude/history.jsonl")
        guard let text = readTail(history, maxBytes: 512 * 1024), !text.isEmpty else {
            return nil
        }
        var best: HistoryProjectCandidate?
        for (offset, line) in text.split(separator: "\n").enumerated() {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rawProject = obj["project"] as? String,
                !rawProject.isEmpty else {
                continue
            }
            let project = PathAccessManager.canonicalPath(rawProject)
            guard directoryExists(project) else {
                continue
            }
            let timestamp = SessionJSONLCodec.parseTimestamp(obj["timestamp"]) ?? Date(timeIntervalSince1970: TimeInterval(offset))
            let candidate = HistoryProjectCandidate(path: project, timestamp: timestamp, order: offset)
            if best.map({ candidate.isNewer(than: $0) }) ?? true {
                best = candidate
            }
        }
        return best?.path
    }

    private func readTail(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(data: data, encoding: .utf8) ?? ""
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex ... firstNewline)
        }
        return text
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isUnderClaudeProjects(_ url: URL) -> Bool {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    private func trashOrRemove(_ url: URL) throws {
        do {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            try fileManager.removeItem(at: url)
        }
    }

    func loadMessages(path: String) -> [ChatMessage] {
        SessionJSONLCodec.parsedObjects(path: path).compactMap { StreamEventParser.messageFromJSONObject($0, fallbackID: UUID().uuidString) }
    }

    /// The `subagents` directory that sits beside a main session jsonl. Given
    /// `.../<enc>/<uuid>.jsonl`, subagent transcripts live in `.../<enc>/<uuid>/subagents/`.
    private func subagentsDirectory(forMainPath mainPath: String) -> URL? {
        let main = URL(fileURLWithPath: mainPath)
        guard main.pathExtension == "jsonl" else {
            return nil
        }
        let sessionUUID = main.deletingPathExtension().lastPathComponent
        let dir = main.deletingLastPathComponent()
            .appendingPathComponent(sessionUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        return directoryExists(dir.path) ? dir : nil
    }

    /// Lazily loads only the lightweight `.meta.json` companions (each ~120 bytes) for a
    /// session's persisted subagents, so opening a session can build subagent shells
    /// without reading the large transcript jsonls. Children are loaded on demand via
    /// `loadSubagentChildCalls(mainPath:agentID:)`.
    func loadSubagentMetas(mainPath: String) -> [SubagentMeta] {
        guard let dir = subagentsDirectory(forMainPath: mainPath) else {
            return []
        }
        guard let entries = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var metas: [SubagentMeta] = []
        for file in entries where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".meta.json") {
            let agentID = file.lastPathComponent
                .replacingOccurrences(of: ".meta.json", with: "")
                .replacingOccurrences(of: "agent-", with: "")
            guard
                let json = try? String(contentsOf: file, encoding: .utf8),
                let meta = SubagentMeta.parse(agentID: agentID, metaJSON: json)
            else {
                continue
            }
            metas.append(meta)
        }
        return metas
    }

    /// Reads a single subagent's transcript jsonl on demand (these can reach ~800KB) and
    /// extracts its internal tool calls as `TranscriptToolItem`s, run through the same
    /// display pipeline as the main transcript so child tools render identically.
    func loadSubagentChildCalls(mainPath: String, agentID: String) -> [TranscriptToolItem] {
        guard let dir = subagentsDirectory(forMainPath: mainPath) else {
            return []
        }
        let file = dir.appendingPathComponent("agent-\(agentID).jsonl")
        guard fileManager.fileExists(atPath: file.path) else {
            return []
        }
        let messages = SessionJSONLCodec.parsedObjects(path: file.path)
            .compactMap { StreamEventParser.messageFromJSONObject($0, fallbackID: UUID().uuidString) }
        return TranscriptDisplayBuilder.displayItems(messages: messages).flatMap { item -> [TranscriptToolItem] in
            switch item {
            case .tool(let tool): [tool]
            case .toolRun(let tools): tools
            default: []
            }
        }
    }

    func exportMarkdown(path: String, outputPath: String, conversationOnly: Bool = false) throws {
        try SessionJSONLCodec.exportMarkdown(path: path, outputPath: outputPath, conversationOnly: conversationOnly)
    }

    func exportJSON(path: String, outputPath: String) throws {
        try SessionJSONLCodec.exportJSON(path: path, outputPath: outputPath)
    }

    static func decodeProjectName(_ encoded: String) -> String {
        SessionJSONLCodec.decodeProjectName(encoded)
    }

    private func migrateTrackedIDsFromSessionNames() -> Set<String> {
        let names = home.appendingPathComponent(".claude/" + "token" + "icode_session_names.json")
        guard
            let data = try? Data(contentsOf: names),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let ids = Set(object.keys.filter { !$0.hasPrefix("desk_") })
        _ = rebuildPathIndexIfNeeded(for: ids)
        let indexedIDs = Set(loadSessionPathIndex().keys)
        return ids.intersection(indexedIDs)
    }

    private func rebuildPathIndexIfNeeded(for ids: Set<String>) -> [String: String] {
        guard !ids.isEmpty else {
            return [:]
        }
        var index = loadSessionPathIndex().filter { fileManager.fileExists(atPath: $0.value) }
        let missing = ids.subtracting(index.keys)
        guard !missing.isEmpty else {
            return index
        }
        for (id, url) in locateTrackedSessionFiles(ids: missing) {
            index[id] = url.path
        }
        writeSessionPathIndex(index)
        return index
    }

    private func locateTrackedSessionFiles(ids: Set<String>) -> [String: URL] {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projectDirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return [:]
        }
        var remaining = ids
        var found: [String: URL] = [:]
        for projectDir in projectDirs {
            guard !remaining.isEmpty else {
                break
            }
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else {
                continue
            }
            for id in remaining {
                let candidates = [
                    projectDir.appendingPathComponent(id).appendingPathExtension("jsonl"),
                    projectDir.appendingPathComponent("sessions").appendingPathComponent(id).appendingPathExtension("jsonl")
                ]
                if let hit = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
                    found[id] = hit
                }
            }
            remaining.subtract(found.keys)
        }
        return found
    }

    private func sessionPath(for id: String, index: [String: String]) -> URL? {
        if let stored = index[id], fileManager.fileExists(atPath: stored) {
            return URL(fileURLWithPath: stored)
        }
        return nil
    }

    private func defaultSessionPath(id: String, projectDir: String) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encodeProjectPath(projectDir), isDirectory: true)
            .appendingPathComponent(id)
            .appendingPathExtension("jsonl")
    }

    private func encodeProjectPath(_ path: String) -> String {
        String(path.map { $0 == "/" || $0 == " " || $0 == "." ? "-" : $0 })
    }

    private func sessionPathIndexURL() -> URL {
        home.appendingPathComponent(".liquidcode/tracked_session_paths.json")
    }

    private func loadSessionPathIndex() -> [String: String] {
        JSONFile.load([String: String].self, from: sessionPathIndexURL()) ?? [:]
    }

    private func writeSessionPathIndex(_ index: [String: String]) {
        let url = sessionPathIndexURL()
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONFile.save(index, to: url)
    }

    private func writeTrackedSessionIDs(_ ids: Set<String>) {
        let path = trackedSessionsPath()
        try? fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = ids.sorted().joined(separator: "\n") + (ids.isEmpty ? "" : "\n")
        try? body.write(to: path, atomically: true, encoding: .utf8)
    }
}

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

struct Shell {
    static func capture(_ launchPath: String, _ args: [String], environment: [String: String]? = nil) -> String? {
        let result = run(launchPath, args, environment: environment)
        guard result.status == 0 else {
            return nil
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func run(_ launchPath: String, _ args: [String], environment: [String: String]? = nil) -> ShellResult {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        if let environment {
            process.environment = environment
        }
        do { try process.run() } catch { return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription) }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ShellResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
