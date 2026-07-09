import SwiftUI

/// A user turn that can be restored or forked from.
struct SessionCheckpoint: Identifiable, Equatable, Sendable {
    var id: String
    var messageID: String
    var checkpointUuid: String?
    var preview: String
    var timestamp: Date
    var turnIndex: Int

    var hasClaudeCheckpoint: Bool {
        if let checkpointUuid, !checkpointUuid.isEmpty {
            return true
        }
        return false
    }
}

enum SessionCheckpointBuilder {
    static func checkpoints(from messages: [ChatMessage]) -> [SessionCheckpoint] {
        var result: [SessionCheckpoint] = []
        var turn = 0
        for message in messages where message.role == .user {
            turn += 1
            let preview = message.content
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                SessionCheckpoint(
                    id: message.id,
                    messageID: message.id,
                    checkpointUuid: message.checkpointUuid,
                    preview: preview.isEmpty ? L("User turn") : String(preview.prefix(120)),
                    timestamp: message.timestamp,
                    turnIndex: turn
                )
            )
        }
        return result
    }
}

struct CheckpointTimelineView: View {
    @EnvironmentObject var model: AppModel

    private var checkpoints: [SessionCheckpoint] {
        SessionCheckpointBuilder.checkpoints(from: model.selectedMessages)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            if model.selectedSessionID == nil {
                emptyState(
                    systemImage: "clock.arrow.circlepath",
                    title: L("No session selected"),
                    detail: L("Open a chat to browse restore points.")
                )
            } else if checkpoints.isEmpty {
                emptyState(
                    systemImage: "clock",
                    title: L("No checkpoints yet"),
                    detail: L("User turns appear here as restore and fork points.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(checkpoints) { point in
                                checkpointCard(point)
                                    .id(point.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear { scrollFocused(proxy: proxy) }
                    .onChange(of: model.focusedCheckpointMessageID) { _, _ in
                        scrollFocused(proxy: proxy)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text(L("Checkpoint Timeline"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if !checkpoints.isEmpty {
                    Text("\(checkpoints.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            Text(L("Restore conversation/code to a user turn, or fork a UI-only branch. Fork does not carry model context."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func checkpointCard(_ point: SessionCheckpoint) -> some View {
        let focused = model.focusedCheckpointMessageID == point.messageID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(LF("Turn %d", point.turnIndex))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                if point.hasClaudeCheckpoint {
                    Label(L("Claude checkpoint"), systemImage: "flag.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.mint)
                } else {
                    Text(L("Conversation only"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(point.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(point.preview)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button {
                    model.performRewind(toMessageID: point.messageID, action: .restoreConversation)
                } label: {
                    Label(L("Restore chat"), systemImage: "text.bubble")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L("Remove messages after this turn. Files stay unchanged."))
                if point.hasClaudeCheckpoint {
                    Button {
                        model.performRewind(toMessageID: point.messageID, action: .restoreCode)
                    } label: {
                        Label(L("Restore code"), systemImage: "doc.badge.clock")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(L("Restore workspace files to this Claude checkpoint."))
                    Button {
                        model.performRewind(toMessageID: point.messageID, action: .restoreAll)
                    } label: {
                        Label(L("Restore all"), systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(L("Restore conversation and files to this turn."))
                }
                Spacer()
                Button {
                    model.forkSession(fromMessageID: point.messageID)
                } label: {
                    Label(L("Fork"), systemImage: "arrow.branch")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L("UI-only branch. Next message starts a fresh Claude session."))
            }
        }
        .padding(12)
        .background(focused ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private func scrollFocused(proxy: ScrollViewProxy) {
        guard let id = model.focusedCheckpointMessageID, !id.isEmpty else {
            return
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .top)
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
