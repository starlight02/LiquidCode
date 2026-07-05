// swiftlint:disable file_length
import AppKit
import SwiftUI
import WebKit

struct PaneResizeHandle: View {
    let title: String
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .help(title)
            .zIndex(20)
    }
}

struct LiquidContentSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colorScheme == .dark ? [
                        Color.white.opacity(0.075),
                        Color.white.opacity(0.035),
                        Color.blue.opacity(0.035)
                    ] : [
                        Color.white.opacity(0.62),
                        Color.white.opacity(0.42),
                        Color.accentColor.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct NativeToolbarMenuLabel: View {
    let title: String
    let systemImage: String
    var active = false
    var minWidth: CGFloat = 0

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(active ? 0.88 : 0.78))
        }
        .foregroundStyle(Color.primary.opacity(active ? 0.88 : 0.78))
        .padding(.horizontal, 11)
        .frame(minWidth: minWidth)
        .frame(height: GlassControlMetric.menuHeight)
        .liquidGlassControl(shape, active: false, fallbackRadius: GlassControlMetric.menuHeight / 2, fallbackIntensity: active ? .regular : .subtle)
        .overlay {
            if active {
                shape
                    .fill(Color.primary.opacity(0.055))
                    .allowsHitTesting(false)
            }
        }
    }
}

struct StandardContentCardBackground: View {
    let cornerRadius: CGFloat
    var tint: Color = .primary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .textBackgroundColor).opacity(colorScheme == .dark ? 0.72 : 0.88))
            .overlay {
                shape.fill(tint.opacity(colorScheme == .dark ? 0.065 : 0.030))
            }
            .overlay {
                shape.stroke(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.055), radius: 10, x: 0, y: 4)
    }
}

// periphery:ignore
struct LiquidComposerWell: View {
    let cornerRadius: CGFloat
    var active = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: colorScheme == .dark ? [
                            Color.white.opacity(active ? 0.16 : 0.10),
                            Color.blue.opacity(active ? 0.12 : 0.06),
                            Color.white.opacity(0.05)
                        ] : [
                            Color.white.opacity(0.54),
                            Color.white.opacity(0.30),
                            Color.accentColor.opacity(active ? 0.16 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.62), Color.white.opacity(0.16), Color.black.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: active ? 1.4 : 1
                )
            }
    }
}

struct LiquidComposerDock: View {
    let cornerRadius: CGFloat
    var active = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.24))
                    .glassEffect(.regular, in: shape)
                    .overlay { tintOverlay(shape: shape) }
                    .overlay { strokeOverlay(shape: shape) }
                    .shadow(color: .white.opacity(colorScheme == .dark ? 0.06 : 0.38), radius: 24, x: -12, y: -10)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { tintOverlay(shape: shape) }
                    .overlay { strokeOverlay(shape: shape) }
                    .shadow(color: .white.opacity(colorScheme == .dark ? 0.06 : 0.30), radius: 20, x: -10, y: -8)
            }
        }
    }

    private func tintOverlay(shape: RoundedRectangle) -> some View {
        shape.fill(
            LinearGradient(
                colors: colorScheme == .dark ? [
                    Color.white.opacity(active ? 0.12 : 0.075),
                    Color.blue.opacity(active ? 0.10 : 0.055),
                    Color.white.opacity(0.035)
                ] : [
                    Color.white.opacity(0.46),
                    Color.cyan.opacity(0.055),
                    Color.accentColor.opacity(active ? 0.13 : 0.075)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func strokeOverlay(shape: RoundedRectangle) -> some View {
        shape.stroke(
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.72),
                    Color.white.opacity(0.18),
                    Color.black.opacity(colorScheme == .dark ? 0.20 : 0.055)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
    }
}

struct LiquidDarkCTA: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.82), Color.black.opacity(0.64), Color.black.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .glassEffect(.regular.interactive().tint(Color.black.opacity(0.72)), in: shape)
                    .overlay { shine(shape) }
                    .overlay { stroke(shape) }
            } else {
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.88), Color.black.opacity(0.76), Color.black.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay { shine(shape) }
                    .overlay { stroke(shape) }
            }
        }
    }

    private func shine(_ shape: RoundedRectangle) -> some View {
        shape.fill(
            LinearGradient(
                colors: [Color.white.opacity(0.20), Color.white.opacity(0.045), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        )
    }

    private func stroke(_ shape: RoundedRectangle) -> some View {
        shape.stroke(
            LinearGradient(
                colors: [Color.white.opacity(0.28), Color.white.opacity(0.08), Color.black.opacity(0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 0.9
        )
    }
}

struct LiquidCodeLogoView: View {
    var compact = false
    var fontSize: CGFloat?

    private var resolvedSize: CGFloat {
        fontSize ?? (compact ? 13 : 20)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("LIQUID")
                .font(.system(size: resolvedSize, weight: .semibold, design: .rounded))
                .tracking(-1.1)
            Text("/")
                .font(.system(size: resolvedSize, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(-0.8)
            Text("CODE")
                .font(.system(size: resolvedSize, weight: .semibold, design: .rounded))
                .tracking(-0.8)
        }
        .accessibilityLabel("LiquidCode")
    }
}

struct Greeting: Equatable {
    let heading: String
    let subtitle: String
}

enum GreetingProvider {
    static let greetings: [Greeting] = [
        Greeting(heading: "What shall we build?", subtitle: "Describe your idea and let's get started"),
        Greeting(heading: "Ready when you are", subtitle: "Start a conversation or pick up where you left off"),
        Greeting(heading: "Let's get to work", subtitle: "Type a task, ask a question, or open a project"),
        Greeting(heading: "What's on your mind?", subtitle: "From quick questions to full features — just ask"),
        Greeting(heading: "Your next idea starts here", subtitle: "Tell me what you'd like to create or explore"),
        Greeting(heading: "Good to see you", subtitle: "Jump into a project or start something new"),
        Greeting(heading: "What are we working on?", subtitle: "Attach files, describe a task, or just chat"),
        Greeting(heading: "Let's build something great", subtitle: "Every line of code starts with a conversation")
    ]

    static func random() -> Greeting {
        greetings.randomElement() ?? Greeting(
            heading: "What shall we build?",
            subtitle: "Describe your idea and let's get started"
        )
    }
}

struct GlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassControl(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false, fallbackRadius: 16)
    }
}

// periphery:ignore
struct IconChip: View {
    let title: String
    let systemImage: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.primary.opacity(active ? 0.90 : 0.78))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .liquidGlassControl(RoundedRectangle(cornerRadius: 13, style: .continuous), active: active, fallbackRadius: 13, fallbackIntensity: active ? .prominent : .regular)
        }
        .buttonStyle(.plain)
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var active = false
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: GlassControlMetric.iconSymbolSize, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(disabled ? 0.62 : active ? 0.90 : 0.82))
                .frame(width: GlassControlMetric.iconButtonSize, height: GlassControlMetric.iconButtonSize)
                .liquidGlassControl(
                    Circle(),
                    active: active,
                    disabled: disabled,
                    fallbackRadius: GlassControlMetric.iconButtonRadius,
                    fallbackIntensity: active ? .prominent : .subtle
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

struct ToolbarMenuIconButton<MenuContent: View>: View {
    let systemImage: String
    let help: String
    var active = false
    var disabled = false
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: GlassControlMetric.iconSymbolSize, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(disabled ? 0.62 : active ? 0.90 : 0.82))
                .frame(width: GlassControlMetric.iconButtonSize, height: GlassControlMetric.iconButtonSize)
                .liquidGlassControl(
                    Circle(),
                    active: active,
                    disabled: disabled,
                    fallbackRadius: GlassControlMetric.iconButtonRadius,
                    fallbackIntensity: active ? .prominent : .subtle
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

struct SectionCaption: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.45), radius: 4)
    }
}

