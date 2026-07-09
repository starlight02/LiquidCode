// swiftlint:disable file_length
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

let toolPreviewVisibleLineLimit = 5

func toolPreviewLineCount(_ text: String) -> Int {
    max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
}

func toolPreviewNeedsScroll(_ text: String, visibleLineLimit: Int = toolPreviewVisibleLineLimit) -> Bool {
    toolPreviewLineCount(text) > visibleLineLimit
}

func toolPreviewMaxHeight(fontSize: CGFloat, verticalPadding: CGFloat = 20, visibleLineLimit: Int = toolPreviewVisibleLineLimit) -> CGFloat {
    (fontSize * 1.42 * CGFloat(visibleLineLimit)) + verticalPadding
}

struct ToolDisplayItemView: View {
    @EnvironmentObject var model: AppModel
    let item: TranscriptToolItem
    var compact: Bool
    var autoExpanded: Bool
    @State private var expanded: Bool

    init(item: TranscriptToolItem, compact: Bool = false, autoExpanded: Bool = false) {
        self.item = item
        self.compact = compact
        self.autoExpanded = autoExpanded
        _expanded = State(initialValue: autoExpanded)
    }

    private var payload: String {
        cleanToolPayload(item.content)
    }

    private var displayPayload: String {
        if !payload.isEmpty {
            return payload
        }
        return item.kind == .use ? L("No input payload.") : L("Completed with no textual output.")
    }

    private var parsedJSON: [(String, String)] {
        toolPayloadKeyValues(payload)
    }

    private var payloadObject: [String: Any] {
        toolPayloadObject(payload) ?? [:]
    }

    private func payloadValue(_ key: String) -> String? {
        guard let value = payloadObject[key] else {
            return nil
        }
        let display = toolPayloadDisplayValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? nil : display
    }

    private var tint: Color {
        item.kind == .use ? Color.accentColor : Color.green
    }

    private var icon: String {
        item.kind == .use ? toolIconName(item.toolName) : "checkmark.circle.fill"
    }

    private var codeEditDiff: String? {
        toolPayloadDiff(payload, toolName: item.toolName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            if !compact {
                TranscriptAvatar(
                    systemImage: icon,
                    foreground: tint,
                    background: tint.opacity(0.14)
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down.circle.fill" : icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                        Text(item.summaryName)
                            .font(.caption.weight(.semibold))
                        Text(item.kind == .use ? L("tool use") : L("tool result"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12))
                            .foregroundStyle(tint)
                            .clipShape(Capsule())
                        Text(item.sourceMessage.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(expanded ? L("Collapse tool details") : L("Expand tool details"))

                toolSummary

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.kind == .use ? L("Input payload") : L("Result payload"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ScrollView(.vertical) {
                            Text(displayPayload)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(maxHeight: toolPreviewMaxHeight(fontSize: 12, verticalPadding: 20))
                        .background(Color.primary.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 9 : 11)
            .background { StandardContentCardBackground(cornerRadius: 16, tint: tint) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: compact ? 0 : 60)
        }
        .padding(.vertical, compact ? 0 : 2)
        .onChange(of: autoExpanded) { _, shouldExpand in
            withAnimation(.snappy(duration: 0.18)) {
                expanded = shouldExpand
            }
        }
        .onChange(of: item.id) { _, _ in
            expanded = autoExpanded
        }
    }

    @ViewBuilder private var toolSummary: some View {
        if item.kind == .use {
            if let diff = codeEditDiff {
                VStack(alignment: .leading, spacing: 7) {
                    if let file = payloadValue("file_path") ?? payloadValue("path") {
                        ToolSectionView(title: L("TARGET"), text: file, monospace: true, tint: tint)
                    }
                    ToolDiffSectionView(diff: diff, tint: tint)
                    Button {
                        let path = payloadValue("file_path") ?? payloadValue("path")
                        model.openDiffReview(path: path)
                    } label: {
                        Label(L("Open Full Diff"), systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            } else if let command = payloadValue("command") {
                ToolSectionView(title: L("COMMAND"), text: command, monospace: true, tint: tint)
            } else if let file = payloadValue("file_path") ?? payloadValue("path") {
                VStack(alignment: .leading, spacing: 7) {
                    ToolSectionView(title: L("TARGET"), text: file, monospace: true, tint: tint)
                    compactKeyValueRows
                }
            } else if parsedJSON.isEmpty {
                Text(payload.isEmpty ? L("No input payload.") : payload)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 4)
                    .textSelection(.enabled)
            } else {
                compactKeyValueRows
            }
        } else {
            ToolSectionView(
                title: item.isError ? L("ERROR") : L("OUTPUT"),
                text: displayPayload,
                monospace: shouldRenderResultAsMonospace(displayPayload),
                tint: item.isError ? .red : tint
            )
        }
    }

    private var compactKeyValueRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(parsedJSON.prefix(compact ? 3 : 6)), id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: compact ? 72 : 110, alignment: .leading)
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 3)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct ToolSectionView: View {
    let title: String
    let text: String
    var monospace = false
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            limitedContent
                .background(tint.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.12), lineWidth: 1))
        }
    }

    @ViewBuilder private var limitedContent: some View {
        if toolPreviewNeedsScroll(text) {
            ScrollView(.vertical) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: toolPreviewMaxHeight(fontSize: monospace ? 13 : 14, verticalPadding: 20))
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if monospace {
                Text(text)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            } else {
                MarkdownRendererView(content: text)
                    .font(.callout)
            }
        }
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolDiffSectionView: View {
    let diff: String
    var tint: Color = .accentColor

    private var lines: [String] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("DIFF"))
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            limitedDiff
                .background(tint.opacity(0.050))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.13), lineWidth: 1))
        }
    }

    @ViewBuilder private var limitedDiff: some View {
        if toolPreviewNeedsScroll(diff) {
            ScrollView(.vertical) {
                diffLines
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: toolPreviewMaxHeight(fontSize: 12, verticalPadding: 20))
        } else {
            diffLines
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private var diffLines: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(diffLineColor(line))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return tint.opacity(0.90)
        }
        if line.hasPrefix("+") {
            return .green
        }
        if line.hasPrefix("-") {
            return .red
        }
        return .secondary
    }
}

struct ToolMessageGroupView: View {
    let items: [TranscriptToolItem]
    var autoExpandedToolItemID: String?
    @State private var expanded: Bool

    init(items: [TranscriptToolItem], autoExpandedToolItemID: String? = nil) {
        self.items = items
        self.autoExpandedToolItemID = autoExpandedToolItemID
        _expanded = State(initialValue: autoExpandedToolItemID != nil)
    }

    private var allComplete: Bool {
        TranscriptToolRunCompletion.isComplete(items)
    }

    private var summary: String {
        let names = items.contains { $0.kind == .use } ? items.filter { $0.kind == .use }.map(\.toolName) : items.map(\.summaryName)
        return Dictionary(grouping: names, by: { $0 })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(
                systemImage: allComplete ? "checkmark.seal.fill" : "square.stack.3d.up",
                foreground: allComplete ? .green : .secondary,
                background: (allComplete ? Color.green : Color.primary).opacity(0.10)
            )
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.bold))
                        Text(L("Tool run")).font(.caption.weight(.semibold))
                        Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(LF("%d use / %d result", items.filter { $0.kind == .use }.count, items.filter { $0.kind == .result }.count))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((allComplete ? Color.green : Color.orange).opacity(0.12))
                            .foregroundStyle(allComplete ? Color.green : Color.orange)
                            .clipShape(Capsule())
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(expanded ? L("Collapse tool run") : L("Expand tool run"))
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            ToolDisplayItemView(item: item, compact: true, autoExpanded: item.id == autoExpandedToolItemID)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(10)
            .background { StandardContentCardBackground(cornerRadius: 18, tint: allComplete ? .green : .orange) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 780, alignment: .leading)
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
        .onChange(of: autoExpandedToolItemID) { _, itemID in
            withAnimation(.snappy(duration: 0.18)) {
                expanded = itemID != nil
            }
        }
        .onChange(of: items.map(\.id).joined(separator: "|")) { _, _ in
            if autoExpandedToolItemID != nil {
                expanded = true
            }
        }
    }
}

