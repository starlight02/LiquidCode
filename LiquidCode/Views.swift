import AppKit
import SwiftUI
import WebKit

private enum ShellMetric {
    static let topBarHeight: CGFloat = 68
}

struct AppShellView: View {
    @EnvironmentObject var model: AppModel
    @State private var paletteQuery = ""
    @State private var sidebarOpen = true
    @State private var secondaryOpen = true
    @State private var previewSidebarOpen = false
    @State private var previewSecondaryOpen = false
    @State private var panelsBeforePreview: (sidebar: Bool, secondary: Bool)?
    @State private var previewWidth: Double = 640
    @State private var sidebarDragStart: Double?
    @State private var rightDragStart: Double?
    private var isFilePreviewMode: Bool { model.selectedFilePath != nil }

    var body: some View {
        ZStack {
            GlassGroup(spacing: LiquidGlassToken.panelSpacing) {
                HStack(spacing: LiquidGlassToken.panelSpacing) {
                    if sidebarOpen && !isFilePreviewMode {
                        SidebarView(onCollapse: { sidebarOpen = false })
                            .frame(width: model.settings.sidebarWidth)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .trailing) {
                                PaneResizeHandle(title: "Resize sidebar")
                                    .offset(x: 7)
                                    .gesture(sidebarResizeGesture)
                            }
                    }

                    ChatPanelView()
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                    if isFilePreviewMode {
                        FilePreviewShellView(onClose: { model.requestCloseFilePreview() })
                            .frame(width: previewWidth)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) {
                                PaneResizeHandle(title: "Resize preview")
                                    .offset(x: -7)
                                    .gesture(previewResizeGesture)
                            }
                    } else if secondaryOpen {
                        SecondaryPanelView(onClose: { secondaryOpen = false })
                            .frame(width: model.settings.secondaryWidth)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) {
                                PaneResizeHandle(title: "Resize secondary panel")
                                    .offset(x: -7)
                                    .gesture(secondaryResizeGesture)
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.snappy(duration: 0.22), value: sidebarOpen)
            .animation(.snappy(duration: 0.22), value: secondaryOpen)
            .animation(.snappy(duration: 0.22), value: isFilePreviewMode)
            .background(LiquidAppBackdrop())
            .background(WindowAccessor(configure: configureLiquidWindow))

            shellToggleButtons
            if isFilePreviewMode && previewSidebarOpen { floatingSidebar }
            if isFilePreviewMode && previewSecondaryOpen { floatingSecondary }

            if model.settingsOpen { SettingsPanelView() }
            if model.agentPanelOpen { AgentFloatingOverlayView() }
            if model.commandPaletteOpen { CommandPaletteView(query: $paletteQuery) }
            if let toast = model.toast { ToastBannerView(toast: toast) }
            if model.changelogOpen { ChangelogSheetView() }
            if let lightbox = model.imageLightbox { ImageLightboxOverlayView(content: lightbox) { model.imageLightbox = nil } }
        }
        .alert(item: $model.currentError) { err in Alert(title: Text(err.title), message: Text(err.message), dismissButton: .default(Text("OK"))) }
        .onAppear { model.bootstrap() }
        .onChange(of: isFilePreviewMode) { _, active in
            if active {
                let screenWidth = NSScreen.main?.visibleFrame.width ?? 1280
                previewWidth = min(900, max(420, screenWidth * 0.50))
                panelsBeforePreview = (sidebarOpen, secondaryOpen)
                previewSidebarOpen = false
                previewSecondaryOpen = false
                sidebarOpen = false
                secondaryOpen = false
            } else if let saved = panelsBeforePreview {
                sidebarOpen = saved.sidebar
                secondaryOpen = saved.secondary
                previewSidebarOpen = false
                previewSecondaryOpen = false
                panelsBeforePreview = nil
            }
        }
    }

    private var shellToggleButtons: some View {
        VStack {
            HStack {
                if isFilePreviewMode {
                    if !previewSidebarOpen {
                        FloatingShellToggleButton(systemImage: "sidebar.leading", help: "Show sidebar overlay") {
                            previewSidebarOpen = true
                        }
                            .help("Show sidebar overlay")
                    }
                } else if !sidebarOpen {
                    FloatingShellToggleButton(systemImage: "sidebar.leading", help: "Show sidebar") {
                        sidebarOpen = true
                    }
                        .help("Show sidebar")
                }
                Spacer()
                if isFilePreviewMode {
                    if !previewSecondaryOpen {
                        FloatingShellToggleButton(systemImage: "sidebar.trailing", help: "Show secondary panel overlay") {
                            previewSecondaryOpen = true
                        }
                            .help("Show secondary panel overlay")
                    }
                } else if !secondaryOpen {
                    FloatingShellToggleButton(systemImage: "sidebar.trailing", help: "Show secondary panel") {
                        secondaryOpen = true
                    }
                        .help("Show secondary panel")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 60)
            Spacer()
        }
        .allowsHitTesting(true)
    }

    private var floatingSidebar: some View {
        HStack {
            GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 18) {
                SidebarView(onCollapse: { previewSidebarOpen = false }).frame(width: min(360, max(260, model.settings.sidebarWidth)), height: 620)
            }
            .padding(.leading, 24)
            .shadow(radius: 18)
            Spacer()
        }.padding(.top, 46)
    }

    private var floatingSecondary: some View {
        HStack {
            Spacer()
            GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 18) {
                SecondaryPanelView(onClose: { previewSecondaryOpen = false }).frame(width: min(520, max(320, model.settings.secondaryWidth)), height: 620)
            }
            .padding(.trailing, previewWidth + 24)
            .shadow(radius: 18)
        }.padding(.top, 46)
    }

    private var sidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if sidebarDragStart == nil { sidebarDragStart = model.settings.sidebarWidth }
                let next = (sidebarDragStart ?? model.settings.sidebarWidth) + value.translation.width
                if next < 100 { sidebarOpen = false; sidebarDragStart = nil }
                else { model.settings.sidebarWidth = min(450, max(180, next)) }
            }
            .onEnded { _ in sidebarDragStart = nil; model.persistSettings() }
    }

    private var secondaryResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if rightDragStart == nil { rightDragStart = model.settings.secondaryWidth }
                let next = (rightDragStart ?? model.settings.secondaryWidth) - value.translation.width
                if next < 120 { secondaryOpen = false; rightDragStart = nil }
                else { model.settings.secondaryWidth = min(600, max(200, next)) }
            }
            .onEnded { _ in rightDragStart = nil; model.persistSettings() }
    }

    private var previewResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if rightDragStart == nil { rightDragStart = previewWidth }
                let next = (rightDragStart ?? previewWidth) - value.translation.width
                if next < 160 { model.requestCloseFilePreview(); rightDragStart = nil }
                else { previewWidth = min(1200, max(300, next)) }
            }
            .onEnded { _ in rightDragStart = nil }
    }
}

private struct PaneResizeHandle: View {
    let title: String
    var body: some View {
        Rectangle()
            .fill(Color.clear)
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(title)
        .zIndex(20)
    }
}

private struct LiquidContentSurface: View {
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

private struct StableControlLabel: View {
    let title: String
    let systemImage: String
    var active = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.76))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .liquidGlassControl(RoundedRectangle(cornerRadius: LiquidGlassToken.controlRadius, style: .continuous), active: active, fallbackRadius: LiquidGlassToken.controlRadius, fallbackIntensity: active ? .prominent : .subtle)
    }
}

private struct NativeToolbarMenuLabel: View {
    let title: String
    let systemImage: String
    var active = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? Color.white.opacity(0.80) : Color.secondary.opacity(0.78))
        }
        .foregroundStyle(active ? Color.white : Color.primary.opacity(0.78))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .liquidGlassControl(Capsule(), active: active, fallbackRadius: 17, fallbackIntensity: active ? .prominent : .subtle)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct StandardContentCardBackground: View {
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

private struct LiquidComposerWell: View {
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

private struct LiquidDarkCTA: View {
    let cornerRadius: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [Color.black.opacity(0.88), Color.black.opacity(0.76), Color.black.opacity(0.92)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.03), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
            }
            .overlay { shape.stroke(Color.white.opacity(0.18), lineWidth: 1) }
    }
}

private struct TokenicodeLogoView: View {
    var compact = false
    var body: some View {
        HStack(spacing: 0) {
            Text("LIQUID")
                .font(.system(size: compact ? 13 : 20, weight: .semibold, design: .rounded))
                .tracking(-1.1)
            Text("/")
                .font(.system(size: compact ? 13 : 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(-0.8)
            Text("CODE")
                .font(.system(size: compact ? 13 : 20, weight: .semibold, design: .rounded))
                .tracking(-0.8)
        }
        .accessibilityLabel("LiquidCode")
    }
}

private struct GlassSearchField: View {
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassControl(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false, fallbackRadius: 16)
    }
}

private struct IconChip: View {
    let title: String
    let systemImage: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.78))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .liquidGlassControl(RoundedRectangle(cornerRadius: 13, style: .continuous), active: active, fallbackRadius: 13, fallbackIntensity: active ? .prominent : .regular)
        }
        .buttonStyle(.plain)
    }
}


private struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var active = false
    var disabled = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary.opacity(disabled ? 0.30 : 0.82))
                .frame(width: 42, height: 42)
                .liquidGlassControl(Circle(), active: active, disabled: disabled, fallbackRadius: 21, fallbackIntensity: active ? .prominent : .subtle)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.58 : 1)
        .help(help)
    }
}

private struct FloatingShellToggleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(width: 36, height: 36)
                .liquidGlassControl(Circle(), fallbackRadius: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SectionCaption: View {
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

private struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.45), radius: 4)
    }
}

private func shortModelName(_ model: String) -> String {
    let cleaned = model
        .replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "[1m]", with: " 1M")
        .replacingOccurrences(of: "-1m", with: " 1M")
        .replacingOccurrences(of: "-", with: " ")
    let pieces = cleaned.split(separator: " ").map(String.init)
    guard !pieces.isEmpty else { return model }
    if pieces.count >= 3 {
        return "\(pieces[0].capitalized) \(pieces[1]).\(pieces[2])" + (pieces.contains("1M") ? " 1M" : "")
    }
    return cleaned.capitalized
}

private func lineCount(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return text.split(separator: "\n", omittingEmptySubsequences: false).count
}

private func fileIconName(for fileName: String, isDirectory: Bool = false) -> String {
    if isDirectory { return "folder" }
    let lower = fileName.lowercased()
    let ext = URL(fileURLWithPath: lower).pathExtension
    if lower == "dockerfile" || lower.hasSuffix(".dockerfile") { return "shippingbox" }
    if ["swift"].contains(ext) { return "swift" }
    if ["js", "jsx", "ts", "tsx", "mjs", "cjs"].contains(ext) { return "curlybraces.square" }
    if ["json", "jsonl", "lock"].contains(ext) { return "curlybraces" }
    if ["html", "htm", "xhtml", "svg"].contains(ext) { return "globe" }
    if ["css", "scss", "sass", "less"].contains(ext) { return "paintbrush" }
    if ["md", "mdx", "txt", "rst", "adoc"].contains(ext) { return "doc.text" }
    if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico"].contains(ext) { return "photo" }
    if ["mp4", "mov", "avi", "webm", "mkv"].contains(ext) { return "film" }
    if ["mp3", "wav", "ogg", "aac", "m4a", "flac"].contains(ext) { return "waveform" }
    if ext == "pdf" { return "doc.richtext" }
    if ["zip", "tar", "gz", "rar", "7z", "dmg", "pkg"].contains(ext) { return "archivebox" }
    if ["sh", "bash", "zsh", "fish", "command", "bat", "ps1"].contains(ext) { return "terminal" }
    if ["py", "rb", "php", "lua", "pl"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
    if ["rs", "go", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm"].contains(ext) { return "hammer" }
    if ["yml", "yaml", "toml", "ini", "env", "plist", "xcconfig"].contains(ext) || lower.hasPrefix(".env") { return "slider.horizontal.3" }
    if ["db", "sqlite", "sql"].contains(ext) { return "cylinder.split.1x2" }
    if ["csv", "tsv", "xls", "xlsx"].contains(ext) { return "tablecells" }
    if ["ttf", "otf", "woff", "woff2"].contains(ext) { return "textformat" }
    if ["key", "pem", "crt", "cer", "p12"].contains(ext) { return "lock.doc" }
    return "doc"
}

private func fileIconColor(for fileName: String, isDirectory: Bool = false) -> Color {
    if isDirectory { return .accentColor }
    let ext = URL(fileURLWithPath: fileName.lowercased()).pathExtension
    if ["swift"].contains(ext) { return .orange }
    if ["js", "jsx", "ts", "tsx", "json"].contains(ext) { return .yellow }
    if ["html", "htm", "css", "scss", "svg"].contains(ext) { return .blue }
    if ["md", "mdx", "txt"].contains(ext) { return .secondary }
    if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return .purple }
    if ["sh", "bash", "zsh", "command"].contains(ext) { return .green }
    if ["zip", "dmg", "pkg", "tar", "gz"].contains(ext) { return .brown }
    return .secondary
}

private func modeIcon(_ mode: SessionMode) -> String {
    switch mode {
    case .code: "bolt.fill"
    case .ask: "bubble.left.and.bubble.right"
    case .plan: "list.bullet.rectangle"
    case .bypass: "star"
    }
}

private func thinkingIcon(_ level: ThinkingLevel) -> String {
    level == .off ? "lightbulb.slash" : "lightbulb"
}

private struct FilePreviewShellView: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void
    private var fileName: String { model.selectedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File Preview" }
    private var fileExtension: String { URL(fileURLWithPath: fileName).pathExtension.lowercased() }
    private var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico"].contains(fileExtension) }
    private var isTextEditable: Bool { !isImage }
    private var availableModes: [FilePreviewMode] {
        if ["html", "htm", "xhtml"].contains(fileExtension) { return [.html, .source, .edit] }
        if ["md", "mdx"].contains(fileExtension) { return [.preview, .source, .edit] }
        if isImage { return [.preview] }
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
                            if let path = model.selectedFilePath { model.openFile(path) }
                        }
                            .buttonStyle(.plain)
                            .tokenicodeControl(radius: 10)
                        Button("Save") { model.saveSelectedFile() }
                            .buttonStyle(.plain)
                            .tokenicodeControl(active: true, radius: 10)
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
                    ToolbarIconButton(systemImage: "doc.on.clipboard", help: "Insert file content into chat", disabled: model.filePreview.isEmpty) { model.insertSelectedContentIntoChat() }
                    Spacer()
                    Button("Delete") { model.requestDeleteSelectedFile() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .tokenicodeControl(radius: 10)
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
            if !availableModes.contains(model.filePreviewMode) { model.filePreviewMode = availableModes.first ?? .preview }
        }
    }
}