func shortModelName(_ model: String) -> String {
    let cleaned = model
        .replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "[1m]", with: " 1M")
        .replacingOccurrences(of: "-1m", with: " 1M")
        .replacingOccurrences(of: "-", with: " ")
    let pieces = cleaned.split(separator: " ").map(String.init)
    guard !pieces.isEmpty else {
        return model
    }
    if pieces.count >= 3 {
        return "\(pieces[0].capitalized) \(pieces[1]).\(pieces[2])" + (pieces.contains("1M") ? " 1M" : "")
    }
    return cleaned.capitalized
}

func lineCount(_ text: String) -> Int {
    guard !text.isEmpty else {
        return 0
    }
    return text.split(separator: "\n", omittingEmptySubsequences: false).count
}

func softWrappedTranscriptText(_ text: String) -> String {
    let softBreak = "\u{200B}"
    let preferredBreakCharacters = Set("/\\._-:=?&%#[](){}".map { $0 })
    var output = ""
    var runLength = 0

    for character in text {
        output.append(character)
        if character.isWhitespace || character.isNewline {
            runLength = 0
            continue
        }

        runLength += 1
        if preferredBreakCharacters.contains(character) || runLength >= 24 {
            output.append(softBreak)
            runLength = 0
        }
    }

    return output
}

func fileIconName(for fileName: String, isDirectory: Bool = false) -> String {
    if isDirectory {
        return "folder"
    }
    let lower = fileName.lowercased()
    let ext = URL(fileURLWithPath: lower).pathExtension
    if lower == "dockerfile" || lower.hasSuffix(".dockerfile") {
        return "shippingbox"
    }
    if ["swift"].contains(ext) {
        return "swift"
    }
    if ["js", "jsx", "ts", "tsx", "mjs", "cjs"].contains(ext) {
        return "curlybraces.square"
    }
    if ["json", "jsonl", "lock"].contains(ext) {
        return "curlybraces"
    }
    if ["html", "htm", "xhtml", "svg"].contains(ext) {
        return "globe"
    }
    if ["css", "scss", "sass", "less"].contains(ext) {
        return "paintbrush"
    }
    if ["md", "mdx", "txt", "rst", "adoc"].contains(ext) {
        return "doc.text"
    }
    if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico"].contains(ext) {
        return "photo"
    }
    if ["mp4", "mov", "avi", "webm", "mkv"].contains(ext) {
        return "film"
    }
    if ["mp3", "wav", "ogg", "aac", "m4a", "flac"].contains(ext) {
        return "waveform"
    }
    if ext == "pdf" {
        return "doc.richtext"
    }
    if ["zip", "tar", "gz", "rar", "7z", "dmg", "pkg"].contains(ext) {
        return "archivebox"
    }
    if ["sh", "bash", "zsh", "fish", "command", "bat", "ps1"].contains(ext) {
        return "terminal"
    }
    if ["py", "rb", "php", "lua", "pl"].contains(ext) {
        return "chevron.left.forwardslash.chevron.right"
    }
    if ["rs", "go", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm"].contains(ext) {
        return "hammer"
    }
    if ["yml", "yaml", "toml", "ini", "env", "plist", "xcconfig"].contains(ext) || lower.hasPrefix(".env") {
        return "slider.horizontal.3"
    }
    if ["db", "sqlite", "sql"].contains(ext) {
        return "cylinder.split.1x2"
    }
    if ["csv", "tsv", "xls", "xlsx"].contains(ext) {
        return "tablecells"
    }
    if ["ttf", "otf", "woff", "woff2"].contains(ext) {
        return "textformat"
    }
    if ["key", "pem", "crt", "cer", "p12"].contains(ext) {
        return "lock.doc"
    }
    return "doc"
}

func fileIconColor(for fileName: String, isDirectory: Bool = false) -> Color {
    if isDirectory {
        return .accentColor
    }
    let ext = URL(fileURLWithPath: fileName.lowercased()).pathExtension
    if ["swift"].contains(ext) {
        return .orange
    }
    if ["js", "jsx", "ts", "tsx", "json"].contains(ext) {
        return .yellow
    }
    if ["html", "htm", "css", "scss", "svg"].contains(ext) {
        return .blue
    }
    if ["md", "mdx", "txt"].contains(ext) {
        return .secondary
    }
    if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
        return .purple
    }
    if ["sh", "bash", "zsh", "command"].contains(ext) {
        return .green
    }
    if ["zip", "dmg", "pkg", "tar", "gz"].contains(ext) {
        return .brown
    }
    return .secondary
}

func modeIcon(_ mode: SessionMode) -> String {
    switch mode {
    case .code: "bolt.fill"
    case .ask: "bubble.left.and.bubble.right"
    case .plan: "list.bullet.rectangle"
    case .bypass: "star"
    }
}

func thinkingIcon(_ level: ThinkingLevel) -> String {
    level == .off ? "lightbulb.slash" : "lightbulb"
}