func cleanToolPayload(_ content: String) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[tool_use:") || first.hasPrefix("[tool_result") else {
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func isCodeEditToolName(_ toolName: String) -> Bool {
    let lower = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return lower == "edit" ||
        lower == "multiedit" ||
        lower == "multi_edit" ||
        lower == "write" ||
        lower == "notebookedit" ||
        lower == "notebook_edit" ||
        lower.contains("apply_patch")
}

func toolPayloadDiff(_ payload: String, toolName: String) -> String? {
    let lowerName = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lowerName == "bash" || lowerName == "shell" {
        return patchDiffFromBashCommand(payload)
    }
    guard isCodeEditToolName(toolName), let object = toolPayloadObject(payload) else {
        return nil
    }
    let filePath = payloadString(object["file_path"]) ?? payloadString(object["path"]) ?? L("edited file")
    if lowerName == "multiedit" || lowerName == "multi_edit" {
        guard let edits = object["edits"] as? [[String: Any]] else {
            return nil
        }
        var chunks: [String] = ["--- \(filePath)", "+++ \(filePath)"]
        for (index, edit) in edits.enumerated() {
            guard let old = payloadString(edit["old_string"]), let new = payloadString(edit["new_string"]) else {
                continue
            }
            chunks.append("@@ edit \(index + 1) @@")
            chunks.append(contentsOf: prefixedDiffLines(oldString: old, newString: new))
        }
        return chunks.count > 2 ? chunks.joined(separator: "\n") : nil
    }
    if lowerName == "write", let content = payloadString(object["content"]) {
        return (["--- /dev/null", "+++ \(filePath)", "@@ new file @@"] + content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+" + String($0) })
            .joined(separator: "\n")
    }
    guard let old = payloadString(object["old_string"]), let new = payloadString(object["new_string"]) else {
        return nil
    }
    return (["--- \(filePath)", "+++ \(filePath)", "@@ replacement @@"] + prefixedDiffLines(oldString: old, newString: new))
        .joined(separator: "\n")
}

private func payloadString(_ value: Any?) -> String? {
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

private func prefixedDiffLines(oldString: String, newString: String) -> [String] {
    let oldLines = oldString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = newString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return oldLines.map { "-" + $0 } + newLines.map { "+" + $0 }
}

private func patchDiffFromBashCommand(_ payload: String) -> String? {
    guard
        let object = toolPayloadObject(payload),
        let command = payloadString(object["command"]),
        command.contains("*** Begin Patch"),
        let start = command.range(of: "*** Begin Patch")
    else {
        return nil
    }
    let patch = String(command[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return patch.isEmpty ? nil : patch
}

func toolPayloadKeyValues(_ payload: String) -> [(String, String)] {
    guard let dict = toolPayloadObject(payload) else {
        return []
    }
    let preferred = ["description", "command", "file_path", "path", "subagent_type", "prompt", "url", "pattern"]
    let keys = preferred.filter { dict[$0] != nil } + dict.keys.sorted().filter { !preferred.contains($0) }
    return keys.compactMap { key in
        guard let raw = dict[key] else {
            return nil
        }
        let value = toolPayloadDisplayValue(raw)
        return (key.replacingOccurrences(of: "_", with: " "), value)
    }
}

func toolPayloadObject(_ payload: String) -> [String: Any]? {
    guard
        let data = payload.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dict = object as? [String: Any] else {
        return nil
    }
    return dict
}

func toolPayloadDisplayValue(_ raw: Any) -> String {
    if let string = raw as? String {
        return string
    }
    if raw is NSNull {
        return "null"
    }
    if let bool = raw as? Bool {
        return bool ? "true" : "false"
    }
    if let number = raw as? NSNumber {
        return number.stringValue
    }
    if
        JSONSerialization.isValidJSONObject(raw),
        let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8) {
        return json
    }
    return String(describing: raw)
}

func toolIconName(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("bash") || lower.contains("shell") {
        return "terminal"
    }
    if lower.contains("read") {
        return "doc.text.magnifyingglass"
    }
    if lower.contains("write") || lower.contains("edit") {
        return "pencil.and.outline"
    }
    if lower.contains("task") || lower.contains("agent") {
        return "point.3.connected.trianglepath.dotted"
    }
    if lower.contains("web") || lower.contains("fetch") {
        return "globe"
    }
    return "wrench.and.screwdriver"
}

func shouldRenderResultAsMonospace(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return false
    }
    if trimmed.contains("\n") && !trimmed.contains("# ") && !trimmed.contains("## ") {
        return true
    }
    return trimmed.contains("error:") || trimmed.contains("warning:") || trimmed.contains("Container ") || trimmed.contains("diff --git")
}

enum InteractionCardKind { case permission, planReview, question }

struct InteractionAdapter {
    let permission: PermissionRequest
    // PermissionRequest currently stores toolName + inputJSON but not the raw
    // control metadata envelope. Parse any mirrored metadata/subtype/input fields
    // from inputJSON first; toolName is only a last-resort UI heuristic.
    var kind: InteractionCardKind {
        if inputContainsQuestions {
            return .question
        }
        if inputContainsPlanReview {
            return .planReview
        }
        if fallbackToolName.contains("askuserquestion") || fallbackToolName.contains("ask_user_question") {
            return .question
        }
        if fallbackToolName.contains("exitplan") || fallbackToolName.contains("plan") {
            return .planReview
        }
        return .permission
    }

    private var fallbackToolName: String {
        permission.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var inputObject: [String: Any]? {
        guard let data = permission.inputJSON.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private var candidateObjects: [[String: Any]] {
        guard let inputObject else {
            return []
        }
        var objects = [inputObject]
        if let metadata = inputObject["metadata"] as? [String: Any] {
            objects.append(metadata)
        }
        if let input = inputObject["input"] as? [String: Any] {
            objects.append(input)
        }
        if let nested = inputObject["request"] as? [String: Any] {
            objects.append(nested)
        }
        return objects
    }

    private var semanticTokens: [String] {
        candidateObjects.flatMap { object in
            ["subtype", "type", "kind", "mode", "action", "tool", "tool_name", "toolName", "name"].compactMap { key in
                (object[key] as? String)?.lowercased()
            }
        }
    }

    private var inputContainsQuestions: Bool {
        candidateObjects.contains { object in object["questions"] != nil || object["question"] != nil || object["options"] != nil }
            || semanticTokens.contains { $0.contains("askuserquestion") || $0.contains("ask_user_question") || $0.contains("question") }
    }

    private var inputContainsPlanReview: Bool {
        candidateObjects.contains { object in
            object["plan"] != nil || object["planContent"] != nil || object["plan_content"] != nil || (object["mode"] as? String)?.lowercased() == "plan"
        } || semanticTokens.contains { $0.contains("exitplan") || $0.contains("exit_plan") || $0.contains("plan_review") }
    }
}

struct InlineInteractionCardView: View {
    let permission: PermissionRequest
    var body: some View {
        switch InteractionAdapter(permission: permission).kind {
        case .question: QuestionInlineCardView(permission: permission)
        case .planReview: PlanReviewInlineCardView(permission: permission)
        case .permission: PermissionInlineCardView(permission: permission)
        }
    }
}

struct ActiveInteractionSlotView: View {
    let permission: PermissionRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Action required"), systemImage: "hand.tap")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            InlineInteractionCardView(permission: permission)
        }
        .padding(.bottom, 4)
    }
}

struct PermissionInlineCardView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    @State private var editedInput = ""
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(color); Text(L("Permission request")).font(.headline); Text(permission.toolName)
                        .font(.caption.monospaced())
                        .padding(
                            .horizontal,
                            6
                        )
                        .padding(.vertical, 2)
                        .background(color.opacity(0.12))
                        .clipShape(Capsule()); Spacer(); Text(permission.risk.rawValue).font(.caption).foregroundStyle(.secondary) } }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(expanded ? L("Collapse permission details") : L("Expand permission details"))
            Text(permission.summary).font(.callout).foregroundStyle(.secondary)
            if expanded {
                TextEditor(text: $editedInput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .onAppear { if editedInput.isEmpty {
                        editedInput = permission.inputJSON
                    } } }
            if toolPayloadDiff(permission.inputJSON, toolName: permission.toolName) != nil {
                Button {
                    let path = SessionDiffBuilder.filePath(in: permission.inputJSON)
                    model.openDiffReview(path: path)
                } label: {
                    Label(L("Open Full Diff"), systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            HStack {
                Button(L("Deny"), role: .destructive) { model.respondPermission(permission, allow: false) }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                Spacer()
                if SessionPermissionRemember.isRememberable(permission) {
                    Button {
                        model.respondPermission(
                            permission,
                            allow: true,
                            editedInput: editedInput.isEmpty ? permission.inputJSON : editedInput,
                            rememberForSession: true
                        )
                    } label: {
                        Label(L("Allow for Session"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                }
                Button {
                    model.respondPermission(permission, allow: true, editedInput: editedInput.isEmpty ? permission.inputJSON : editedInput)
                } label: {
                    Label(L("Allow Once"), systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                .liquidGlassButton(active: true, radius: 11)
            }
        }
        .padding(14)
        .background { StandardContentCardBackground(cornerRadius: 16, tint: color) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .padding(.leading, 44)
    }

    private var icon: String {
        permission.risk == .destructive ? "exclamationmark.triangle.fill" : permission.risk == .shell ? "terminal.fill" : "checkmark.shield.fill"
    }

    private var color: Color {
        permission.risk == .destructive ? .red : permission.risk == .shell ? .orange : .accentColor
    }
}

struct PlanReviewInlineCardView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    var compact: Bool = false
    @State private var expanded = true
    @State private var revisionNote = ""
    private var plan: PlanDraft {
        PlanPayloadParser.parse(inputJSON: permission.inputJSON, fallbackSummary: permission.summary)
    }

    var body: some View {
        let plan = plan
        return VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(Color.accentColor)
                    Text(L("Plan review")).font(.headline)
                    if plan.stepCount > 0 {
                        Text(LF("%d steps", plan.stepCount))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Button {
                        model.secondaryTab = .plan
                        model.secondaryOpen = true
                    } label: {
                        Image(systemName: "sidebar.right").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(L("View plan details in the inspector"))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(expanded ? L("Collapse plan details") : L("Expand plan details"))
            if expanded && !compact {
                MarkdownRendererView(content: plan.markdown).font(.callout)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField(L("Tell Claude how to adjust this plan…"), text: $revisionNote, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1 ... 4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(LiquidGlassToken.hairline, lineWidth: 1)
                    }
                HStack {
                    Button(L("Reject"), role: .destructive) { model.respondPermission(permission, allow: false) }
                        .buttonStyle(.plain)
                        .liquidGlassButton(radius: 11)
                    Button {
                        model.submitPlanRevision(permission, note: revisionNote)
                        revisionNote = ""
                    } label: {
                        Label(L("Send adjustment"), systemImage: "arrow.uturn.left")
                    }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                    .disabled(revisionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button {
                        model.setComposerMode(.code)
                        model.respondPermission(permission, allow: true, editedInput: permission.inputJSON)
                    } label: {
                        Label(L("Approve Plan"), systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .liquidGlassButton(active: true, radius: 11)
                }
            }
        }
        .padding(14)
        .background { StandardContentCardBackground(cornerRadius: 16, tint: .accentColor) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
        .padding(.leading, compact ? 0 : 44)
    }
}

struct QuestionInlineCardView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    @State private var answer = ""
    @State private var selectedOption: String?

    private var question: ParsedQuestionPrompt {
        questionPrompts(from: permission.inputJSON, fallback: permission.summary).first ?? ParsedQuestionPrompt(
            header: L("Question"),
            question: permission.summary,
            options: [],
            multiSelect: false
        )
    }

    private var canSend: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: "questionmark.bubble.fill", foreground: .white, background: .accentColor)
            VStack(alignment: .leading, spacing: 12) {
                QuestionCardHeaderView(title: L("Claude Code question"), subtitle: question.header, isPending: true)
                MarkdownRendererView(content: question.question)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                if !question.options.isEmpty {
                    QuestionOptionsListView(options: question.options, selected: selectedOption) { option in
                        selectedOption = option.label
                        answer = option.label
                    }
                }
                TextField(L("Type an answer"), text: $answer)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LiquidGlassToken.hairline, lineWidth: 1))
                HStack(spacing: 10) {
                    Button(L("Skip")) { model.respondPermission(permission, allow: true, editedInput: questionSkipResponseJSON(permission.inputJSON)) }
                        .buttonStyle(.plain)
                        .liquidGlassButton(radius: 11)
                    Spacer()
                    Button {
                        model.respondPermission(permission, allow: true, editedInput: questionResponseJSON(permission.inputJSON, answer: answer))
                    } label: {
                        Label(L("Send Answer"), systemImage: "arrow.right")
                    }
                    .buttonStyle(.plain)
                    .liquidGlassButton(active: canSend, radius: 11)
                    .disabled(!canSend)
                }
            }
            .padding(16)
            .background { StandardContentCardBackground(cornerRadius: 18, tint: .accentColor) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 720, alignment: .leading)
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
    }
}

struct QuestionTranscriptCardView: View {
    let question: TranscriptQuestionItem

    private var prompt: ParsedQuestionPrompt {
        questionPrompts(from: question.inputJSON, fallback: L("Claude asked a question")).first ?? ParsedQuestionPrompt(
            header: L("Question"),
            question: question.inputJSON,
            options: [],
            multiSelect: false
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: "questionmark.bubble", foreground: Color.accentColor, background: Color.accentColor.opacity(0.14))
            VStack(alignment: .leading, spacing: 11) {
                QuestionCardHeaderView(title: L("Question from Claude Code"), subtitle: prompt.header, isPending: false)
                MarkdownRendererView(content: prompt.question)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                if !prompt.options.isEmpty {
                    QuestionOptionsListView(options: prompt.options, selected: nil, onSelect: nil)
                }
            }
            .padding(14)
            .background { StandardContentCardBackground(cornerRadius: 18, tint: .accentColor) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 720, alignment: .leading)
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
    }
}

struct QuestionCardHeaderView: View {
    let title: String
    let subtitle: String
    let isPending: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: isPending ? "questionmark.bubble.fill" : "questionmark.bubble")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            Text(isPending ? L("Awaiting reply") : L("History"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isPending ? Color.orange : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isPending ? Color.orange : Color.secondary).opacity(0.10), in: Capsule())
        }
    }
}

struct QuestionOptionsListView: View {
    let options: [ParsedQuestionOption]
    let selected: String?
    var onSelect: ((ParsedQuestionOption) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options) { option in
                Button {
                    onSelect?(option)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected == option.label ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected == option.label ? Color.accentColor : Color.secondary.opacity(0.55))
                            .frame(width: 16, height: 18)
                            .padding(.top, 1)
                            .opacity(onSelect == nil && selected == nil ? 0 : 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !option.description.isEmpty {
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, option.description.isEmpty ? 9 : 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (selected == option.label ? Color.accentColor : Color.primary)
                            .opacity(selected == option.label ? 0.14 : 0.045)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(
                                selected == option.label ? Color.accentColor.opacity(0.35) : LiquidGlassToken.hairline,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor(enabled: onSelect != nil)
                .allowsHitTesting(onSelect != nil)
            }
        }
    }
}

struct ParsedQuestionOption: Identifiable, Equatable, Sendable {
    var id: String { label + "\n" + description }
    var label: String
    var description: String
}

struct ParsedQuestionPrompt: Identifiable, Equatable, Sendable {
    var id: String { header + "\n" + question }
    var header: String
    var question: String
    var options: [ParsedQuestionOption]
    var multiSelect: Bool
}

func questionPrompts(from json: String, fallback: String) -> [ParsedQuestionPrompt] {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return []
    }
    let rawQuestions = obj["questions"] as? [[String: Any]] ?? [obj]
    let prompts = rawQuestions.compactMap { raw -> ParsedQuestionPrompt? in
        let question = (raw["question"] as? String ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return nil
        }
        let rawOptions: Any? = raw["options"] ?? obj["options"]
        let options: [ParsedQuestionOption]
        if let strings = rawOptions as? [String] {
            options = strings.map { ParsedQuestionOption(label: $0, description: "") }
        } else if let dicts = rawOptions as? [[String: Any]] {
            options = dicts.compactMap { option in
                let label = (option["label"] as? String ?? option["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else {
                    return nil
                }
                let description = (option["description"] as? String ?? option["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return ParsedQuestionOption(label: label, description: description)
            }
        } else {
            options = []
        }
        return ParsedQuestionPrompt(
            header: (raw["header"] as? String ?? obj["header"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            question: question,
            options: options,
            multiSelect: raw["multiSelect"] as? Bool ?? obj["multiSelect"] as? Bool ?? false
        )
    }
    return prompts.isEmpty && !fallback.isEmpty ? [ParsedQuestionPrompt(header: "", question: fallback, options: [], multiSelect: false)] : prompts
}

func questionResponseJSON(_ input: String, answer: String) -> String {
    var obj: [String: Any] = [:]
    if let data = input.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        obj = parsed
    }
    obj["answer"] = answer; obj["answers"] = ["0": answer]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else {
        return input
    }
    return String(data: data, encoding: .utf8) ?? input
}

func questionSkipResponseJSON(_ input: String) -> String {
    var obj: [String: Any] = [:]
    if let data = input.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        obj = parsed
    }
    obj.removeValue(forKey: "answer")
    obj["answers"] = [String: Any]()
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else {
        return input
    }
    return String(data: data, encoding: .utf8) ?? input
}

enum InputBarPresentation {
    case chat
    case welcome
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let verticalInset: CGFloat
    var onPasteImages: () -> Bool = { false }
    var onSend: () -> Bool = { false }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        textView.onSend = onSend
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.backgroundColor = .clear
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        if let textView = textView as? ComposerNSTextView {
            textView.onPasteImages = onPasteImages
            textView.onSend = onSend
        }
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onPasteImages: (() -> Bool)?
    var onSend: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if onPasteImages?() == true {
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        if shouldSend(with: event) {
            if onSend?() == true {
                return
            }
            return
        }
        super.keyDown(with: event)
    }

    private func shouldSend(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !hasMarkedText() else {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.isDisjoint(with: [.shift, .option, .control, .command])
    }
}

struct InputBarView: View {
    let presentation: InputBarPresentation
    @EnvironmentObject var model: AppModel
    @State private var slashVisible = false
    @State private var slashQuery = ""
    @State private var slashSelectedIndex = 0

    init(presentation: InputBarPresentation = .chat) {
        self.presentation = presentation
    }

    private var slashCommands: [PaletteCommand] {
        model.filteredPaletteCommands(slashQuery).filter { $0.title.hasPrefix("/") || $0.subtitle.localizedCaseInsensitiveContains("slash") } }

    private var canSend: Bool {
        (!model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty) && model.pendingPermissionsForSelectedSession.isEmpty
    }

    private var isBusy: Bool {
        model.selectedHasActiveTurn
    }

    private var editorHeight: CGFloat {
        let rows = max(2, lineCount(model.composerText))
        return min(92, max(56, CGFloat(rows) * 22 + 12))
    }

    private var usesDock: Bool {
        presentation == .chat
    }

    private var inputTextInset: CGFloat {
        9
    }

    private var barMaxWidth: CGFloat {
        usesDock ? LiquidGlassToken.chatMaxWidth : LiquidGlassToken.composerMaxWidth
    }

    private var projectSelectionTitle: String {
        guard !model.workingDirectory.isEmpty else {
            return L("Project")
        }
        return URL(fileURLWithPath: model.workingDirectory).lastPathComponent
    }

    var body: some View {
        VStack(spacing: usesDock ? 10 : 8) {
            if let activeInteraction = model.pendingPermissionsForSelectedSession.first {
                ActiveInteractionSlotView(permission: activeInteraction)
                    .frame(maxWidth: barMaxWidth)
            }
            if slashVisible {
                SlashCommandPopoverView(commands: slashCommands, query: slashQuery, selectedIndex: slashSelectedIndex, onSelect: selectSlashCommand)
                    .frame(maxWidth: barMaxWidth, alignment: .leading)
            }
            if !model.attachments.isEmpty {
                FileUploadChipsNativeView()
                    .padding(.horizontal, usesDock ? 16 : 22)
                    .frame(maxWidth: barMaxWidth, alignment: .leading)
            }

            VStack(spacing: usesDock ? 12 : 10) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        if model.composerText.isEmpty {
                            Text(isBusy ? L("Add a follow-up while Claude works...") :
                                model.workingDirectory.isEmpty ? L("Type a message to start...") :
                                L("Add message..."))
                                .foregroundStyle(.tertiary)
                                .font(.system(size: max(15, model.settings.fontSize)))
                                .padding(.top, inputTextInset)
                        }
                        ComposerTextView(
                            text: Binding(get: { model.composerText }, set: { model.updateComposerText($0) }),
                            fontSize: max(15, model.settings.fontSize),
                            verticalInset: inputTextInset,
                            onPasteImages: { model.attachImagesFromPasteboard() },
                            onSend: {
                                guard canSend else {
                                    return false
                                }
                                model.sendComposer()
                                return true
                            }
                        )
                        .frame(height: editorHeight)
                        .onChange(of: model.composerText) { _, value in updateSlashState(value) }
                        .background(SlashKeyboardBridge(
                            isActive: slashVisible,
                            commandCount: min(12, slashCommands.count),
                            onMove: { delta in moveSlashSelection(delta) },
                            onSelect: { selectCurrentSlashCommand() },
                            onClose: { slashVisible = false }
                        ))
                    }
                    if isBusy {
                        Button {
                            model.interrupt()
                        } label: {
                            composerActionIcon(systemImage: "stop.fill", fill: Color.red.opacity(0.18), foreground: .red)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(L("Stop current turn"))
                    } else {
                        Button {
                            model.sendComposer()
                        } label: {
                            composerActionIcon(
                                systemImage: "arrow.right",
                                fill: canSend ? Color.primary.opacity(0.88) : Color.primary.opacity(0.14),
                                foreground: canSend ? .white : .secondary
                            )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: [])
                        .pointingHandCursor(enabled: canSend)
                        .disabled(!canSend)
                        .help(model.pendingPermissionsForSelectedSession.isEmpty ? L("Send (Return)") : L("Respond to inline card first"))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlassControl(
                    RoundedRectangle(cornerRadius: 30, style: .continuous),
                    active: isBusy,
                    interactive: false,
                    fallbackRadius: 30,
                    fallbackIntensity: .subtle
                )
                .shadow(color: .black.opacity(usesDock ? 0.08 : 0), radius: usesDock ? 16 : 0, y: usesDock ? 6 : 0)
                .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
                    model.attachDroppedProviders(providers)
                }

                GeometryReader { proxy in
                    let compact = proxy.size.width < 720
                    let needsScroll = proxy.size.width < 520

                    if needsScroll {
                        ScrollView(.horizontal, showsIndicators: false) {
                            bottomToolbar(compact: true)
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                        }
                    } else {
                        bottomToolbar(compact: compact)
                            .frame(width: proxy.size.width, alignment: .leading)
                    }
                }
                .frame(height: GlassControlMetric.iconButtonSize)
            }
            .padding(.horizontal, usesDock ? 16 : 22)
            .padding(.top, usesDock ? 14 : 0)
            .padding(.bottom, usesDock ? 12 : 0)
            .frame(maxWidth: barMaxWidth)
            .background {
                if usesDock {
                    LiquidComposerDock(cornerRadius: 38, active: isBusy)
                }
            }
            .shadow(color: .black.opacity(usesDock ? 0.10 : 0), radius: usesDock ? 28 : 0, y: usesDock ? 14 : 0)
        }
        .padding(.horizontal, usesDock ? 24 : 12)
        .padding(.top, usesDock ? 10 : 8)
        .padding(.bottom, usesDock ? 14 : 0)
        .frame(maxWidth: .infinity)
    }

    private func composerActionIcon(systemImage: String, fill: Color, foreground: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .bold))
            .frame(width: 44, height: 44)
            .background(fill)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func bottomToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            projectPickerButton(compact: compact)
            ToolbarIconButton(systemImage: "paperclip", help: "Attach files") { model.attachFiles() }

            let modeActive = model.settings.sessionMode == .plan || model.settings.sessionMode == .bypass
            HStack(spacing: compact ? 8 : 10) {
                Menu {
                    ForEach(SessionMode.allCases) { mode in
                        Button { model.setComposerMode(mode) } label: {
                            Label(mode.label, systemImage: model.settings.sessionMode == mode ? "checkmark" : modeIcon(mode))
                        }
                    }
                } label: {
                    NativeToolbarMenuLabel(
                        title: compact ? "" : model.settings.sessionMode.label,
                        systemImage: modeIcon(model.settings.sessionMode),
                        active: modeActive,
                        minWidth: compact ? 38 : 74
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L("Select mode"))

                let thinkingActive = model.settings.thinkingLevel != .off
                Menu {
                    ForEach(ThinkingLevel.allCases) { level in
                        Button { model.setComposerThinkingLevel(level) } label: {
                            Label(level.label, systemImage: model.settings.thinkingLevel == level ? "checkmark" : thinkingIcon(level))
                        }
                    }
                } label: {
                    NativeToolbarMenuLabel(
                        title: compact ? "" : model.settings.thinkingLevel.label,
                        systemImage: thinkingIcon(model.settings.thinkingLevel),
                        active: thinkingActive,
                        minWidth: compact ? 38 : 76
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L("Select thinking level"))
            }

            HStack(spacing: compact ? 8 : 10) {
                Menu {
                    ForEach(RewindAction.allCases) { action in
                        Button {
                            model.performRewind(action)
                        } label: {
                            Label(action.label, systemImage: action.systemImage)
                        }
                        .disabled(model.selectedLastUserMessage == nil)
                    }
                } label: {
                    NativeToolbarMenuLabel(
                        title: compact ? "" : L("Rewind"),
                        systemImage: "arrow.counterclockwise",
                        disabled: model.selectedLastUserMessage == nil,
                        minWidth: compact ? 38 : 84
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor(enabled: model.selectedLastUserMessage != nil)
                .disabled(model.selectedLastUserMessage == nil)
                .help(L("Restore conversation, code, both, or prepare a summary from the last user turn"))

                Menu {
                    ForEach(model.skills) { skill in
                        Button("/\(skill.name)") {
                            model.updateComposerText("/\(skill.name) ")
                            updateSlashState(model.composerText)
                        }
                    }
                    if model.skills.isEmpty {
                        Button(L("No skills loaded")) {}.disabled(true)
                    }
                } label: {
                    NativeToolbarMenuLabel(title: compact ? "" : L("Skills"), systemImage: "sparkles", minWidth: compact ? 38 : 78)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(L("Insert skill slash command"))
            }

            Spacer(minLength: compact ? 6 : 12)

            Menu {
                ForEach(defaultModels, id: \.self) { option in
                    Button { model.setComposerModel(option) } label: {
                        Label(model.modelMenuDisplayName(option), systemImage: model.isComposerModelSelected(option) ? "checkmark" : "circle")
                    }
                }
            } label: {
                NativeToolbarMenuLabel(
                    title: model.modelToolbarDisplayName(model.settings.selectedModel, compact: compact),
                    systemImage: "clock",
                    minWidth: compact ? 74 : 142
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(L("Select model"))
        }
    }

    private func projectPickerButton(compact: Bool) -> some View {
        Menu {
            Button {
                model.chooseWorkingDirectory()
            } label: {
                Label(L("Choose Folder…"), systemImage: "folder.badge.plus")
            }
            Button {
                model.selectMostRecentClaudeProject()
            } label: {
                Label(L("Use Claude Recent Project"), systemImage: "clock.arrow.circlepath")
            }
            if !model.workingDirectory.isEmpty {
                Divider()
                Button(role: .destructive) {
                    model.clearWorkingDirectory()
                } label: {
                    Label(L("Clear Project"), systemImage: "xmark.circle")
                }
            }
        } label: {
            NativeToolbarMenuLabel(
                title: compact ? "" : projectSelectionTitle,
                systemImage: model.workingDirectory.isEmpty ? "folder.badge.plus" : "folder.fill",
                active: !model.workingDirectory.isEmpty,
                minWidth: compact ? 38 : (model.workingDirectory.isEmpty ? 88 : 118)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(model.workingDirectory.isEmpty ? L("Choose a project folder or start with Claude Code's default directory") : model.workingDirectory)
    }

    private func updateSlashState(_ text: String) {
        if let query = SlashCommandParser.query(from: text) {
            slashVisible = true
            slashQuery = query
            slashSelectedIndex = min(slashSelectedIndex, max(0, min(12, slashCommands.count) - 1))
        } else {
            slashVisible = false
            slashQuery = ""
            slashSelectedIndex = 0
        }
    }

    private func moveSlashSelection(_ delta: Int) {
        let count = min(12, slashCommands.count)
        guard count > 0 else {
            slashSelectedIndex = 0; return
        }
        slashSelectedIndex = (slashSelectedIndex + delta + count) % count
    }

    private func selectCurrentSlashCommand() {
        let commands = Array(slashCommands.prefix(12))
        guard commands.indices.contains(slashSelectedIndex) else {
            return
        }
        selectSlashCommand(commands[slashSelectedIndex])
    }

    private func selectSlashCommand(_ command: PaletteCommand) {
        switch command.kind {
        case .sendSlash(let slash): model.updateComposerText(slash + " ")
        default: model.runCommand(command)
        }
        slashVisible = false
        slashSelectedIndex = 0
    }
}

struct SlashKeyboardBridge: NSViewRepresentable {
    var isActive: Bool
    var commandCount: Int
    var onMove: (Int) -> Void
    var onSelect: () -> Void
    var onClose: () -> Void
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isActive: isActive, commandCount: commandCount, onMove: onMove, onSelect: onSelect, onClose: onClose)
    }

    final class Coordinator {
        private var monitor: Any?
        private var onMove: ((Int) -> Void)?
        private var onSelect: (() -> Void)?
        private var onClose: (() -> Void)?
        private var currentCommandCount = 0

        func update(isActive: Bool, commandCount: Int, onMove: @escaping (Int) -> Void, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
            currentCommandCount = commandCount
            self.onMove = onMove
            self.onSelect = onSelect
            self.onClose = onClose
            if !isActive {
                removeMonitor()
                return
            }
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else {
                        return event
                    }
                    if MainActor.assumeIsolated({ Self.textInputHasMarkedText() }) {
                        return event
                    }
                    switch event.keyCode {
                    case 126 where currentCommandCount > 0: self.onMove?(-1); return nil
                    case 125 where currentCommandCount > 0: self.onMove?(1); return nil
                    case 36 where currentCommandCount > 0: self.onSelect?(); return nil
                    case 53: self.onClose?(); return nil
                    default: return event
                    }
                }
            }
        }

        @MainActor static func textInputHasMarkedText() -> Bool {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
                return false
            }
            return textView.hasMarkedText()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor); self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }

}

struct SlashCommandPopoverView: View {
    let commands: [PaletteCommand]
    let query: String
    let selectedIndex: Int
    let onSelect: (PaletteCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: "slash.circle"); Text(query.isEmpty ? L("Commands") : LF("Commands matching /%@", query)).font(.caption.bold()); Spacer() }
                .foregroundStyle(.secondary)
            ForEach(Array(commands.prefix(12).enumerated()), id: \.element.id) { index, command in
                Button { onSelect(command) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.title).font(.system(.callout, design: .monospaced).weight(.semibold))
                        Text(command.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            if commands.isEmpty {
                Text(LF("No command matches /%@", query)).font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.18)))
    }
}

struct FileUploadChipsNativeView: View {
    @EnvironmentObject var model: AppModel
    private var imageAttachments: [AttachmentChip] {
        model.attachments.filter(\.isImage)
    }

    private var fileAttachments: [AttachmentChip] {
        model.attachments.filter { !$0.isImage }
    }

    private var hasImages: Bool {
        !imageAttachments.isEmpty
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: hasImages ? 12 : 10) {
                ForEach(imageAttachments) { attachment in
                    ComposerImageAttachmentCard(attachment: attachment)
                }
                ForEach(fileAttachments) { attachment in
                    AttachmentChipView(attachment: attachment)
                }
            }
            .padding(.horizontal, hasImages ? 10 : 3)
            .padding(.vertical, hasImages ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .frame(height: hasImages ? 88 : 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ComposerImageAttachmentMetric {
    static let width: CGFloat = 104
    static let height: CGFloat = 72
    static let radius: CGFloat = 20
    static let closeSize: CGFloat = 27
}

struct ComposerImageAttachmentCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let attachment: AttachmentChip

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ComposerImageAttachmentMetric.radius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(width: ComposerImageAttachmentMetric.width, height: ComposerImageAttachmentMetric.height)
                .clipShape(shape)
                .background { cardBase }
                .overlay { cardChrome }
                .contentShape(shape)
                .onTapGesture(perform: openAttachmentPreview)
                .accessibilityLabel(attachment.name)

            removeButton
                .padding(4)
        }
        .frame(
            width: ComposerImageAttachmentMetric.width + 8,
            height: ComposerImageAttachmentMetric.height + 8,
            alignment: .center
        )
        .help(attachment.path)
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = NSImage(contentsOfFile: attachment.path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: ComposerImageAttachmentMetric.width, height: ComposerImageAttachmentMetric.height)
        } else {
            unavailableThumbnail
        }
    }

    private var unavailableThumbnail: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.secondary.opacity(colorScheme == .dark ? 0.22 : 0.12),
                    Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 5) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 22, weight: .semibold))
                Text(L("Unavailable"))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.secondary)
        }
    }

    private var cardBase: some View {
        shape
            .fill(.thinMaterial)
            .overlay {
                shape.fill(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.26))
            }
            .shadow(color: .white.opacity(colorScheme == .dark ? 0.04 : 0.42), radius: 11, x: -5, y: -5)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.13), radius: 15, x: 0, y: 8)
    }

    private var cardChrome: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.26),
                    Color.clear,
                    Color.black.opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)

            Text(attachment.name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.48), radius: 4, x: 0, y: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.34 : 0.58),
                        Color.white.opacity(0.13),
                        Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.9
            )
        }
    }

    private var removeButton: some View {
        Button { model.removeAttachment(attachment) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: ComposerImageAttachmentMetric.closeSize, height: ComposerImageAttachmentMetric.closeSize)
                .liquidGlassControl(
                    Circle(),
                    interactive: false,
                    fallbackRadius: ComposerImageAttachmentMetric.closeSize / 2,
                    fallbackIntensity: .regular
                )
                .overlay(Circle().stroke(Color.white.opacity(colorScheme == .dark ? 0.24 : 0.42), lineWidth: 0.8))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(L("Remove attachment"))
    }

    private func openAttachmentPreview() {
        guard let reference = MessageImageReference.reference(fromSource: attachment.path) else {
            model.toastWarning("Image unavailable", attachment.path)
            return
        }
        model.openImageLightbox(reference)
    }
}

