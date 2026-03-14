import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DmuxAgentProviderTests: XCTestCase {

    func test_agentKind_rawValues() {
        XCTAssertEqual(AgentKind.claude.rawValue, "claude")
        XCTAssertEqual(AgentKind.codex.rawValue, "codex")
    }

    func test_trackedAgentSession_stores_metadata() {
        let session = TrackedAgentSession(
            agent: .claude,
            sessionId: "abc-123",
            cwd: "/Users/test/project",
            transcriptPath: "/Users/test/.claude/projects/-Users-test-project/abc-123.jsonl",
            workspaceId: UUID(),
            panelId: UUID(),
            pid: 12345
        )

        XCTAssertEqual(session.agent, .claude)
        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.cwd, "/Users/test/project")
        XCTAssertNotNil(session.transcriptPath)
    }

    func test_transferPayload_verbatim() {
        let payload = TransferPayload.verbatim("""
        [Context transferred from another dmux pane]
        Auth bug fix in login_controller.rb
        [End of transferred context]
        """)

        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("login_controller"))
        } else {
            XCTFail("Expected verbatim payload")
        }
    }

    func test_transferPayload_summarized() {
        let payload = TransferPayload.summarized(
            original: "very long conversation...",
            summary: "Fixed auth bug in 3 files"
        )

        if case .summarized(_, let summary) = payload {
            XCTAssertEqual(summary, "Fixed auth bug in 3 files")
        } else {
            XCTFail("Expected summarized payload")
        }
    }

    func test_transferPayload_empty() {
        let payload = TransferPayload.empty(reason: "No context available")
        XCTAssertTrue(payload.text.contains("No context available"))
    }
}