struct FilePreviewShellView: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void
    private var fileName: String {
        model.selectedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File Preview"
    }

    private var fileExtension: String {
        URL(fileURLWithPath: fileName).pathExtension.lowercased()
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico"].contains(fileExtension)
    }

    private var isTextEditable: Bool {
        !isImage
    }

    private var availableModes: [FilePreviewMode] {
        if ["html", "htm", "xhtml"].contains(fileExtension) {
            return [.html, .source, .edit]
        }
        if ["md", "mdx"].contains(fileExtension) {
            return [.preview, .source, .edit]
        }
        if isImage {
            return [.preview]
        }
        return [.source, .edit]
    }

    var body: some View {
        GlassPanel(role: .inspector, prominence: .regular, cornerRadius: LiquidGlassToken.panelRadius) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: fileIconName(for: fileName, isDirectory: false))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(fileIconColor(for: fileName))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(fileName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            if lineCount(model.filePreview) > 0 {
                                Text("\(lineCount(model.filePreview)) lines")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if model.fileEditDirty {
                                Text("Unsaved")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(model.selectedFilePath ?? "No file selected").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if model.fileEditDirty {
                        Button("Discard") {
                            if let path = model.selectedFilePath {
                                model.openFile(path)
                            }
                        }
                        .buttonStyle(.plain)
                        .liquidGlassButton(radius: 10)
                        Button("Save") { model.saveSelectedFile() }
                            .buttonStyle(.plain)
                            .liquidGlassButton(active: true, radius: 10)
                    }
                    HStack(spacing: 3) {
                        ForEach(availableModes) { mode in
                            FilePreviewModeButton(mode: mode, active: model.filePreviewMode == mode) {
                                model.filePreviewMode = mode
                            }
                        }
                    }
                    .padding(4)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    ToolbarIconButton(systemImage: "arrow.clockwise", help: "Reload file") {
                        model.reloadSelectedFile()
                    }
                    ToolbarIconButton(systemImage: "xmark", help: "Close preview mode", action: onClose)
                }
                .frame(height: 68)
                .padding(.horizontal, 14)
                Divider()
                HStack(spacing: 8) {
                    ToolbarIconButton(systemImage: "folder", help: "Reveal in Finder") { model.revealSelectedFile() }
                    ToolbarIconButton(systemImage: "arrow.up.right.square", help: "Open with default app") { model.openSelectedFile() }
                    ToolbarIconButton(systemImage: "curlybraces.square", help: "Open in VS Code") { model.openSelectedInVSCode() }
                    ToolbarIconButton(systemImage: "link", help: "Copy path") { model.copySelectedPath() }
                    ToolbarIconButton(systemImage: "text.insert", help: "Insert path into chat") { model.insertSelectedPathIntoChat() }
                    ToolbarIconButton(systemImage: "doc.on.clipboard", help: "Insert file content into chat", disabled: model.filePreview.isEmpty) {
                        model.insertSelectedContentIntoChat() }
                    Spacer()
                    Button("Delete") { model.requestDeleteSelectedFile() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .liquidGlassButton(radius: 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                switch model.filePreviewMode {
                case .preview:
                    if isImage, let path = model.selectedFilePath {
                        ImageFilePreview(path: path)
                    } else {
                        ScrollView {
                            MarkdownRendererView(content: model.filePreview)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                        }
                    }
                case .html:
                    HTMLPreviewView(html: model.filePreview, basePath: model.selectedFilePath)
                case .source:
                    CodeSourceView(text: model.filePreview)
                case .edit:
                    if isTextEditable {
                        CodeEditorWithLineNumbers(text: $model.filePreview)
                            .onChange(of: model.filePreview) { _, _ in model.markFilePreviewEdited() }
                    } else {
                        ImageFilePreview(path: model.selectedFilePath ?? "")
                    }
                }
            }
        }
        .onChange(of: fileName) { _, _ in
            if !availableModes.contains(model.filePreviewMode) {
                model.filePreviewMode = availableModes.first ?? .preview
            }
        }
    }
}

struct FilePreviewModeButton: View {
    let mode: FilePreviewMode
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(mode == .html ? "Preview" : mode.rawValue)
                .font(.system(size: 13, weight: active ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(active ? Color(nsColor: .controlBackgroundColor).opacity(0.92) : Color.clear)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct CodeSourceView: View {
    let text: String
    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(height: 22, alignment: .trailing)
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 10)
                .frame(minWidth: 38)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(highlightCodeLine(line))
                            .font(.system(size: 14, design: .monospaced))
                            .frame(height: 22, alignment: .leading)
                    }
                }
                .padding(.top, 10)
                .padding(.trailing, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
    }
}

struct CodeEditorWithLineNumbers: View {
    @Binding var text: String
    private var count: Int {
        max(1, lineCount(text))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(1 ... count, id: \.self) { index in
                        Text("\(index)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(height: 22, alignment: .trailing)
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 10)
            }
            .frame(width: 52)
            .background(Color.primary.opacity(0.035))
            TextEditor(text: $text)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .textSelection(.enabled)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.46))
    }
}

struct ImageFilePreview: View {
    let path: String
    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            ScrollView([.vertical, .horizontal]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.04))
        } else {
            ContentUnavailableView("Cannot render image", systemImage: "photo.badge.exclamationmark", description: Text(path))
        }
    }
}

