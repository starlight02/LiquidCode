import Foundation

/// One configured Claude Code hook entry (read-only inventory).
struct ClaudeHookEntry: Identifiable, Equatable, Sendable {
    var id: String
    var event: String
    var matcher: String
    var command: String
    var source: String
    var isAsync: Bool
}

/// One installed/enabled Claude Code plugin (read-only inventory).
struct ClaudePluginEntry: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var marketplace: String?
    var version: String?
    var enabled: Bool
    var installPath: String?
    var scope: String?
}

/// Scans Claude Code settings and plugin install metadata. Never mutates user config.
enum ClaudeExtensionsService {
    static func loadHooks(projectPath: String?) -> [ClaudeHookEntry] {
        var entries: [ClaudeHookEntry] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userSettings = home.appendingPathComponent(".claude/settings.json")
        entries += hooks(fromSettingsFile: userSettings, source: "User settings")

        if let projectPath, !projectPath.isEmpty {
            let projectSettings = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude/settings.json")
            entries += hooks(fromSettingsFile: projectSettings, source: "Project settings")
        }

        // Hooks declared by installed plugins (enabled or not — still visible).
        for plugin in loadPlugins() {
            guard let installPath = plugin.installPath else {
                continue
            }
            let hooksFile = URL(fileURLWithPath: installPath).appendingPathComponent("hooks/hooks.json")
            entries += hooks(fromPluginHooksFile: hooksFile, source: "Plugin \(plugin.id)")
        }
        return entries
    }

    static func loadPlugins() -> [ClaudePluginEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let enabled = enabledPluginIDs(from: home.appendingPathComponent(".claude/settings.json"))
        let installedURL = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard
            let data = try? Data(contentsOf: installedURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let plugins = root["plugins"] as? [String: Any]
        else {
            // Fall back to enabled-only list if install registry is missing.
            return enabled.sorted().map { id in
                let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
                return ClaudePluginEntry(
                    id: id,
                    name: parts.first ?? id,
                    marketplace: parts.count > 1 ? parts[1] : nil,
                    version: nil,
                    enabled: true,
                    installPath: nil,
                    scope: nil
                )
            }
        }

        var result: [ClaudePluginEntry] = []
        var seen = Set<String>()
        for (id, raw) in plugins {
            let records = raw as? [[String: Any]] ?? []
            let latest = records.last
            let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
            let entry = ClaudePluginEntry(
                id: id,
                name: parts.first ?? id,
                marketplace: parts.count > 1 ? parts[1] : nil,
                version: latest?["version"] as? String,
                enabled: enabled.contains(id),
                installPath: latest?["installPath"] as? String,
                scope: latest?["scope"] as? String
            )
            result.append(entry)
            seen.insert(id)
        }
        // Enabled but not in install registry (edge case).
        for id in enabled where !seen.contains(id) {
            let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
            result.append(
                ClaudePluginEntry(
                    id: id,
                    name: parts.first ?? id,
                    marketplace: parts.count > 1 ? parts[1] : nil,
                    version: nil,
                    enabled: true,
                    installPath: nil,
                    scope: nil
                )
            )
        }
        return result.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    // MARK: - Private parsers

    private static func enabledPluginIDs(from settingsURL: URL) -> Set<String> {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let map = root["enabledPlugins"] as? [String: Any]
        else {
            return []
        }
        var ids = Set<String>()
        for (key, value) in map {
            if let flag = value as? Bool, flag {
                ids.insert(key)
            } else if value is String {
                ids.insert(key)
            }
        }
        return ids
    }

    private static func hooks(fromSettingsFile url: URL, source: String) -> [ClaudeHookEntry] {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else {
            return []
        }
        return parseHookEvents(hooks, source: source, idPrefix: "\(source):\(url.path)")
    }

    private static func hooks(fromPluginHooksFile url: URL, source: String) -> [ClaudeHookEntry] {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        // Plugin hooks.json is either { "hooks": { Event: [...] } } or bare { Event: [...] }.
        let hooks = (root["hooks"] as? [String: Any]) ?? root
        return parseHookEvents(hooks, source: source, idPrefix: "\(source):\(url.path)")
    }

    private static func parseHookEvents(_ hooks: [String: Any], source: String, idPrefix: String) -> [ClaudeHookEntry] {
        var entries: [ClaudeHookEntry] = []
        for (event, raw) in hooks {
            guard let groups = raw as? [[String: Any]] else {
                continue
            }
            for (groupIndex, group) in groups.enumerated() {
                let matcher = (group["matcher"] as? String) ?? ""
                let nested = group["hooks"] as? [[String: Any]] ?? []
                if nested.isEmpty {
                    // Flat form: group itself is a hook command.
                    if let command = hookCommand(group) {
                        entries.append(
                            ClaudeHookEntry(
                                id: "\(idPrefix)#\(event)#\(groupIndex)",
                                event: event,
                                matcher: matcher,
                                command: command,
                                source: source,
                                isAsync: group["async"] as? Bool ?? false
                            )
                        )
                    }
                    continue
                }
                for (hookIndex, hook) in nested.enumerated() {
                    guard let command = hookCommand(hook) else {
                        continue
                    }
                    entries.append(
                        ClaudeHookEntry(
                            id: "\(idPrefix)#\(event)#\(groupIndex)#\(hookIndex)",
                            event: event,
                            matcher: matcher,
                            command: command,
                            source: source,
                            isAsync: hook["async"] as? Bool ?? false
                        )
                    )
                }
            }
        }
        return entries.sorted {
            if $0.event != $1.event {
                return $0.event < $1.event
            }
            return $0.command < $1.command
        }
    }

    private static func hookCommand(_ dict: [String: Any]) -> String? {
        if let command = dict["command"] as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let type = dict["type"] as? String, type != "command" {
            return "[\(type)]"
        }
        return nil
    }
}
