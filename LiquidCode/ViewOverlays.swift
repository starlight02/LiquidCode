import AppKit
import SwiftUI
import WebKit

struct ProviderRowCard: View {
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
                    if
                        let preset = provider
                            .preset {
                        Text(preset)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule()) }
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

struct OnboardingPlanCardView: View {
    @EnvironmentObject var model: AppModel
    private var plan: OnboardingPlan {
        model.onboardingPlan
    }

    var body: some View {
        if plan.state != .ready {
            VStack(alignment: .leading, spacing: 8) {
                Label("TOKENICODE setup", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text(plan.message).font(.caption).foregroundStyle(.secondary)
                if plan.tokenicodeProviderCount > 0 {
                    Text("\(plan.tokenicodeProviderCount) provider(s) detected").font(.caption2).foregroundStyle(.tertiary)
                }
                HStack {
                    if plan.canMigrate {
                        Button("Migrate") { model.executeTokenicodeProviderMigration() }.buttonStyle(.borderedProminent)
                    }
                    if plan.shouldPrompt || plan.state == .tokenicodeMigrationAvailable {
                        Button("Skip") { model.skipTokenicodeProviderMigration() }
                    }
                    if plan.canRollback {
                        Button("Rollback") { model.rollbackTokenicodeProviderMigration() }
                    }
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

func settingsTabIcon(_ tab: SettingsTab) -> String {
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
    @State private var query = ""
    var body: some View {
        Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { model.commandPaletteOpen = false }
        GlassPanel(role: .commandPalette, prominence: .prominent, cornerRadius: 22) {
            VStack(spacing: 0) {
                TextField("Type a command or session action", text: $query).textFieldStyle(.plain).font(.title3).padding(16)
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
        VStack {
            Spacer(); HStack {
                Image(systemName: icon); VStack(alignment: .leading) { Text(toast.title).font(.headline); Text(toast.message).font(.caption).lineLimit(2) }; Button {
                    model.toast = nil
                } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
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
                    Text("What's New").font(.title.bold()); Spacer(); Button { model.changelogOpen = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                ForEach(bundledChangelog) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Version \(entry.version) · \(entry.date)").font(.headline)
                        ForEach(entry.items, id: \.self) { Text("• \($0)") }
                    }
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }
}
