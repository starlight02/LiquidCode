import AppIntents
import AppKit
import SwiftUI

@MainActor
final class LiquidCodeAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            LiquidCodeMainWindowController.shared.show(model: self.model)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LiquidCodeMainWindowController.shared.show(model: model)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasActiveTurn else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Claude is still working"
        alert.informativeText = "A turn, tool permission, or streamed response is active. Quit anyway?"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@MainActor
private final class LiquidCodeMainWindowController: NSObject, NSWindowDelegate {
    static let shared = LiquidCodeMainWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        let window = existingOrCreateWindow(model: model)
        if !window.isVisible {
            window.setFrame(cascadeFrame(for: window), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func existingOrCreateWindow(model: AppModel) -> NSWindow {
        if let window {
            return window
        }
        let content = LiquidCodeRootView()
            .environmentObject(model)
        let hosting = NSHostingController(rootView: content)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(screenFrame.width * 0.86, LiquidGlassToken.minWindowWidth), 1760)
        let height = min(max(screenFrame.height * 0.86, LiquidGlassToken.minWindowHeight), 1080)
        let rect = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LiquidCode"
        window.minSize = NSSize(width: LiquidGlassToken.minWindowWidth, height: LiquidGlassToken.minWindowHeight)
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureLiquidWindow(window)
        self.window = window
        return window
    }

    private func cascadeFrame(for window: NSWindow) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? window.frame
        var frame = window.frame
        if frame.width < window.minSize.width || frame.height < window.minSize.height {
            frame.size = NSSize(width: max(frame.width, window.minSize.width), height: max(frame.height, window.minSize.height))
        }
        if !screenFrame.intersects(frame) {
            frame.origin = NSPoint(x: screenFrame.midX - frame.width / 2, y: screenFrame.midY - frame.height / 2)
        }
        return frame
    }
}

@main
struct LiquidCodeApp: App {
    @NSApplicationDelegateAdaptor(LiquidCodeAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            LiquidCodeCommands(model: appDelegate.model)
        }
    }
}

private struct LiquidCodeRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        AppShellView()
            .preferredColorScheme(colorScheme)
            .frame(minWidth: LiquidGlassToken.minWindowWidth, minHeight: LiquidGlassToken.minWindowHeight)
    }

    private var colorScheme: ColorScheme? {
        switch model.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct LiquidCodeCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings") {
                LiquidCodeMainWindowController.shared.show(model: model)
                model.settingsOpen = true
            }
            .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { LiquidCodeMainWindowController.shared.show(model: model) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Chat") {
                LiquidCodeMainWindowController.shared.show(model: model)
                model.newChat()
            }
            .keyboardShortcut("n")
            Button("Command Palette") { model.commandPaletteOpen = true }.keyboardShortcut("k")
            Button("Next Session") { model.selectNextSession() }.keyboardShortcut(.tab, modifiers: [.control])
            Button("Previous Session") { model.selectPreviousSession() }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Increase Font Size") { model.adjustFontSize(1) }.keyboardShortcut("+", modifiers: [.command])
            Button("Decrease Font Size") { model.adjustFontSize(-1) }.keyboardShortcut("-", modifiers: [.command])
        }
        CommandMenu("Claude") {
            Button("Send") { model.sendComposer() }.keyboardShortcut(.return, modifiers: [])
            Button("Interrupt") { model.interrupt() }.keyboardShortcut(".")
            Picker("Mode", selection: $model.settings.sessionMode) { ForEach(SessionMode.allCases) { Text($0.label).tag($0) } }
        }
        CommandMenu("Panels") {
            Button("Files") { LiquidCodeMainWindowController.shared.show(model: model); model.secondaryTab = .files }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Skills") { LiquidCodeMainWindowController.shared.show(model: model); model.secondaryTab = .skills }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Plan") { LiquidCodeMainWindowController.shared.show(model: model); model.secondaryTab = .plan }.keyboardShortcut("5", modifiers: [.command, .option])
            Button("MCP") { LiquidCodeMainWindowController.shared.show(model: model); model.settingsTab = .mcp; model.settingsOpen = true }.keyboardShortcut(
                "3",
                modifiers: [.command, .option]
            )
            Button("Agents") { LiquidCodeMainWindowController.shared.show(model: model); model.agentPanelOpen.toggle() }.keyboardShortcut("4", modifiers: [.command, .option])
            Button("Settings") { LiquidCodeMainWindowController.shared.show(model: model); model.settingsOpen = true }.keyboardShortcut(",")
        }
    }
}
