import XCTest
@testable import LiquidCode

final class StreamEventParserTests: XCTestCase {
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
        XCTAssertTrue(message.content.contains("I will inspect the file."))
        XCTAssertTrue(message.content.contains("[tool_use: Read]"))
        XCTAssertTrue(message.content.contains("README.md"))
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
