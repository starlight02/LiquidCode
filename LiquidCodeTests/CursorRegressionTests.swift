import XCTest

final class CursorRegressionTests: XCTestCase {
    func testAppShellDoesNotInstallAFullWindowCursorOverlay() throws {
        let source = try Self.source("LiquidCode/Views.swift")

        XCTAssertFalse(
            source.contains("ClickableCursorBridge"),
            "Cursor regression: AppShellView must not install a full-window cursor overlay. AppKit text fields own their I-beam cursor rects."
        )
    }

    func testNativeGlassHasNoGlobalCursorMonitorOrTextCursorOverride() throws {
        let source = try Self.source("LiquidCode/NativeGlass.swift")

        for forbidden in [
            "ClickableCursorBridge",
            "ClickableCursorTrackingView",
            "CursorHitPolicy",
            "CursorRegionBridge",
            "CursorRegionRegistry",
            "CursorRegionTrackingView",
            "NSEvent.addLocalMonitorForEvents",
            "addCursorRect(bounds, cursor: .arrow)",
            "NSCursor.iBeam",
            ".iBeam",
            "window.acceptsMouseMovedEvents = true"
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Cursor regression: NativeGlass.swift must not contain global cursor management token: \(forbidden)"
            )
        }
    }

    func testComposerDoesNotRegisterOversizedTextCursorShield() throws {
        let source = try Self.source("LiquidCode/ViewSettingsPanels.swift")

        XCTAssertFalse(
            source.contains("CursorRegionBridge"),
            "Cursor regression: composer must not use SwiftUI-sized text cursor shields; oversized regions make blank areas show I-beam."
        )
    }

    func testClickableControlsStillOptIntoLocalPointingHandOnly() throws {
        let source = try Self.source("LiquidCode/NativeGlass.swift")

        XCTAssertTrue(
            source.contains("func pointingHandCursor(enabled: Bool = true)"),
            "Clickable controls still need an explicit local hover modifier."
        )
        XCTAssertTrue(
            source.contains("NSCursor.pointingHand.push()"),
            "Local button hover should push pointing hand only while the view is hovered."
        )
        XCTAssertTrue(
            source.contains("NSCursor.pop()"),
            "Local button hover must pop on exit/disappear instead of forcing a global arrow cursor."
        )
        XCTAssertFalse(
            source.contains("NSCursor.arrow.set()"),
            "Cursor regression: local hover exit must not force arrow globally, or text inputs can flicker when moving into them."
        )
    }

    func testSearchFieldDoesNotApplyPointingHandToTheWholeField() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let searchField = try XCTUnwrap(Self.typeBody(named: "GlassSearchField", in: source))

        XCTAssertTrue(
            searchField.contains("TextField(L(placeholder), text: $text)"),
            "Search field regression: the left search field should remain a native text input."
        )
        XCTAssertEqual(
            searchField.components(separatedBy: ".pointingHandCursor").count - 1,
            1,
            "Search field regression: only the clear-search button may opt into pointing hand; the whole search field must not."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func typeBody(named typeName: String, in source: String) -> String? {
        guard
            let signatureRange = source.range(of: "struct \(typeName)"),
            let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{")
        else {
            return nil
        }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            if source[cursor] == "{" {
                depth += 1
            } else if source[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    let bodyStart = source.index(after: openingBrace)
                    return String(source[bodyStart ..< cursor])
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