func highlightCodeLine(_ line: String, language: String = "") -> AttributedString {
    var attributed = AttributedString(line.isEmpty ? " " : line)
    let keywordsByLanguage: [String: [String]] = [
        "swift": ["import", "func", "struct", "class", "enum", "let", "var", "return", "if", "else", "switch", "case", "for", "while", "guard", "try", "catch", "async", "await"],
        "python": ["def", "class", "import", "from", "return", "if", "else", "elif", "for", "while", "try", "except", "async", "await", "True", "False"],
        "typescript": ["export", "import", "const", "let", "var", "function", "return", "if", "else", "switch", "case", "for", "while", "async", "await", "from", "true", "false"],
        "javascript": ["export", "import", "const", "let", "var", "function", "return", "if", "else", "switch", "case", "for", "while", "async", "await", "from", "true", "false"],
        "rust": ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "match", "true", "false"],
        "go": ["func", "var", "const", "type", "struct", "interface", "package", "import", "return", "defer", "go"],
        "java": ["public", "private", "protected", "class", "interface", "static", "final", "void", "return", "new"],
        "c++": ["std", "auto", "class", "struct", "template", "typename", "const", "return", "true", "false"],
        "cpp": ["std", "auto", "class", "struct", "template", "typename", "const", "return", "true", "false"],
        "sql": ["SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "TRUE", "FALSE", "NULL"],
        "markdown": ["#", "##", "###", "-", "*", "`"],
        "json": ["true", "false", "null"],
        "yaml": ["true", "false", "null", "enabled"],
        "html": ["section", "div", "span", "html", "body", "class", "id"],
        "css": ["color", "background", "display", "grid", "flex", "font", "margin", "padding"],
        "xml": ["note", "xml", "version"]
    ]
    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let aliases = ["js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "cc": "c++", "cxx": "c++"]
    let languageKey = aliases[normalizedLanguage] ?? normalizedLanguage
    let fallbackKeywords = keywordsByLanguage.values.flatMap { $0 }
    let keywords = keywordsByLanguage[languageKey] ?? fallbackKeywords
    for keyword in keywords {
        if let range = attributed.range(of: keyword) {
            attributed[range].foregroundColor = .blue
            attributed[range].font = .system(size: 14, weight: .semibold, design: .monospaced)
        }
    }
    for marker in ["//", "#"] {
        if let comment = attributed.range(of: marker) {
            attributed[comment.lowerBound ..< attributed.endIndex].foregroundColor = .secondary
            break
        }
    }
    return attributed
}

struct SidebarView: View {
    var onCollapse: () -> Void = {}
    @EnvironmentObject var model: AppModel
    @State private var renameTarget: SessionRecord?
    @State private var renameText = ""
    @State private var projectExpansion: [String: Bool] = [:]

    private var searchedSessions: [SessionRecord] {
        model.sessions.filter { session in
            let matchesSearch = model.searchText.isEmpty || session.title.localizedCaseInsensitiveContains(model.searchText) || session.project
                .localizedCaseInsensitiveContains(model.searchText)
            let matchesRunning = !model.showRunningSessionsOnly || model.hasActiveTurn(for: session.id)
            return matchesSearch && matchesRunning
        }
    }

    private var pinnedSessions: [SessionRecord] {
        searchedSessions.filter { $0.pinned && !$0.archived }
    }

    private var activeSessions: [SessionRecord] {
        searchedSessions.filter { !$0.pinned && !$0.archived }
    }

    private var archivedSessions: [SessionRecord] {
        searchedSessions.filter { $0.archived }
    }

    var body: some View {
        GlassPanel(role: .sidebar, prominence: .regular, cornerRadius: LiquidGlassToken.panelRadius) {
            VStack(spacing: 0) {
                sidebarHeader
                primaryAction
                searchAndFilters
                undoBanner
                Divider().opacity(0.5)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        taskGroupsHeader
                        taskGroups
                        sessionSection("Pinned", pinnedSessions, trailing: pinnedSessions.isEmpty ? nil : "\(pinnedSessions.count)")
                        projectSessionSections(activeSessions)
                        if model.showArchivedSessions {
                            sessionSection("Archived", archivedSessions, trailing: archivedSessions.isEmpty ? nil : "\(archivedSessions.count)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                Divider().opacity(0.5)
                sidebarFooter
            }
        }
        .sheet(item: $renameTarget) { session in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Session").font(.headline)
                TextField("Title", text: $renameText)
                HStack {
                    Spacer()
                    Button("Cancel") { renameTarget = nil }
                    Button("Save") { model.rename(session, to: renameText); renameTarget = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 360)
        }
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center) {
            LiquidCodeLogoView()
            Spacer()
            Button(action: onCollapse) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide sidebar")
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var primaryAction: some View {
        Button(action: model.returnToStartScreen) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 15.5, weight: .bold))
                Text("New Chat")
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background { LiquidDarkCTA(cornerRadius: 24) }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .help("Return to the start screen")
    }

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            GlassSearchField(placeholder: "Search sessions", text: $model.searchText)
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    ToolbarIconButton(systemImage: "checklist", help: "Batch select", active: model.sessionSelectionMode) { model.toggleSessionSelectionMode() }
                    ToolbarIconButton(systemImage: "bolt.circle", help: "Running sessions", active: model.showRunningSessionsOnly) { model.showRunningSessionsOnly.toggle() }
                    ToolbarIconButton(systemImage: model.showArchivedSessions ? "archivebox.fill" : "archivebox", help: "Show archived", active: model.showArchivedSessions) {
                        model.showArchivedSessions.toggle() }
                }
                Spacer()
                if model.sessionSelectionMode {
                    Button("Archive") { model.archiveSelectedSessions() }
                        .buttonStyle(.borderless)
                        .disabled(model.selectedSessionIDs.isEmpty)
                    Button("Delete") { model.deleteSelectedSessions() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .disabled(model.selectedSessionIDs.isEmpty)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var undoBanner: some View {
        if let deleted = model.recentlyDeletedSession {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Deleted \(deleted.session.title)")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button("Undo") { model.undoLastSessionDelete() }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            Button { model.agentPanelOpen.toggle() } label: { Label("Agents", systemImage: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(.plain)
            Spacer()
            Button { model.settingsOpen = true } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.plain)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var taskGroupsHeader: some View {
        if !model.workingDirectory.isEmpty {
            HStack(spacing: 6) {
                SectionCaption(title: "Task Groups")
                Spacer(minLength: 0)
                Button {
                    if let name = promptForFileName(title: "New task group", defaultValue: "New Task Group") {
                        model.createGroup(name: name)
                    }
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Create task group in current project")
            }
        }
    }

    @ViewBuilder private var taskGroups: some View {
        if !model.workingDirectory.isEmpty {
            ForEach(model.sessionGroups.filter { $0.projectPath == model.workingDirectory }) { group in
                let scopedSessions = model.sessions.filter { group.sessionIDs.contains($0.id) && $0.projectDir == group.projectPath }
                DisclosureGroup {
                    ForEach(scopedSessions) { session in
                        SessionRowView(session: session)
                            .onTapGesture { model.selectSession(session.id) }
                            .contextMenu { Button("Remove from Group") { model.removeSession(session, from: group) } }
                    }
                } label: {
                    HStack {
                        Image(systemName: "tray.2")
                        Text(group.name).font(.caption.bold())
                        Spacer()
                        Text("\(scopedSessions.count)").foregroundStyle(.secondary)
                    }
                    .liquidGlassRow()
                }
                .contextMenu {
                    if let selected = model.selectedSession, selected.projectDir == group.projectPath {
                        Button("Add Current Session") { model.addSession(selected, to: group) }
                    }
                    Button("Delete Group", role: .destructive) { model.deleteGroup(group) }
                }
            }
        }
    }

    @ViewBuilder private func projectSessionSections(_ sessions: [SessionRecord]) -> some View {
        ForEach(projectGroups(from: sessions)) { group in
            projectDisclosure(group)
        }
    }

    private func projectGroups(from sessions: [SessionRecord]) -> [ProjectSessionGroup] {
        Dictionary(grouping: sessions, by: { $0.projectDir })
            .map { ProjectSessionGroup(path: $0.key, sessions: $0.value.sorted { $0.modifiedAt > $1.modifiedAt }) }
            .sorted { lhs, rhs in
                if lhs.firstConversationAt != rhs.firstConversationAt {
                    return lhs.firstConversationAt > rhs.firstConversationAt
                }
                return lhs.latest > rhs.latest
            }
    }

    @ViewBuilder private func projectDisclosure(_ group: ProjectSessionGroup) -> some View {
        let isExpanded = isProjectExpanded(group.path)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                projectExpansion[group.path] = !isExpanded
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10, height: 14, alignment: .center)
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14, alignment: .center)
                    Text(group.name)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.sessions.count)")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.path)

            if isExpanded {
                ForEach(group.sessions) { session in sessionRow(session) }
            }
        }
    }

    private func isProjectExpanded(_ path: String) -> Bool {
        // Default: only the currently-open project is expanded; explicit toggles win.
        projectExpansion[path] ?? (!path.isEmpty && path == model.workingDirectory)
    }

    private struct ProjectSessionGroup: Identifiable {
        let path: String
        let sessions: [SessionRecord]
        var id: String { path }
        var name: String { path.isEmpty ? "Unknown Project" : URL(fileURLWithPath: path).lastPathComponent }
        var latest: Date { sessions.first?.modifiedAt ?? .distantPast }
        var firstConversationAt: Date {
            sessions.map { $0.createdAt ?? $0.modifiedAt }.min() ?? .distantPast
        }
    }

    @ViewBuilder private func sessionSection(_ title: String, _ sessions: [SessionRecord], trailing: String? = nil) -> some View {
        if !sessions.isEmpty {
            SectionCaption(title: title, trailing: trailing)
            ForEach(sessions) { session in sessionRow(session) }
        }
    }

    private func sessionRow(_ session: SessionRecord) -> some View {
        SessionRowView(session: session)
            .onTapGesture {
                if model.sessionSelectionMode {
                    model.toggleSessionSelection(session)
                } else {
                    model.selectSession(session.id)
                }
            }
            .contextMenu {
                Button(session.pinned ? "Unpin" : "Pin") { model.togglePin(session) }
                Button(session.archived ? "Unarchive" : "Archive") { model.toggleArchive(session) }
                Button("Generate Title") { model.generateSessionTitle(session) }
                Button("Rename") { renameTarget = session; renameText = session.title }
                let projectGroups = model.sessionGroups.filter { $0.projectPath == session.projectDir }
                if !projectGroups.isEmpty {
                    Menu("Add to Group") { ForEach(projectGroups) { group in Button(group.name) { model.addSession(session, to: group) } } }
                }
                Divider()
                Button("Export Markdown") { model.exportMarkdown(session: session) }
                Button("Export JSON") { model.exportJSON(session: session) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteSession(session) }
            }
    }
}

struct SessionRowView: View {
    @EnvironmentObject var model: AppModel
    let session: SessionRecord
    @State private var isHovered = false
    @State private var pendingDelete = false
    var selected: Bool {
        model.selectedSessionID == session.id
    }

    var checked: Bool {
        model.selectedSessionIDs.contains(session.id)
    }

    var running: Bool {
        model.hasActiveTurn(for: session.id)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.sessionSelectionMode {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.primary.opacity(0.78) : .secondary)
            } else {
                StatusDot(color: running ? .green : (session.isDraft ? .orange : .mint.opacity(0.8)))
            }
            Text(session.title)
                .lineLimit(1)
                .font(.system(size: 14, weight: selected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.86))
            if session.isDraft {
                Text("Draft")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if model.sessionSelectionMode {
                if session.archived {
                    Image(systemName: "archivebox.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if isHovered || selected || pendingDelete || session.pinned || session.archived {
                sessionActions
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background { rowBackground }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .pointingHandCursor()
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
                if !hovering {
                    pendingDelete = false
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: selected)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: pendingDelete)
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        if selected || checked {
            shape
                .fill(Color.white.opacity(0.10))
                .liquidGlassControl(shape, active: false, interactive: false, fallbackRadius: 15, fallbackIntensity: .regular)
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.primary.opacity(0.050),
                                Color.black.opacity(0.035)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.62), Color.white.opacity(0.18), Color.black.opacity(0.075)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
                }
        } else if isHovered {
            shape
                .fill(Color.white.opacity(0.055))
                .liquidGlassControl(shape, active: false, interactive: false, fallbackRadius: 15, fallbackIntensity: .subtle)
        } else {
            Color.clear
        }
    }

    private var sessionActions: some View {
        HStack(spacing: 5) {
            Button {
                model.togglePin(session)
            } label: {
                Image(systemName: session.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 23, height: 23)
                    .foregroundStyle(session.pinned ? Color.primary.opacity(0.86) : Color.secondary)
                    .background(Color.primary.opacity(session.pinned ? 0.105 : 0.035), in: Circle())
            }
            .buttonStyle(.plain)
            .help(session.pinned ? "Unpin conversation" : "Pin conversation")

            if session.archived {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 23, height: 23)
                    .foregroundStyle(.secondary)
            }

            Button {
                if pendingDelete {
                    model.deleteSession(session)
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        pendingDelete = true
                    }
                }
            } label: {
                Image(systemName: pendingDelete ? "trash.fill" : "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: pendingDelete ? 28 : 23, height: 23)
                    .foregroundStyle(pendingDelete ? Color.white : Color.secondary)
                    .background(pendingDelete ? Color.red : Color.primary.opacity(0.035), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(pendingDelete ? "Click again to delete from Claude Code" : "Delete conversation")
        }
    }
}

struct ChatPanelView: View {
    @EnvironmentObject var model: AppModel
    let sidebarOpen: Bool
    let onToggleSidebar: () -> Void
    let secondaryOpen: Bool
    let isFilePreviewMode: Bool
    let onToggleSecondary: () -> Void
    @State private var findOpen = false
    @State private var agentPopoverOpen = false
    @State private var logoOpacity: Double = 0
    @State private var headingOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var chipsOpacity: Double = 0
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.white.opacity(0.30)).frame(height: 0.5).blendMode(.overlay)
            if findOpen {
                FindBarView(onClose: { findOpen = false })
            }
            ZStack {
                if model.selectedSessionID == nil {
                    welcomeState
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .scale(scale: 0.92)).combined(with: .offset(y: -60))
                        ))
                } else {
                    ZStack(alignment: .bottom) {
                        if model.selectedMessages.isEmpty && model.selectedStreamingText.isEmpty && model.pendingPermissionsForSelectedSession.isEmpty {
                            readyState
                                .transition(.opacity.combined(with: .offset(y: 8)))
                        } else {
                            transcript
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                        InputBarView(presentation: .chat)
                            .padding(.bottom, 8)
                            .zIndex(10)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: model.selectedSessionID)
            .animation(.easeInOut(duration: 0.3), value: model.selectedMessages.isEmpty)
        }
        .background(LiquidContentSurface(cornerRadius: LiquidGlassToken.panelRadius))
        .clipShape(RoundedRectangle(cornerRadius: LiquidGlassToken.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlassToken.panelRadius, style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 24, y: 14)
        .background(FindKeyboardBridge(
            isEnabled: model.selectedSessionID != nil,
            isActive: findOpen,
            onOpen: { findOpen = true },
            onClose: { findOpen = false },
            onNavigate: { model.searchChatNext(direction: $0) }
        ))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            if !sidebarOpen {
                ToolbarIconButton(
                    systemImage: "sidebar.leading",
                    help: "Show sidebar",
                    active: false,
                    action: onToggleSidebar
                )
            }

            if model.selectedSessionID != nil && !model.workingDirectory.isEmpty {
                Text(model.modelDisplayName(model.settings.selectedModel))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(URL(fileURLWithPath: model.workingDirectory).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    agentPopoverOpen.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.selectedHasActiveTurn ? Color.orange : Color.mint)
                            .frame(width: 7, height: 7)
                        Text("Agent")
                        if !model.selectedToolCalls.isEmpty {
                            Text("\(model.selectedToolCalls.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.selectedHasActiveTurn ? Color.orange : Color.mint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(agentPopoverOpen ? Color.accentColor.opacity(0.10) : Color.clear)
                .clipShape(Capsule())
                .popover(isPresented: $agentPopoverOpen, arrowEdge: .top) {
                    AgentPopoverView()
                        .environmentObject(model)
                }
            }
            if model.selectedHasActiveTurn {
                ActivityPillView()
            }
            Spacer()
            HStack(spacing: 10) {
                if !model.workingDirectory.isEmpty {
                    ToolbarIconButton(systemImage: "square.and.arrow.down", help: "Export current session") {
                        if let selected = model.selectedSession {
                            model.exportMarkdown(session: selected)
                        } }
                    ToolbarIconButton(systemImage: "magnifyingglass", help: "Find in transcript", active: findOpen) { findOpen.toggle() }
                    ToolbarIconButton(
                        systemImage: "list.bullet.rectangle",
                        help: secondaryOpen && model.secondaryTab == .plan ? "Hide plan panel" : "Show plan panel",
                        active: secondaryOpen && model.secondaryTab == .plan,
                        action: togglePlanInspector
                    )
                }
                if !isFilePreviewMode {
                    ToolbarIconButton(
                        systemImage: "sidebar.trailing",
                        help: secondaryOpen ? "Hide inspector" : "Show inspector",
                        active: false,
                        action: onToggleSecondary
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: ShellMetric.topBarHeight)
        .background {
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private func togglePlanInspector() {
        if isFilePreviewMode {
            model.requestCloseFilePreview()
            model.secondaryTab = .plan
            if !secondaryOpen {
                onToggleSecondary()
            }
            return
        }
        if secondaryOpen && model.secondaryTab == .plan {
            onToggleSecondary()
        } else {
            model.secondaryTab = .plan
            if !secondaryOpen {
                onToggleSecondary()
            }
        }
    }

    private var welcomeState: some View {
        welcomeHero
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .onAppear {
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if reduceMotion {
                    logoOpacity = 1; headingOpacity = 1; subtitleOpacity = 1; chipsOpacity = 1
                } else {
                    withAnimation(.easeOut(duration: 0.45).delay(0.08)) { logoOpacity = 1 }
                    withAnimation(.easeOut(duration: 0.45).delay(0.22)) { headingOpacity = 1 }
                    withAnimation(.easeOut(duration: 0.4).delay(0.36)) { subtitleOpacity = 1 }
                    withAnimation(.easeOut(duration: 0.35).delay(0.50)) { chipsOpacity = 1 }
                }
            }
    }

    private var welcomeHero: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                let logoShape = RoundedRectangle(cornerRadius: 27, style: .continuous)
                LiquidCodeLogoView(fontSize: 26)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 17)
                    .liquidGlassControl(
                        logoShape,
                        interactive: false,
                        fallbackRadius: 27,
                        fallbackIntensity: .regular
                    )
                    .overlay {
                        logoShape.stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.62),
                                    Color.white.opacity(0.16),
                                    Color.black.opacity(0.055)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                    }
                    .shadow(color: .black.opacity(0.055), radius: 14, y: 7)
                    .opacity(logoOpacity)

                Text(model.currentGreeting.heading)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .opacity(headingOpacity)

                Text(model.currentGreeting.subtitle)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .opacity(subtitleOpacity)
            }

            InputBarView(presentation: .welcome)
                .opacity(chipsOpacity)
        }
    }

    private var readyState: some View {
        VStack(spacing: 12) {
            LiquidCodeLogoView(compact: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Ready when you are")
                .font(.title3.weight(.semibold))
            Text("Use / for commands, attach files, choose thinking effort, or switch into Plan mode before sending.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text(model.workingDirectory)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var displayItems: [TranscriptDisplayItem] {
        TranscriptDisplayBuilder.displayItems(messages: model.selectedMessages, pendingPermissions: model.pendingPermissionsForSelectedSession)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(displayItems) { item in
                        switch item {
                        case .message(let message):
                            MessageBubbleView(
                                message: message,
                                findText: model.chatFindText,
                                activeOccurrenceIndex: model.selectedChatFindTarget?.itemID == message.id ? model.selectedChatFindTarget?.occurrenceIndex : nil
                            ).id(message.id)
                        case .interaction(let permission):
                            InlineInteractionCardView(permission: permission).id("interaction_\(permission.id)")
                        case .tool(let item):
                            ToolDisplayItemView(item: item).id(item.id)
                        case .toolRun(let items):
                            ToolMessageGroupView(items: items).id(items.map(\.id).joined(separator: "_"))
                        }
                    }
                    if !model.selectedStreamingText.isEmpty {
                        MessageBubbleView(
                            message: ChatMessage(role: .assistant, content: model.selectedStreamingText),
                            findText: model.chatFindText
                        ).id("streaming") }
                    ForEach(model.selectedPendingUserMessages) { pending in QueuedUserMessageView(message: pending).id("queued_\(pending.id)") }
                }
                .frame(maxWidth: LiquidGlassToken.chatMaxWidth, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .padding(.bottom, 154)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: model.selectedMessages.count) { _, _ in if let last = model.selectedMessages.last {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            } }
            .onChange(of: model.selectedStreamingText) { _, _ in withAnimation { proxy.scrollTo("streaming", anchor: .bottom) } }
            .onChange(of: model.selectedPendingUserMessages.count) { _, _ in if let last = model.selectedPendingUserMessages.last {
                withAnimation { proxy.scrollTo(
                    "queued_\(last.id)",
                    anchor: .bottom
                ) } } }
            .onChange(of: model.selectedChatFindTarget?.id) { _, _ in
                if let target = model.selectedChatFindTarget {
                    withAnimation { proxy.scrollTo(target.itemID, anchor: .center) }
                } }
        }
    }
}

extension AppModel {
    var pendingPermissionsForSelectedSession: [PermissionRequest] {
        guard let selectedSessionID else {
            return []
        }
        return pendingPermissions.filter { $0.sessionID == selectedSessionID }
    }
}

struct ActivityPillView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if let permission = model.pendingPermissionsForSelectedSession.first {
                Text("Awaiting: \(permission.toolName)")
            } else if !model.selectedStreamingText.isEmpty {
                Text("Writing")
            } else {
                Text("Running")
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }
}

struct FindBarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    let onClose: () -> Void

    private var targets: [ChatFindTarget] {
        model.selectedChatFindTargets
    }

    private var status: String {
        guard !model.chatFindText.isEmpty else {
            return ""
        }
        guard !targets.isEmpty else {
            return "0 / 0"
        }
        return "\(min(model.chatFindIndex + 1, targets.count)) / \(targets.count)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Find in conversation", text: $model.chatFindText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.searchChatNext(direction: 1) }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Button { model.searchChatNext(direction: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.chatFindText.isEmpty || targets.isEmpty)
                .help("Previous match")
            Button { model.searchChatNext(direction: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.chatFindText.isEmpty || targets.isEmpty)
                .help("Next match")
            Button { model.chatFindText = ""; onClose() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close find bar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .onAppear { focused = true }
        .onChange(of: model.chatFindText) { _, _ in model.resetChatFindIndex() }
    }
}

struct FindKeyboardBridge: NSViewRepresentable {
    var isEnabled: Bool
    var isActive: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    let onNavigate: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen, onClose: onClose, onNavigate: onNavigate)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isActive = isActive
        context.coordinator.onOpen = onOpen
        context.coordinator.onClose = onClose
        context.coordinator.onNavigate = onNavigate
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var isEnabled = false
        var isActive = false
        var onOpen: () -> Void
        var onClose: () -> Void
        var onNavigate: (Int) -> Void
        private var monitor: Any?

        init(onOpen: @escaping () -> Void, onClose: @escaping () -> Void, onNavigate: @escaping (Int) -> Void) {
            self.onOpen = onOpen
            self.onClose = onClose
            self.onNavigate = onNavigate
        }

        func install() {
            guard monitor == nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else {
                    return event
                }
                if
                    isEnabled,
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                    event.charactersIgnoringModifiers?.lowercased() == "f" {
                    onOpen()
                    return nil
                }
                if isActive, event.keyCode == 53 {
                    onClose()
                    return nil
                }
                if isActive, event.keyCode == 36 {
                    onNavigate(event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) ? -1 : 1)
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

struct QueuedUserMessageView: View {
    let message: PendingUserMessage
    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Queued")
                    Spacer()
                    Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                MarkdownRendererView(content: message.content)
                if !message.attachments.isEmpty {
                    Text("\(message.attachments.count) attachment(s) queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.22)) }
            .frame(maxWidth: 760, alignment: .trailing)
        }
    }
}

struct PlanInspectorView: View {
    @EnvironmentObject var model: AppModel
    private var planMessages: [ChatMessage] {
        model.selectedMessages.filter { message in
            let lower = ((message.toolName ?? "") + " " + message.content).lowercased()
            return lower.contains("plan") || lower.contains("exitplanmode") || lower.contains("todo")
        }
    }

    private var pendingPlanApprovals: [PermissionRequest] {
        model.pendingPermissionsForSelectedSession.filter { InteractionAdapter(permission: $0).kind == .planReview }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("Plan", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    if model.settings.sessionMode == .plan {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
                Text("Review plan drafts, todos, and resolved plan approvals without resizing the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider().opacity(0.55)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if planMessages.isEmpty && pendingPlanApprovals.isEmpty {
                        ContentUnavailableView("No plan yet", systemImage: "list.bullet.rectangle", description: Text("Switch to Plan mode or approve an ExitPlanMode card."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                    if !pendingPlanApprovals.isEmpty {
                        Label("Plan approval pending in the composer action slot.", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background { StandardContentCardBackground(cornerRadius: 10, tint: .accentColor) }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(planMessages) { message in
                        MarkdownRendererView(content: message.content)
                            .padding(10)
                            .background { StandardContentCardBackground(cornerRadius: 10, tint: .accentColor) }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(12)
            }
        }
    }
}

struct MessageBubbleView: View {
    let message: ChatMessage
    var findText: String = ""
    var activeOccurrenceIndex: Int?

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .assistant:
            assistantMessage
        case .thinking:
            thinkingMessage
        case .tool:
            systemLikeMessage(icon: "wrench.and.screwdriver", tint: .secondary, title: message.toolName ?? "Tool")
        case .error:
            systemLikeMessage(icon: "exclamationmark.triangle.fill", tint: .red, title: "Error")
        case .system:
            systemLikeMessage(icon: "info.circle", tint: .secondary, title: "System")
        }
    }

    private var isFindMatch: Bool {
        !findText.isEmpty && !chatFindOccurrenceRanges(in: message.content, query: findText).isEmpty
    }

    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: "chevron.left.forwardslash.chevron.right", foreground: .white, background: .primary)
            VStack(alignment: .leading, spacing: 8) {
                if isFindMatch {
                    Label("match", systemImage: "magnifyingglass")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                MarkdownRendererView(content: message.content, findText: findText, activeOccurrenceIndex: activeOccurrenceIndex)
                    .textSelection(.enabled)
                    .font(.system(size: 16, weight: .regular))
                    .lineSpacing(4)
            }
            .frame(maxWidth: 920, alignment: .leading)
            Spacer(minLength: 60)
        }
        .padding(.vertical, 3)
    }

    private var thinkingMessage: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: "brain.head.profile", foreground: Color.accentColor, background: Color.accentColor.opacity(0.12))
            DisclosureGroup {
                MarkdownRendererView(content: message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } label: {
                Text(message.content.isEmpty ? "Thinking…" : "Thinking…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: 60)
        }
        .padding(.vertical, 1)
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text(softWrappedTranscriptText(message.content.isEmpty ? " " : message.content))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.attachments.isEmpty {
                    MessageAttachmentStripView(attachments: message.attachments, inverse: true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [Color.primary.opacity(0.90), Color.primary.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
            .frame(maxWidth: 720, alignment: .trailing)
        }
    }

    private func systemLikeMessage(icon: String, tint: Color, title: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: icon, foreground: tint, background: tint.opacity(0.12))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                MarkdownRendererView(content: message.content, findText: findText, activeOccurrenceIndex: activeOccurrenceIndex)
                    .textSelection(.enabled)
                    .font(.system(size: 13, design: message.role == .tool ? .monospaced : .default))
            }
            .padding(10)
            .background(tint.opacity(message.role == .error ? 0.12 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.14), lineWidth: 1))
            .frame(maxWidth: 760, alignment: .leading)
            Spacer(minLength: 60)
        }
    }
}

struct TranscriptAvatar: View {
    let systemImage: String
    let foreground: Color
    let background: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 26, height: 26)
            .background(background)
            .clipShape(Circle())
            .shadow(color: background.opacity(0.18), radius: 8, y: 3)
    }
}

struct MessageAttachmentStripView: View {
    let attachments: [AttachmentChip]
    var inverse = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                        Text(attachment.name)
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))
                            .foregroundStyle(inverse ? Color.white.opacity(0.62) : Color.secondary.opacity(0.65))
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(inverse ? Color.white.opacity(0.12) : Color.primary.opacity(0.055))
                    .clipShape(Capsule())
                    .help(attachment.path)
                }
            }
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case bullet(String)
    case task(checked: Bool, String)
    case numbered(String)
    case quote(String)
    case code(String, String)
    case image(MarkdownImageReference)
    case table(headers: [String], rows: [[String]])
    case horizontalRule
    case paragraph(String)
}

