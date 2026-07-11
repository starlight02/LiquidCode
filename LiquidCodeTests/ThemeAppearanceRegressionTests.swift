import AppKit
import Combine
@testable import LiquidCode
import XCTest

final class ThemeAppearanceRegressionTests: XCTestCase {
    func testThemeModePreferredColorSchemeMapping() {
        XCTAssertNil(ThemeMode.system.preferredColorScheme)
        XCTAssertEqual(ThemeMode.light.preferredColorScheme, .light)
        XCTAssertEqual(ThemeMode.dark.preferredColorScheme, .dark)
    }

    func testThemeModeNSAppearanceMapping() {
        XCTAssertNil(ThemeMode.system.nsAppearance)
        XCTAssertEqual(ThemeMode.light.nsAppearance?.name, NSAppearance.Name.aqua)
        XCTAssertEqual(ThemeMode.dark.nsAppearance?.name, NSAppearance.Name.darkAqua)
    }

    func testThemeModeLabelsAreLocalizedKeys() {
        // Labels resolve through L(); source keys must stay stable for en/zh catalogs.
        XCTAssertEqual(ThemeMode.system.label, L("Follow System"))
        XCTAssertEqual(ThemeMode.light.label, L("Light"))
        XCTAssertEqual(ThemeMode.dark.label, L("Night"))
    }

    @MainActor
    func testAppearanceControllerAppliesAndRestoresSystemFollow() {
        let previousApp = NSApp.appearance
        let probe = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        probe.isReleasedWhenClosed = false
        probe.contentView = NSView(frame: probe.contentLayoutRect)
        let previousWindow = probe.appearance
        defer {
            NSApp.appearance = previousApp
            probe.appearance = previousWindow
            probe.contentView?.appearance = previousWindow
            probe.close()
        }

        AppearanceController.apply(.dark)
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.darkAqua)
        XCTAssertEqual(probe.appearance?.name, NSAppearance.Name.darkAqua)

        AppearanceController.apply(.light)
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.aqua)
        XCTAssertEqual(probe.appearance?.name, NSAppearance.Name.aqua)

        // Critical path: forced night → follow system must clear overrides, not no-op.
        AppearanceController.apply(.dark)
        AppearanceController.apply(.system)
        XCTAssertNil(NSApp.appearance, "system theme must clear NSApp.appearance override")
        XCTAssertNil(probe.appearance, "system theme must clear window.appearance override")
        XCTAssertNil(probe.contentView?.appearance, "system theme must clear contentView.appearance override")
    }

    @MainActor
    func testSetThemeReassignsPublishedSettingsValue() {
        let model = AppModel()
        model.settings.theme = .system

        var published = false
        let cancellable = model.objectWillChange.sink { _ in
            published = true
        }
        defer { _ = cancellable }

        model.setTheme(.dark)
        XCTAssertEqual(model.settings.theme, .dark)
        XCTAssertTrue(published, "setTheme must reassign AppSettings so @Published notifies observers")

        published = false
        model.setTheme(.light)
        XCTAssertEqual(model.settings.theme, .light)
        XCTAssertTrue(published)
    }

    func testThemeChipsAvoidLiquidGlassButtonHitDeadZone() throws {
        let source = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        guard let range = source.range(of: "private var generalContent") else {
            return XCTFail("Could not locate generalContent")
        }
        let body = String(source[range.lowerBound...].prefix(3200))
        XCTAssertTrue(body.contains("model.setTheme(theme)"), "Theme chips must call setTheme")
        XCTAssertTrue(
            body.contains(".contentShape(RoundedRectangle"),
            "Theme chips need an explicit contentShape for reliable hit testing"
        )
        XCTAssertFalse(
            body.contains("liquidGlassButton(active: model.settings.theme"),
            "Theme chips must not use liquidGlassButton/.glassEffect — nested glass deadens clicks on macOS 26"
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let project = url.appendingPathComponent("LiquidCode.xcodeproj")
            if FileManager.default.fileExists(atPath: project.path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
