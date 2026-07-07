@testable import LiquidCode
import XCTest

final class TranscriptAutoExpansionRegressionTests: XCTestCase {
    func testCommittedIncompleteToolRunAutoExpandsWhileTurnIsActiveWithoutStreamingItems() throws {
        let message = ChatMessage(
            id: "assistant-stream-tools",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(
                    id: "read-block",
                    kind: .toolUse,
                    toolUseID: "read-1",
                    toolName: "Read",
                    inputJSON: #"{"file_path":"README.md"}"#
                ),
                ChatContentBlock(
                    id: "read-result-block",
                    kind: .toolResult,
                    text: "read ok",
                    toolUseID: "read-1"
                ),
                ChatContentBlock(
                    id: "bash-block",
                    kind: .toolUse,
                    toolUseID: "bash-1",
                    toolName: "Bash",
                    inputJSON: #"{"command":"xcodebuild test"}"#
                )
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])
        let state = TranscriptAutoExpansionPolicy.state(for: items, isStreaming: true)

        XCTAssertEqual(items.count, 1)
        guard case .toolRun(let runItems) = items.first else {
            return XCTFail("expected streaming tool blocks to render as one tool run")
        }
        XCTAssertEqual(runItems.map(\.id), [
            "assistant-stream-tools_tool_0_read-block",
            "assistant-stream-tools_tool_result_1_read-1",
            "assistant-stream-tools_tool_2_bash-block"
        ])
        let expandedDisplayID = [
            "toolrun",
            "assistant-stream-tools_tool_0_read-block",
            "assistant-stream-tools_tool_result_1_read-1",
            "assistant-stream-tools_tool_2_bash-block"
        ].joined(separator: "_")
        XCTAssertEqual(state.expandedDisplayItemID, expandedDisplayID)
        XCTAssertEqual(state.expandedToolItemID, "assistant-stream-tools_tool_2_bash-block")
    }

    func testTranscriptAutoExpansionPolicyCollapsesCompletedToolRunTranscript() throws {
        let message = ChatMessage(
            id: "assistant-complete-tools",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(
                    id: "read-block",
                    kind: .toolUse,
                    toolUseID: "read-1",
                    toolName: "Read",
                    inputJSON: #"{"file_path":"README.md"}"#
                ),
                ChatContentBlock(
                    id: "read-result-block",
                    kind: .toolResult,
                    text: "read ok",
                    toolUseID: "read-1"
                )
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])
        let state = TranscriptAutoExpansionPolicy.state(for: items, isStreaming: false)

        XCTAssertEqual(items.count, 1)
        guard case .toolRun = items.first else {
            return XCTFail("expected completed tool use/result to render as one tool run")
        }
        XCTAssertNil(state.expandedDisplayItemID)
        XCTAssertNil(state.expandedToolItemID)
    }

    func testTranscriptAutoExpansionPolicyCollapsesStreamingTranscriptWhenAssistantTextTrailsToolRun() throws {
        let message = ChatMessage(
            id: "assistant-finished-tools",
            role: .assistant,
            content: "",
            blocks: [
                ChatContentBlock(
                    id: "read-block",
                    kind: .toolUse,
                    toolUseID: "read-1",
                    toolName: "Read",
                    inputJSON: #"{"file_path":"README.md"}"#
                ),
                ChatContentBlock(
                    id: "read-result-block",
                    kind: .toolResult,
                    text: "read ok",
                    toolUseID: "read-1"
                ),
                ChatContentBlock(kind: .text, text: "Done reading the file.")
            ]
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])
        let state = TranscriptAutoExpansionPolicy.state(for: items, isStreaming: true)

        XCTAssertEqual(items.count, 2)
        guard case .toolRun = items.first else {
            return XCTFail("expected tool use/result to render before the trailing assistant text")
        }
        guard case .message(let trailingText) = items.last else {
            return XCTFail("expected trailing assistant text to be the latest transcript item")
        }
        XCTAssertEqual(trailingText.content, "Done reading the file.")
        XCTAssertNil(state.expandedDisplayItemID)
        XCTAssertNil(state.expandedToolItemID)
    }

    func testTranscriptToolRunCompletionReturnsFalseWhenAGroupedRunLacksAResult() throws {
        let message = ChatMessage(
            id: "assistant-incomplete-tools",
            role: .assistant,
            content: """
            [tool_use: Read]
            {"file_path":"README.md"}
            [tool_use: Bash]
            {"command":"xcodebuild test -project LiquidCode.xcodeproj -scheme LiquidCode"}
            [tool_result]
            read ok
            """
        )

        let items = TranscriptDisplayBuilder.displayItems(messages: [message])

        guard case .toolRun(let runItems) = items.first else {
            return XCTFail("expected two tool uses to remain represented as a grouped run")
        }
        XCTAssertEqual(runItems.map(\.kind), [.use, .use, .result])
        XCTAssertFalse(TranscriptToolRunCompletion.isComplete(runItems))
    }

    @MainActor
    func testStreamingToolInputPayloadGrowsAsPartialJSONArrives() throws {
        let model = AppModel()
        model.selectedSessionID = "session-1"

        let start: [String: Any] = [
            "type": "content_block_start",
            "index": 0,
            "content_block": [
                "type": "tool_use",
                "id": "tool-stream-1",
                "name": "Bash",
                "input": [:]
            ]
        ]
        let inputDelta: [String: Any] = [
            "type": "content_block_delta",
            "index": 0,
            "delta": [
                "type": "input_json_delta",
                "partial_json": #"{"command":"echo hi"}"#
            ]
        ]

        for event in StreamEventParser.events(from: start, sessionID: "session-1") {
            model.handle(event)
        }
        let toolBefore = try XCTUnwrap(model.selectedStreamingMessage?.blocks.first { $0.kind == .toolUse })
        XCTAssertEqual(model.selectedStreamingMessage?.content, "")
        let inputLengthBefore = (toolBefore.inputJSON ?? "").count

        for event in StreamEventParser.events(from: inputDelta, sessionID: "session-1") {
            model.handle(event)
        }
        let toolAfter = try XCTUnwrap(model.selectedStreamingMessage?.blocks.first { $0.kind == .toolUse })

        XCTAssertEqual(model.selectedStreamingMessage?.content, "")
        XCTAssertGreaterThan(
            (toolAfter.inputJSON ?? "").count,
            inputLengthBefore,
            "A streamed input_json_delta must grow the tool block's input as partial JSON arrives, so the transcript reflects the tool being built up live."
        )
        XCTAssertTrue(
            (toolAfter.inputJSON ?? "").contains("echo hi"),
            "The streamed partial JSON must accumulate into the tool block input."
        )
    }
}
