import XCTest
@testable import cmux

final class DmuxIntegrationTests: XCTestCase {

    // MARK: - Claude Provider Full Flow

    func test_claudeProvider_fullTransferFlow() async {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"List all models"},"sessionId":"t-123"}
        {"type":"progress","data":{"type":"hook_progress"},"sessionId":"t-123"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found User, Post, Comment in app/models/"}]},"sessionId":"t-123"}
        """

        let provider = ClaudeProvider()
        let tmpFile = NSTemporaryDirectory() + "test-integration-claude-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)
        XCTAssertEqual(messages.count, 2)

        let payload = await DmuxTransferCoordinator.preparePayload(messages: messages)

        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("List all models"))
            XCTAssertTrue(text.contains("User, Post, Comment"))
            XCTAssertTrue(text.contains("[Context transferred"))
            XCTAssertTrue(text.contains("[End of transferred context]"))
        } else {
            XCTFail("Expected verbatim payload for short conversation")
        }
    }

    // MARK: - Codex Provider Full Flow

    func test_codexProvider_fullTransferFlow() async {
        let jsonl = """
        {"timestamp":"2026-03-11T19:00:00Z","type":"session_meta","payload":{"id":"019cde3f","cwd":"/tmp"}}
        {"timestamp":"2026-03-11T19:00:01Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system prompt"}]}}
        {"timestamp":"2026-03-11T19:00:02Z","type":"turn_context","payload":{"user_message":"Fix the bug"}}
        {"timestamp":"2026-03-11T19:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed in auth.rb line 42"}]}}
        """

        let provider = CodexProvider()
        let tmpFile = NSTemporaryDirectory() + "test-integration-codex-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)
        XCTAssertEqual(messages.count, 2, "Should have user (turn_context) + assistant, skip developer and session_meta")

        let payload = await DmuxTransferCoordinator.preparePayload(messages: messages)

        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("Fix the bug"))
            XCTAssertTrue(text.contains("auth.rb"))
        } else {
            XCTFail("Expected verbatim payload")
        }
    }

    // MARK: - Cross-Provider Normalization

    func test_bothProviders_produceNormalizedMessages() async {
        // Claude format
        let claudeJsonl = """
        {"type":"user","message":{"role":"user","content":"hello from claude"},"sessionId":"c-1"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"claude response"}]},"sessionId":"c-1"}
        """

        // Codex format
        let codexJsonl = """
        {"timestamp":"2026-03-11T19:00:00Z","type":"turn_context","payload":{"user_message":"hello from codex"}}
        {"timestamp":"2026-03-11T19:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex response"}]}}
        """

        let claudeProvider = ClaudeProvider()
        let codexProvider = CodexProvider()

        let claudeFile = NSTemporaryDirectory() + "test-norm-claude-\(UUID().uuidString).jsonl"
        let codexFile = NSTemporaryDirectory() + "test-norm-codex-\(UUID().uuidString).jsonl"
        try! claudeJsonl.write(toFile: claudeFile, atomically: true, encoding: .utf8)
        try! codexJsonl.write(toFile: codexFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: claudeFile)
            try? FileManager.default.removeItem(atPath: codexFile)
        }

        let claudeMessages = claudeProvider.extractMessages(from: claudeFile)
        let codexMessages = codexProvider.extractMessages(from: codexFile)

        // Both should produce the same normalized structure
        XCTAssertEqual(claudeMessages.count, 2)
        XCTAssertEqual(codexMessages.count, 2)
        XCTAssertEqual(claudeMessages[0].role, "user")
        XCTAssertEqual(codexMessages[0].role, "user")
        XCTAssertEqual(claudeMessages[1].role, "assistant")
        XCTAssertEqual(codexMessages[1].role, "assistant")
    }

    // MARK: - Drag Coordinator Intent Transitions

    @MainActor
    func test_dragCoordinator_intentTransitions() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()
        let targetId = UUID()
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 400)

        coordinator.beginDrag(at: NSPoint(x: 200, y: 200), sourcePanelId: sourceId, sourcePaneBounds: bounds)
        XCTAssertTrue(coordinator.isDragging)

        // Below threshold → none
        var intent = coordinator.computeIntent(currentPoint: NSPoint(x: 210, y: 200), targetPanelId: nil)
        XCTAssertEqual(intent, .none)

        // Inside pane, enough distance → split
        intent = coordinator.computeIntent(currentPoint: NSPoint(x: 300, y: 200), targetPanelId: nil)
        if case .split(let dir) = intent {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected split, got \(intent)")
        }

        // Cross into target pane → merge
        intent = coordinator.computeIntent(currentPoint: NSPoint(x: 500, y: 200), targetPanelId: targetId)
        if case .merge(let id) = intent {
            XCTAssertEqual(id, targetId)
        } else {
            XCTFail("Expected merge, got \(intent)")
        }

        // Cross into empty → fork
        intent = coordinator.computeIntent(currentPoint: NSPoint(x: 500, y: 200), targetPanelId: nil)
        if case .fork(let dir) = intent {
            XCTAssertEqual(dir, .right)
        } else {
            XCTFail("Expected fork, got \(intent)")
        }

        // End drag
        let (panelId, finalIntent) = coordinator.endDrag()
        XCTAssertEqual(panelId, sourceId)
        XCTAssertFalse(coordinator.isDragging)
        if case .fork = finalIntent { } else { XCTFail("Expected fork as final intent") }
    }

    // MARK: - Transfer Payload Edge Cases

    func test_transferPayload_emptyMessages() async {
        let payload = await DmuxTransferCoordinator.preparePayload(messages: [])
        if case .empty(let reason) = payload {
            XCTAssertTrue(reason.contains("No context"))
        } else {
            XCTFail("Expected empty payload")
        }
    }

    func test_transferPayload_singleMessage() async {
        let messages = [TransferMessage(role: "user", content: "just one message")]
        let payload = await DmuxTransferCoordinator.preparePayload(messages: messages)
        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("just one message"))
        } else {
            XCTFail("Expected verbatim")
        }
    }

    // MARK: - Session Registry

    @MainActor
    func test_sessionRegistry_registerAndLookup() {
        let registry = AgentSessionRegistry()
        let panelId = UUID()
        let workspaceId = UUID()

        let session = TrackedAgentSession(
            agent: .claude,
            sessionId: "test-session",
            cwd: "/tmp/test",
            transcriptPath: "/tmp/test.jsonl",
            workspaceId: workspaceId,
            panelId: panelId,
            pid: 123
        )

        registry.register(session)
        XCTAssertNotNil(registry.session(forPanelId: panelId))
        XCTAssertEqual(registry.session(forPanelId: panelId)?.sessionId, "test-session")
        XCTAssertEqual(registry.sessionsForWorkspace(workspaceId).count, 1)

        registry.unregister(panelId: panelId)
        XCTAssertNil(registry.session(forPanelId: panelId))
    }

    // MARK: - Drag Coordinator Activation Check

    func test_dragCoordinator_activationModifiers() {
        // This tests the static method — we can't easily create NSEvents in tests,
        // but we can verify the modifier flags constant is set correctly
        let expectedModifiers: NSEvent.ModifierFlags = [.control, .shift]
        XCTAssertEqual(DmuxDragCoordinator.activationModifiers, expectedModifiers)
    }
}
