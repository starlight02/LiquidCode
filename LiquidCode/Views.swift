import AppKit
import SwiftUI
import WebKit

enum ShellMetric {
    static let topBarHeight: CGFloat = 68
}

enum GlassControlMetric {
    static let iconButtonSize: CGFloat = 36
    static let iconSymbolSize: CGFloat = 13
    static let iconButtonRadius: CGFloat = 18
    static let menuHeight: CGFloat = 32
}

struct AppShellView: View {
    @EnvironmentObject var model: AppModel
    @State private var sidebarOpen = true
    @State private var previewWidth: Double = 640
    @State private var sidebarDragStart: Double?
    @State private var rightDragStart: Double?
    private var isFilePreviewMode: Bool {
        model.selectedFilePath != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let previewPaneWidth = resolvedPreviewWidth(containerWidth: geometry.size.width)
            let secondaryPaneWidth = resolvedSecondaryWidth(containerWidth: geometry.size.width)

            ZStack(alignment: .top) {
                HStack(spacing: LiquidGlassToken.panelSpacing) {
                    if sidebarOpen {
                        SidebarView(
                            onCollapse: { sidebarOpen = false },
                            sidebarResizeGesture: sidebarResizeGesture
                        )
                        .frame(width: model.settings.sidebarWidth)
                        .frame(maxHeight: .infinity)
                    }

                    ChatPanelView(
                        sidebarOpen: sidebarOpen,
                        onToggleSidebar: { sidebarOpen.toggle() },
                        secondaryOpen: model.secondaryOpen,
                        isFilePreviewMode: isFilePreviewMode,
                        onToggleSecondary: { model.secondaryOpen.toggle() }
                    )
                    .frame(minWidth: LiquidGlassToken.chatMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                    if isFilePreviewMode {
                        FilePreviewShellView(onClose: { model.requestCloseFilePreview() })
                            .frame(width: previewPaneWidth)
                            .frame(maxHeight: .infinity)
                            .layoutPriority(0)
                            .overlay(alignment: .leading) {
                                PaneResizeHandle(
                                    title: "Resize preview",
                                    dragGesture: previewResizeGesture
                                )
                                .offset(x: -4)
                            }
                    } else if model.secondaryOpen {
                        SecondaryPanelView(onClose: { model.secondaryOpen = false })
                            .frame(width: secondaryPaneWidth)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) {
                                PaneResizeHandle(
                                    title: "Resize secondary panel",
                                    dragGesture: secondaryResizeGesture
                                )
                                .offset(x: -4)
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(model.settingsOpen || model.commandPaletteOpen || model.changelogOpen || model.imageLightbox != nil)
                .accessibilityHidden(model.settingsOpen || model.commandPaletteOpen || model.changelogOpen || model.imageLightbox != nil)
                .animation(.snappy(duration: 0.22), value: sidebarOpen)
                .animation(.snappy(duration: 0.22), value: model.secondaryOpen)
                .animation(.snappy(duration: 0.22), value: isFilePreviewMode)
                .background(LiquidAppBackdrop())
                .background(WindowAccessor(configure: configureLiquidWindow))

                if model.settingsOpen {
                    SettingsPanelView()
                        .zIndex(1000)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                if model.commandPaletteOpen {
                    CommandPaletteView()
                        .zIndex(1001)
                }
                if let toast = model.toast {
                    ToastBannerView(toast: toast)
                        .zIndex(1100)
                }
                if model.changelogOpen {
                    ChangelogSheetView()
                        .zIndex(1002)
                }
                if let lightbox = model.imageLightbox {
                    ImageLightboxOverlayView(content: lightbox) { model.imageLightbox = nil }
                        .zIndex(1200)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(item: $model.currentError) { err in Alert(title: Text(err.title), message: Text(err.message), dismissButton: .default(Text(L("OK")))) }
        .onAppear { model.bootstrap() }
        .onChange(of: model.selectedSessionID) { _, newValue in
            if newValue == nil {
                model.secondaryOpen = false
            }
        }
        .onChange(of: isFilePreviewMode) { _, active in
            if active {
                let screenWidth = NSScreen.main?.visibleFrame.width ?? 1280
                previewWidth = min(820, max(520, screenWidth * 0.40))
                model.secondaryOpen = true
            }
        }
    }

    private var previewMinimumWidth: CGFloat {
        360
    }

    private var secondaryMinimumWidth: CGFloat {
        LiquidGlassToken.inspectorMinWidth
    }

    private var secondaryMaximumWidth: CGFloat {
        LiquidGlassToken.inspectorMaxWidth
    }

    private var previewMaximumWidth: CGFloat {
        920
    }

    private var previewChatReservedWidth: CGFloat {
        LiquidGlassToken.chatMinWidth + 40
    }

    private func resolvedPreviewWidth(containerWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, containerWidth - 20)
        let sidebarReserved = sidebarOpen ? CGFloat(model.settings.sidebarWidth) : 0
        let spacingCount: CGFloat = sidebarOpen ? 2 : 1
        let layoutMaximum = contentWidth - sidebarReserved - previewChatReservedWidth - spacingCount * LiquidGlassToken.panelSpacing
        let maximum = min(previewMaximumWidth, max(previewMinimumWidth, layoutMaximum))
        return min(max(previewMinimumWidth, CGFloat(previewWidth)), maximum)
    }

    private func resolvedSecondaryWidth(containerWidth: CGFloat) -> CGFloat {
        guard model.secondaryOpen, !isFilePreviewMode else {
            return CGFloat(model.settings.secondaryWidth)
        }
        let contentWidth = max(0, containerWidth - 20)
        let sidebarReserved = sidebarOpen ? CGFloat(model.settings.sidebarWidth) : 0
        let spacingCount: CGFloat = sidebarOpen ? 2 : 1
        let layoutMaximum = contentWidth - sidebarReserved - LiquidGlassToken.chatMinWidth - spacingCount * LiquidGlassToken.panelSpacing
        let maximum = min(secondaryMaximumWidth, max(secondaryMinimumWidth, layoutMaximum))
        return min(max(secondaryMinimumWidth, CGFloat(model.settings.secondaryWidth)), maximum)
    }

    private var sidebarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if sidebarDragStart == nil {
                    sidebarDragStart = model.settings.sidebarWidth
                }
                let next = (sidebarDragStart ?? model.settings.sidebarWidth) + value.translation.width
                if next < 160 {
                    sidebarOpen = false; sidebarDragStart = nil
                } else {
                    model.settings.sidebarWidth = min(450, max(Double(LiquidGlassToken.sidebarWidth), next))
                }
            }
            .onEnded { _ in sidebarDragStart = nil; model.persistSettings() }
    }

    private var secondaryResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if rightDragStart == nil {
                    rightDragStart = model.settings.secondaryWidth
                }
                let next = (rightDragStart ?? model.settings.secondaryWidth) - value.translation.width
                if next < 260 {
                    model.secondaryOpen = false; rightDragStart = nil
                } else {
                    model.settings.secondaryWidth = min(Double(secondaryMaximumWidth), max(Double(secondaryMinimumWidth), next))
                }
            }
            .onEnded { _ in rightDragStart = nil; model.persistSettings() }
    }

    private var previewResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if rightDragStart == nil {
                    rightDragStart = previewWidth
                }
                let next = (rightDragStart ?? previewWidth) - value.translation.width
                if next < 270 {
                    model.requestCloseFilePreview(); rightDragStart = nil
                } else {
                    previewWidth = min(
                        Double(previewMaximumWidth),
                        max(Double(previewMinimumWidth), next)
                    ) }
            }
            .onEnded { _ in rightDragStart = nil }
    }
}
