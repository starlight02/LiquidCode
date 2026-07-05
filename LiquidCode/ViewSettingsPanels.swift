// swiftlint:disable file_length
import AppKit
import SwiftUI
import WebKit

struct ToolDisplayItemView: View {
    let item: TranscriptToolItem
    var compact: Bool = false
    @State private var expanded = false

    private var payload: String {
        cleanToolPayload(item.content)
    }

    private var displayPayload: String {
        if !payload.isEmpty {
            return payload
        }
        return item.kind == .use ? "No input payload." : "Completed with no textual output."
    }

    private var parsedJSON: [(String, String)] {
        toolPayloadKeyValues(payload)
    }

    private var tint: Color {
        item.kind == .use ? Color.accentColor : Color.green
    }

    private var icon: String {
        item.kind == .use ? toolIconName(item.toolName) : "checkmark.circle.fill"
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
                        Text(item.kind == .use ? "tool use" : "tool result")
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

                toolSummary

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.kind == .use ? "Input payload" : "Result payload")
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
                        .frame(maxHeight: 160)
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
    }

    @ViewBuilder private var toolSummary: some View {
        if item.kind == .use {
            if parsedJSON.isEmpty {
                Text(payload.isEmpty ? "No input payload." : payload)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 4)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(parsedJSON.prefix(compact ? 3 : 6)), id: \.0) { key, value in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(key)
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
        } else {
            MarkdownRendererView(content: displayPayload)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct ToolMessageGroupView: View {
    let items: [TranscriptToolItem]
    @State private var expanded: Bool
    init(items: [TranscriptToolItem]) {
        self.items = items
        _expanded = State(initialValue: items.count <= 2 || !TranscriptToolRunCompletion.isComplete(items))
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
                        Text("Tool run").font(.caption.weight(.semibold))
                        Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(items.filter { $0.kind == .use }.count) use / \(items.filter { $0.kind == .result }.count) result")
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
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { ToolDisplayItemView(item: $0, compact: true) }
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
    }
}

func cleanToolPayload(_ content: String) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[tool_use:") || first.hasPrefix("[tool_result") else {
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func toolPayloadKeyValues(_ payload: String) -> [(String, String)] {
    guard
        let data = payload.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dict = object as? [String: Any] else {
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
            Label("Action required", systemImage: "hand.tap")
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
                    Image(systemName: icon).foregroundStyle(color); Text("Permission request").font(.headline); Text(permission.toolName)
                        .font(.caption.monospaced())
                        .padding(
                            .horizontal,
                            6
                        )
                        .padding(.vertical, 2)
                        .background(color.opacity(0.12))
                        .clipShape(Capsule()); Spacer(); Text(permission.risk.rawValue).font(.caption).foregroundStyle(.secondary) } }
                .buttonStyle(.plain)
            Text(permission.summary).font(.callout).foregroundStyle(.secondary)
            if expanded {
                TextEditor(text: $editedInput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .onAppear { if editedInput.isEmpty {
                        editedInput = permission.inputJSON
                    } } }
            HStack {
                Button("Deny", role: .destructive) { model.respondPermission(permission, allow: false) }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                Spacer()
                Button {
                    model.respondPermission(permission, allow: true, editedInput: editedInput.isEmpty ? permission.inputJSON : editedInput)
                } label: {
                    Label("Allow Once", systemImage: "checkmark")
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
    private var planText: String {
        permission.summary.isEmpty ? permission.inputJSON : permission.summary
    }

    private var stepCount: Int {
        planText.split(separator: "\n").filter { $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(Color.accentColor); Text("Plan review")
                        .font(.headline); if stepCount > 0 {
                        Text("\(stepCount) steps")
                            .font(.caption)
                            .padding(
                                .horizontal,
                                6
                            )
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule()) }; Spacer(); Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption) } }.buttonStyle(.plain)
            if expanded && !compact {
                MarkdownRendererView(content: planText).font(.callout)
            }
            HStack {
                Button("Reject", role: .destructive) { model.respondPermission(permission, allow: false) }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                Button("Restart Plan") {
                    model.settings.sessionMode = .plan; model.persistSettings(); model.updateComposerText("Please revise the plan before execution:\n\n"); model.respondPermission(
                        permission,
                        allow: false
                    ); model.toastInfo("Plan", "Describe the revision in the composer") }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                Spacer()
                Button {
                    model.settings.sessionMode = .code; model.persistSettings(); model.respondPermission(permission, allow: true, editedInput: permission.inputJSON)
                } label: {
                    Label("Approve Plan", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .liquidGlassButton(active: true, radius: 11)
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
    private var prompt: String {
        questionPrompt(from: permission.inputJSON, fallback: permission.summary)
    }

    private var options: [String] {
        questionOptions(from: permission.inputJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.accentColor); Text("Claude asks a question").font(.headline); Spacer() }
            Text(prompt).font(.callout)
            if
                !options
                    .isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) { ForEach(options, id: \.self) { option in
                    Button(option) { answer = option }.buttonStyle(.bordered) } } }
            TextField("Type an answer", text: $answer)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button("Skip") { model.respondPermission(permission, allow: true, editedInput: questionSkipResponseJSON(permission.inputJSON)) }
                    .buttonStyle(.plain)
                    .liquidGlassButton(radius: 11)
                Spacer()
                Button {
                    model.respondPermission(permission, allow: true, editedInput: questionResponseJSON(permission.inputJSON, answer: answer))
                } label: {
                    Label("Send Answer", systemImage: "arrow.right")
                }
                .buttonStyle(.plain)
                .liquidGlassButton(active: true, radius: 11)
                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background { StandardContentCardBackground(cornerRadius: 16, tint: .accentColor) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
        .padding(.leading, 44)
    }
}

func questionPrompt(from json: String, fallback: String) -> String {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return fallback
    }
    if let question = obj["question"] as? String {
        return question
    }
    if let questions = obj["questions"] as? [[String: Any]], let first = questions.first, let question = first["question"] as? String {
        return question
    }
    return fallback
}

func questionOptions(from json: String) -> [String] {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return []
    }
    let rawOptions: Any? = obj["options"] ?? (obj["questions"] as? [[String: Any]])?.first?["options"]
    if let strings = rawOptions as? [String] {
        return strings
    }
    if let dicts = rawOptions as? [[String: Any]] {
        return dicts.compactMap { $0["label"] as? String ?? $0["value"] as? String }
    }
    return []
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

        let textView = NSTextView()
        textView.delegate = context.coordinator
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
        !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingPermissionsForSelectedSession.isEmpty
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
            return "Project"
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
                    .frame(maxWidth: barMaxWidth)
            }

            VStack(spacing: usesDock ? 12 : 10) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        if model.composerText.isEmpty {
                            Text(isBusy ? "Add a follow-up while Claude works..." :
                                model.workingDirectory.isEmpty ? "Type a message to start..." :
                                "Add message...")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: max(15, model.settings.fontSize)))
                                .padding(.top, inputTextInset)
                        }
                        ComposerTextView(
                            text: Binding(get: { model.composerText }, set: { model.updateComposerText($0) }),
                            fontSize: max(15, model.settings.fontSize),
                            verticalInset: inputTextInset
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
                        .help("Stop current turn")
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
                        .disabled(!canSend)
                        .help(model.pendingPermissionsForSelectedSession.isEmpty ? "Send (Return)" : "Respond to inline card first")
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
                    NativeToolbarMenuLabel(title: compact ? "" : "Rewind", systemImage: "arrow.counterclockwise", minWidth: compact ? 38 : 84)
                }
                .buttonStyle(.plain)
                .disabled(model.selectedLastUserMessage == nil)
                .help("Restore conversation, code, both, or prepare a summary from the last user turn")

                Menu {
                    ForEach(model.skills) { skill in
                        Button("/\(skill.name)") {
                            model.updateComposerText("/\(skill.name) ")
                            updateSlashState(model.composerText)
                        }
                    }
                    if model.skills.isEmpty {
                        Button("No skills loaded") {}.disabled(true)
                    }
                } label: {
                    NativeToolbarMenuLabel(title: compact ? "" : "Skills", systemImage: "sparkles", minWidth: compact ? 38 : 78)
                }
                .buttonStyle(.plain)
                .help("Insert skill slash command")
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
        }
    }

    private func projectPickerButton(compact: Bool) -> some View {
        Menu {
            Button {
                model.chooseWorkingDirectory()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            Button {
                model.selectMostRecentClaudeProject()
            } label: {
                Label("Use Claude Recent Project", systemImage: "clock.arrow.circlepath")
            }
            if !model.workingDirectory.isEmpty {
                Divider()
                Button(role: .destructive) {
                    model.clearWorkingDirectory()
                } label: {
                    Label("Clear Project", systemImage: "xmark.circle")
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
        .help(model.workingDirectory.isEmpty ? "Choose a project folder or start with Claude Code's default directory" : model.workingDirectory)
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
            HStack { Image(systemName: "slash.circle"); Text(query.isEmpty ? "Commands" : "Commands matching /\(query)").font(.caption.bold()); Spacer() }
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
                }.buttonStyle(.plain)
            }
            if commands.isEmpty {
                Text("No command matches /\(query)").font(.caption).foregroundStyle(.secondary).padding(8)
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
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { ForEach(model.attachments) { AttachmentChipView(attachment: $0) } }.padding(
            .horizontal,
            2
        ) }
        .frame(height: 34)
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
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
                            Label(tab.rawValue, systemImage: tab.systemImage)
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
                case .skills: SkillsPanelView()
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
                                ContentUnavailableView("No files match", systemImage: "magnifyingglass", description: Text(fileSearchText))
                                    .padding(.vertical, 24)
                            } else {
                                ForEach(searchResults) { SearchFileResultRowView(node: $0, rootPath: model.workingDirectory) }
                            }
                        } else if model.fileTree.isEmpty {
                            ContentUnavailableView("Empty project", systemImage: "folder", description: Text("Create a file or refresh the tree."))
                                .padding(.vertical, 28)
                        } else {
                            ForEach(model.fileTree) { FileNodeView(node: $0) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .contextMenu {
                    Button("New file") { createFile() }
                    Button("New folder") { createFolder() }
                    Button("Refresh") { model.reloadFileTree() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(model.workingDirectory.isEmpty ? "Files" : URL(fileURLWithPath: model.workingDirectory).lastPathComponent)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if changedCount > 0 {
                    Text("\(changedCount) changed")
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary.opacity(0.7))
            Text("Select a project from the welcome screen to browse files")
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
        if let name = promptForFileName(title: "New file", defaultValue: "untitled.txt") {
            model.createFile(inDirectory: model.workingDirectory, named: name)
        }
    }

    private func createFolder() {
        if let name = promptForFileName(title: "New folder", defaultValue: "untitled") {
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
                .contextMenu {
                    Button("New file here") { model.createFile(inDirectory: node.path) }
                    Button("New folder here") { if let name = promptForFileName(title: "New folder", defaultValue: "untitled") {
                        model.createFolder(
                            inDirectory: node.path,
                            named: name
                        ) } }
                    Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) {
                        model.requestRenameFile(node.path, to: name)
                    } }
                    Button("Reveal") { model.requestRevealFile(node.path) }
                    Button("Open") { model.requestOpenExternalFile(node.path) }
                    Button("Insert Path") { model.requestInsertFilePath(node.path) }
                    Divider()
                    Button("Delete", role: .destructive) { model.requestDeleteFile(node.path) }
                }
        } else {
            Button { _ = model.requestOpenFile(node.path) } label: { FileNodeLabelView(node: node, icon: icon) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Preview") { _ = model.requestOpenFile(node.path) }
                    Button("Insert Path") { model.requestInsertFilePath(node.path) }
                    Button("Insert Content") { model.requestInsertFileContent(node.path) }
                    Button("Copy Path") { model.requestCopyFilePath(node.path) }
                    Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) {
                        model.requestRenameFile(node.path, to: name)
                    } }
                    Button("Reveal") { model.requestRevealFile(node.path) }
                    Button("Open") { model.requestOpenExternalFile(node.path) }
                    Button("Share") { model.requestShareFile(node.path) }
                    Divider()
                    Button("Delete", role: .destructive) { model.requestDeleteFile(node.path) }
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
            Button("New file here") { model.createFile(inDirectory: node.path) }
            Button("New folder here") { if let name = promptForFileName(title: "New folder", defaultValue: "untitled") {
                model.createFolder(inDirectory: node.path, named: name)
            } }
            Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) {
                model.requestRenameFile(node.path, to: name)
            } }
            Button("Reveal") { model.requestRevealFile(node.path) }
            Button("Open") { openDirectory() }
            Button("Insert Path") { model.requestInsertFilePath(node.path) }
            Divider()
            Button("Delete", role: .destructive) { model.requestDeleteFile(node.path) }
        } else {
            Button("Preview") { _ = model.requestOpenFile(node.path) }
            Button("Insert Path") { model.requestInsertFilePath(node.path) }
            Button("Insert Content") { model.requestInsertFileContent(node.path) }
            Button("Copy Path") { model.requestCopyFilePath(node.path) }
            Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) {
                model.requestRenameFile(node.path, to: name)
            } }
            Button("Reveal") { model.requestRevealFile(node.path) }
            Button("Open") { model.requestOpenExternalFile(node.path) }
            Button("Share") { model.requestShareFile(node.path) }
            Divider()
            Button("Delete", role: .destructive) { model.requestDeleteFile(node.path) }
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
    alert.informativeText = "Enter a file or folder name."
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
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
    alert.informativeText = "Enter a server name and either a command with args or an HTTP URL."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let nameField = NSTextField(string: defaultName)
    nameField.placeholderString = "server name"
    let commandField = NSTextField(string: defaultCommand)
    commandField.placeholderString = "npx -y @modelcontextprotocol/server-filesystem /path or https://host/mcp"

    let stack = NSStackView(views: [
        labeledField("Name", field: nameField),
        labeledField("Command / URL", field: commandField)
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
    for node in nodes {
        if node.name.localizedCaseInsensitiveContains(needle) || node.path.localizedCaseInsensitiveContains(needle) {
            result.append(node)
        }
        result.append(contentsOf: flattenFileNodes(node.children, query: needle))
    }
    return result
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
                    Label("Skills", systemImage: "sparkles")
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
                        Button("Global Skill") { createSkill(projectScoped: false) }
                        Button("Project Skill") { createSkill(projectScoped: true) }.disabled(model.workingDirectory.isEmpty)
                    }
                    ToolbarIconButton(systemImage: "arrow.clockwise", help: "Reload skills") { model.reloadMCPAndSkills() }
                }
                Text("Global and project skills are available as slash commands in the composer.")
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
                            skillSearchText.isEmpty ? "No skills" : "No matching skills",
                            systemImage: "sparkles",
                            description: Text(skillSearchText.isEmpty ? "Create a global or project skill from the + menu." : skillSearchText)
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
                Text(skill.description.isEmpty ? "No description" : skill.description)
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
                Button("Use in Input") { model.useSkillInComposer(skill) }
                Button("Edit") { if model.requestOpenFile(skill.path) {
                    model.selectedSkill = skill
                } }
                Button("Duplicate") { model.duplicateSkill(skill) }
                Button("Reveal in Finder") { model.requestRevealFile(skill.path) }
                Button("Open") { model.requestOpenExternalFile(skill.path) }
                Divider()
                Button("Delete", role: .destructive) { model.selectedSkill = skill; model.deleteSelectedSkill() }
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
            .help(skill.disabled ? "Enable skill" : "Disable skill")
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
            Button("Use in Input") { model.useSkillInComposer(skill) }
            Button("Edit") { if model.requestOpenFile(skill.path) {
                model.selectedSkill = skill
            } }
            Button("Duplicate") { model.duplicateSkill(skill) }
            Button(skill.disabled ? "Enable" : "Disable") { model.selectedSkill = skill; model.toggleSelectedSkillEnabled() }
            Button("Reveal in Finder") { model.requestRevealFile(skill.path) }
            Button("Open") { model.requestOpenExternalFile(skill.path) }
            Divider()
            Button("Delete", role: .destructive) { model.selectedSkill = skill; model.deleteSelectedSkill() }
        }
    }

    private func scopeBadge(_ scope: String) -> some View {
        Text(scope == "global" ? "G" : "P")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .frame(width: 18, height: 18)
            .background((scope == "global" ? Color.blue : Color.green).opacity(0.18))
            .foregroundStyle(scope == "global" ? Color.blue : Color.green)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help(scope.capitalized)
    }

    @ViewBuilder private func metadataLine(for skill: SkillInfo) -> some View {
        let parts = [
            skill.model.map { "model: \($0)" },
            skill.context.map { "context: \($0)" },
            skill.version.map { "version: \($0)" }
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func createSkill(projectScoped: Bool) {
        if let name = promptForFileName(title: projectScoped ? "New project skill" : "New global skill", defaultValue: "new-skill") {
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
            HStack { Text("MCP Servers").font(.headline); Spacer(); Button("Reload") { model.reloadMCPAndSkills() } }
            HStack { TextField("name", text: $serverName); TextField("command", text: $command); Button("Add") { if !serverName.isEmpty {
                model.addMCPServer(
                    name: serverName,
                    command: command
                ); serverName = ""; command = "" } } }
            List(model.mcpServers) { server in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(server.name).font(.headline); Spacer(); Text(server.transport).font(.caption).padding(4).background(.thinMaterial).clipShape(Capsule()) }
                    Text(server.command ?? server.url ?? "No command/url").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Text(server.source).font(.caption2).foregroundStyle(.tertiary); Spacer(); Button("Test") { model.testMCPServer(server) }; if
                            server
                                .source != "Claude" {
                            Button(
                                "Delete",
                                role: .destructive
                            ) { model.deleteMCPServer(server) } } }
                }.padding(.vertical, 4)
            }
        }.padding(12)
    }
}

