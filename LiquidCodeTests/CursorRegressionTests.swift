import XCTest

final class CursorRegressionTests: XCTestCase {
    func testAppShellDoesNotInstallAFullWindowCursorOverlay() throws {
        let source = try Self.source("LiquidCode/Views.swift")

        XCTAssertFalse(
            source.contains("ClickableCursorBridge"),
            "Cursor regression: AppShellView must not install a full-window cursor overlay. AppKit text fields own their I-beam cursor rects."
        )
        XCTAssertTrue(
            source.contains("ZStack(alignment: .top)"),
            "Selection regression: AppShellView should keep top-oriented layout without installing a full-window input overlay."
        )
        XCTAssertFalse(
            source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
            "Selection regression: WindowDragRegion must not use a full-height wrapper that can steal hit testing from selectable text."
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
        XCTAssertFalse(
            source.contains("window.isMovableByWindowBackground = true"),
            "Selection regression: full-window background dragging steals text selection from message and input views."
        )
        XCTAssertTrue(
            source.contains("window.isMovableByWindowBackground = false"),
            "Selection regression: only explicit title drag regions may move the window."
        )
        XCTAssertTrue(
            source.contains("override func mouseDragged(with event: NSEvent)"),
            "Selection regression: the explicit title drag region must move the window from its own mouse-drag path instead of relying on global background dragging."
        )
        XCTAssertTrue(
            source.contains("window.setFrameOrigin(NSPoint("),
            "Selection regression: the explicit title drag region should update the NSWindow origin directly so text views can keep their own selection gestures."
        )
        XCTAssertTrue(
            source.contains("override func hitTest(_ point: NSPoint) -> NSView?"),
            "Selection regression: the transparent title drag region must explicitly opt into hit testing; otherwise top-bar dragging silently stops working."
        )
        XCTAssertTrue(
            source.contains("installWindowDragStrip(in: window)"),
            "Selection regression: the explicit title drag strip should be installed at the NSWindow contentView level, not through an unreliable full-window SwiftUI overlay."
        )
        XCTAssertTrue(
            source.contains("LiquidCodeWindowDragStrip"),
            "Selection regression: the NSWindow drag strip should be identifiable so configureLiquidWindow does not stack duplicate hit-test views."
        )
        XCTAssertTrue(
            source.contains("contentView.superview ?? contentView"),
            "Selection regression: the title drag strip should sit above the SwiftUI hosting view in the NSWindow theme frame."
        )
        XCTAssertTrue(
            source.contains("excludedLeadingWidth = 96"),
            "Selection regression: the title drag strip must not steal the close/minimize/zoom traffic-light hit area."
        )
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

    func testStackedImageCardsKeepVisibleLowerCardsClickable() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let imageStack = try XCTUnwrap(Self.typeBody(named: "MessageImageStackView", in: source))
        let imageCard = try XCTUnwrap(Self.typeBody(named: "MessageImageCardView", in: source))

        XCTAssertTrue(
            imageStack.contains(".position("),
            "Image stack regression: positioned cards keep hit regions aligned with the visible stacked image."
        )
        XCTAssertFalse(
            imageStack.contains(".offset(x: placement.origin.x, y: placement.origin.y)"),
            "Image stack regression: offset leaves an invisible top-card hit rect covering the lower image."
        )
        XCTAssertTrue(
            imageCard.contains(".contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))"),
            "Image stack regression: each image card should only hit-test inside its rounded visible card."
        )
    }

    func testQuestionCardsUseSingleColumnOptionListForHistoryAndRealtime() throws {
        let source = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        let realtimeQuestion = try XCTUnwrap(Self.typeBody(named: "QuestionInlineCardView", in: source))
        let historicalQuestion = try XCTUnwrap(Self.typeBody(named: "QuestionTranscriptCardView", in: source))
        let optionList = try XCTUnwrap(Self.typeBody(named: "QuestionOptionsListView", in: source))

        XCTAssertTrue(
            realtimeQuestion.contains("QuestionOptionsListView(options: question.options"),
            "Question card regression: realtime AskUserQuestion options should use the same single-column answer list."
        )
        XCTAssertTrue(
            historicalQuestion.contains("QuestionOptionsListView(options: prompt.options"),
            "Question card regression: historical AskUserQuestion options should use the same single-column answer list."
        )
        XCTAssertFalse(
            realtimeQuestion.contains(".overlay(alignment: .leading)"),
            "Question card regression: realtime question cards must not render a blue leading rail that looks like a stray selection bar."
        )
        XCTAssertFalse(
            historicalQuestion.contains(".overlay(alignment: .leading)"),
            "Question card regression: historical question cards must not render a blue leading rail that visually competes with the content."
        )
        XCTAssertTrue(
            optionList.contains("VStack(alignment: .leading, spacing: 8)"),
            "Question card regression: answer options must render one answer per row."
        )
        XCTAssertFalse(
            optionList.contains("LazyVGrid"),
            "Question card regression: adaptive grids make answers collapse into a horizontal row."
        )
        XCTAssertFalse(
            optionList.contains(".adaptive("),
            "Question card regression: adaptive grid columns are forbidden for question answers."
        )
        XCTAssertTrue(
            optionList.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "Question card regression: each answer row should span the card width."
        )
    }

    func testTranscriptAutoScrollsToBottomAnchorForUserMessagesAndStreaming() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let chatPanel = try XCTUnwrap(Self.typeBody(named: "ChatPanelView", in: source))

        XCTAssertTrue(
            chatPanel.contains("private let transcriptBottomAnchorID = \"transcript_bottom_anchor\""),
            "Auto-scroll regression: transcript needs a stable bottom sentinel instead of targeting the last raw message id."
        )
        XCTAssertTrue(
            chatPanel.contains("Color.clear.frame(height: 1).id(transcriptBottomAnchorID)"),
            "Auto-scroll regression: a bottom sentinel must exist after messages, streaming output, and queued user messages."
        )
        XCTAssertTrue(
            chatPanel.contains("streamingText: model.selectedStreamingText"),
            "Auto-scroll regression: streaming deltas must update the lightweight bottom-follow token."
        )
        XCTAssertTrue(
            chatPanel.contains("pendingMessages: model.selectedPendingUserMessages"),
            "Auto-scroll regression: queued user messages must also force the transcript to the bottom without joining every queued id."
        )
        XCTAssertTrue(
            chatPanel.contains(".onAppear { scrollToTranscriptBottom(proxy, animated: false) }"),
            "Auto-scroll regression: opening a transcript should land at the latest content."
        )
        XCTAssertTrue(
            chatPanel.contains(".onChange(of: transcriptAutoScrollToken)"),
            "Auto-scroll regression: every user send and assistant stream update should scroll to the bottom sentinel."
        )
        XCTAssertFalse(
            chatPanel.contains(".onChange(of: model.selectedMessages.count)"),
            "Auto-scroll regression: raw message count misses display-item regrouping and same-count streaming updates."
        )
    }

