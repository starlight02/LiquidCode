import SwiftUI

/// Inline transcript card for a Claude subagent spawned through the Agent/Task tool.
/// It replaces the generic JSON tool card with a status-aware, clickable summary that
/// opens the right inspector for the subagent's full internal activity.
struct SubagentCardView: View {
    @EnvironmentObject var model: AppModel
    let activity: SubagentActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: avatarImage, foreground: .white, background: statusColor)
            VStack(alignment: .leading, spacing: 10) {
                header
                if !activity.description.isEmpty {
                    Text(activity.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let summary = activity.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
                HStack(spacing: 8) {
                    Button {
                        openInspector()
                    } label: {
                        Label(L("View details"), systemImage: "sidebar.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)

                    if activity.status == .running {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                            .frame(width: 14, height: 14)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { StandardContentCardBackground(cornerRadius: 16, tint: statusColor) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(statusColor).frame(width: 3) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(activity.subagentType)
                .font(.headline)
                .lineLimit(1)
            statusBadge
            toolCountBadge
            Spacer(minLength: 0)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            StatusDot(color: statusColor)
                .scaleEffect(0.78)
            Text(statusLabel)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.12))
        .foregroundStyle(statusColor)
        .clipShape(Capsule())
    }

    private var toolCountBadge: some View {
        Text(LF("%d tools", activity.childToolUseCount))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.1))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch activity.status {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    private var statusLabel: String {
        switch activity.status {
        case .running: L("Running")
        case .succeeded: L("Succeeded")
        case .failed: L("Failed")
        }
    }

    private var avatarImage: String {
        switch activity.status {
        case .running: "point.3.connected.trianglepath.dotted"
        case .succeeded: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func openInspector() {
        model.focusedSubagentID = activity.id
        model.secondaryTab = .agent
        model.secondaryOpen = true
        if let sessionID = model.selectedSessionID, let agentID = activity.agentID {
            model.loadSubagentChildCallsIfNeeded(sessionID: sessionID, agentID: agentID)
        }
    }
}

/// Right inspector tab for subagent activity. Each subagent is shown as a collapsible
/// section; expanded bodies reuse `ToolDisplayItemView` so child tool calls look and
/// behave exactly like regular transcript tool cards.
struct AgentInspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.selectedSubagentActivities.isEmpty {
                        ContentUnavailableView(
                            L("No sub-agents"),
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text(L("Subagent work appears here when Claude delegates a task."))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    } else {
                        ForEach(model.selectedSubagentActivities) { activity in
                            SubagentActivitySectionView(
                                activity: activity,
                                defaultExpanded: activity.id == model.focusedSubagentID
                            )
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(L("Agents"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("\(model.selectedSubagentActivities.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                Spacer()
            }
            Text(L("Inspect delegated subagent work, status, and internal tool calls."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SubagentActivitySectionView: View {
    @EnvironmentObject var model: AppModel
    let activity: SubagentActivity
    let defaultExpanded: Bool
    @State private var expanded: Bool

    init(activity: SubagentActivity, defaultExpanded: Bool) {
        self.activity = activity
        self.defaultExpanded = defaultExpanded
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
                loadChildrenIfNeeded()
            } label: {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    StatusDot(color: statusColor)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(activity.subagentType)
                                .font(.headline)
                                .lineLimit(1)
                            Text(statusLabel)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(statusColor.opacity(0.12))
                                .foregroundStyle(statusColor)
                                .clipShape(Capsule())
                        }
                        if !activity.description.isEmpty {
                            Text(activity.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(LF("%d tools", activity.childToolUseCount))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                expandedBody
            }
        }
        .padding(12)
        .background { StandardContentCardBackground(cornerRadius: 16, tint: statusColor) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(statusColor).frame(width: 3) }
        .onAppear {
            if defaultExpanded {
                loadChildrenIfNeeded()
            }
        }
        .onChange(of: model.focusedSubagentID) { _, focusedID in
            guard focusedID == activity.id else {
                return
            }
            expanded = true
            loadChildrenIfNeeded()
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        if activity.childToolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if activity.status == .running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Waiting for internal activity…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let summary = activity.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(L("No internal tool calls captured for this subagent."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 22)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(activity.childToolCalls) { tool in
                    ToolDisplayItemView(item: tool, compact: true, autoExpanded: false)
                }
            }
            .padding(.leading, 18)
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    private var statusLabel: String {
        switch activity.status {
        case .running: L("Running")
        case .succeeded: L("Succeeded")
        case .failed: L("Failed")
        }
    }

    private func loadChildrenIfNeeded() {
        guard expanded, let sessionID = model.selectedSessionID, let agentID = activity.agentID else {
            return
        }
        model.loadSubagentChildCallsIfNeeded(sessionID: sessionID, agentID: agentID)
    }
}