struct AgentPanelView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.selectedToolCalls.isEmpty {
                    ContentUnavailableView(
                        "No agent activity",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Tool calls and sub-agent work appear here while Claude is running.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    ForEach(model.selectedToolCalls) { tool in
                        HStack(alignment: .top, spacing: 10) {
                            StatusDot(color: tool.status == .failed || tool.status == .denied ? .red : tool.status == .succeeded ? .mint : .orange)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(tool.name).font(.headline)
                                    Text(tool.status.rawValue)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.05))
                                        .clipShape(Capsule())
                                }
                                if
                                    !tool.inputPreview
                                        .isEmpty {
                                    Text(tool.inputPreview).font(.system(.caption, design: .monospaced)).lineLimit(3).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let parent = tool.parentID {
                                    Text("Parent: \(parent)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .liquidGlassCard(role: .floatingCard, prominence: .subtle, radius: 16)
                    }
                }
            }
            .padding(8)
        }
    }
}

struct AgentPopoverView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agents")
                        .font(.headline)
                    Spacer()
                    Text("\(max(model.selectedToolCalls.count, model.selectedHasActiveTurn ? 1 : 0)) agents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                AgentPanelView()
                    .frame(width: 430, height: 320)
            }
            .padding(16)
        }
        .frame(width: 462, height: 360)
    }
}