    func testSidebarRowsUseExplicitStateAndTaskGroupsRespectSelectionMode() throws {
        let source = try Self.source("LiquidCode/ViewComponents.swift")
        let sidebar = try XCTUnwrap(Self.typeBody(named: "SidebarView", in: source))
        let row = try XCTUnwrap(Self.typeBody(named: "SessionRowView", in: source))
        let taskGroupsStart = try XCTUnwrap(sidebar.range(of: "@ViewBuilder private func taskGroups"))
        let taskGroupsEnd = try XCTUnwrap(sidebar[taskGroupsStart.lowerBound...].range(of: "@ViewBuilder private func projectSessionSections"))
        let taskGroups = String(sidebar[taskGroupsStart.lowerBound ..< taskGroupsEnd.lowerBound])

        XCTAssertFalse(
            row.contains("@EnvironmentObject var model: AppModel"),
            "Sidebar performance regression: every session row must not subscribe to the entire AppModel."
        )
        XCTAssertTrue(
            row.contains("let selectionMode: Bool"),
            "Sidebar performance regression: row selection rendering should depend on a narrow value."
        )
        XCTAssertTrue(
            row.contains("let onTogglePin: () -> Void") && row.contains("let onDelete: () -> Void"),
            "Sidebar row actions must remain explicit after removing the environment object."
        )
        // Collapse whitespace so the assertion checks the control-flow shape, not the
        // exact indentation (which SwiftFormat owns and can reflow at any nesting depth).
        let normalizedTaskGroups = taskGroups.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let togglesSelection = normalizedTaskGroups
            .contains("if model.sessionSelectionMode { model.toggleSessionSelection(session)")
        XCTAssertTrue(
            togglesSelection && taskGroups.contains("model.removeSession(session, from: group)"),
            "Task-group session rows must toggle batch selection instead of opening the conversation while selection mode is active."
        )
    }

    func testComposerReturnKeySendsFromNativeTextViewAndPreservesModifiedReturn() throws {
        let source = try Self.source("LiquidCode/ViewSettingsPanels.swift")
        let composer = try XCTUnwrap(Self.typeBody(named: "ComposerTextView", in: source))
        let textView = try XCTUnwrap(Self.typeBody(named: "ComposerNSTextView", in: source))
        let inputBar = try XCTUnwrap(Self.typeBody(named: "InputBarView", in: source))

        XCTAssertTrue(
            composer.contains("var onSend: () -> Bool = { false }"),
            "Return-send regression: the native NSTextView needs an explicit send callback; SwiftUI keyboardShortcut is swallowed by text editing."
        )
        XCTAssertTrue(
            composer.contains("textView.onSend = onSend"),
            "Return-send regression: the send callback must be installed and refreshed on the underlying NSTextView."
        )
        XCTAssertTrue(
            textView.contains("override func keyDown(with event: NSEvent)"),
            "Return-send regression: ComposerNSTextView must intercept Return directly."
        )
        XCTAssertTrue(
            textView.contains("event.keyCode == 36 || event.keyCode == 76"),
            "Return-send regression: both Return and keypad Enter should use the send path."
        )
        XCTAssertTrue(
            textView.contains("flags.isDisjoint(with: [.shift, .option, .control, .command])"),
            "Return-send regression: modified Return must remain available for newlines or system text behavior."
        )
        XCTAssertTrue(
            inputBar.contains("onSend: {"),
            "Return-send regression: InputBarView must wire Return to model.sendComposer()."
        )
        XCTAssertTrue(
            inputBar.contains("guard canSend else"),
            "Return-send regression: Return must honor the same disabled state as the send button."
        )
        XCTAssertTrue(
            inputBar.contains("model.sendComposer()"),
            "Return-send regression: native Return should send the composer content."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func typeBody(named typeName: String, in source: String) -> String? {
        let signatures = [
            "struct \(typeName)",
            "class \(typeName)",
            "final class \(typeName)",
            "private final class \(typeName)"
        ]
        guard
            let signatureRange = signatures.compactMap({ source.range(of: $0) }).first,
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