struct SecondaryPanelView: View {
    @EnvironmentObject var model: AppModel
    var onClose: () -> Void = {}
    var body: some View {
        GlassPanel(role: .inspector, prominence: .regular, cornerRadius: LiquidGlassToken.panelRadius) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(SecondaryTab.allCases) { tab in
                        Button { model.secondaryTab = tab } label: {
                            Label(tab.label, systemImage: tab.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.secondaryTab == tab ? Color.white : Color.primary.opacity(0.74))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .liquidGlassControl(
                                    Capsule(),
                                    active: model.secondaryTab == tab,
                                    fallbackRadius: 16,
                                    fallbackIntensity: model.secondaryTab == tab ? .prominent : .subtle
                                )
                        }
                        .buttonStyle(.plain)
                        .help(tab.label)
                    }
                    Spacer()
                    ToolbarIconButton(systemImage: "xmark", help: "Close panel", action: onClose)
                }
                .padding(.horizontal, 14)
                .frame(height: ShellMetric.topBarHeight)
                Divider()
                switch model.secondaryTab {
                case .files: FilePanelView()
                case .plan: PlanInspectorView()
                case .agent: AgentInspectorView()
                case .skills: SkillsPanelView()
                case .diffs: SessionDiffReviewView()
                case .timeline: CheckpointTimelineView()
                }
            }
        }
    }
}