struct AgentFloatingOverlayView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Color.black
            .opacity(0.12)
            .ignoresSafeArea()
            .pointingHandCursor()
            .onTapGesture { model.agentPanelOpen = false }
        HStack {
            Spacer()
            GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Agent Activity", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.title3.bold())
                        Spacer()
                        ToolbarIconButton(systemImage: "xmark", help: "Close agents") { model.agentPanelOpen = false }
                    }
                    AgentPanelView()
                }
                .padding(18)
                .frame(width: 440, height: 580)
            }
            .padding(.trailing, 32)
        }
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
                HStack { Button("Deny", role: .destructive) { model.respondPermission(permission, allow: false) }; Spacer(); Button("Allow Once") { model.respondPermission(
                    permission,
                    allow: true,
                    editedInput: editedInput
                ) }.buttonStyle(.borderedProminent) }
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
            Text("Settings")
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
                        Text(tab.rawValue)
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
                    Text("Interaction parity")
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
            Label(model.cliStatus.installed ? "CLI ready" : "CLI missing", systemImage: model.cliStatus.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.cliStatus.installed ? .mint : .orange)
            if let version = model.cliStatus.version {
                Text("v\(version)").foregroundStyle(.secondary)
            }
            if model.cliStatus.updateAvailable, let latest = model.cliStatus.latestVersion {
                Text("Update available: \(latest)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Changelog") { model.showChangelog() }.buttonStyle(.plain).liquidGlassButton(radius: 10)
            Button("Check CLI") { model.refreshCLIStatus() }.buttonStyle(.plain).liquidGlassButton(radius: 10)
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "General", subtitle: "LiquidCode visual identity with native interaction parity", icon: "sun.max") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme")
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
                    Text("Accent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(AccentTheme.allCases) { accent in
                            Button { model.settings.accent = accent; model.persistSettings() } label: {
                                HStack { Circle().fill(accent.color).frame(width: 16, height: 16); Text(accent.rawValue.capitalized); Spacer() }
                            }
                            .buttonStyle(.plain)
                            .liquidGlassButton(active: model.settings.accent == accent, radius: 14)
                        }
                    }
                }
            }

            SettingsSectionCard(title: "Composer defaults", subtitle: "Mode, thinking and typography used by new sends", icon: "text.cursor") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Font size: \(Int(model.settings.fontSize))")
                            .font(.caption.weight(.semibold))
                        Slider(value: $model.settings.fontSize, in: 11 ... 22) { Text("Font Size") }
                            .onChange(of: model.settings.fontSize) { _, _ in model.persistSettings() }
                    }
                    Picker("Mode", selection: $model.settings.sessionMode) { ForEach(SessionMode.allCases) { Text($0.label).tag($0) } }
                        .onChange(of: model.settings.sessionMode) { _, value in model.setComposerMode(value) }
                    Picker("Thinking", selection: $model.settings.thinkingLevel) { ForEach(ThinkingLevel.allCases) { Text($0.label).tag($0) } }
                        .onChange(of: model.settings.thinkingLevel) { _, value in model.setComposerThinkingLevel(value) }
                }
            }
        }
    }

    private var mcpContent: some View {
        SettingsSectionCard(title: "MCP Servers", subtitle: "Create, edit, test and delete app-local MCP profiles", icon: "server.rack") {
            HStack(spacing: 8) {
                TextField("server name", text: $mcpName).textFieldStyle(.roundedBorder)
                TextField("command with args or URL", text: $mcpCommand).textFieldStyle(.roundedBorder)
                Button("Add") { if !mcpName.isEmpty {
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
                                if !server.args.isEmpty {
                                    Text("\(server.args.count) args")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.04))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(mcpCommandLine(server)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Test") { model.testMCPServer(server) }
                            .buttonStyle(.plain)
                            .liquidGlassButton(radius: 10)
                        if server.source == "LiquidCode" {
                            Button("Edit") {
                                if let result = promptForMCPServer(title: "Edit MCP server", defaultName: server.name, defaultCommand: mcpCommandLine(server)) {
                                    model.updateMCPServer(server, name: result.name, command: result.command)
                                }
                            }
                            .buttonStyle(.plain)
                            .liquidGlassButton(radius: 10)
                            Button("Delete", role: .destructive) { model.deleteMCPServer(server) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .liquidGlassButton(radius: 10)
                        } else {
                            Text("Read-only")
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
                    ContentUnavailableView("No MCP servers", systemImage: "server.rack")
                }
            }
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
            SettingsSectionCard(title: "Claude Code CLI", subtitle: "Native install, update, login and repair", icon: "terminal") {
                HStack(alignment: .top, spacing: 14) {
                    StatusDot(color: model.cliStatus.installed ? .mint : .orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.cliStatus.installed ? "Installed" : "Not installed")
                            .font(.headline)
                        Text(model.cliStatus.path ?? "Claude CLI executable was not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Auth: \(model.cliStatus.authStatus) · node \(model.cliStatus.nodeAvailable ? "yes" : "no") · npm \(model.cliStatus.npmAvailable ? "yes" : "no")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let version = model.cliStatus.version {
                        Text("v\(version)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if model.cliStatus.updateAvailable, let latest = model.cliStatus.latestVersion {
                    Label("Update available: \(latest)", systemImage: "arrow.down.circle.fill")
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
                    Button("Refresh") { model.refreshCLIStatus() }; Button("Install / Update") { model.installOrUpdateCLI() }; Button("Login") { model.openClaudeLogin()
                    }; Button("Repair") { model.repairCLI() }; Button("Open Config") { model.openClaudeConfig() } }
                    .buttonStyle(.plain)
            }
        }
    }

    private var feedbackContent: some View {
        SettingsSectionCard(title: "Feedback & Diagnostics", subtitle: "Logs and support artifacts", icon: "bubble.left.and.text.bubble.right") {
            Text("Diagnostics live at:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(AppPaths.shared.logs.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack { Button("Reveal Logs") { model.revealLogs() }; Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(
                "LiquidCode \(model.cliStatus.version ?? "unknown")\nLogs: \(AppPaths.shared.logs.path)",
                forType: .string
            ); model.toastSuccess("Copied diagnostics", AppPaths.shared.logs.path) } }
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
