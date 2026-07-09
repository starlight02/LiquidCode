import SwiftUI

/// Status capsule for an MCP server row (idle / testing / ok / failed + tool count).
struct MCPRuntimeBadge: View {
    let server: MCPServer

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(server.runtimeStatus.label)
                .font(.caption2.weight(.semibold))
            if let count = server.toolCount {
                Text(LF("%d tools", count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(dotColor.opacity(0.12))
        .foregroundStyle(dotColor == .secondary ? Color.secondary : dotColor)
        .clipShape(Capsule())
        .help(server.lastError ?? server.runtimeStatus.label)
    }

    private var dotColor: Color {
        switch server.runtimeStatus {
        case .idle: return .secondary
        case .testing: return .orange
        case .ok: return .mint
        case .failed: return .red
        }
    }
}

/// Settings → Hooks & Plugins (read-only inventory).
struct ExtensionsSettingsContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(
                title: L("Hooks & Plugins"),
                subtitle: L("Read-only view of Claude Code hooks and installed plugins"),
                icon: "puzzlepiece.extension"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("HookCallback permissions are auto-approved by LiquidCode so Claude Code hooks can run without interrupting you."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(L("Reload")) {
                            model.reloadClaudeExtensions()
                        }
                        .buttonStyle(.plain)
                        .liquidGlassButton(radius: 10)
                    }
                }
            }

            SettingsSectionCard(
                title: L("Plugins"),
                subtitle: L("Installed plugins from ~/.claude and enabledPlugins"),
                icon: "shippingbox"
            ) {
                if model.claudePlugins.isEmpty {
                    Text(L("No plugins installed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.claudePlugins) { plugin in
                            pluginRow(plugin)
                        }
                    }
                }
            }

            SettingsSectionCard(
                title: L("Hooks"),
                subtitle: L("From user/project settings and plugin hooks.json"),
                icon: "bolt.horizontal"
            ) {
                if model.claudeHooks.isEmpty {
                    Text(L("No hooks configured"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.claudeHooks) { hook in
                            hookRow(hook)
                        }
                    }
                }
            }
        }
        .onAppear {
            if model.claudePlugins.isEmpty && model.claudeHooks.isEmpty {
                model.reloadClaudeExtensions()
            }
        }
    }

    private func pluginRow(_ plugin: ClaudePluginEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: plugin.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(plugin.enabled ? Color.mint : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plugin.name)
                        .font(.headline)
                    if let market = plugin.marketplace {
                        Text(market)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Capsule())
                    }
                    Text(plugin.enabled ? L("Enabled") : L("Disabled"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(plugin.enabled ? Color.mint : Color.secondary)
                }
                HStack(spacing: 8) {
                    if let version = plugin.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let scope = plugin.scope {
                        Text(scope)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let path = plugin.installPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hookRow(_ hook: ClaudeHookEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(hook.event)
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                if !hook.matcher.isEmpty {
                    Text(hook.matcher)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if hook.isAsync {
                    Text(L("async"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(hook.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(hook.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