private struct FilePreviewModeButton: View {
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

private struct CodeSourceView: View {
    let text: String
    private var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
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

private struct CodeEditorWithLineNumbers: View {
    @Binding var text: String
    private var count: Int { max(1, lineCount(text)) }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(1...count, id: \.self) { index in
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

private struct ImageFilePreview: View {
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

private func highlightCodeLine(_ line: String) -> AttributedString {
    var attributed = AttributedString(line.isEmpty ? " " : line)
    let keywords = ["import", "func", "struct", "class", "enum", "let", "var", "return", "if", "else", "switch", "case", "for", "while", "guard", "try", "catch", "async", "await", "export", "const", "from"]
    for keyword in keywords {
        if let range = attributed.range(of: keyword) {
            attributed[range].foregroundColor = .blue
            attributed[range].font = .system(size: 14, weight: .semibold, design: .monospaced)
        }
    }
    if let comment = attributed.range(of: "//") {
        attributed[comment.lowerBound..<attributed.endIndex].foregroundColor = .secondary
    }
    return attributed
}

struct SidebarView: View {
    var onCollapse: () -> Void = {}
    @EnvironmentObject var model: AppModel
    @State private var renameTarget: SessionRecord?
    @State private var renameText = ""

    private var searchedSessions: [SessionRecord] {
        model.sessions.filter { session in
            let matchesSearch = model.searchText.isEmpty || session.title.localizedCaseInsensitiveContains(model.searchText) || session.project.localizedCaseInsensitiveContains(model.searchText)
            let matchesRunning = !model.showRunningSessionsOnly || model.hasActiveTurn(for: session.id)
            return matchesSearch && matchesRunning
        }
    }
    private var pinnedSessions: [SessionRecord] { searchedSessions.filter { $0.pinned && !$0.archived } }
    private var activeSessions: [SessionRecord] { searchedSessions.filter { !$0.pinned && !$0.archived } }
    private var archivedSessions: [SessionRecord] { searchedSessions.filter { $0.archived } }

    var body: some View {
        GlassPanel(role: .sidebar, prominence: .regular, cornerRadius: LiquidGlassToken.panelRadius) {
            VStack(spacing: 0) {
                sidebarHeader
                primaryAction
                if !model.workingDirectory.isEmpty { projectCard }
                searchAndFilters
                undoBanner
                Divider().opacity(0.5)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        taskGroupsHeader
                        taskGroups
                        sessionSection("Pinned", pinnedSessions, trailing: pinnedSessions.isEmpty ? nil : "\(pinnedSessions.count)")
                        datedSessionSections(activeSessions)
                        if model.showArchivedSessions { sessionSection("Archived", archivedSessions, trailing: archivedSessions.isEmpty ? nil : "\(archivedSessions.count)") }
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
            }.padding().frame(width: 360)
        }
    }

    private var sidebarHeader: some View {
        HStack(alignment: .center) {
            TokenicodeLogoView()
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
        Button(action: model.newChat) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                Text("New Chat")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background { LiquidDarkCTA(cornerRadius: 28) }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .help("Open a project folder and start a new Claude Code session")
    }

    private var projectCard: some View {
        HStack(spacing: 10) {
            StatusDot(color: model.selectedHasActiveTurn ? .green : .mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: model.workingDirectory).lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text((model.workingDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(model.selectedHasActiveTurn ? "Running" : "Ready")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .liquidGlassCard(role: .floatingCard, prominence: .subtle, radius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            GlassSearchField(placeholder: "Search sessions", text: $model.searchText)
            HStack(spacing: 8) {
                ToolbarIconButton(systemImage: "checklist", help: "Batch select", active: model.sessionSelectionMode) { model.toggleSessionSelectionMode() }
                ToolbarIconButton(systemImage: "bolt.circle", help: "Running sessions", active: model.showRunningSessionsOnly) { model.showRunningSessionsOnly.toggle() }
                ToolbarIconButton(systemImage: model.showArchivedSessions ? "archivebox.fill" : "archivebox", help: "Show archived", active: model.showArchivedSessions) { model.showArchivedSessions.toggle() }
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
                    .tokenicodeRow()
                }
                .contextMenu {
                    if let selected = model.selectedSession, selected.projectDir == group.projectPath { Button("Add Current Session") { model.addSession(selected, to: group) } }
                    Button("Delete Group", role: .destructive) { model.deleteGroup(group) }
                }
            }
        }
    }

    @ViewBuilder private func datedSessionSections(_ sessions: [SessionRecord]) -> some View {
        let today = sessions.filter { Calendar.current.isDateInToday($0.modifiedAt) }
        let yesterday = sessions.filter { Calendar.current.isDateInYesterday($0.modifiedAt) }
        let week = sessions.filter { !Calendar.current.isDateInToday($0.modifiedAt) && !Calendar.current.isDateInYesterday($0.modifiedAt) && Calendar.current.isDate($0.modifiedAt, equalTo: Date(), toGranularity: .weekOfYear) }
        let earlier = sessions.filter { session in
            !today.contains(session) && !yesterday.contains(session) && !week.contains(session)
        }
        sessionSection("Today", today)
        sessionSection("Yesterday", yesterday)
        sessionSection("This Week", week)
        sessionSection("Earlier", earlier)
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
                if model.sessionSelectionMode { model.toggleSessionSelection(session) }
                else { model.selectSession(session.id) }
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
    var selected: Bool { model.selectedSessionID == session.id }
    var checked: Bool { model.selectedSessionIDs.contains(session.id) }
    var running: Bool { model.hasActiveTurn(for: session.id) }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.sessionSelectionMode {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
            } else {
                StatusDot(color: running ? .green : (session.isDraft ? .orange : .mint.opacity(0.8)))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .lineLimit(1)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    if session.isDraft {
                        Text("Draft").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: session.projectDir).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.primary.opacity(0.68) : .secondary)
                        .lineLimit(1)
                    Text(session.modifiedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            HStack(spacing: 5) {
                if session.pinned { Image(systemName: "pin.fill").font(.caption2) }
                if session.archived { Image(systemName: "archivebox.fill").font(.caption2) }
            }
            .foregroundStyle(.secondary)
        }
        .tokenicodeRow(active: selected || checked, radius: 15)
    }
}

struct ChatPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var findOpen = false
    @State private var planPanelOpen = false
    @State private var agentPopoverOpen = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.white.opacity(0.30)).frame(height: 0.5).blendMode(.overlay)
            if findOpen { FindBarView(onClose: { findOpen = false }) }
            HStack(spacing: 0) {
                ZStack {
                    if model.selectedSessionID == nil { welcomeState }
                    else if model.selectedMessages.isEmpty && model.selectedStreamingText.isEmpty && model.pendingPermissionsForSelectedSession.isEmpty { readyState }
                    else { transcript }
                }
                if planPanelOpen { PlanSidePanelView(onClose: { planPanelOpen = false }) }
            }
            if !model.workingDirectory.isEmpty { InputBarView() }
        }
        .background(LiquidContentSurface(cornerRadius: LiquidGlassToken.panelRadius))
        .clipShape(RoundedRectangle(cornerRadius: LiquidGlassToken.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LiquidGlassToken.panelRadius, style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 24, y: 14)
        .background(FindKeyboardBridge(isEnabled: !model.workingDirectory.isEmpty, isActive: findOpen, onOpen: { findOpen = true }, onClose: { findOpen = false }, onNavigate: { model.searchChatNext(direction: $0) }))
    }

    private var toolbar: some View {
        GlassPanel(role: .toolbar, prominence: .subtle, cornerRadius: 22) {
            HStack(spacing: 14) {
                if !model.workingDirectory.isEmpty {
                    Text(shortModelName(model.settings.selectedModel))
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
                    Label(model.cliStatus.installed ? "CLI" : "CLI missing", systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(model.cliStatus.installed ? Color.mint.opacity(0.8) : Color.orange)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Choose a project to start")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .tokenicodeControl()
                }
                if model.selectedHasActiveTurn { ActivityPillView() }
                Spacer()
                if !model.workingDirectory.isEmpty {
                    ToolbarIconButton(systemImage: "square.and.arrow.down", help: "Export current session") { if let selected = model.selectedSession { model.exportMarkdown(session: selected) } }
                    ToolbarIconButton(systemImage: "magnifyingglass", help: "Find in transcript", active: findOpen) { findOpen.toggle() }
                    ToolbarIconButton(systemImage: "list.bullet.rectangle", help: "Show plan panel", active: planPanelOpen || model.settings.sessionMode == .plan) { planPanelOpen.toggle() }
                    ToolbarIconButton(systemImage: "stop.fill", help: "Interrupt current turn", disabled: !model.selectedHasActiveTurn) { model.interrupt() }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: ShellMetric.topBarHeight)
        }
    }

    private var welcomeState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                TokenicodeLogoView()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(LiquidGlassToken.hairline))
                Text("Welcome to LiquidCode")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Select a project folder to get started")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                IconChip(title: "Select Folder", systemImage: "folder", active: true) { model.newChat() }
                    .frame(width: 190)

                if !model.recentProjects.isEmpty {
                    VStack(spacing: 10) {
                        Text("Recent Projects")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(model.recentProjects.prefix(6))) { project in
                                    Button { model.loadProject(project.path) } label: {
                                        Label(project.name, systemImage: "folder")
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.bordered)
                                    .help(project.path)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(.top, 14)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var readyState: some View {
        VStack(spacing: 12) {
            TokenicodeLogoView(compact: true)
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
                            MessageBubbleView(message: message, findText: model.chatFindText, activeOccurrenceIndex: model.selectedChatFindTarget?.itemID == message.id ? model.selectedChatFindTarget?.occurrenceIndex : nil).id(message.id)
                        case .interaction(let permission):
                            InlineInteractionCardView(permission: permission).id("interaction_\(permission.id)")
                        case .tool(let item):
                            ToolDisplayItemView(item: item).id(item.id)
                        case .toolRun(let items):
                            ToolMessageGroupView(items: items).id(items.map(\.id).joined(separator: "_"))
                        }
                    }
                    if !model.selectedStreamingText.isEmpty { MessageBubbleView(message: ChatMessage(role: .assistant, content: model.selectedStreamingText), findText: model.chatFindText).id("streaming") }
                    ForEach(model.selectedPendingUserMessages) { pending in QueuedUserMessageView(message: pending).id("queued_\(pending.id)") }
                }
                .frame(maxWidth: LiquidGlassToken.chatMaxWidth, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: model.selectedMessages.count) { _, _ in if let last = model.selectedMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            .onChange(of: model.selectedStreamingText) { _, _ in withAnimation { proxy.scrollTo("streaming", anchor: .bottom) } }
            .onChange(of: model.selectedPendingUserMessages.count) { _, _ in if let last = model.selectedPendingUserMessages.last { withAnimation { proxy.scrollTo("queued_\(last.id)", anchor: .bottom) } } }
            .onChange(of: model.selectedChatFindTarget?.id) { _, _ in if let target = model.selectedChatFindTarget { withAnimation { proxy.scrollTo(target.itemID, anchor: .center) } } }
        }
    }
}

private extension AppModel {
    var pendingPermissionsForSelectedSession: [PermissionRequest] {
        guard let selectedSessionID else { return [] }
        return pendingPermissions.filter { $0.sessionID == selectedSessionID }
    }
}

private struct ActivityPillView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if let permission = model.pendingPermissionsForSelectedSession.first { Text("Awaiting: \(permission.toolName)") }
            else if !model.selectedStreamingText.isEmpty { Text("Writing") }
            else { Text("Running") }
        }
        .font(.caption)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.thinMaterial).clipShape(Capsule())
    }
}

private struct FindBarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    let onClose: () -> Void