struct MarkdownRendererView: View {
    @EnvironmentObject var model: AppModel
    let content: String
    var findText: String = ""
    var activeOccurrenceIndex: Int?
    private var blocks: [MarkdownBlock] {
        parseMarkdown(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in render(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text): inlineText(text).font(level <= 1 ? .title3.bold() : .headline).padding(.top, level <= 1 ? 4 : 2)
        case .bullet(let text): HStack(alignment: .top, spacing: 6) { Text("•").foregroundStyle(.secondary); inlineText(text) }
        case .task(let checked, let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.mint : Color.secondary)
                    .font(.caption)
                    .padding(.top, 3)
                inlineText(text)
            }
        case .numbered(let text): HStack(alignment: .top, spacing: 6) { Text("#").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary); inlineText(text) }
        case .quote(let text): inlineText(text).padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 3) }
        case .code(let lang, let text):
            VStack(alignment: .leading, spacing: 5) {
                if !lang.isEmpty {
                    Text(lang).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text(highlightedAttributedString(text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .image(let reference): MarkdownImageView(reference: reference)
        case .table(let headers, let rows):
            VStack(spacing: 0) {
                markdownTableRow(headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in markdownTableRow(row, isHeader: false) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LiquidGlassToken.hairline, lineWidth: 1))
        case .horizontalRule:
            Divider().padding(.vertical, 4)
        case .paragraph(let text): inlineText(text)
        }
    }

    private func markdownTableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inlineText(cell)
                    .font(isHeader ? .caption.weight(.semibold) : .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(isHeader ? Color.primary.opacity(0.055) : Color.primary.opacity(0.025))
                    .overlay(alignment: .trailing) { Rectangle().fill(LiquidGlassToken.hairline).frame(width: 1) }
            }
        }
    }

    private func inlineText(_ text: String) -> Text {
        guard chatFindOccurrenceRanges(in: text, query: findText).isEmpty else {
            return Text(highlightedAttributedString(text))
        }
        let parts = text.components(separatedBy: "`")
        return parts.indices.reduce(Text("")) { output, index in
            output + Text(parts[index])
                .font(index.isMultiple(of: 2) ? .body : .system(.body, design: .monospaced))
                .foregroundStyle(index.isMultiple(of: 2) ? Color.primary : Color.accentColor)
        }
    }

    private func highlightedAttributedString(_ text: String) -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        let nsText = text as NSString
        for (occurrence, range) in chatFindOccurrenceRanges(in: text, query: findText).enumerated() {
            let nsRange = NSRange(range, in: text)
            let isActive = activeOccurrenceIndex == nil || activeOccurrenceIndex == occurrence
            mutable.addAttribute(.backgroundColor, value: (isActive ? NSColor.controlAccentColor : NSColor.systemYellow).withAlphaComponent(isActive ? 0.42 : 0.32), range: nsRange)
            mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: nsRange)
        }
        if nsText.length == 0 {
            return AttributedString("")
        }
        return AttributedString(mutable)
    }
}

