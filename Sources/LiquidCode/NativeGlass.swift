import AppKit
import SwiftUI

enum GlassRole { case sidebar, toolbar, inspector, composer, commandPalette, permissionSheet, floatingCard }
enum GlassProminence { case subtle, regular, prominent }

enum LiquidGlassToken {
    static let sidebarWidth: CGFloat = 240
    static let inspectorWidth: CGFloat = 340
    static let chatMaxWidth: CGFloat = 960
    static let composerMaxWidth: CGFloat = 920
    static let cardRadius: CGFloat = 18
    static let panelRadius: CGFloat = 30
    static let panelSpacing: CGFloat = 10
    static let controlRadius: CGFloat = 13
    static let modalRadius: CGFloat = 28
    static let hairline = Color.secondary.opacity(0.14)
    static let sidebarFill = Color(nsColor: .windowBackgroundColor).opacity(0.62)
    static let chatFill = Color(nsColor: .textBackgroundColor).opacity(0.72)
    static let selectedFill = Color.accentColor.opacity(0.12)
}

struct LiquidAppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: colorScheme == .dark ? [
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                    Color(red: 0.08, green: 0.11, blue: 0.18),
                    Color(red: 0.02, green: 0.04, blue: 0.08)
                ] : [
                    Color(red: 0.88, green: 0.95, blue: 1.00),
                    Color(red: 0.98, green: 0.99, blue: 1.00),
                    Color(red: 0.93, green: 0.91, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            liquidOrb(color: .cyan, opacity: colorScheme == .dark ? 0.32 : 0.42, size: 620, x: -210, y: -180)
            liquidOrb(color: .blue, opacity: colorScheme == .dark ? 0.26 : 0.34, size: 720, x: 420, y: -260)
            liquidOrb(color: .mint, opacity: colorScheme == .dark ? 0.18 : 0.24, size: 540, x: -150, y: 520)
            liquidOrb(color: .purple, opacity: colorScheme == .dark ? 0.19 : 0.22, size: 640, x: 760, y: 520)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.10 : 0.46), Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.18), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 900, height: 180)
                .rotationEffect(.degrees(-17))
                .offset(x: 120, y: -20)
                .blur(radius: 44)
                .blendMode(.screen)
            NoiseVeil(opacity: colorScheme == .dark ? 0.045 : 0.030)
        }
        .ignoresSafeArea()
    }

    private func liquidOrb(color: Color, opacity: Double, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(opacity * 0.34), .clear],
                    center: .center,
                    startRadius: size * 0.04,
                    endRadius: size * 0.52
                )
            )
            .frame(width: size, height: size)
            .offset(x: x, y: y)
            .blur(radius: 34)
            .blendMode(.screen)
    }
}

private struct NoiseVeil: View {
    let opacity: Double
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 3
            for x in stride(from: CGFloat(0), through: size.width, by: step) {
                for y in stride(from: CGFloat(0), through: size.height, by: step) {
                    let seed = Int(x * 17 + y * 31) % 11
                    if seed == 0 || seed == 7 {
                        context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(opacity)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct GlassPanel<Content: View>: View {
    let role: GlassRole
    let prominence: GlassProminence
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    init(role: GlassRole, prominence: GlassProminence = .regular, cornerRadius: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.role = role; self.prominence = prominence; self.cornerRadius = cornerRadius; self.content = content()
    }

    var body: some View {
        let pane = role == .sidebar || role == .inspector
        let structural = pane || role == .toolbar
        let resolvedRadius = (cornerRadius == 0 && pane) ? LiquidGlassToken.panelRadius : cornerRadius
        let shape = RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
        let strokeOpacity = prominence == .prominent ? 0.42 : (structural ? 0.28 : 0.22)
        let darkStrokeOpacity = structural ? 0.075 : 0.055
        let shadowOpacity = structural ? 0.16 : (prominence == .prominent ? 0.24 : 0.10)
        let shadowRadius: CGFloat = structural ? 26 : (prominence == .prominent ? 32 : 14)
        let shadowY: CGFloat = structural ? 16 : (prominence == .prominent ? 20 : 8)
        Group {
            if #available(macOS 26.0, *) {
                content
                    .frame(maxWidth: pane ? .infinity : nil, maxHeight: pane ? .infinity : nil, alignment: .topLeading)
                    .background(LiquidGlassSurface(role: role, prominence: prominence, cornerRadius: resolvedRadius))
                    .glassEffect(.regular, in: shape)
            } else {
                content
                    .frame(maxWidth: pane ? .infinity : nil, maxHeight: pane ? .infinity : nil, alignment: .topLeading)
                    .background(NativeGlassBackground(role: role, prominence: prominence))
            }
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(strokeOpacity), .white.opacity(strokeOpacity * 0.16), .white.opacity(strokeOpacity * 0.52)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .overlay { shape.stroke(Color.black.opacity(darkStrokeOpacity), lineWidth: 0.5) }
        .shadow(color: .white.opacity(structural ? 0.36 : 0.16), radius: 18, x: -10, y: -10)
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
    }
}

struct LiquidGlassControlBackground: View {
    var active = false
    var disabled = false
    var radius: CGFloat = LiquidGlassToken.controlRadius
    var intensity: GlassProminence = .regular
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(fill))
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(active ? 0.54 : 0.38), Color.white.opacity(0.10), Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: active ? 1.2 : 0.9
            )
        }
        .shadow(color: .white.opacity(colorScheme == .dark ? 0.04 : 0.30), radius: active ? 10 : 6, x: -3, y: -3)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.08), radius: active ? 11 : 7, x: 0, y: active ? 6 : 3)
        .opacity(disabled ? 0.48 : 1)
    }

    private var fill: Color {
        if active { return Color.accentColor.opacity(colorScheme == .dark ? 0.34 : 0.20) }
        switch intensity {
        case .subtle: return Color.white.opacity(colorScheme == .dark ? 0.07 : 0.18)
        case .regular: return Color.white.opacity(colorScheme == .dark ? 0.10 : 0.26)
        case .prominent: return Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34)
        }
    }
}