    private var targets: [ChatFindTarget] { model.selectedChatFindTargets }
    private var status: String {
        guard !model.chatFindText.isEmpty else { return "" }
        guard !targets.isEmpty else { return "0 / 0" }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .onAppear { focused = true }
        .onChange(of: model.chatFindText) { _, _ in model.resetChatFindIndex() }
    }
}

private struct FindKeyboardBridge: NSViewRepresentable {
    var isEnabled: Bool
    var isActive: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    let onNavigate: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen, onClose: onClose, onNavigate: onNavigate) }
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
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.uninstall() }

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
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if isEnabled,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "f" {
                    self.onOpen()
                    return nil
                }
                if isActive, event.keyCode == 53 {
                    self.onClose()
                    return nil
                }
                if isActive, event.keyCode == 36 {
                    self.onNavigate(event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) ? -1 : 1)
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct QueuedUserMessageView: View {
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

private struct PlanSidePanelView: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void
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
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Plan Panel").font(.headline); Spacer(); Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text(model.settings.sessionMode == .plan ? "Plan mode is active" : "Review resolved plan messages; live approvals stay by the composer.").font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if planMessages.isEmpty && pendingPlanApprovals.isEmpty {
                        ContentUnavailableView("No plan yet", systemImage: "list.bullet.rectangle", description: Text("Switch to Plan mode or approve an ExitPlanMode card."))
                    }
                    if !pendingPlanApprovals.isEmpty {
                        Label("Plan approval pending in the action slot above the composer.", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background { StandardContentCardBackground(cornerRadius: 10, tint: .accentColor) }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(planMessages) { MarkdownRendererView(content: $0.content).padding(10).background { StandardContentCardBackground(cornerRadius: 10, tint: .accentColor) }.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                }
            }
        }.padding(12).frame(width: 320).background(.ultraThinMaterial).overlay(alignment: .leading) { Divider() }
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

    private var isFindMatch: Bool { !findText.isEmpty && !chatFindOccurrenceRanges(in: message.content, query: findText).isEmpty }

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
                Text(message.content.isEmpty ? " " : message.content)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
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