struct MarkdownImageView: View {
    @EnvironmentObject var model: AppModel
    let reference: MarkdownImageReference

    var body: some View {
        if let url = model.resolveMarkdownImageURL(reference.source), let image = NSImage(contentsOf: url) {
            Button { model.openImageLightbox(source: reference.source, alt: reference.alt) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(reference.alt.isEmpty ? url.lastPathComponent : reference.alt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .background { StandardContentCardBackground(cornerRadius: 14, tint: .accentColor) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open image")
        } else {
            Label(reference.source, systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct HTMLPreviewView: NSViewRepresentable {
    let html: String
    let basePath: String?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let baseURL = basePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        nsView.loadHTMLString(html, baseURL: baseURL)
    }
}

struct ImageLightboxOverlayView: View {
    let content: ImageLightboxContent
    let onClose: () -> Void

    private var imageTitle: String {
        guard let alt = content.alt, !alt.isEmpty else {
            return "Image Preview"
        }
        return alt
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(0.58)
                .ignoresSafeArea()
                .pointingHandCursor()
                .onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(imageTitle).font(.headline)
                        if let filePath = content.filePath {
                            Text(filePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Close image preview")
                }
                if let image = NSImage(data: content.imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 920, maxHeight: 680)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ContentUnavailableView("Cannot display image", systemImage: "photo.badge.exclamationmark")
                }
            }
            .padding(18)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(radius: 28)
            .padding(32)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

func parseMarkdown(_ content: String) -> [MarkdownBlock] {
    var result: [MarkdownBlock] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var codeLanguage = ""
    var inCode = false
    func flushParagraph() {
        if !paragraph.isEmpty {
            result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll()
        } }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var index = 0
    while index < lines.count {
        let rawLine = lines[index]
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if inCode {
                result.append(.code(codeLanguage, codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                codeLanguage = ""
                inCode = false
            } else {
                flushParagraph()
                inCode = true
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            index += 1
            continue
        }
        if inCode {
            codeLines.append(rawLine); index += 1; continue
        }
        if trimmed.isEmpty {
            flushParagraph(); index += 1; continue
        }
        if let image = markdownImageReference(from: trimmed) {
            flushParagraph(); result.append(.image(image)); index += 1; continue
        }
        if isMarkdownHorizontalRule(trimmed) {
            flushParagraph(); result.append(.horizontalRule); index += 1; continue
        }
        if let table = markdownTableStarting(at: index, lines: lines) {
            flushParagraph()
            result.append(.table(headers: table.headers, rows: table.rows))
            index = table.nextIndex
            continue
        }
        if trimmed.hasPrefix("### ") {
            flushParagraph(); result.append(.heading(3, String(trimmed.dropFirst(4)))); index += 1; continue
        }
        if trimmed.hasPrefix("## ") {
            flushParagraph(); result.append(.heading(2, String(trimmed.dropFirst(3)))); index += 1; continue
        }
        if trimmed.hasPrefix("# ") {
            flushParagraph(); result.append(.heading(1, String(trimmed.dropFirst(2)))); index += 1; continue
        }
        if trimmed.hasPrefix("> ") {
            flushParagraph(); result.append(.quote(String(trimmed.dropFirst(2)))); index += 1; continue
        }
        if let task = markdownTask(from: trimmed) {
            flushParagraph(); result.append(.task(checked: task.checked, task.text)); index += 1; continue
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            flushParagraph(); result.append(.bullet(String(trimmed.dropFirst(2)))); index += 1; continue
        }
        if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            flushParagraph(); result.append(.numbered(trimmed.replacingOccurrences(
                of: #"^\d+\.\s"#,
                with: "",
                options: .regularExpression
            ))); index += 1; continue }
        paragraph.append(rawLine)
        index += 1
    }
    if inCode {
        result.append(.code(codeLanguage, codeLines.joined(separator: "\n")))
    }
    flushParagraph()
    return result.isEmpty ? [.paragraph(content)] : result
}

func markdownTask(from line: String) -> (checked: Bool, text: String)? {
    guard let match = line.range(of: #"^[-*]\s+\[([ xX])\]\s+"#, options: .regularExpression) else {
        return nil
    }
    let marker = String(line[match])
    let checked = marker.localizedCaseInsensitiveContains("[x]")
    let text = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
    return (checked, text)
}

func isMarkdownHorizontalRule(_ line: String) -> Bool {
    line.range(of: #"^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$"#, options: .regularExpression) != nil
}

struct MarkdownTableParseResult {
    let headers: [String]
    let rows: [[String]]
    let nextIndex: Int
}

func markdownTableStarting(at index: Int, lines: [String]) -> MarkdownTableParseResult? {
    guard index + 1 < lines.count else {
        return nil
    }
    let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
    let separatorLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
    let headers = splitMarkdownTableRow(headerLine)
    guard headers.count >= 2, isMarkdownTableSeparator(separatorLine) else {
        return nil
    }
    var rows: [[String]] = []
    var next = index + 2
    while next < lines.count {
        let line = lines[next].trimmingCharacters(in: .whitespaces)
        let cells = splitMarkdownTableRow(line)
        guard cells.count >= 2 else {
            break
        }
        rows.append(cells)
        next += 1
    }
    return MarkdownTableParseResult(headers: headers, rows: rows, nextIndex: next)
}

func splitMarkdownTableRow(_ line: String) -> [String] {
    var normalized = line
    if normalized.hasPrefix("|") {
        normalized.removeFirst()
    }
    if normalized.hasSuffix("|") {
        normalized.removeLast()
    }
    let cells = normalized.split(separator: "|", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
    return cells.contains(where: { !$0.isEmpty }) ? cells : []
}

func isMarkdownTableSeparator(_ line: String) -> Bool {
    let cells = splitMarkdownTableRow(line)
    guard cells.count >= 2 else {
        return false
    }
    return cells.allSatisfy { cell in
        cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
    }
}
