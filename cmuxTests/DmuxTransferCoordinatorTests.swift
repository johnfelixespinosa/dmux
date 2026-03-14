import XCTest
@testable import cmux

final class DmuxTransferCoordinatorTests: XCTestCase {

    func test_preparePayload_shortConversation_returnsVerbatim() async {
        let messages: [TransferMessage] = [
            .init(role: "user", content: "What does app.rb do?"),
            .init(role: "assistant", content: "It is the Sinatra entry point."),
        ]

        let payload = await DmuxTransferCoordinator.preparePayload(messages: messages)

        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("app.rb"))
            XCTAssertTrue(text.contains("Sinatra"))
            XCTAssertTrue(text.contains("[Context transferred"))
        } else {
            XCTFail("Expected verbatim payload for short conversation")
        }
    }

    func test_preparePayload_emptyMessages_returnsEmpty() async {
        let payload = await DmuxTransferCoordinator.preparePayload(messages: [])

        if case .empty(let reason) = payload {
            XCTAssertTrue(reason.contains("No context"))
        } else {
            XCTFail("Expected empty payload")
        }
    }

    func test_estimateTokenCount() {
        XCTAssertTrue(DmuxTransferCoordinator.estimateTokenCount("Hello world") < 100)
        XCTAssertTrue(DmuxTransferCoordinator.estimateTokenCount(String(repeating: "word ", count: 1000)) > 1000)
    }

    func test_buildSummarizationRequest_createsValidJSON() {
        let messages: [TransferMessage] = [
            .init(role: "user", content: "Fix the login bug"),
            .init(role: "assistant", content: "Found it in auth_controller.rb"),
        ]

        let request = DmuxTransferCoordinator.buildSummarizationRequest(messages: messages)

        XCTAssertEqual(request["model"] as? String, "claude-haiku-4-5-20251001")
        let reqMessages = request["messages"] as? [[String: String]]
        XCTAssertNotNil(reqMessages)
        XCTAssertEqual(reqMessages?.count, 1)
        XCTAssertEqual(reqMessages?.first?["role"], "user")
        XCTAssertTrue(reqMessages?.first?["content"]?.contains("login bug") ?? false)
    }
}