private struct TranscriptAvatar: View {
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

private struct MessageAttachmentStripView: View {
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

private struct MarkdownRendererView: View {
    @EnvironmentObject var model: AppModel
    let content: String
    var findText: String = ""
    var activeOccurrenceIndex: Int?
    private var blocks: [MarkdownBlock] { parseMarkdown(content) }

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
                if !lang.isEmpty { Text(lang).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
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
        guard chatFindOccurrenceRanges(in: text, query: findText).isEmpty else { return Text(highlightedAttributedString(text)) }
        var output = Text("")
        let parts = text.components(separatedBy: "`")
        for index in parts.indices { output = output + Text(parts[index]).font(index.isMultiple(of: 2) ? .body : .system(.body, design: .monospaced)).foregroundStyle(index.isMultiple(of: 2) ? Color.primary : Color.accentColor) }
        return output
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
        if nsText.length == 0 { return AttributedString("") }
        return AttributedString(mutable)
    }
}


private struct MarkdownImageView: View {
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

private struct HTMLPreviewView: NSViewRepresentable {
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

private struct ImageLightboxOverlayView: View {
    let content: ImageLightboxContent
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(content.alt?.isEmpty == false ? content.alt! : "Image Preview").font(.headline)
                        if let filePath = content.filePath { Text(filePath).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
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
    func flushParagraph() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll() } }
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
        if inCode { codeLines.append(rawLine); index += 1; continue }
        if trimmed.isEmpty { flushParagraph(); index += 1; continue }
        if let image = markdownImageReference(from: trimmed) { flushParagraph(); result.append(.image(image)); index += 1; continue }
        if isMarkdownHorizontalRule(trimmed) { flushParagraph(); result.append(.horizontalRule); index += 1; continue }
        if let table = markdownTableStarting(at: index, lines: lines) {
            flushParagraph()
            result.append(.table(headers: table.headers, rows: table.rows))
            index = table.nextIndex
            continue
        }
        if trimmed.hasPrefix("### ") { flushParagraph(); result.append(.heading(3, String(trimmed.dropFirst(4)))); index += 1; continue }
        if trimmed.hasPrefix("## ") { flushParagraph(); result.append(.heading(2, String(trimmed.dropFirst(3)))); index += 1; continue }
        if trimmed.hasPrefix("# ") { flushParagraph(); result.append(.heading(1, String(trimmed.dropFirst(2)))); index += 1; continue }
        if trimmed.hasPrefix("> ") { flushParagraph(); result.append(.quote(String(trimmed.dropFirst(2)))); index += 1; continue }
        if let task = markdownTask(from: trimmed) { flushParagraph(); result.append(.task(checked: task.checked, task.text)); index += 1; continue }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { flushParagraph(); result.append(.bullet(String(trimmed.dropFirst(2)))); index += 1; continue }
        if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil { flushParagraph(); result.append(.numbered(trimmed.replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression))); index += 1; continue }
        paragraph.append(rawLine)
        index += 1
    }
    if inCode { result.append(.code(codeLanguage, codeLines.joined(separator: "\n"))) }
    flushParagraph()
    return result.isEmpty ? [.paragraph(content)] : result
}

private func markdownTask(from line: String) -> (checked: Bool, text: String)? {
    guard let match = line.range(of: #"^[-*]\s+\[([ xX])\]\s+"#, options: .regularExpression) else { return nil }
    let marker = String(line[match])
    let checked = marker.localizedCaseInsensitiveContains("[x]")
    let text = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
    return (checked, text)
}

private func isMarkdownHorizontalRule(_ line: String) -> Bool {
    line.range(of: #"^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$"#, options: .regularExpression) != nil
}

private func markdownTableStarting(at index: Int, lines: [String]) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
    guard index + 1 < lines.count else { return nil }
    let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
    let separatorLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
    let headers = splitMarkdownTableRow(headerLine)
    guard headers.count >= 2, isMarkdownTableSeparator(separatorLine) else { return nil }
    var rows: [[String]] = []
    var next = index + 2
    while next < lines.count {
        let line = lines[next].trimmingCharacters(in: .whitespaces)
        let cells = splitMarkdownTableRow(line)
        guard cells.count >= 2 else { break }
        rows.append(cells)
        next += 1
    }
    return (headers, rows, next)
}

private func splitMarkdownTableRow(_ line: String) -> [String] {
    var normalized = line
    if normalized.hasPrefix("|") { normalized.removeFirst() }
    if normalized.hasSuffix("|") { normalized.removeLast() }
    let cells = normalized.split(separator: "|", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
    return cells.contains(where: { !$0.isEmpty }) ? cells : []
}

private func isMarkdownTableSeparator(_ line: String) -> Bool {
    let cells = splitMarkdownTableRow(line)
    guard cells.count >= 2 else { return false }
    return cells.allSatisfy { cell in
        cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
    }
}


private struct ToolDisplayItemView: View {
    let item: TranscriptToolItem
    var compact: Bool = false
    @State private var expanded = false

    private var payload: String { cleanToolPayload(item.content) }
    private var displayPayload: String {
        if !payload.isEmpty { return payload }
        return item.kind == .use ? "No input payload." : "Completed with no textual output."
    }
    private var parsedJSON: [(String, String)] { toolPayloadKeyValues(payload) }
    private var tint: Color { item.kind == .use ? Color.accentColor : Color.green }
    private var icon: String { item.kind == .use ? toolIconName(item.toolName) : "checkmark.circle.fill" }

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

private struct ToolMessageGroupView: View {
    let items: [TranscriptToolItem]
    @State private var expanded: Bool
    init(items: [TranscriptToolItem]) {
        self.items = items
        _expanded = State(initialValue: items.count <= 2 || !TranscriptToolRunCompletion.isComplete(items))
    }
    private var allComplete: Bool { TranscriptToolRunCompletion.isComplete(items) }
    private var summary: String {
        let names = items.contains { $0.kind == .use } ? items.filter { $0.kind == .use }.map(\.toolName) : items.map(\.summaryName)
        return Dictionary(grouping: names, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TranscriptAvatar(systemImage: allComplete ? "checkmark.seal.fill" : "square.stack.3d.up", foreground: allComplete ? .green : .secondary, background: (allComplete ? Color.green : Color.primary).opacity(0.10))
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

private func cleanToolPayload(_ content: String) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("[tool_use:") || first.hasPrefix("[tool_result") else {
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func toolPayloadKeyValues(_ payload: String) -> [(String, String)] {
    guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any] else { return [] }
    let preferred = ["description", "command", "file_path", "path", "subagent_type", "prompt", "url", "pattern"]
    let keys = preferred.filter { dict[$0] != nil } + dict.keys.sorted().filter { !preferred.contains($0) }
    return keys.map { key in
        let raw = dict[key]!
        let value: String
        if let string = raw as? String { value = string }
        else if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) { value = json }
        else { value = String(describing: raw) }
        return (key.replacingOccurrences(of: "_", with: " "), value)
    }
}

private func toolIconName(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("bash") || lower.contains("shell") { return "terminal" }
    if lower.contains("read") { return "doc.text.magnifyingglass" }
    if lower.contains("write") || lower.contains("edit") { return "pencil.and.outline" }
    if lower.contains("task") || lower.contains("agent") { return "point.3.connected.trianglepath.dotted" }
    if lower.contains("web") || lower.contains("fetch") { return "globe" }
    return "wrench.and.screwdriver"
}


struct ToolCardView: View {
    let tool: ToolCall
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.inputPreview.isEmpty { Text(tool.inputPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if !tool.resultPreview.isEmpty { Divider(); MarkdownRendererView(content: tool.resultPreview).font(.caption).textSelection(.enabled) }
            }.padding(.top, 6)
        } label: {
            HStack { Image(systemName: icon); Text(tool.name).font(.callout.bold()); Text(tool.status.rawValue).font(.caption).foregroundStyle(statusColor); Spacer(); if let completed = tool.completedAt { Text(completed, style: .time).font(.caption2) } }
        }
        .padding(12)
        .background { StandardContentCardBackground(cornerRadius: 12, tint: statusColor) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private var icon: String { tool.name == "Bash" ? "terminal" : tool.name == "Edit" || tool.name == "Write" ? "pencil.and.scribble" : "wrench.and.screwdriver" }
    private var statusColor: Color { tool.status == .failed || tool.status == .denied ? .red : tool.status == .succeeded ? .green : .secondary }
}


private enum InteractionCardKind { case permission, planReview, question }

private struct InteractionAdapter {
    let permission: PermissionRequest
    // PermissionRequest currently stores toolName + inputJSON but not the raw
    // control metadata envelope. Parse any mirrored metadata/subtype/input fields
    // from inputJSON first; toolName is only a last-resort UI heuristic.
    var kind: InteractionCardKind {
        if inputContainsQuestions { return .question }
        if inputContainsPlanReview { return .planReview }
        if fallbackToolName.contains("askuserquestion") || fallbackToolName.contains("ask_user_question") { return .question }
        if fallbackToolName.contains("exitplan") || fallbackToolName.contains("plan") { return .planReview }
        return .permission
    }
    private var fallbackToolName: String { permission.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var inputObject: [String: Any]? {
        guard let data = permission.inputJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private var candidateObjects: [[String: Any]] {
        guard let inputObject else { return [] }
        var objects = [inputObject]
        if let metadata = inputObject["metadata"] as? [String: Any] { objects.append(metadata) }
        if let input = inputObject["input"] as? [String: Any] { objects.append(input) }
        if let nested = inputObject["request"] as? [String: Any] { objects.append(nested) }
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

private struct InlineInteractionCardView: View {
    let permission: PermissionRequest
    var body: some View {
        switch InteractionAdapter(permission: permission).kind {
        case .question: QuestionInlineCardView(permission: permission)
        case .planReview: PlanReviewInlineCardView(permission: permission)
        case .permission: PermissionInlineCardView(permission: permission)
        }
    }
}

private struct ActiveInteractionSlotView: View {
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

private struct PermissionInlineCardView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    @State private var editedInput = ""
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: { HStack(spacing: 8) { Image(systemName: icon).foregroundStyle(color); Text("Permission request").font(.headline); Text(permission.toolName).font(.caption.monospaced()).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.12)).clipShape(Capsule()); Spacer(); Text(permission.risk.rawValue).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain)
            Text(permission.summary).font(.callout).foregroundStyle(.secondary)
            if expanded { TextEditor(text: $editedInput).font(.system(.caption, design: .monospaced)).frame(height: 120).onAppear { if editedInput.isEmpty { editedInput = permission.inputJSON } } }
            HStack {
                Button("Deny", role: .destructive) { model.respondPermission(permission, allow: false) }
                    .buttonStyle(.plain)
                    .tokenicodeControl(radius: 11)
                Spacer()
                Button {
                    model.respondPermission(permission, allow: true, editedInput: editedInput.isEmpty ? permission.inputJSON : editedInput)
                } label: {
                    Label("Allow Once", systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                .tokenicodeControl(active: true, radius: 11)
            }
        }
        .padding(14)
        .background { StandardContentCardBackground(cornerRadius: 16, tint: color) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .padding(.leading, 44)
    }
    private var icon: String { permission.risk == .destructive ? "exclamationmark.triangle.fill" : permission.risk == .shell ? "terminal.fill" : "checkmark.shield.fill" }
    private var color: Color { permission.risk == .destructive ? .red : permission.risk == .shell ? .orange : .accentColor }
}

private struct PlanReviewInlineCardView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    var compact: Bool = false
    @State private var expanded = true
    private var planText: String { permission.summary.isEmpty ? permission.inputJSON : permission.summary }
    private var stepCount: Int { planText.split(separator: "\n").filter { $0.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: { HStack { Image(systemName: "list.bullet.rectangle").foregroundStyle(Color.accentColor); Text("Plan review").font(.headline); if stepCount > 0 { Text("\(stepCount) steps").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.12)).clipShape(Capsule()) }; Spacer(); Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption) } }.buttonStyle(.plain)
            if expanded && !compact { MarkdownRendererView(content: planText).font(.callout) }
            HStack {
                Button("Reject", role: .destructive) { model.respondPermission(permission, allow: false) }
                    .buttonStyle(.plain)
                    .tokenicodeControl(radius: 11)
                Button("Restart Plan") { model.settings.sessionMode = .plan; model.persistSettings(); model.updateComposerText("Please revise the plan before execution:\n\n"); model.respondPermission(permission, allow: false); model.toastInfo("Plan", "Describe the revision in the composer") }
                    .buttonStyle(.plain)
                    .tokenicodeControl(radius: 11)
                Spacer()
                Button {
                    model.settings.sessionMode = .code; model.persistSettings(); model.respondPermission(permission, allow: true, editedInput: permission.inputJSON)
                } label: {
                    Label("Approve Plan", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .tokenicodeControl(active: true, radius: 11)
            }
        }
        .padding(14)
        .background { StandardContentCardBackground(cornerRadius: 16, tint: .accentColor) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
        .padding(.leading, compact ? 0 : 44)
    }
}

private struct QuestionInlineCardView: View {
    @EnvironmentObject var model: AppModel
    let permission: PermissionRequest
    @State private var answer = ""
    private var prompt: String { questionPrompt(from: permission.inputJSON, fallback: permission.summary) }
    private var options: [String] { questionOptions(from: permission.inputJSON) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.accentColor); Text("Claude asks a question").font(.headline); Spacer() }
            Text(prompt).font(.callout)
            if !options.isEmpty { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) { ForEach(options, id: \.self) { option in Button(option) { answer = option }.buttonStyle(.bordered) } } }
            TextField("Type an answer", text: $answer)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button("Skip") { model.respondPermission(permission, allow: true, editedInput: questionSkipResponseJSON(permission.inputJSON)) }
                    .buttonStyle(.plain)
                    .tokenicodeControl(radius: 11)
                Spacer()
                Button {
                    model.respondPermission(permission, allow: true, editedInput: questionResponseJSON(permission.inputJSON, answer: answer))
                } label: {
                    Label("Send Answer", systemImage: "arrow.right")
                }
                .buttonStyle(.plain)
                .tokenicodeControl(active: true, radius: 11)
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

private func questionPrompt(from json: String, fallback: String) -> String {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
    if let question = obj["question"] as? String { return question }
    if let questions = obj["questions"] as? [[String: Any]], let first = questions.first, let question = first["question"] as? String { return question }
    return fallback
}
private func questionOptions(from json: String) -> [String] {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let rawOptions: Any? = obj["options"] ?? (obj["questions"] as? [[String: Any]])?.first?["options"]
    if let strings = rawOptions as? [String] { return strings }
    if let dicts = rawOptions as? [[String: Any]] { return dicts.compactMap { $0["label"] as? String ?? $0["value"] as? String } }
    return []
}
private func questionResponseJSON(_ input: String, answer: String) -> String {
    var obj: [String: Any] = [:]
    if let data = input.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = parsed }
    obj["answer"] = answer; obj["answers"] = ["0": answer]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return input }
    return String(decoding: data, as: UTF8.self)
}
private func questionSkipResponseJSON(_ input: String) -> String {
    var obj: [String: Any] = [:]
    if let data = input.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = parsed }
    obj.removeValue(forKey: "answer")
    obj["answers"] = [String: Any]()
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return input }
    return String(decoding: data, as: UTF8.self)
}

struct InputBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var slashVisible = false
    @State private var slashQuery = ""
    @State private var slashSelectedIndex = 0
    private var slashCommands: [PaletteCommand] { model.filteredPaletteCommands(slashQuery).filter { $0.title.hasPrefix("/") || $0.subtitle.localizedCaseInsensitiveContains("slash") } }
    private var canSend: Bool { !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingPermissionsForSelectedSession.isEmpty }
    private var isBusy: Bool { model.selectedHasActiveTurn }
    private var editorHeight: CGFloat {
        let rows = max(1, lineCount(model.composerText))
        return min(92, max(34, CGFloat(rows) * 22 + 12))
    }

    var body: some View {
        VStack(spacing: 8) {
            if let activeInteraction = model.pendingPermissionsForSelectedSession.first {
                ActiveInteractionSlotView(permission: activeInteraction)
                    .frame(maxWidth: LiquidGlassToken.composerMaxWidth)
            }
            if slashVisible {
                SlashCommandPopoverView(commands: slashCommands, query: slashQuery, selectedIndex: slashSelectedIndex, onSelect: selectSlashCommand)
                    .frame(maxWidth: LiquidGlassToken.composerMaxWidth, alignment: .leading)
            }
            if !model.attachments.isEmpty {
                FileUploadChipsNativeView()
                    .frame(maxWidth: LiquidGlassToken.composerMaxWidth)
            }

            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        if model.composerText.isEmpty {
                            Text(isBusy ? "Add a follow-up while Claude works..." : "Add message...")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 17))
                                .padding(.horizontal, 6)
                                .padding(.top, 7)
                        }
                        TextEditor(text: Binding(get: { model.composerText }, set: { model.updateComposerText($0) }))
                            .font(.system(size: max(15, model.settings.fontSize)))
                            .scrollContentBackground(.hidden)
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
                        Button { model.interrupt() } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(Color.red.opacity(0.14))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Stop current turn")
                    }
                    Button { model.sendComposer() } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(canSend ? Color.primary.opacity(0.88) : Color.primary.opacity(0.14))
                            .foregroundStyle(canSend ? .white : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canSend)
                    .help(model.pendingPermissionsForSelectedSession.isEmpty ? "Send (Return)" : "Respond to inline card first")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background { LiquidComposerWell(cornerRadius: 30, active: isBusy) }
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)

                bottomToolbar
            }
            .frame(maxWidth: LiquidGlassToken.composerMaxWidth)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [Color.clear, Color.white.opacity(0.22), Color.accentColor.opacity(0.055)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 150)
            .allowsHitTesting(false)
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            ToolbarIconButton(systemImage: "paperclip", help: "Attach files") { model.attachFiles() }
            let modeActive = model.settings.sessionMode == .plan || model.settings.sessionMode == .bypass
            Menu {
                ForEach(SessionMode.allCases) { mode in
                    Button { model.settings.sessionMode = mode; model.persistSettings() } label: {
                        Label(mode.label, systemImage: model.settings.sessionMode == mode ? "checkmark" : modeIcon(mode))
                    }
                }
            } label: {
                NativeToolbarMenuLabel(title: model.settings.sessionMode.label, systemImage: modeIcon(model.settings.sessionMode), active: modeActive)
                    .frame(minWidth: 82, alignment: .leading)
            }
            .buttonStyle(.plain)

            let thinkingActive = model.settings.thinkingLevel != .off
            Menu {
                ForEach(ThinkingLevel.allCases) { level in
                    Button { model.settings.thinkingLevel = level; model.persistSettings() } label: {
                        Label(level.rawValue.capitalized, systemImage: model.settings.thinkingLevel == level ? "checkmark" : thinkingIcon(level))
                    }
                }
            } label: {
                NativeToolbarMenuLabel(title: model.settings.thinkingLevel == .off ? "No think" : model.settings.thinkingLevel.rawValue.capitalized, systemImage: thinkingIcon(model.settings.thinkingLevel), active: thinkingActive)
                    .frame(minWidth: 82, alignment: .leading)
            }
            .buttonStyle(.plain)

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
                NativeToolbarMenuLabel(title: "Rewind", systemImage: "arrow.counterclockwise")
                    .frame(minWidth: 92, alignment: .leading)
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
                if model.skills.isEmpty { Button("No skills loaded") {}.disabled(true) }
            } label: {
                NativeToolbarMenuLabel(title: "Skills", systemImage: "sparkles")
                    .frame(minWidth: 86, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Insert skill slash command")

            Spacer()

            Menu {
                ForEach(defaultModels, id: \.self) { option in
                    Button { model.settings.selectedModel = option; model.persistSettings() } label: {
                        Label(shortModelName(option), systemImage: model.settings.selectedModel == option ? "checkmark" : "circle")
                    }
                }
            } label: {
                NativeToolbarMenuLabel(title: shortModelName(model.settings.selectedModel), systemImage: "clock")
                    .frame(minWidth: 122, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
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
        guard count > 0 else { slashSelectedIndex = 0; return }
        slashSelectedIndex = (slashSelectedIndex + delta + count) % count
    }

    private func selectCurrentSlashCommand() {
        let commands = Array(slashCommands.prefix(12))
        guard commands.indices.contains(slashSelectedIndex) else { return }
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

private struct SlashKeyboardBridge: NSViewRepresentable {
    var isActive: Bool
    var commandCount: Int
    var onMove: (Int) -> Void
    var onSelect: () -> Void
    var onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
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
                    guard let self else { return event }
                    if MainActor.assumeIsolated({ Self.textInputHasMarkedText() }) { return event }
                    switch event.keyCode {
                    case 126 where self.currentCommandCount > 0: self.onMove?(-1); return nil
                    case 125 where self.currentCommandCount > 0: self.onMove?(1); return nil
                    case 36 where self.currentCommandCount > 0: self.onSelect?(); return nil
                    case 53: self.onClose?(); return nil
                    default: return event
                    }
                }
            }
        }

        @MainActor private static func textInputHasMarkedText() -> Bool {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
            return textView.hasMarkedText()
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        deinit { removeMonitor() }
    }

}

private struct SlashCommandPopoverView: View {
    let commands: [PaletteCommand]
    let query: String
    let selectedIndex: Int
    let onSelect: (PaletteCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: "slash.circle"); Text(query.isEmpty ? "Commands" : "Commands matching /\(query)").font(.caption.bold()); Spacer() }.foregroundStyle(.secondary)
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
            if commands.isEmpty { Text("No command matches /\(query)").font(.caption).foregroundStyle(.secondary).padding(8) }
        }.padding(8).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.18)))
    }
}