private struct LiquidGlassSurface: View {
    let role: GlassRole
    let prominence: GlassProminence
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: baseColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(colorScheme == .dark ? 0.12 : 0.56), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.12), .clear],
                center: .bottomTrailing,
                startRadius: 8,
                endRadius: 520
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var baseColors: [Color] {
        let glassAlpha: Double
        switch prominence {
        case .subtle: glassAlpha = colorScheme == .dark ? 0.10 : 0.20
        case .regular: glassAlpha = colorScheme == .dark ? 0.14 : 0.26
        case .prominent: glassAlpha = colorScheme == .dark ? 0.20 : 0.34
        }
        let roleBoost: Double = (role == .sidebar || role == .inspector) ? 0.06 : 0.0
        if colorScheme == .dark {
            return [
                Color.white.opacity(glassAlpha + roleBoost * 0.45),
                Color.blue.opacity(0.055 + roleBoost * 0.25),
                Color.white.opacity(glassAlpha * 0.42)
            ]
        }
        return [
            Color.white.opacity(glassAlpha + roleBoost),
            Color.white.opacity((glassAlpha + roleBoost) * 0.55),
            Color.accentColor.opacity(0.055 + roleBoost * 0.25)
        ]
    }
}

struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct LiquidGlassCard: ViewModifier {
    var role: GlassRole = .floatingCard
    var prominence: GlassProminence = .regular
    var radius: CGFloat = LiquidGlassToken.cardRadius
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        GlassPanel(role: role, prominence: prominence, cornerRadius: radius) {
            content.padding(padding)
        }
    }
}

extension View {
    func liquidGlassCard(role: GlassRole = .floatingCard, prominence: GlassProminence = .regular, radius: CGFloat = LiquidGlassToken.cardRadius, padding: CGFloat = 0) -> some View {
        modifier(LiquidGlassCard(role: role, prominence: prominence, radius: radius, padding: padding))
    }

    func tokenicodeControl(active: Bool = false, radius: CGFloat = LiquidGlassToken.controlRadius) -> some View {
        self
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.78))
            .background { LiquidGlassControlBackground(active: active, radius: radius, intensity: active ? .prominent : .regular) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func tokenicodeRow(active: Bool = false, radius: CGFloat = 14) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(active ? LiquidGlassToken.selectedFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct NativeGlassBackground: NSViewRepresentable {
    let role: GlassRole
    let prominence: GlassProminence

    func makeNSView(context: Context) -> NSView { makeGlassView() }
    func updateNSView(_ nsView: NSView, context: Context) { configure(nsView) }

    private func makeGlassView() -> NSView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    private func configure(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        if let visual = view as? NSVisualEffectView {
            visual.state = .active
            visual.blendingMode = .withinWindow
            visual.material = material
            visual.isEmphasized = prominence == .prominent
        }
        view.layer?.backgroundColor = Self.fallbackColor(for: prominence).cgColor
    }

    private var groupName: String {
        switch role {
        case .sidebar: "liquidcode.sidebar"
        case .toolbar: "liquidcode.toolbar"
        case .inspector: "liquidcode.inspector"
        case .composer: "liquidcode.composer"
        case .commandPalette: "liquidcode.commandPalette"
        case .permissionSheet: "liquidcode.permissionSheet"
        case .floatingCard: "liquidcode.floatingCard"
        }
    }

    private var material: NSVisualEffectView.Material {
        switch role {
        case .sidebar: .sidebar
        case .toolbar: .headerView
        case .inspector: .hudWindow
        case .composer: .popover
        case .commandPalette: .menu
        case .permissionSheet: .sheet
        case .floatingCard: .popover
        }
    }

    static func fallbackColor(for prominence: GlassProminence) -> NSColor {
        switch prominence {
        case .subtle: NSColor.windowBackgroundColor.withAlphaComponent(0.22)
        case .regular: NSColor.windowBackgroundColor.withAlphaComponent(0.30)
        case .prominent: NSColor.windowBackgroundColor.withAlphaComponent(0.42)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { MainActor.assumeIsolated { configure(window) } } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { MainActor.assumeIsolated { configure(window) } } }
    }
}

@MainActor func configureLiquidWindow(_ window: NSWindow) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbarStyle = .unifiedCompact
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.isOpaque = false
    window.tabbingMode = .preferred
}
