import Foundation

/// In-memory session rule for auto-allowing a later identical tool permission.
/// Never persisted — killed with the session (delete / rewind).
struct SessionPermissionRule: Identifiable, Equatable, Sendable {
    var id: String
    var toolName: String
    /// Normalized match key (Bash command, or file path for Edit/Write/Read).
    var pattern: String
    var risk: PermissionRequest.Risk
    var createdAt: Date
}

/// Pure helpers for session-scoped permission remember. Matching is deliberately
/// conservative: only Bash (exact normalized command) and Edit/Write/Read (exact path).
/// Destructive / network / external MCP / questions / plan reviews never remember.
enum SessionPermissionRemember {
    /// Risks that must never auto-allow or offer "Allow for Session".
    static let blockedRisks: Set<PermissionRequest.Risk> = [
        .destructive, .network, .externalMcp
    ]

    /// Tools whose pattern we know how to extract safely.
    private static let pathTools: Set<String> = ["Edit", "Write", "Read"]

    static func isRememberable(_ permission: PermissionRequest) -> Bool {
        if blockedRisks.contains(permission.risk) {
            return false
        }
        switch InteractionAdapter(permission: permission).kind {
        case .question, .planReview:
            return false
        case .permission:
            break
        }
        return pattern(for: permission) != nil
    }

    /// Builds a rule from a live permission request, or nil when it is not rememberable.
    static func makeRule(from permission: PermissionRequest, now: Date = Date()) -> SessionPermissionRule? {
        guard isRememberable(permission), let pattern = pattern(for: permission) else {
            return nil
        }
        return SessionPermissionRule(
            id: UUID().uuidString,
            toolName: permission.toolName,
            pattern: pattern,
            risk: permission.risk,
            createdAt: now
        )
    }

    static func findMatch(in rules: [SessionPermissionRule], permission: PermissionRequest) -> SessionPermissionRule? {
        guard isRememberable(permission), let pattern = pattern(for: permission) else {
            return nil
        }
        return rules.first { $0.toolName == permission.toolName && $0.pattern == pattern }
    }

    /// Normalized match key for a permission, or nil when we refuse to remember it.
    static func pattern(for permission: PermissionRequest) -> String? {
        let tool = permission.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if tool == "Bash" {
            if let command = stringField(in: permission.inputJSON, keys: ["command", "cmd"]) {
                return normalize(command)
            }
            // Fall back to summary only when it looks like a bare command (not raw JSON).
            let summary = permission.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, !summary.hasPrefix("{") {
                return normalize(summary)
            }
            return nil
        }
        if pathTools.contains(tool) {
            if let path = stringField(in: permission.inputJSON, keys: ["file_path", "filePath", "path"]) {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        return nil
    }

    static func appendRule(_ rule: SessionPermissionRule, to rules: inout [SessionPermissionRule]) {
        if rules.contains(where: { $0.toolName == rule.toolName && $0.pattern == rule.pattern }) {
            return
        }
        rules.append(rule)
    }

    // MARK: - Private

    private static func normalize(_ text: String) -> String? {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func stringField(in inputJSON: String, keys: [String]) -> String? {
        guard
            let data = inputJSON.data(using: .utf8),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        var candidates = [root]
        for nest in ["input", "metadata", "request"] {
            if let nested = root[nest] as? [String: Any] {
                candidates.append(nested)
            }
        }
        for object in candidates {
            for key in keys {
                if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}