private struct FileUploadChipsNativeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { ForEach(model.attachments) { AttachmentChipView(attachment: $0) } }.padding(.horizontal, 2) }.frame(height: 34).padding(6).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
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
                            Label(tab.rawValue, systemImage: tab == .files ? "folder" : "sparkles")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(model.secondaryTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                        .foregroundStyle(model.secondaryTab == tab ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close panel")
                }
                .padding(.horizontal, 14)
                .frame(height: ShellMetric.topBarHeight)
                Divider()
                switch model.secondaryTab {
                case .files: FilePanelView()
                case .skills: SkillsPanelView()
                }
            }
        }
    }
}

struct FilePanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var fileSearchText = ""
    private var searchResults: [FileNode] { flattenFileNodes(model.fileTree, query: fileSearchText) }
    private var showingSearchResults: Bool { !fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var deletedChangeBadges: [(String, String)] { model.fileChangeBadges.filter { $0.value == "D" }.sorted { $0.key < $1.key } }
    private var changedCount: Int { model.changedFiles.count + model.fileChangeBadges.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            if model.workingDirectory.isEmpty {
                emptyState
            } else {
                if !deletedChangeBadges.isEmpty { deletedBadges }
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
                ToolbarIconButton(systemImage: "doc.badge.plus", help: "New file", disabled: model.workingDirectory.isEmpty) { createFile() }
                ToolbarIconButton(systemImage: "folder.badge.plus", help: "New folder", disabled: model.workingDirectory.isEmpty) { createFolder() }
                ToolbarIconButton(systemImage: "arrow.clockwise", help: "Refresh files", disabled: model.workingDirectory.isEmpty) { model.reloadFileTree() }
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
                    Button("New folder here") { if let name = promptForFileName(title: "New folder", defaultValue: "untitled") { model.createFolder(inDirectory: node.path, named: name) } }
                    Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) { model.requestRenameFile(node.path, to: name) } }
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
                    Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) { model.requestRenameFile(node.path, to: name) } }
                    Button("Reveal") { model.requestRevealFile(node.path) }
                    Button("Open") { model.requestOpenExternalFile(node.path) }
                    Button("Share") { model.requestShareFile(node.path) }
                    Divider()
                    Button("Delete", role: .destructive) { model.requestDeleteFile(node.path) }
                }
        }
    }
    private var icon: String { fileIconName(for: node.name, isDirectory: false) }
}

private struct SearchFileResultRowView: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let rootPath: String
    var body: some View {
        Button { if node.isDirectory { openDirectory() } else { _ = model.requestOpenFile(node.path) } } label: {
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
        .tokenicodeRow(active: model.selectedFilePath == node.path, radius: 10)
    }
    @ViewBuilder private var contextMenu: some View {
        if node.isDirectory {
            Button("New file here") { model.createFile(inDirectory: node.path) }
            Button("New folder here") { if let name = promptForFileName(title: "New folder", defaultValue: "untitled") { model.createFolder(inDirectory: node.path, named: name) } }
            Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) { model.requestRenameFile(node.path, to: name) } }
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
            Button("Rename") { if let name = promptForFileName(title: "Rename", defaultValue: node.name) { model.requestRenameFile(node.path, to: name) } }
            Button("Reveal") { model.requestRevealFile(node.path) }
            Button("Open") { model.requestOpenExternalFile(node.path) }
            Button("Share") { model.requestShareFile(node.path) }
            Divider()
            Button("Delete", role: .destructive) { model.requestDeleteFile(node.path) }
        }
    }
    private var icon: String { fileIconName(for: node.name, isDirectory: node.isDirectory) }
    private var parentContext: String {
        let parent = URL(fileURLWithPath: node.path).deletingLastPathComponent().path
        guard !rootPath.isEmpty else { return parent }
        if parent == rootPath { return "." }
        if parent.hasPrefix(rootPath) { return String(parent.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return parent
    }
    private func openDirectory() { model.requestOpenExternalFile(node.path) }
}

private struct FileNodeLabelView: View {
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
        .tokenicodeRow(active: model.selectedFilePath == node.path, radius: 10)
    }
}

