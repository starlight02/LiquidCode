import AppKit
import SwiftUI
import WebKit

func settingsTabIcon(_ tab: SettingsTab) -> String {
    switch tab {
    case .general: "sun.max"
    case .cli: "terminal"
    case .mcp: "server.rack"
    case .feedback: "bubble.left.and.text.bubble.right"
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    var body: some View {
        Color.black
            .opacity(0.18)
            .ignoresSafeArea()
            .pointingHandCursor()
            .onTapGesture { model.commandPaletteOpen = false }
        GlassPanel(role: .commandPalette, prominence: .prominent, cornerRadius: 22) {
            VStack(spacing: 0) {
                TextField(L("Type a command or session action"), text: $query).textFieldStyle(.plain).font(.title3).padding(16)
                Divider()
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(model.filteredPaletteCommands(query)) { cmd in
                    Button { model.runCommand(cmd) } label: {
                        VStack(alignment: .leading) { Text(cmd.title).font(.headline); Text(cmd.subtitle).font(.caption).foregroundStyle(.secondary) }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(10) }.buttonStyle(.plain) } }.padding(8) }
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
            Button { model.removeAttachment(attachment) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .help(L("Remove attachment"))
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
        VStack {
            Spacer(); HStack {
                Image(systemName: icon); VStack(alignment: .leading) { Text(toast.title).font(.headline); Text(toast.message).font(.caption).lineLimit(2) }; Button {
                    model.toast = nil
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(L("Dismiss notification")) }
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                ))
                .padding(.bottom, 24) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var icon: String {
        switch toast.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct ChangelogSheetView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Color.black.opacity(0.22).ignoresSafeArea()
        GlassPanel(role: .floatingCard, prominence: .prominent, cornerRadius: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("What's New")).font(.title.bold()); Spacer(); Button { model.changelogOpen = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help(L("Close changelog")) }
                ForEach(bundledChangelog) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LF("Version %@ · %@", entry.version, entry.date)).font(.headline)
                        ForEach(entry.items, id: \.self) { Text("• \(L($0))") }
                    }
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }
}
