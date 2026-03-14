import XCTest
@testable import cmux

final class DmuxClaudeProviderTests: XCTestCase {

    @MainActor
    func test_extractMessages_parsesUserAndAssistant() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"Fix the auth bug"},"sessionId":"abc-123"}
        {"type":"progress","data":{"type":"hook_progress"},"sessionId":"abc-123"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found issue in auth.rb"}]},"sessionId":"abc-123"}
        """

        let provider = ClaudeProvider()
        let tmpFile = NSTemporaryDirectory() + "test-claude-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Fix the auth bug")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertTrue(messages[1].content.contains("auth.rb"))
    }

    @MainActor
    func test_extractMessages_skipsNonConversationEntries() {
        let jsonl = """
        {"type":"progress","data":{"type":"hook_progress"},"sessionId":"abc"}
        {"type":"file-history-snapshot","messageId":"xyz"}
        {"type":"user","message":{"role":"user","content":"hello"},"sessionId":"abc"}
        """

        let provider = ClaudeProvider()
        let tmpFile = NSTemporaryDirectory() + "test-claude-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)
        XCTAssertEqual(messages.count, 1)
    }

    @MainActor
    func test_resolveTranscriptPath_encodesPathCorrectly() {
        let provider = ClaudeProvider()
        let path = provider.resolveTranscriptPath(cwd: "/Users/john/project", sessionId: "abc-123")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(path, "\(home)/.claude/projects/-Users-john-project/abc-123.jsonl")
    }
}
