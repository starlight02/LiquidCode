import XCTest

/// Locks the structural invariants that kept the sidebar Settings control dead
/// across multiple "fix(settings)" patches. These are source-shape tests: if
/// somebody puts the footer back inside glassEffect content or re-opens Settings
/// synchronously under the same mouse-up, the suite fails before ship.
final class SettingsHitTestingRegressionTests: XCTestCase {
    func testSidebarFooterIsOverlaySiblingNotInsideGlassPanelContent() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let body = try XCTUnwrap(
            Self.typeBody(named: "SidebarView", in: source),
            "Could not locate SidebarView body for hit-testing regression"
        )

        XCTAssertTrue(
            body.contains(".overlay(alignment: .bottom)"),
            "Settings regression: sidebar footer must be an overlay sibling so it is not inside glassEffect content hit-testing."
        )
        XCTAssertTrue(
            body.contains("SidebarFooterMetrics.reservedHeight"),
            "Settings regression: ScrollView must reserve the footer band so rows never sit under the overlay."
        )
        XCTAssertTrue(
            body.contains("sidebarFooter"),
            "Settings regression: Agents/Settings footer must still exist."
        )

        // The old failure mode: footer declared as the last child inside GlassPanel's VStack.
        // Overlay placement is the lock; also forbid reintroducing a trailing overlay resize
        // handle that covers the footer.
        XCTAssertFalse(
            body.contains("sidebarResizeGesture"),
            "Settings regression: resize handle must not re-enter SidebarView; it lives in the AppShell gutter."
        )
        XCTAssertFalse(
            body.contains("bottomExclusion: 0"),
            "Settings regression: a zero bottomExclusion re-expands the resize strip into the Settings control."
        )
    }

    func testAppShellResizeStripExcludesFooterBand() throws {
        let source = try Self.source("LiquidCode/Views.swift")
        XCTAssertTrue(
            source.contains("bottomExclusion: SidebarFooterMetrics.reservedHeight"),
            "Settings regression: AppShellView resize strip must exclude the sidebar footer band."
        )
        XCTAssertTrue(
            source.contains("PaneResizeHandle("),
            "Settings regression: sidebar resize must stay a gutter PaneResizeHandle, not an overlay on the sidebar."
        )
    }

    func testOpenSettingsDefersPastCurrentMouseUp() throws {
        let source = try Self.source("LiquidCode/AppModel/ModelConfig.swift")
        let body = try XCTUnwrap(
            Self.functionBody(named: "openSettings", in: source),
            "Could not locate openSettings for open/dismiss race regression"
        )

        XCTAssertTrue(
            body.contains("DispatchQueue.main.async"),
            "Settings regression: openSettings must defer settingsOpen past the current mouse-up so the backdrop does not eat the same click."
        )
        XCTAssertTrue(
            body.contains("if settingsOpen"),
            "Settings regression: openSettings should no-op when already open instead of re-inserting the backdrop mid-gesture."
        )
        XCTAssertTrue(
            body.contains("self?.settingsOpen = true") || body.contains("self.settingsOpen = true"),
            "Settings regression: deferred path must still set settingsOpen = true."
        )
        // Synchronous top-level assignment (outside DispatchQueue) is the flash-close race.
        let withoutAsyncBlocks = body
            .components(separatedBy: "DispatchQueue.main.async")
            .first ?? body
        XCTAssertFalse(
            withoutAsyncBlocks.contains("settingsOpen = true"),
            "Settings regression: settingsOpen must not be set synchronously in openSettings."
        )
    }

    func testSettingsPanelGatesBackdropDismissAfterAppear() throws {
        let source = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        let body = try XCTUnwrap(
            Self.typeBody(named: "SettingsPanelView", in: source),
            "Could not locate SettingsPanelView for backdrop dismiss regression"
        )

        XCTAssertTrue(
            body.contains("allowsBackdropDismiss"),
            "Settings regression: backdrop dismiss must be gated until after the opening click ends."
        )
        XCTAssertTrue(
            body.contains("guard allowsBackdropDismiss else { return }"),
            "Settings regression: backdrop tap must check the gate before closeSettings()."
        )
        XCTAssertTrue(
            body.contains("Task.sleep"),
            "Settings regression: backdrop gate must open after a short delay, not immediately on appear."
        )
        XCTAssertFalse(
            body.contains(".contentShape(Rectangle())\n        .onTapGesture"),
            "Settings regression: full-panel contentShape+tap reintroduces flash-close."
        )
    }

    func testGlassPanelStrokesNeverOwnHitTesting() throws {
        let source = try Self.source("LiquidCode/NativeGlass.swift")
        let body = try XCTUnwrap(
            Self.typeBody(named: "GlassPanel", in: source),
            "Could not locate GlassPanel for stroke hit-testing regression"
        )

        let strokeOverlays = body.components(separatedBy: ".overlay {")
            .dropFirst()
            .filter { $0.contains("shape.stroke") || $0.contains("shape.stroke(") }
        XCTAssertFalse(strokeOverlays.isEmpty, "GlassPanel should still draw stroke overlays.")
        for overlay in strokeOverlays {
            XCTAssertTrue(
                overlay.contains("allowsHitTesting(false)"),
                "Settings regression: decorative glass strokes must set allowsHitTesting(false)."
            )
        }
    }

    // MARK: - Source helpers

    private static func source(_ relativePath: String) throws -> String {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func typeBody(named typeName: String, in source: String) -> String? {
        let signatures = [
            "struct \(typeName): View {",
            "struct \(typeName)<",
            "struct \(typeName) {"
        ]
        guard
            let signatureRange = signatures.compactMap({ source.range(of: $0) }).first,
            let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{")
        else {
            return nil
        }
        return balancedBody(from: openingBrace, in: source)
    }

    private static func functionBody(named name: String, in source: String) -> String? {
        let needles = [
            "func \(name)(",
            "func \(name) ("
        ]
        guard
            let signatureRange = needles.compactMap({ source.range(of: $0) }).first,
            let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{")
        else {
            return nil
        }
        return balancedBody(from: openingBrace, in: source)
    }

    private static func balancedBody(from openingBrace: String.Index, in source: String) -> String? {
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            let ch = source[cursor]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
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
