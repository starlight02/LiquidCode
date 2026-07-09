import Foundation

/// Lightweight, fail-soft git probes for the active workspace.
/// Never throws into the UI — non-git directories simply yield `nil`.
enum GitStatusService {
    private static let gitPath = "/usr/bin/git"

    /// Current branch name, or a short detached-HEAD label, or nil when not a repo / git unavailable.
    static func currentBranch(at path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard isRepository(at: trimmed) else {
            return nil
        }
        let branchArgs = ["-C", trimmed, "rev-parse", "--abbrev-ref", "HEAD"]
        if let branch = Shell.capture(gitPath, branchArgs), branch != "HEAD" {
            return branch
        }
        let shortArgs = ["-C", trimmed, "rev-parse", "--short", "HEAD"]
        if let short = Shell.capture(gitPath, shortArgs) {
            return "detached@\(short)"
        }
        return nil
    }

    /// True only when `path` is inside a git work tree (not bare).
    static func isRepository(at path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let args = ["-C", trimmed, "rev-parse", "--is-inside-work-tree"]
        return Shell.capture(gitPath, args) == "true"
    }
}
