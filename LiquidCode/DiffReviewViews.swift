import AppKit
import SwiftUI

/// One code-edit tool payload that can be reviewed as a full diff.
struct SessionDiffEntry: Identifiable, Equatable, Sendable {
    var id: String
    var path: String
    var toolName: String
    var messageID: String
    var diff: String
    var timestamp: Date

    var lineCount: Int {
        diff.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Collects Edit / Write / MultiEdit / Bash-patch diffs from a session transcript.
enum SessionDiffBuilder {
    static func entries(from messages: [ChatMessage]) -> [SessionDiffEntry] {
        var result: [SessionDiffEntry] = []
        for message in messages {
            for (index, block) in message.blocks.enumerated() {
                guard block.kind == .toolUse else {
                    continue
                }
                let toolName = block.toolName ?? message.toolName ?? message.derivedToolName
                let payload = block.inputJSON ?? ""
                guard let diff = toolPayloadDiff(payload, toolName: toolName), !diff.isEmpty else {
                    continue
                }
                let path = filePath(in: payload) ?? pathFromDiffHeader(diff) ?? L("edited file")
                result.append(
                    SessionDiffEntry(
                        id: "\(message.id)#\(index)#\(toolName)",
                        path: path,
                        toolName: toolName,
                        messageID: message.id,
                        diff: diff,
                        timestamp: message.timestamp
                    )
                )
            }
            // Legacy single-tool messages without blocks.
            if message.blocks.isEmpty, let toolName = message.toolName, !toolName.isEmpty {
                let payload = message.content
                if let diff = toolPayloadDiff(payload, toolName: toolName), !diff.isEmpty {
                    let path = filePath(in: payload) ?? pathFromDiffHeader(diff) ?? L("edited file")
                    result.append(
                        SessionDiffEntry(
                            id: "\(message.id)#legacy#\(toolName)",
                            path: path,
                            toolName: toolName,
                            messageID: message.id,
                            diff: diff,
                            timestamp: message.timestamp
                        )
                    )
                }
            }
        }
        return result
    }

    /// Groups entries by path, preserving first-seen path order (latest edits last within a path).
    static func groupedByPath(_ entries: [SessionDiffEntry]) -> [(path: String, entries: [SessionDiffEntry])] {
        var order: [String] = []
        var buckets: [String: [SessionDiffEntry]] = [:]
        for entry in entries {
            if buckets[entry.path] == nil {
                order.append(entry.path)
                buckets[entry.path] = []
            }
            buckets[entry.path, default: []].append(entry)
        }
        return order.map { path in (path, buckets[path] ?? []) }
    }

    static func filePath(in payload: String) -> String? {
        guard let object = toolPayloadObject(payload) else {
            return nil
        }
        if let path = payloadStringPublic(object["file_path"]) ?? payloadStringPublic(object["path"]) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func pathFromDiffHeader(_ diff: String) -> String? {
        for line in diff.split(separator: "\n").prefix(4) {
            let text = String(line)
            if text.hasPrefix("+++ "), !text.contains("/dev/null") {
                return String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func payloadStringPublic(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if value is NSNull {
            return nil
        }
        return String(describing: value)
    }
}

struct SessionDiffReviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var expandedPaths: Set<String> = []

    private var entries: [SessionDiffEntry] {
        SessionDiffBuilder.entries(from: model.selectedMessages)
    }

    private var groups: [(path: String, entries: [SessionDiffEntry])] {
        SessionDiffBuilder.groupedByPath(entries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            if model.selectedSessionID == nil {
                emptyState(systemImage: "doc.text.magnifyingglass", title: L("No session selected"), detail: L("Open a chat to review code edits."))
            } else if groups.isEmpty {
                emptyState(systemImage: "doc.badge.plus", title: L("No diffs yet"), detail: L("Edit, Write, and apply_patch tool calls will appear here."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(groups, id: \.path) { group in
                                fileGroup(group)
                                    .id(group.path)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear {
                        expandFocused(proxy: proxy)
                    }
                    .onChange(of: model.focusedDiffPath) { _, _ in
                        expandFocused(proxy: proxy)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(L("Diff Review"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            Text(L("Code edits from this session, grouped by file."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func fileGroup(_ group: (path: String, entries: [SessionDiffEntry])) -> some View {
        let expanded = expandedPaths.contains(group.path) || model.focusedDiffPath == group.path
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expandedPaths.contains(group.path) {
                    expandedPaths.remove(group.path)
                } else {
                    expandedPaths.insert(group.path)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text((group.path as NSString).lastPathComponent)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(group.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.entries.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if expanded {
                ForEach(group.entries) { entry in
                    entryCard(entry)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func entryCard(_ entry: SessionDiffEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.toolName)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                Text(LF("%d lines", entry.lineCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyDiff(entry.diff)
                } label: {
                    Label(L("Copy"), systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                if FileManager.default.fileExists(atPath: entry.path) {
                    Button {
                        model.openFile(entry.path)
                    } label: {
                        Label(L("Open file"), systemImage: "doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            ToolDiffSectionView(diff: truncatedDiff(entry.diff), tint: .accentColor)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Cap extremely large patches so the inspector stays responsive.
    private func truncatedDiff(_ diff: String, maxLines: Int = 400) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines {
            return diff
        }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        return head + "\n… (\(lines.count - maxLines) more lines truncated)"
    }

    private func copyDiff(_ diff: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diff, forType: .string)
        model.toastSuccess("Copied", L("Diff copied to clipboard"))
    }

    private func expandFocused(proxy: ScrollViewProxy) {
        guard let path = model.focusedDiffPath, !path.isEmpty else {
            return
        }
        expandedPaths.insert(path)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(path, anchor: .top)
            }
        }
    }

    private func emptyState(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary.opacity(0.7))
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
