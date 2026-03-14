import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DmuxCodexProviderTests: XCTestCase {

    @MainActor
    func test_extractMessages_parsesCodexFormat() {
        let jsonl = """
        {"timestamp":"2026-03-11T19:00:00Z","type":"session_meta","payload":{"id":"019cde3f","timestamp":"2026-03-11T18:53:45Z","cwd":"/Users/test/project"}}
        {"timestamp":"2026-03-11T19:00:01Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system instructions"}]}}
        {"timestamp":"2026-03-11T19:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the login bug"}]}}
        {"timestamp":"2026-03-11T19:00:03Z","type":"event_msg","payload":{"type":"turn_started","turn_id":"t1"}}
        {"timestamp":"2026-03-11T19:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Found the issue in auth.rb line 42."}]}}
        """

        let provider = CodexProvider()
        let tmpFile = NSTemporaryDirectory() + "test-codex-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Fix the login bug")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertTrue(messages[1].content.contains("auth.rb"))
    }

    @MainActor
    func test_extractMessages_handlesTurnContext() {
        let jsonl = """
        {"timestamp":"2026-03-11T19:00:00Z","type":"turn_context","payload":{"user_message":"What does app.rb do?"}}
        {"timestamp":"2026-03-11T19:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"It is the Sinatra entry point."}]}}
        """

        let provider = CodexProvider()
        let tmpFile = NSTemporaryDirectory() + "test-codex-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "What does app.rb do?")
    }

    @MainActor
    func test_extractMessages_skipsDeveloperRole() {
        let jsonl = """
        {"timestamp":"2026-03-11T19:00:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are a coding agent"}]}}
        {"timestamp":"2026-03-11T19:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}
        """

        let provider = CodexProvider()
        let tmpFile = NSTemporaryDirectory() + "test-codex-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, "user")
    }
}
