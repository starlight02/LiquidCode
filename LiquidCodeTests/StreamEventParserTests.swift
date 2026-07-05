@testable import LiquidCode
import XCTest

final class StreamEventParserTests: XCTestCase {
    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    // swiftlint:disable:next line_length
    private static let tinyJPEGBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD50ooor8MP9Uz/2Q=="

    func testAssistantMessageRendersTextAndToolUseBlocks() throws {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": "msg-1",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "I will inspect the file."],
                    ["type": "tool_use", "id": "tool-1", "name": "Read", "input": ["file_path": "README.md"]]
                ]
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.id, "msg-1")
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "I will inspect the file.")
        XCTAssertFalse(message.content.contains("[tool_use:"))
        XCTAssertEqual(message.blocks.map(\.kind), [.text, .toolUse])
        XCTAssertEqual(message.blocks.last?.toolName, "Read")
        XCTAssertEqual(message.blocks.last?.toolUseID, "tool-1")
        XCTAssertTrue(message.blocks.last?.inputJSON?.contains("README.md") == true)

        let events = StreamEventParser.events(from: object, sessionID: "session-1")
        XCTAssertTrue(events.contains { event in
            if case .message(_, let parsedMessage) = event {
                return parsedMessage.id == "msg-1"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .toolStarted(_, let tool) = event {
                return tool.id == "tool-1" && tool.name == "Read" && tool.inputPreview.contains("README.md")
            }
            return false
        })
    }

    func testEmptyAssistantMessageWithoutToolUseIsIgnored() throws {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": "empty-assistant",
            "message": [
                "role": "assistant",
                "content": []
            ]
        ]

        XCTAssertNil(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertTrue(StreamEventParser.events(from: object, sessionID: "session-1").isEmpty)
    }

    func testControlRequestMapsPermissionMetadataAndShellRisk() throws {
        let object: [String: Any] = [
            "type": "control_request",
            "request_id": "req-1",
            "request": [
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "description": "Run the release build",
                "input": ["command": "swift build -c release"],
                "tool_use_id": "tool-1",
                "parent_tool_use_id": "parent-1",
                "agent_id": "agent-1"
            ]
        ]

        let events = StreamEventParser.events(from: object, sessionID: "session-1")
        guard case .permissionRequested(let permission) = try XCTUnwrap(events.first) else {
            return XCTFail("expected permission request")
        }
        XCTAssertEqual(permission.id, "req-1")
        XCTAssertEqual(permission.requestID, "req-1")
        XCTAssertEqual(permission.sessionID, "session-1")
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertEqual(permission.summary, "Run the release build")
        XCTAssertEqual(permission.toolUseID, "tool-1")
        XCTAssertEqual(permission.parentToolUseID, "parent-1")
        XCTAssertEqual(permission.agentID, "agent-1")
        XCTAssertEqual(permission.risk, .shell)
        XCTAssertTrue(permission.inputJSON.contains("swift build -c release"))
    }

    @MainActor
    func testTaskSubagentPermissionFeedsAgentPanelToolCallMetadata() throws {
        let object: [String: Any] = [
            "type": "control_request",
            "request_id": "req-task-1",
            "request": [
                "subtype": "can_use_tool",
                "tool_name": "Task",
                "description": "Launch visual reviewer",
                "input": [
                    "description": "Compare reference screenshots",
                    "subagent_type": "visual-reviewer"
                ],
                "tool_use_id": "tool-task-1",
                "parent_tool_use_id": "parent-tool-1",
                "agent_id": "agent-visual-1"
            ]
        ]

        let events = StreamEventParser.events(from: object, sessionID: "session-1")
        guard case .permissionRequested(let permission) = try XCTUnwrap(events.first) else {
            return XCTFail("expected task permission request")
        }
        XCTAssertEqual(permission.toolUseID, "tool-task-1")
        XCTAssertEqual(permission.parentToolUseID, "parent-tool-1")
        XCTAssertEqual(permission.agentID, "agent-visual-1")

        let model = AppModel()
        model.selectedSessionID = "session-1"
        model.handle(try XCTUnwrap(events.first))

        let tool = try XCTUnwrap(model.selectedToolCalls.first)
        XCTAssertEqual(tool.id, "tool-task-1")
        XCTAssertEqual(tool.sessionID, "session-1")
        XCTAssertEqual(tool.name, "visual-reviewer")
        XCTAssertEqual(tool.status, .waitingForPermission)
        XCTAssertEqual(tool.parentID, "parent-tool-1")
        XCTAssertTrue(tool.inputPreview.contains("Compare reference screenshots"))
        XCTAssertTrue(tool.inputPreview.contains("visual-reviewer"))
        XCTAssertTrue(tool.resultPreview.contains("Launch visual reviewer"))
    }

    func testToolResultUpdatesMatchingToolCall() throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "tool-result-message",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "tool-1", "content": "42 tests passed"]
                ]
            ]
        ]

        let events = StreamEventParser.events(from: object, sessionID: "session-1")
        XCTAssertTrue(events.contains { event in
            if case .toolUpdated(_, let tool) = event {
                return tool.id == "tool-1" && tool.status == .succeeded && tool.resultPreview.contains("42 tests passed")
            }
            return false
        })
    }

    func testContentBlockStreamingEventsExposeStructuredBlocks() throws {
        let start: [String: Any] = [
            "type": "content_block_start",
            "index": 1,
            "content_block": [
                "type": "tool_use",
                "id": "tool-stream-1",
                "name": "Bash",
                "input": [:]
            ]
        ]
        let inputDelta: [String: Any] = [
            "type": "content_block_delta",
            "index": 1,
            "delta": [
                "type": "input_json_delta",
                "partial_json": "{\"command\":\"echo hi\"}"
            ]
        ]
        let thinkingDelta: [String: Any] = [
            "type": "content_block_delta",
            "index": 0,
            "delta": [
                "type": "thinking_delta",
                "thinking": "I should inspect the project."
            ]
        ]

        let startEvents = StreamEventParser.events(from: start, sessionID: "session-1")
        guard case .streamBlockStarted("session-1", .some(1), let block) = try XCTUnwrap(startEvents.first) else {
            return XCTFail("expected structured stream block start")
        }
        XCTAssertEqual(block.kind, .toolUse)
        XCTAssertEqual(block.toolUseID, "tool-stream-1")
        XCTAssertEqual(block.toolName, "Bash")

        let inputEvents = StreamEventParser.events(from: inputDelta, sessionID: "session-1")
        guard case .streamBlockDelta("session-1", .some(1), .toolUse, let partialJSON) = try XCTUnwrap(inputEvents.first) else {
            return XCTFail("expected tool input stream delta")
        }
        XCTAssertEqual(partialJSON, "{\"command\":\"echo hi\"}")

        let thinkingEvents = StreamEventParser.events(from: thinkingDelta, sessionID: "session-1")
        guard case .streamBlockDelta("session-1", .some(0), .thinking, let thinking) = try XCTUnwrap(thinkingEvents.first) else {
            return XCTFail("expected thinking stream delta")
        }
        XCTAssertEqual(thinking, "I should inspect the project.")
    }

    func testUserImageContentBlockParsesAsRenderableImage() throws {
        let object: [String: Any] = [
            "type": "human",
            "uuid": "user-image",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "what is in this image?"],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": Self.tinyPNGBase64
                        ]
                    ]
                ]
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.id, "user-image")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "what is in this image?")
        XCTAssertEqual(message.images.count, 1)
        XCTAssertEqual(message.images.first?.mimeType, "image/png")
        XCTAssertNotNil(message.images.first?.imageData)
        XCTAssertFalse(message.content.contains("[Image: source:"))
    }

    func testRealClaudeImagePromptRemovesDisplayMarkersAndDeduplicatesExactSameImageBlock() throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "real-image-prompt",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "[Image #1] [Image #2] 现在我总觉得这些按钮不像液态玻璃"],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": Self.tinyPNGBase64
                        ]
                    ],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": Self.tinyPNGBase64
                        ]
                    ]
                ]
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "现在我总觉得这些按钮不像液态玻璃")
        XCTAssertFalse(message.content.contains("[Image"))
        XCTAssertEqual(message.images.count, 1)
        XCTAssertNotNil(message.images.first?.imageData)
    }

    func testRealClaudeImagePromptKeepsDistinctImagesInOneUserMessageWithoutRawMarkers() throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "real-image-prompt-two-distinct-images",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "[\u{200B}Image #\u{200B}1]\u{200B} [\u{200B}Image #\u{200B}2]\u{200B} 现在我总觉得这些按钮不像液态玻璃"],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": Self.tinyJPEGBase64
                        ]
                    ],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": Self.tinyPNGBase64
                        ]
                    ]
                ]
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "现在我总觉得这些按钮不像液态玻璃")
        XCTAssertFalse(message.content.contains("[Image"))
        XCTAssertFalse(message.content.contains("[\u{200B}Image"))
        XCTAssertEqual(message.images.count, 2)
        XCTAssertEqual(message.images.map(\.mimeType), ["image/jpeg", "image/png"])
        XCTAssertTrue(message.images.allSatisfy { $0.imageData != nil })
    }

    func testClaudeMetaImageSourceCompanionMessageIsIgnored() throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "meta-image-source",
            "isMeta": true,
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "[Image: source: /var/folders/missing/clipboard.png]"],
                    ["type": "text", "text": "[Image: source: /Users/starshine/Pictures/same-day.png]"]
                ]
            ]
        ]

        XCTAssertNil(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertTrue(StreamEventParser.events(from: object, sessionID: "session-1").isEmpty)
    }

    func testQueueOperationPromptIsNotRenderedAsAssistantMessage() throws {
        let object: [String: Any] = [
            "type": "queue-operation",
            "operation": "enqueue",
            "timestamp": "2026-07-04T13:29:02.708Z",
            "sessionId": "real-session",
            "content": "你好？"
        ]

        XCTAssertNil(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertTrue(StreamEventParser.events(from: object, sessionID: "session-1").isEmpty)
    }

    func testLastPromptMetadataIsNotRenderedAsAssistantMessage() throws {
        let object: [String: Any] = [
            "type": "last-prompt",
            "lastPrompt": "你好？",
            "leafUuid": "leaf",
            "sessionId": "real-session"
        ]

        XCTAssertNil(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertTrue(StreamEventParser.events(from: object, sessionID: "session-1").isEmpty)
    }

    func testClaudeSlashCommandProtocolRendersAsSystemCommandEvent() throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "command-clear",
            "message": [
                "role": "user",
                "content": """
                <command-name>/clear</command-name>
                            <command-message>clear</command-message>
                            <command-args></command-args>
                """
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.toolName, "Claude Code Command")
        XCTAssertEqual(message.content, "`/clear`")
        XCTAssertFalse(message.content.contains("<command-name>"))
        XCTAssertNil(message.checkpointUuid)

        let events = StreamEventParser.events(from: object, sessionID: "session-1")
        XCTAssertTrue(events.contains { event in
            if case .message(_, let parsed) = event {
                return parsed.id == "command-clear" && parsed.role == .system && parsed.content == "`/clear`"
            }
            return false
        })
    }

    func testClaudeInterruptionMarkerRendersAsSystemEventWithoutRawBrackets() throws {
        let object: [String: Any] = [
            "type": "user",
            "uuid": "interrupt",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "[Request interrupted by user]"]
                ]
            ]
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.toolName, "Interrupted")
        XCTAssertEqual(message.content, "User interrupted the request.")
        XCTAssertFalse(message.content.contains("[Request interrupted by user]"))
        XCTAssertNil(message.checkpointUuid)
    }

    func testSystemLocalCommandProtocolCanRenderAsReadableControlEvent() throws {
        let object: [String: Any] = [
            "type": "system",
            "subtype": "local_command",
            "uuid": "context-command",
            "content": """
            <command-name>/context</command-name>
                        <command-message>context</command-message>
                        <command-args></command-args>
            """
        ]

        let message = try XCTUnwrap(StreamEventParser.messageFromJSONObject(object, fallbackID: "fallback"))
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.toolName, "Claude Code Command")
        XCTAssertEqual(message.content, "`/context`")
        XCTAssertTrue(StreamEventParser.events(from: object, sessionID: "session-1").contains { event in
            if case .message(_, let parsed) = event {
                return parsed.id == "context-command"
            }
            return false
        })
    }

    func testProviderRecordRoundTripsMappingsAndExtraEnvironment() throws {
        let provider = ProviderRecord(
            id: "kimi-code",
            name: "Kimi Code",
            baseURL: "https://api.kimi.com/coding/",
            apiFormat: .anthropic,
            modelMappings: ["opus": "kimi-for-coding", "sonnet": "kimi-for-coding"],
            extraEnv: ["ENABLE_TOOL_SEARCH": "false"],
            preset: "kimi-code"
        )

        let data = try JSONEncoder.liquid.encode(provider)
        let decoded = try JSONDecoder.liquid.decode(ProviderRecord.self, from: data)
        XCTAssertEqual(decoded.id, provider.id)
        XCTAssertEqual(decoded.name, provider.name)
        XCTAssertEqual(decoded.baseURL, provider.baseURL)
        XCTAssertEqual(decoded.apiFormat, provider.apiFormat)
        XCTAssertEqual(decoded.preset, provider.preset)
        XCTAssertEqual(decoded.modelMappings["opus"], "kimi-for-coding")
        XCTAssertEqual(decoded.extraEnv["ENABLE_TOOL_SEARCH"], "false")
    }
}
