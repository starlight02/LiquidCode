import SwiftUI

/// Shared checklist rows for TodoWrite payloads. Used by the transcript history card
/// and the Plan inspector's "current todos" surface so both stay visually consistent.
struct TodoChecklistRowsView: View {
    let items: [TodoItem]

    var body: some View {
        if items.isEmpty {
            Text(L("Todo list cleared."))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { todo in
                    todoRow(todo)
                }
            }
        }
    }

    @ViewBuilder
    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(color: statusColor(todo.status))
                .alignmentGuide(.firstTextBaseline) { dimension in dimension[.bottom] - 2 }
            Text(rowText(todo))
                .font(.callout)
                .fontWeight(todo.status == .inProgress ? .semibold : .regular)
                .foregroundStyle(todo.status == .completed ? Color.secondary : Color.primary)
                .strikethrough(todo.status == .completed, color: .secondary)
            Spacer(minLength: 0)
        }
    }

    private func rowText(_ todo: TodoItem) -> String {
        // While a task is running the CLI prefers the present-continuous `activeForm`
        // ("Running tests"); pending/completed rows use the imperative `content`.
        if todo.status == .inProgress, !todo.activeForm.isEmpty {
            return todo.activeForm
        }
        return todo.content
    }

    private func statusColor(_ status: TodoItem.Status) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .orange
        case .pending: .secondary
        }
    }
}

/// Inline transcript card for a `TodoWrite` call. Renders the parsed checklist with
/// per-item status dots instead of the raw JSON dump the generic tool card showed.
/// Each TodoWrite in the transcript keeps its own card so the checklist's evolution
/// stays visible on the timeline.
struct TodoListCardView: View {
    let item: TranscriptTodoItem

    private var completedCount: Int {
        item.items.filter { $0.status == .completed }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: "checklist", foreground: .white, background: .accentColor)
            VStack(alignment: .leading, spacing: 10) {
                header
                TodoChecklistRowsView(items: item.items)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { StandardContentCardBackground(cornerRadius: 16, tint: .accentColor) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Todos")).font(.headline)
            if !item.items.isEmpty {
                Text("\(completedCount)/\(item.items.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

/// Read-only inspector surface listing the agent's current checklist (latest TodoWrite)
/// plus every plan drafted this session, parsed from `ExitPlanMode` tool calls rather
/// than string-matched message text. Approval still happens on the composer's inline
/// review card; this panel only shows plan content so it can be read without shrinking
/// the transcript.
struct PlanInspectorView: View {
    @EnvironmentObject var model: AppModel

    private struct PlanEntry: Identifiable {
        let id: String
        let draft: PlanDraft
        let isPending: Bool
    }

    private var planEntries: [PlanEntry] {
        var entries: [PlanEntry] = []
        var seen = Set<String>()
        for message in model.selectedMessages {
            for block in message.blocks where block.kind == .toolUse && block.toolName == "ExitPlanMode" {
                let key = block.toolUseID ?? block.id
                guard seen.insert(key).inserted else {
                    continue
                }
                let draft = PlanPayloadParser.parse(inputJSON: block.inputJSON ?? "", fallbackSummary: "")
                entries.append(PlanEntry(id: "plan_\(message.id)_\(key)", draft: draft, isPending: false))
            }
        }
        for permission in pendingPlanApprovals {
            let key = permission.toolUseID ?? permission.requestID
            guard seen.insert(key).inserted else {
                continue
            }
            let draft = PlanPayloadParser.parse(inputJSON: permission.inputJSON, fallbackSummary: permission.summary)
            entries.append(PlanEntry(id: "plan_pending_\(permission.id)", draft: draft, isPending: true))
        }
        return entries
    }

    private var pendingPlanApprovals: [PermissionRequest] {
        model.pendingPermissionsForSelectedSession.filter { InteractionAdapter(permission: $0).kind == .planReview }
    }

    private var currentTodos: SessionTodoState? {
        model.selectedTodoState
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    currentTodosSection
                    if planEntries.isEmpty && currentTodos == nil {
                        ContentUnavailableView(
                            L("No plan yet"),
                            systemImage: "list.bullet.rectangle",
                            description: Text(L("Switch to Plan mode and let Claude draft a plan, or approve an ExitPlanMode card."))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    }
                    ForEach(Array(planEntries.enumerated()), id: \.element.id) { index, entry in
                        PlanDraftCardView(draft: entry.draft, isPending: entry.isPending, initiallyExpanded: index == planEntries.count - 1)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var currentTodosSection: some View {
        if let state = currentTodos {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .foregroundStyle(Color.accentColor)
                    Text(L("Current todos"))
                        .font(.subheadline.weight(.semibold))
                    if !state.items.isEmpty {
                        Text("\(state.completedCount)/\(state.items.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
                TodoChecklistRowsView(items: state.items)
            }
            .padding(12)
            .background { StandardContentCardBackground(cornerRadius: 12, tint: .accentColor) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(L("Plan"), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if !planEntries.isEmpty {
                    Text("\(planEntries.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                if model.settings.sessionMode == .plan {
                    Text(L("Active"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14))
                        .foregroundStyle(Color.orange)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            Text(L("Current checklist and plans Claude drafted this session. Approve or revise from the composer card."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A single plan draft rendered as a collapsible markdown card, matching the
/// composer review card's visual language (accent tint + leading rule + step count).
private struct PlanDraftCardView: View {
    let draft: PlanDraft
    let isPending: Bool
    @State private var expanded: Bool

    init(draft: PlanDraft, isPending: Bool, initiallyExpanded: Bool) {
        self.draft = draft
        self.isPending = isPending
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                    Text(isPending ? L("Awaiting approval") : L("Plan"))
                        .font(.subheadline.weight(.semibold))
                    if draft.stepCount > 0 {
                        Text(LF("%d steps", draft.stepCount))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(expanded ? L("Collapse plan details") : L("Expand plan details"))
            if expanded {
                MarkdownRendererView(content: draft.markdown).font(.callout)
            }
        }
        .padding(12)
        .background { StandardContentCardBackground(cornerRadius: 12, tint: isPending ? .orange : .accentColor) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(isPending ? Color.orange : Color.accentColor).frame(width: 3) }
    }
}