struct FilePanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var fileSearchText = ""
    private var searchResults: [FileNode] {
        flattenFileNodes(model.fileTree, query: fileSearchText)
    }

    private var showingSearchResults: Bool {
        !fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var deletedChangeBadges: [(String, String)] {
        model.fileChangeBadges.filter { $0.value == "D" }.sorted { $0.key < $1.key }
    }

    private var changedCount: Int {
        model.changedFiles.count + model.fileChangeBadges.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            if model.workingDirectory.isEmpty {
                emptyState
            } else {
                if let branch = model.gitBranch, !branch.isEmpty {
                    gitBranchRow(branch)
                }
                if changedCount > 0 {
                    thisTurnSummary
                }
                if !deletedChangeBadges.isEmpty {
                    deletedBadges
                }
                GlassSearchField(placeholder: "Search files...", text: $fileSearchText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if showingSearchResults {
                            if searchResults.isEmpty {
                                ContentUnavailableView(L("No files match"), systemImage: "magnifyingglass", description: Text(fileSearchText))
                                    .padding(.vertical, 24)
                            } else {
                                ForEach(searchResults) { SearchFileResultRowView(node: $0, rootPath: model.workingDirectory) }
                            }
                        } else if model.fileTree.isEmpty {
                            ContentUnavailableView(L("Empty project"), systemImage: "folder", description: Text(L("Create a file or refresh the tree.")))
                                .padding(.vertical, 28)
                        } else {
                            ForEach(model.fileTree) { FileNodeView(node: $0) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .contextMenu {
                    Button(L("New file")) { createFile() }
                    Button(L("New folder")) { createFolder() }
                    Button(L("Refresh")) { model.reloadFileTree() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(model.workingDirectory.isEmpty ? L("Files") : URL(fileURLWithPath: model.workingDirectory).lastPathComponent)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if changedCount > 0 {
                    Text(LF("%d changed", changedCount))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.mint.opacity(0.16))
                        .foregroundStyle(.mint)
                        .clipShape(Capsule())
                }
                Spacer()
                HStack(spacing: 10) {
                    ToolbarIconButton(systemImage: "doc.badge.plus", help: "New file", disabled: model.workingDirectory.isEmpty) { createFile() }
                    ToolbarIconButton(systemImage: "folder.badge.plus", help: "New folder", disabled: model.workingDirectory.isEmpty) { createFolder() }
                    ToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh files", disabled: model.workingDirectory.isEmpty) { model.reloadFileTree() }
                }
            }
            if !model.workingDirectory.isEmpty {
                Text((model.workingDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func gitBranchRow(_ branch: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(branch)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help(L("Git branch"))
    }

    private var thisTurnSummary: some View {
        Button {
            model.openDiffReview()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.mint)
                Text(L("This turn"))
                    .font(.caption.weight(.semibold))
                Text(LF("%d changed", changedCount))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.mint.opacity(0.16))
                    .foregroundStyle(.mint)
                    .clipShape(Capsule())
                Spacer(minLength: 0)
                Text(L("Open Full Diff"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary.opacity(0.7))
            Text(L("Select a project from the welcome screen to browse files"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var deletedBadges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(deletedChangeBadges, id: \.0) { path, badge in
                    HStack(spacing: 4) { Text(badge); Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1) }
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                        .help(path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 34)
    }

    private func createFile() {
        if let name = promptForFileName(title: L("New file"), defaultValue: "untitled.txt") {
            model.createFile(inDirectory: model.workingDirectory, named: name)
        }
    }

    private func createFolder() {
        if let name = promptForFileName(title: L("New folder"), defaultValue: "untitled") {
            model.createFolder(inDirectory: model.workingDirectory, named: name)
        }
    }
}

struct FileNodeView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    var body: some View {
        if node.isDirectory {
            DisclosureGroup { ForEach(node.children) { FileNodeView(node: $0) } } label: { FileNodeLabelView(node: node, icon: "folder") }
                .pointingHandCursor()
                .help(node.path)
                .contextMenu {
                    Button(L("New file here")) { model.createFile(inDirectory: node.path) }
                    Button(L("New folder here")) { if let name = promptForFileName(title: L("New folder"), defaultValue: "untitled") {
                        model.createFolder(
                            inDirectory: node.path,
                            named: name
                        ) } }
                    Button(L("Rename")) { if let name = promptForFileName(title: L("Rename"), defaultValue: node.name) {
                        model.requestRenameFile(node.path, to: name)
                    } }
                    Button(L("Reveal")) { model.requestRevealFile(node.path) }
                    Button(L("Open")) { model.requestOpenExternalFile(node.path) }
                    Button(L("Insert Path")) { model.requestInsertFilePath(node.path) }
                    Divider()
                    Button(L("Delete"), role: .destructive) { model.requestDeleteFile(node.path) }
                }
        } else {
            Button { _ = model.requestOpenFile(node.path) } label: { FileNodeLabelView(node: node, icon: icon) }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(node.path)
                .contextMenu {
                    Button(L("Preview")) { _ = model.requestOpenFile(node.path) }
                    Button(L("Insert Path")) { model.requestInsertFilePath(node.path) }
                    Button(L("Insert Content")) { model.requestInsertFileContent(node.path) }
                    Button(L("Copy Path")) { model.requestCopyFilePath(node.path) }
                    Button(L("Rename")) { if let name = promptForFileName(title: L("Rename"), defaultValue: node.name) {
                        model.requestRenameFile(node.path, to: name)
                    } }
                    Button(L("Reveal")) { model.requestRevealFile(node.path) }
                    Button(L("Open")) { model.requestOpenExternalFile(node.path) }
                    Button(L("Share")) { model.requestShareFile(node.path) }
                    Divider()
                    Button(L("Delete"), role: .destructive) { model.requestDeleteFile(node.path) }
                }
        }
    }

    private var icon: String {
        fileIconName(for: node.name, isDirectory: false)
    }
}

struct SearchFileResultRowView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let rootPath: String
    var body: some View {
        Button { if node.isDirectory {
            openDirectory()
        } else {
            _ = model.requestOpenFile(node.path)
        } } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(fileIconColor(for: node.name, isDirectory: node.isDirectory))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).lineLimit(1)
                    Text(parentContext).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let badge = model.fileChangeBadges[node.path] ?? (model.changedFiles.contains(node.path) ? "M" : nil) {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(changeColor(for: badge).opacity(0.14))
                        .foregroundStyle(changeColor(for: badge))
                        .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu }
        .liquidGlassRow(active: model.selectedFilePath == node.path, radius: 10)
    }

    @ViewBuilder private var contextMenu: some View {
        if node.isDirectory {
            Button(L("New file here")) { model.createFile(inDirectory: node.path) }
            Button(L("New folder here")) { if let name = promptForFileName(title: L("New folder"), defaultValue: "untitled") {
                model.createFolder(inDirectory: node.path, named: name)
            } }
            Button(L("Rename")) { if let name = promptForFileName(title: L("Rename"), defaultValue: node.name) {
                model.requestRenameFile(node.path, to: name)
            } }
            Button(L("Reveal")) { model.requestRevealFile(node.path) }
            Button(L("Open")) { openDirectory() }
            Button(L("Insert Path")) { model.requestInsertFilePath(node.path) }
            Divider()
            Button(L("Delete"), role: .destructive) { model.requestDeleteFile(node.path) }
        } else {
            Button(L("Preview")) { _ = model.requestOpenFile(node.path) }
            Button(L("Insert Path")) { model.requestInsertFilePath(node.path) }
            Button(L("Insert Content")) { model.requestInsertFileContent(node.path) }
            Button(L("Copy Path")) { model.requestCopyFilePath(node.path) }
            Button(L("Rename")) { if let name = promptForFileName(title: L("Rename"), defaultValue: node.name) {
                model.requestRenameFile(node.path, to: name)
            } }
            Button(L("Reveal")) { model.requestRevealFile(node.path) }
            Button(L("Open")) { model.requestOpenExternalFile(node.path) }
            Button(L("Share")) { model.requestShareFile(node.path) }
            Divider()
            Button(L("Delete"), role: .destructive) { model.requestDeleteFile(node.path) }
        }
    }

    private var icon: String {
        fileIconName(for: node.name, isDirectory: node.isDirectory)
    }

    private var parentContext: String {
        let parent = URL(fileURLWithPath: node.path).deletingLastPathComponent().path
        guard !rootPath.isEmpty else {
            return parent
        }
        if parent == rootPath {
            return "."
        }
        if parent.hasPrefix(rootPath) {
            return String(parent.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return parent
    }

    private func openDirectory() {
        model.requestOpenExternalFile(node.path)
    }
}

struct FileNodeLabelView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(fileIconColor(for: node.name, isDirectory: node.isDirectory))
                .frame(width: 18)
            Text(node.name)
                .lineLimit(1)
                .font(.system(size: 13, weight: model.selectedFilePath == node.path ? .semibold : .regular))
            if let badge = model.fileChangeBadges[node.path] ?? (model.changedFiles.contains(node.path) ? "M" : nil) {
                Text(badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(changeColor(for: badge).opacity(0.14))
                    .foregroundStyle(changeColor(for: badge))
                    .clipShape(Capsule())
            }
        }
        .liquidGlassRow(active: model.selectedFilePath == node.path, radius: 10)
    }
}

@MainActor func promptForFileName(title: String, defaultValue: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = L("Enter a file or folder name.")
    alert.addButton(withTitle: L("OK"))
    alert.addButton(withTitle: L("Cancel"))
    let field = NSTextField(string: defaultValue)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    let response = alert.runModal()
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return response == .alertFirstButtonReturn && !value.isEmpty ? value : nil
}

@MainActor func promptForMCPServer(title: String, defaultName: String, defaultCommand: String) -> (name: String, command: String)? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = L("Enter a server name and either a command with args or an HTTP URL.")
    alert.addButton(withTitle: L("Save"))
    alert.addButton(withTitle: L("Cancel"))

    let nameField = NSTextField(string: defaultName)
    nameField.placeholderString = L("server name")
    let commandField = NSTextField(string: defaultCommand)
    commandField.placeholderString = "npx -y @modelcontextprotocol/server-filesystem /path or https://host/mcp"

    let stack = NSStackView(views: [
        labeledField(L("Name"), field: nameField),
        labeledField(L("Command / URL"), field: commandField)
    ])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 420, height: 76)
    alert.accessoryView = stack

    let response = alert.runModal()
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return response == .alertFirstButtonReturn && !name.isEmpty && !command.isEmpty ? (name, command) : nil
}

@MainActor func labeledField(_ label: String, field: NSTextField) -> NSView {
    let text = NSTextField(labelWithString: label)
    text.font = .systemFont(ofSize: 11, weight: .semibold)
    text.textColor = .secondaryLabelColor
    field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
    let stack = NSStackView(views: [text, field])
    stack.orientation = .vertical
    stack.spacing = 3
    stack.frame = NSRect(x: 0, y: 0, width: 420, height: 36)
    return stack
}

func changeColor(for badge: String) -> Color {
    switch badge {
    case "A": .green
    case "D": .red
    default: .orange
    }
}

func flattenFileNodes(_ nodes: [FileNode], query: String) -> [FileNode] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
        return []
    }
    var result: [FileNode] = []
    result.reserveCapacity(min(nodes.count, 128))
    appendMatchingFileNodes(nodes, needle: needle, into: &result)
    return result
}

private func appendMatchingFileNodes(_ nodes: [FileNode], needle: String, into result: inout [FileNode]) {
    for node in nodes {
        if node.name.localizedCaseInsensitiveContains(needle) || node.path.localizedCaseInsensitiveContains(needle) {
            result.append(node)
        }
        if !node.children.isEmpty {
            appendMatchingFileNodes(node.children, needle: needle, into: &result)
        }
    }
}

struct SkillsPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var skillSearchText = ""

    private var filteredSkills: [SkillInfo] {
        let needle = skillSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = model.skills
        guard !needle.isEmpty else {
            return source.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return source.filter { skill in
            skill.name.localizedCaseInsensitiveContains(needle) ||
                skill.description.localizedCaseInsensitiveContains(needle) ||
                skill.scope.localizedCaseInsensitiveContains(needle)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var projectSkills: [SkillInfo] {
        filteredSkills.filter { $0.scope == "project" }
    }

    private var globalSkills: [SkillInfo] {
        filteredSkills.filter { $0.scope == "global" }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label(L("Skills"), systemImage: "sparkles")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("\(filteredSkills.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                    Spacer()
                    ToolbarMenuIconButton(systemImage: "plus", help: "Create skill") {
                        Button(L("Global Skill")) { createSkill(projectScoped: false) }
                        Button(L("Project Skill")) { createSkill(projectScoped: true) }.disabled(model.workingDirectory.isEmpty)
                    }
                    ToolbarIconButton(systemImage: "arrow.clockwise", help: "Reload skills") { model.reloadMCPAndSkills() }
                }
                Text(L("Global and project skills are available as slash commands in the composer."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                GlassSearchField(placeholder: "Search skills...", text: $skillSearchText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.55)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filteredSkills.isEmpty {
                        ContentUnavailableView(
                            skillSearchText.isEmpty ? L("No skills") : L("No matching skills"),
                            systemImage: "sparkles",
                            description: Text(skillSearchText.isEmpty ? L("Create a global or project skill from the + menu.") : skillSearchText)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        skillGroup("Project", projectSkills)
                        skillGroup("Global", globalSkills)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func skillGroup(_ title: String, _ skills: [SkillInfo]) -> some View {
        if !skills.isEmpty {
            SectionCaption(title: title, trailing: "\(skills.count)")
            ForEach(skills) { skill in skillRow(skill) }
        }
    }

    private func skillRow(_ skill: SkillInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "diamond")
                .foregroundStyle(skill.disabled ? .secondary : Color.accentColor)
                .frame(width: 24, height: 24)
                .background((skill.disabled ? Color.secondary : Color.accentColor).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 14, weight: model.selectedSkill?.path == skill.path ? .semibold : .regular))
                        .lineLimit(1)
                    scopeBadge(skill.scope)
                }
                Text(skill.description.isEmpty ? L("No description") : skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let allowedTools = skill.allowedTools, !allowedTools.isEmpty {
                    FlowBadges(items: Array(allowedTools.prefix(5)))
                        .padding(.top, 2)
                }
                metadataLine(for: skill)
            }
            Spacer(minLength: 6)
            ToolbarMenuIconButton(systemImage: "ellipsis", help: "Skill actions") {
                Button(L("Use in Input")) { model.useSkillInComposer(skill) }
                Button(L("Edit")) { if model.requestOpenFile(skill.path) {
                    model.selectedSkill = skill
                } }
                Button(L("Duplicate")) { model.duplicateSkill(skill) }
                Button(L("Reveal in Finder")) { model.requestRevealFile(skill.path) }
                Button(L("Open")) { model.requestOpenExternalFile(skill.path) }
                Divider()
                Button(L("Delete"), role: .destructive) { model.selectedSkill = skill; model.deleteSelectedSkill() }
            }
            Toggle("", isOn: Binding(
                get: { !skill.disabled },
                set: { enabled in
                    guard enabled == skill.disabled else {
                        return
                    }
                    model.selectedSkill = skill
                    model.toggleSelectedSkillEnabled()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(skill.disabled ? L("Enable skill") : L("Disable skill"))
            .pointingHandCursor()
        }
        .padding(10)
        .liquidGlassControl(
            RoundedRectangle(cornerRadius: 16, style: .continuous),
            active: model.selectedSkill?.path == skill.path,
            interactive: false,
            fallbackRadius: 16,
            fallbackIntensity: model.selectedSkill?.path == skill.path ? .prominent : .subtle
        )
        .contentShape(Rectangle())
        .pointingHandCursor()
        .onTapGesture {
            if model.requestOpenFile(skill.path) {
                model.selectedSkill = skill
            }
        }
        .contextMenu {
            Button(L("Use in Input")) { model.useSkillInComposer(skill) }
            Button(L("Edit")) { if model.requestOpenFile(skill.path) {
                model.selectedSkill = skill
            } }
            Button(L("Duplicate")) { model.duplicateSkill(skill) }
            Button(skill.disabled ? L("Enable") : L("Disable")) { model.selectedSkill = skill; model.toggleSelectedSkillEnabled() }
            Button(L("Reveal in Finder")) { model.requestRevealFile(skill.path) }
            Button(L("Open")) { model.requestOpenExternalFile(skill.path) }
            Divider()
            Button(L("Delete"), role: .destructive) { model.selectedSkill = skill; model.deleteSelectedSkill() }
        }
    }

    private func scopeBadge(_ scope: String) -> some View {
        Text(scope == "global" ? L("G") : L("P"))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .frame(width: 18, height: 18)
            .background((scope == "global" ? Color.blue : Color.green).opacity(0.18))
            .foregroundStyle(scope == "global" ? Color.blue : Color.green)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(scope == "global" ? L("Global") : L("Project"))
    }

    @ViewBuilder private func metadataLine(for skill: SkillInfo) -> some View {
        let parts = [
            skill.model.map { LF("model: %@", $0) },
            skill.context.map { LF("context: %@", $0) },
            skill.version.map { LF("version: %@", $0) }
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func createSkill(projectScoped: Bool) {
        if let name = promptForFileName(title: projectScoped ? L("New project skill") : L("New global skill"), defaultValue: "new-skill") {
            model.createSkill(name: name, projectScoped: projectScoped)
        }
    }
}

struct FlowBadges: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.10))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

struct MCPPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var serverName = ""
    @State private var command = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(L("MCP Servers")).font(.headline); Spacer(); Button(L("Reload")) { model.reloadMCPAndSkills() } }
            HStack { TextField(L("name"), text: $serverName); TextField(L("command"), text: $command); Button(L("Add")) { if !serverName.isEmpty {
                model.addMCPServer(
                    name: serverName,
                    command: command
                ); serverName = ""; command = "" } } }
            List(model.mcpServers) { server in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(server.name).font(.headline)
                        Spacer()
                        MCPRuntimeBadge(server: server)
                        Text(server.transport).font(.caption).padding(4).background(.thinMaterial).clipShape(Capsule())
                    }
                    Text(server.command ?? server.url ?? L("No command/url")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let error = server.lastError, server.runtimeStatus == .failed {
                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    }
                    HStack {
                        Text(server.source).font(.caption2).foregroundStyle(.tertiary); Spacer(); Button(L("Test")) { model.testMCPServer(server) }; if
                            server
                                .source != "Claude" {
                            Button(
                                L("Delete"),
                                role: .destructive
                            ) { model.deleteMCPServer(server) } } }
                }.padding(.vertical, 4)
            }
        }.padding(12)
    }
}

struct PermissionSheetView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    @State private var editedInput: String = ""
    var body: some View {
        Color.black.opacity(0.24).ignoresSafeArea()
        GlassPanel(role: .permissionSheet, prominence: .prominent, cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(color); VStack(alignment: .leading) {
                            Text(permission.title).font(.title3.bold()); Text(permission.risk.rawValue).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                Text(permission.summary).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $editedInput).font(.system(.caption, design: .monospaced)).frame(height: 180).onAppear { editedInput = permission.inputJSON }
                HStack {
                    Button(L("Deny"), role: .destructive) { model.respondPermission(permission, allow: false) }
                    Spacer()
                    if SessionPermissionRemember.isRememberable(permission) {
                        Button(L("Allow for Session")) {
                            model.respondPermission(
                                permission,
                                allow: true,
                                editedInput: editedInput,
                                rememberForSession: true
                            )
                        }
                    }
                    Button(L("Allow Once")) {
                        model.respondPermission(
                            permission,
                            allow: true,
                            editedInput: editedInput
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(width: 620)
        }
    }

    private var icon: String {
        permission.risk == .destructive ? "exclamationmark.triangle.fill" : permission.risk == .shell ? "terminal.fill" : "checkmark.shield.fill"
    }

    private var color: Color {
        permission.risk == .destructive ? .red : permission.risk == .shell ? .orange : .accentColor
    }
}

struct SettingsPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var mcpName = ""
    @State private var mcpCommand = ""

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.26)
                .ignoresSafeArea()
                .pointingHandCursor()
                .onTapGesture { model.settingsOpen = false }
            GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 30) {
                VStack(spacing: 0) {
                    settingsHeader
                    Divider().opacity(0.65)
                    HStack(spacing: 0) {
                        settingsSidebar
                        Divider().opacity(0.65)
                        ScrollView {
                            Group {
                                switch model.settingsTab {
                                case .general: generalContent
                                case .mcp: mcpContent
                                case .extensions: ExtensionsSettingsContent()
                                case .cli: cliContent
                                case .feedback: feedbackContent
                                }
                            }
                            .padding(26)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider().opacity(0.65)
                    settingsFooter
                }
                .frame(width: 980, height: 660)
            }
            .padding(32)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var settingsHeader: some View {
        HStack {
            Text(L("Settings"))
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Spacer()
            ToolbarIconButton(systemImage: "xmark", help: "Close settings") { model.settingsOpen = false }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                Button { model.settingsTab = tab } label: {
                    HStack(spacing: 12) {
                        Image(systemName: settingsTabIcon(tab))
                            .frame(width: 18)
                        Text(tab.label)
                        if tab == .cli && model.cliStatus.updateAvailable {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                        }
                        Spacer()
                    }
                    .font(.system(size: 15, weight: model.settingsTab == tab ? .semibold : .medium))
                    .liquidGlassRow(active: model.settingsTab == tab, radius: 12)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LiquidCode v0.1.0")
                        .font(.caption.weight(.semibold))
                    Text(L("Interaction parity"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .liquidGlassCard(role: .floatingCard, prominence: .subtle, radius: 16)
        }
        .padding(18)
        .frame(width: 190)
    }

    private var settingsFooter: some View {
        HStack(spacing: 12) {
            Label(
                model.cliStatus.installed ? L("CLI ready") : L("CLI missing"),
                systemImage: model.cliStatus.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(model.cliStatus.installed ? .mint : .orange)
            if let version = model.cliStatus.version {
                Text("v\(version)").foregroundStyle(.secondary)
            }
            if model.cliStatus.updateAvailable, let latest = model.cliStatus.latestVersion {
                Text(LF("Update available: %@", latest))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Spacer()
            Button(L("Changelog")) { model.showChangelog() }.buttonStyle(.plain).liquidGlassButton(radius: 10)
            Button(L("Check CLI")) { model.refreshCLIStatus() }.buttonStyle(.plain).liquidGlassButton(radius: 10)
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: L("General"), subtitle: L("LiquidCode visual identity with native interaction parity"), icon: "sun.max") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Theme"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(ThemeMode.allCases) { theme in
                            Button { model.settings.theme = theme; model.persistSettings() } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: theme == .dark ? "moon.fill" : theme == .light ? "sun.max.fill" : "circle.lefthalf.filled")
                                        .font(.title3)
                                    Text(theme.label)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .liquidGlassButton(active: model.settings.theme == theme, radius: 16)
                        }
                    }
                    Text(L("Accent"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(AccentTheme.allCases) { accent in
                            Button { model.settings.accent = accent; model.persistSettings() } label: {
                                HStack { Circle().fill(accent.color).frame(width: 16, height: 16); Text(L(accent.rawValue.capitalized)); Spacer() }
                            }
                            .buttonStyle(.plain)
                            .liquidGlassButton(active: model.settings.accent == accent, radius: 14)
                        }
                    }
                }
            }

            SettingsSectionCard(title: L("Notifications"), subtitle: L("Alert when Claude needs you while LiquidCode is in the background"), icon: "bell") {
                Toggle(isOn: Binding(
                    get: { model.settings.notificationsEnabled },
                    set: { model.settings.notificationsEnabled = $0; model.persistSettings() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Background notifications"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(L("Permission, questions, plan review, and turn completion when the app is inactive."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            SettingsSectionCard(title: L("Updates"), subtitle: L("Check the release feed and verify signed downloads"), icon: "arrow.down.app") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L("latest.json URL (optional)"), text: Binding(
                        get: { model.settings.updateManifestURL },
                        set: { model.settings.updateManifestURL = $0; model.persistSettings() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        Button(model.appUpdateChecking ? L("Checking…") : L("Check for Updates")) {
                            model.checkForAppUpdates(openDownload: false)
                        }
                        .buttonStyle(.plain)
                        .liquidGlassButton(active: true, radius: 10)
                        .disabled(model.appUpdateChecking)
                        if case .available(_, let latest, _) = model.appUpdateStatus {
                            Button(LF("Download %@", latest)) {
                                model.checkForAppUpdates(openDownload: true)
                            }
                            .buttonStyle(.plain)
                            .liquidGlassButton(radius: 10)
                        }
                    }
                    Text(updateStatusLabel(model.appUpdateStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSectionCard(title: L("Composer defaults"), subtitle: L("Mode, thinking and typography used by new sends"), icon: "text.cursor") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text(LF("Font size: %d", Int(model.settings.fontSize)))
                            .font(.caption.weight(.semibold))
                        Slider(value: $model.settings.fontSize, in: 11 ... 22) { Text(L("Font Size")) }
                            .onChange(of: model.settings.fontSize) { _, _ in model.persistSettings() }
                    }
                    Picker(L("Mode"), selection: $model.settings.sessionMode) { ForEach(SessionMode.allCases) { Text($0.label).tag($0) } }
                        .onChange(of: model.settings.sessionMode) { _, value in model.setComposerMode(value) }
                    Picker(L("Thinking"), selection: $model.settings.thinkingLevel) { ForEach(ThinkingLevel.allCases) { Text($0.label).tag($0) } }
                        .onChange(of: model.settings.thinkingLevel) { _, value in model.setComposerThinkingLevel(value) }
                }
            }
        }
    }

    private var mcpContent: some View {
        SettingsSectionCard(title: L("MCP Servers"), subtitle: L("Create, edit, test and delete app-local MCP profiles"), icon: "server.rack") {
            HStack(spacing: 8) {
                TextField(L("server name"), text: $mcpName).textFieldStyle(.roundedBorder)
                TextField(L("command with args or URL"), text: $mcpCommand).textFieldStyle(.roundedBorder)
                Button(L("Add")) { if !mcpName.isEmpty {
                    model.addMCPServer(name: mcpName, command: mcpCommand); mcpName = ""; mcpCommand = ""
                } }
                .buttonStyle(.plain)
                .liquidGlassButton(active: true, radius: 10)
                .disabled(mcpName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            VStack(spacing: 10) {
                ForEach(model.mcpServers) { server in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: server.transport == "stdio" ? "terminal" : "link")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(server.name).font(.headline)
                                Text(server.source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(Capsule())
                                MCPRuntimeBadge(server: server)
                                if !server.args.isEmpty {
                                    Text(LF("%d args", server.args.count))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.04))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(mcpCommandLine(server)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            if let error = server.lastError, server.runtimeStatus == .failed {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button(L("Test")) { model.testMCPServer(server) }
                            .buttonStyle(.plain)
                            .liquidGlassButton(radius: 10)
                        if server.source == "LiquidCode" {
                            Button(L("Edit")) {
                                if let result = promptForMCPServer(title: L("Edit MCP server"), defaultName: server.name, defaultCommand: mcpCommandLine(server)) {
                                    model.updateMCPServer(server, name: result.name, command: result.command)
                                }
                            }
                            .buttonStyle(.plain)
                            .liquidGlassButton(radius: 10)
                            Button(L("Delete"), role: .destructive) { model.deleteMCPServer(server) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .liquidGlassButton(radius: 10)
                        } else {
                            Text(L("Read-only"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.035))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if model.mcpServers.isEmpty {
                    ContentUnavailableView(L("No MCP servers"), systemImage: "server.rack")
                }
            }
        }
    }

    private func updateStatusLabel(_ status: UpdateAvailability) -> String {
        switch status {
        case .upToDate(let current):
            return LF("Up to date · %@", current)
        case .available(let current, let latest, let build):
            return LF("Update available · %@ → %@ (build %@)", current, latest, build)
        case .unknown(let reason):
            return reason
        }
    }

    private func mcpCommandLine(_ server: MCPServer) -> String {
        if let url = server.url {
            return url
        }
        return ([server.command ?? ""] + server.args).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var cliContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionCard(title: L("Claude Code CLI"), subtitle: L("Native install, update, login and repair"), icon: "terminal") {
                HStack(alignment: .top, spacing: 14) {
                    StatusDot(color: model.cliStatus.installed ? .mint : .orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.cliStatus.installed ? L("Installed") : L("Not installed"))
                            .font(.headline)
                        Text(model.cliStatus.path ?? L("Claude CLI executable was not found"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(LF(
                            "Auth: %@ · node %@ · npm %@",
                            L(model.cliStatus.authStatus),
                            model.cliStatus.nodeAvailable ? L("yes") : L("no"),
                            model.cliStatus.npmAvailable ? L("yes") : L("no")
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let version = model.cliStatus.version {
                        Text("v\(version)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if model.cliStatus.updateAvailable, let latest = model.cliStatus.latestVersion {
                    Label(LF("Update available: %@", latest), systemImage: "arrow.down.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if model.setupProgress.phase != .idle {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.setupProgress.percent)
                        Text(model.setupProgress.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button(L("Refresh")) { model.refreshCLIStatus() }; Button(L("Install / Update")) { model.installOrUpdateCLI() }; Button(L("Login")) { model.openClaudeLogin()
                    }; Button(L("Repair")) { model.repairCLI() }; Button(L("Open Config")) { model.openClaudeConfig() } }
                    .buttonStyle(.plain)
            }
        }
    }

    private var feedbackContent: some View {
        SettingsSectionCard(title: L("Feedback & Diagnostics"), subtitle: L("Logs and support artifacts"), icon: "bubble.left.and.text.bubble.right") {
            Text(L("Diagnostics live at:"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(AppPaths.shared.logs.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack { Button(L("Reveal Logs")) { model.revealLogs() }; Button(L("Copy Diagnostics")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(
                "LiquidCode \(model.cliStatus.version ?? "unknown")\nLogs: \(AppPaths.shared.logs.path)",
                forType: .string
            ); model.toastSuccess(L("Copied diagnostics"), AppPaths.shared.logs.path) } }
        }
    }

}

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            content
        }
        .padding(18)
        .liquidGlassCard(role: .floatingCard, prominence: .subtle, radius: 22)
    }
}