@MainActor private func promptForFileName(title: String, defaultValue: String) -> String? {
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

@MainActor private func promptForMCPServer(title: String, defaultName: String, defaultCommand: String) -> (name: String, command: String)? {
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

@MainActor private func labeledField(_ label: String, field: NSTextField) -> NSView {
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

private func changeColor(for badge: String) -> Color {
    switch badge { case "A": .green; case "D": .red; default: .orange }
}

private func flattenFileNodes(_ nodes: [FileNode], query: String) -> [FileNode] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var result: [FileNode] = []
    for node in nodes {
        if node.name.localizedCaseInsensitiveContains(needle) || node.path.localizedCaseInsensitiveContains(needle) { result.append(node) }
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
        guard !needle.isEmpty else { return source.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        return source.filter { skill in
            skill.name.localizedCaseInsensitiveContains(needle) ||
            skill.description.localizedCaseInsensitiveContains(needle) ||
            skill.scope.localizedCaseInsensitiveContains(needle)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var projectSkills: [SkillInfo] { filteredSkills.filter { $0.scope == "project" } }
    private var globalSkills: [SkillInfo] { filteredSkills.filter { $0.scope == "global" } }

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
                    Menu {
                        Button("Global Skill") { createSkill(projectScoped: false) }
                        Button("Project Skill") { createSkill(projectScoped: true) }.disabled(model.workingDirectory.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 30, height: 30)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .tokenicodeControl(radius: 10)
                    .help("Create skill")
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
                        ContentUnavailableView(skillSearchText.isEmpty ? "No skills" : "No matching skills", systemImage: "sparkles", description: Text(skillSearchText.isEmpty ? "Create a global or project skill from the + menu." : skillSearchText))
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
            Menu {
                Button("Use in Input") { model.useSkillInComposer(skill) }
                Button("Edit") { if model.requestOpenFile(skill.path) { model.selectedSkill = skill } }
                Button("Duplicate") { model.duplicateSkill(skill) }
                Button("Reveal in Finder") { model.requestRevealFile(skill.path) }
                Button("Open") { model.requestOpenExternalFile(skill.path) }
                Divider()
                Button("Delete", role: .destructive) { model.selectedSkill = skill; model.deleteSelectedSkill() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .tokenicodeControl(radius: 9)
            .help("Skill actions")
            Toggle("", isOn: Binding(
                get: { !skill.disabled },
                set: { enabled in
                    guard enabled == skill.disabled else { return }
                    model.selectedSkill = skill
                    model.toggleSelectedSkillEnabled()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(skill.disabled ? "Enable skill" : "Disable skill")
        }
        .padding(10)
        .background(model.selectedSkill?.path == skill.path ? AnyShapeStyle(Color.accentColor.opacity(0.11)) : AnyShapeStyle(Color.primary.opacity(0.028)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(model.selectedSkill?.path == skill.path ? Color.accentColor.opacity(0.20) : LiquidGlassToken.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if model.requestOpenFile(skill.path) {
                model.selectedSkill = skill
            }
        }
        .contextMenu {
            Button("Use in Input") { model.useSkillInComposer(skill) }
            Button("Edit") { if model.requestOpenFile(skill.path) { model.selectedSkill = skill } }
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

private struct FlowBadges: View {
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
            HStack { TextField("name", text: $serverName); TextField("command", text: $command); Button("Add") { if !serverName.isEmpty { model.addMCPServer(name: serverName, command: command); serverName = ""; command = "" } } }
            List(model.mcpServers) { server in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(server.name).font(.headline); Spacer(); Text(server.transport).font(.caption).padding(4).background(.thinMaterial).clipShape(Capsule()) }
                    Text(server.command ?? server.url ?? "No command/url").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack { Text(server.source).font(.caption2).foregroundStyle(.tertiary); Spacer(); Button("Test") { model.testMCPServer(server) }; if server.source != "Claude" { Button("Delete", role: .destructive) { model.deleteMCPServer(server) } } }
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
                    ContentUnavailableView("No agent activity", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Tool calls and sub-agent work appear here while Claude is running."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                } else {
                    ForEach(model.selectedToolCalls) { tool in
                        HStack(alignment: .top, spacing: 10) {
                            StatusDot(color: tool.status == .failed || tool.status == .denied ? .red : tool.status == .succeeded ? .mint : .orange)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(tool.name).font(.headline)
                                    Text(tool.status.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.05)).clipShape(Capsule())
                                }
                                if !tool.inputPreview.isEmpty { Text(tool.inputPreview).font(.system(.caption, design: .monospaced)).lineLimit(3).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let parent = tool.parentID { Text("Parent: \(parent)").font(.caption2).foregroundStyle(.tertiary) }
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
        Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { model.agentPanelOpen = false }
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
                HStack { Image(systemName: icon).font(.title).foregroundStyle(color); VStack(alignment: .leading) { Text(permission.title).font(.title3.bold()); Text(permission.risk.rawValue).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                Text(permission.summary).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $editedInput).font(.system(.caption, design: .monospaced)).frame(height: 180).onAppear { editedInput = permission.inputJSON }
                HStack { Button("Deny", role: .destructive) { model.respondPermission(permission, allow: false) }; Spacer(); Button("Allow Once") { model.respondPermission(permission, allow: true, editedInput: editedInput) }.buttonStyle(.borderedProminent) }
            }.padding(22).frame(width: 620)
        }
    }
    private var icon: String { permission.risk == .destructive ? "exclamationmark.triangle.fill" : permission.risk == .shell ? "terminal.fill" : "checkmark.shield.fill" }
    private var color: Color { permission.risk == .destructive ? .red : permission.risk == .shell ? .orange : .accentColor }
}

struct SettingsPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var newProviderKey = ""
    @State private var mcpName = ""
    @State private var mcpCommand = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.26).ignoresSafeArea().onTapGesture { model.settingsOpen = false }
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
                                case .provider: providerContent
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
                        Text(tab.rawValue == "Provider" ? "API Providers" : tab.rawValue)
                        if tab == .cli && model.cliStatus.updateAvailable {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                        }
                        Spacer()
                    }
                    .font(.system(size: 15, weight: model.settingsTab == tab ? .semibold : .medium))
                    .tokenicodeRow(active: model.settingsTab == tab, radius: 12)
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
                    Text("TOKENICODE parity")
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
            if let version = model.cliStatus.version { Text("v\(version)").foregroundStyle(.secondary) }
            if model.cliStatus.updateAvailable, let latest = model.cliStatus.latestVersion {
                Text("Update available: \(latest)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Changelog") { model.showChangelog() }.buttonStyle(.plain).tokenicodeControl(radius: 10)
            Button("Check CLI") { model.refreshCLIStatus() }.buttonStyle(.plain).tokenicodeControl(radius: 10)
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "General", subtitle: "LiquidCode visual identity with TOKENICODE interaction parity", icon: "sun.max") {
                OnboardingPlanCardView()
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
                            .tokenicodeControl(active: model.settings.theme == theme, radius: 16)
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
                            .tokenicodeControl(active: model.settings.accent == accent, radius: 14)
                        }
                    }
                }
            }

            SettingsSectionCard(title: "Composer defaults", subtitle: "Mode, thinking and typography used by new sends", icon: "text.cursor") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Font size: \(Int(model.settings.fontSize))")
                            .font(.caption.weight(.semibold))
                        Slider(value: $model.settings.fontSize, in: 11...22) { Text("Font Size") }
                            .onChange(of: model.settings.fontSize) { _, _ in model.persistSettings() }
                    }
                    Picker("Mode", selection: $model.settings.sessionMode) { ForEach(SessionMode.allCases) { Text($0.label).tag($0) } }
                        .onChange(of: model.settings.sessionMode) { _, _ in model.persistSettings() }
                    Picker("Thinking", selection: $model.settings.thinkingLevel) { ForEach(ThinkingLevel.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                        .onChange(of: model.settings.thinkingLevel) { _, _ in model.persistSettings() }
                }
            }
        }
    }

    private var providerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionCard(title: "API Providers", subtitle: "Presets, keychain secrets, model mapping, import/export", icon: "lock.rectangle") {
                HStack(spacing: 10) {
                    Label("Inherit system configuration", systemImage: model.activeProviderID == nil ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Use external tools such as CC-Switch or environment variables")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use System") { model.activeProviderID = nil; model.saveProviders() }
                        .buttonStyle(.plain)
                        .tokenicodeControl(active: model.activeProviderID == nil, radius: 10)
                }
                .padding(12)
                .background(model.activeProviderID == nil ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack {
                    Menu("+ Add") {
                        Button("Custom Provider") { model.addProvider() }
                        Divider()
                        ForEach(providerPresets) { preset in Button(preset.name) { model.addProvider(from: preset) } }
                    }
                    .menuStyle(.button)
                    Button("Import JSON") { model.importProviders() }
                    Button("Export") { model.exportProviders() }
                    Spacer()
                    Button("Delete", role: .destructive) { model.deleteActiveProvider() }
                        .disabled(model.activeProviderID == nil)
                }
                .buttonStyle(.plain)

                VStack(spacing: 10) {
                    ForEach(model.providers) { provider in
                        ProviderRowCard(provider: provider, active: model.activeProviderID == provider.id) {
                            model.activeProviderID = provider.id
                            model.saveProviders()
                        } test: {
                            model.activeProviderID = provider.id
                            model.testActiveProvider()
                        } delete: {
                            model.activeProviderID = provider.id
                            model.deleteActiveProvider()
                        }
                    }
                    if model.providers.isEmpty {
                        ContentUnavailableView("No custom providers", systemImage: "lock.rectangle", description: Text("Use system Anthropic config or add a preset."))
                            .frame(height: 120)
                    }
                }
            }

            if let index = activeProviderIndex {
                SettingsSectionCard(title: "Provider details", subtitle: "Edit active provider and save API key into Keychain", icon: "slider.horizontal.3") {
                    VStack(spacing: 12) {
                        TextField("Name", text: providerNameBinding(index)).textFieldStyle(.roundedBorder)
                        TextField("Base URL", text: providerBaseURLBinding(index)).textFieldStyle(.roundedBorder)
                        Picker("API Format", selection: providerAPIFormatBinding(index)) { ForEach(ProviderRecord.APIFormat.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow { Text("Opus").foregroundStyle(.secondary); TextField("opus model", text: providerMappingBinding(index, tier: "opus")) }
                            GridRow { Text("Sonnet").foregroundStyle(.secondary); TextField("sonnet model", text: providerMappingBinding(index, tier: "sonnet")) }
                            GridRow { Text("Haiku").foregroundStyle(.secondary); TextField("haiku model", text: providerMappingBinding(index, tier: "haiku")) }
                        }
                        SecureField("API Key", text: $newProviderKey).textFieldStyle(.roundedBorder)
                        HStack { Button("Save Key") { model.setProviderKey(providerID: model.providers[index].id, key: newProviderKey); newProviderKey = "" }; Button("Test Connection") { model.testActiveProvider() }; Button("Save Provider") { model.saveProviders() } }
                    }
                }
            }
        }
    }

    private var mcpContent: some View {
        SettingsSectionCard(title: "MCP Servers", subtitle: "Create, edit, test and delete app-local MCP profiles", icon: "server.rack") {
            HStack(spacing: 8) {
                TextField("server name", text: $mcpName).textFieldStyle(.roundedBorder)
                TextField("command with args or URL", text: $mcpCommand).textFieldStyle(.roundedBorder)
                Button("Add") { if !mcpName.isEmpty { model.addMCPServer(name: mcpName, command: mcpCommand); mcpName = ""; mcpCommand = "" } }
                    .buttonStyle(.plain)
                    .tokenicodeControl(active: true, radius: 10)
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
                                Text(server.source).font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.05)).clipShape(Capsule())
                                if !server.args.isEmpty {
                                    Text("\(server.args.count) args").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.04)).clipShape(Capsule())
                                }
                            }
                            Text(mcpCommandLine(server)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Test") { model.testMCPServer(server) }
                            .buttonStyle(.plain)
                            .tokenicodeControl(radius: 10)
                        if server.source == "LiquidCode" {
                            Button("Edit") {
                                if let result = promptForMCPServer(title: "Edit MCP server", defaultName: server.name, defaultCommand: mcpCommandLine(server)) {
                                    model.updateMCPServer(server, name: result.name, command: result.command)
                                }
                            }
                            .buttonStyle(.plain)
                            .tokenicodeControl(radius: 10)
                            Button("Delete", role: .destructive) { model.deleteMCPServer(server) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .tokenicodeControl(radius: 10)
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
                if model.mcpServers.isEmpty { ContentUnavailableView("No MCP servers", systemImage: "server.rack") }
            }
        }
    }

    private func mcpCommandLine(_ server: MCPServer) -> String {
        if let url = server.url { return url }
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
                    if let version = model.cliStatus.version { Text("v\(version)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
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
                HStack { Button("Refresh") { model.refreshCLIStatus() }; Button("Install / Update") { model.installOrUpdateCLI() }; Button("Login") { model.openClaudeLogin() }; Button("Repair") { model.repairCLI() }; Button("Open Config") { model.openClaudeConfig() } }
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
            HStack { Button("Reveal Logs") { model.revealLogs() }; Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("LiquidCode \(model.cliStatus.version ?? "unknown")\nLogs: \(AppPaths.shared.logs.path)", forType: .string); model.toastSuccess("Copied diagnostics", AppPaths.shared.logs.path) } }
        }
    }

    private var activeProviderIndex: Int? { model.providers.firstIndex { $0.id == model.activeProviderID } }
    private func providerNameBinding(_ index: Int) -> Binding<String> { Binding(get: { model.providers[index].name }, set: { model.providers[index].name = $0; model.providers[index].updatedAt = Date(); model.saveProviders() }) }
    private func providerBaseURLBinding(_ index: Int) -> Binding<String> { Binding(get: { model.providers[index].baseURL }, set: { model.providers[index].baseURL = $0; model.providers[index].updatedAt = Date(); model.saveProviders() }) }
    private func providerAPIFormatBinding(_ index: Int) -> Binding<ProviderRecord.APIFormat> { Binding(get: { model.providers[index].apiFormat }, set: { model.providers[index].apiFormat = $0; model.providers[index].updatedAt = Date(); model.saveProviders() }) }
    private func providerMappingBinding(_ index: Int, tier: String) -> Binding<String> { Binding(get: { model.providers[index].modelMappings[tier] ?? "" }, set: { model.providers[index].modelMappings[tier] = $0; model.providers[index].updatedAt = Date(); model.saveProviders() }) }
}

private struct SettingsSectionCard<Content: View>: View {
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

private struct ProviderRowCard: View {
    let provider: ProviderRecord
    let active: Bool
    let select: () -> Void
    let test: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) { Image(systemName: active ? "largecircle.fill.circle" : "circle") }
                .buttonStyle(.plain)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(provider.name).font(.headline)
                    if let preset = provider.preset { Text(preset).font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.05)).clipShape(Capsule()) }
                }
                Text(provider.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Button("Test") { test() }.buttonStyle(.plain).tokenicodeControl(radius: 10)
            Button { delete() } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(12)
        .background(active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OnboardingPlanCardView: View {
    @EnvironmentObject var model: AppModel
    private var plan: OnboardingPlan { model.onboardingPlan }
    var body: some View {
        if plan.state != .ready {
            VStack(alignment: .leading, spacing: 8) {
                Label("TOKENICODE setup", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text(plan.message).font(.caption).foregroundStyle(.secondary)
                if plan.tokenicodeProviderCount > 0 { Text("\(plan.tokenicodeProviderCount) provider(s) detected").font(.caption2).foregroundStyle(.tertiary) }
                HStack {
                    if plan.canMigrate { Button("Migrate") { model.executeTokenicodeProviderMigration() }.buttonStyle(.borderedProminent) }
                    if plan.shouldPrompt || plan.state == .tokenicodeMigrationAvailable { Button("Skip") { model.skipTokenicodeProviderMigration() } }
                    if plan.canRollback { Button("Rollback") { model.rollbackTokenicodeProviderMigration() } }
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private func settingsTabIcon(_ tab: SettingsTab) -> String {
    switch tab {
    case .general: "sun.max"
    case .provider: "lock.rectangle"
    case .cli: "terminal"
    case .mcp: "server.rack"
    case .feedback: "bubble.left.and.text.bubble.right"
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @Binding var query: String
    var body: some View {
        Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { model.commandPaletteOpen = false }
        GlassPanel(role: .commandPalette, prominence: .prominent, cornerRadius: 22) {
            VStack(spacing: 0) {
                TextField("Type a command or session action", text: $query).textFieldStyle(.plain).font(.title3).padding(16)
                Divider()
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(model.filteredPaletteCommands(query)) { cmd in Button { model.runCommand(cmd) } label: { VStack(alignment: .leading) { Text(cmd.title).font(.headline); Text(cmd.subtitle).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(10) }.buttonStyle(.plain) } }.padding(8) }
            }.frame(width: 620, height: 520)
        }
    }
}

struct AttachmentChipView: View {
    @EnvironmentObject var model: AppModel
    let attachment: AttachmentChip
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file)).font(.caption2).foregroundStyle(.tertiary)
            }
            Button { model.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }
}

struct ToastBannerView: View {
    @EnvironmentObject var model: AppModel
    let toast: ToastMessage
    var body: some View {
        VStack { Spacer(); HStack { Image(systemName: icon); VStack(alignment: .leading) { Text(toast.title).font(.headline); Text(toast.message).font(.caption).lineLimit(2) }; Button { model.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(14).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).padding(.bottom, 24) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    private var icon: String { switch toast.kind { case .info: "info.circle"; case .success: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" } }
}

struct ChangelogSheetView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Color.black.opacity(0.22).ignoresSafeArea()
        GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("What's New").font(.title.bold()); Spacer(); Button { model.changelogOpen = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                ForEach(bundledChangelog) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Version \(entry.version) · \(entry.date)").font(.headline)
                        ForEach(entry.items, id: \.self) { Text("• \($0)") }
                    }
                }
            }.padding(24).frame(width: 560)
        }
    }
}
