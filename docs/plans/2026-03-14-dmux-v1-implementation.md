# dmux v1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship dmux as a staged rebrand of cmux with provider-based context transfer. Two new gestures — merge (drag pane into pane) and fork (drag pane into empty space) — transfer agent context between panes. All animations happen during the drag, not after release. Intent is determined by distance: drag stays inside pane = split, crosses into another pane = merge, crosses into empty space = fork.

**Architecture:** Fork of cmux (AGPL-3.0). Staged rebrand with backward-compatible CMUX_* env vars. Generic agent provider layer with ClaudeProvider and CodexProvider. Workspace-level drag coordinator (not per-pane). Shortcut routing through AppDelegate's existing `performSplitShortcut` machinery. Tracked agent sessions stored on panels, not read back from live PTY.

**Tech Stack:** Swift 5 / AppKit / SwiftUI, Ghostty (libghostty via Zig), Bonsplit (split layout), Metal/QuartzCore (rendering), Claude API (summarization), macOS 13+

---

## Task 1: Staged Rebrand — cmux to dmux

Rename user-visible strings, env vars, socket paths, bundle IDs, and CLI names. Keep CMUX_* compatibility aliases so existing shells, wrappers, and state files don't break.

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift:2977-2998` (env vars)
- Modify: `Sources/SocketControlSettings.swift:64,292-297` (socket path, directory name)
- Modify: `Sources/cmuxApp.swift` (app display name)
- Modify: `Sources/AppDelegate.swift` (window title references)
- Modify: `CLI/cmux.swift:9639-9651` (CLI entry point)
- Modify: `cmux.entitlements` (bundle ID)
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj` (product name, bundle ID)
- Modify: `Resources/Info.plist` (display name)

**Step 1: Add DMUX_* env vars alongside CMUX_***

In `Sources/GhosttyTerminalView.swift` around lines 2977-2998, add DMUX_* variables while keeping CMUX_* for compatibility:

```swift
// dmux primary env vars
env["DMUX_SURFACE_ID"] = id.uuidString
env["DMUX_WORKSPACE_ID"] = tabId.uuidString
env["DMUX_PANEL_ID"] = id.uuidString
env["DMUX_TAB_ID"] = tabId.uuidString
env["DMUX_SOCKET_PATH"] = SocketControlSettings.socketPath()

// cmux backward compatibility
env["CMUX_SURFACE_ID"] = id.uuidString
env["CMUX_WORKSPACE_ID"] = tabId.uuidString
env["CMUX_PANEL_ID"] = id.uuidString
env["CMUX_TAB_ID"] = tabId.uuidString
env["CMUX_SOCKET_PATH"] = SocketControlSettings.socketPath()
```

**Step 2: Update socket path defaults**

In `Sources/SocketControlSettings.swift`:
- Line 64: Change `directoryName` from `"cmux"` to `"dmux"`
- Line 296: Change `socketDirectoryName` from `"cmux"` to `"dmux"`
- Line 297: Change `stableSocketFileName` from `"cmux.sock"` to `"dmux.sock"`
- Add a fallback that checks for the legacy `cmux` socket path if the `dmux` path doesn't exist, so existing socket callers still work.

**Step 3: Update bundle ID and product name**

In `GhosttyTabs.xcodeproj/project.pbxproj`:
- Change `com.cmuxterm.app` to `com.dmuxterm.app` (both Debug and Release)
- Change `com.cmuxterm.app.debug` to `com.dmuxterm.app.debug`
- Change product name from `cmux` to `dmux` (user-visible app name)

In `cmux.entitlements`: update bundle ID reference.

**Step 4: Update CLI help text**

In `CLI/cmux.swift` around line 9639, update the CLI tool name and help text references from "cmux" to "dmux". Update env var documentation at line 9631 to mention DMUX_* as primary, CMUX_* as compatibility aliases.

**Step 5: Verify build**

```bash
cd /Users/johnespinosa/Desktop/Projects/dmux
git submodule update --init --recursive
./scripts/setup.sh
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add Sources/GhosttyTerminalView.swift Sources/SocketControlSettings.swift Sources/cmuxApp.swift CLI/cmux.swift cmux.entitlements GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "rebrand: staged rename cmux→dmux with backward-compatible CMUX_* aliases"
```

---

## Task 2: Agent Provider Substrate

Create the shared types and provider protocol that both Claude and Codex providers implement. This is the abstraction layer that makes context transfer agent-agnostic.

**Files:**
- Create: `Sources/DmuxAgentProvider.swift`
- Test: `cmuxTests/DmuxAgentProviderTests.swift`

**Step 1: Write the failing test**

Create `cmuxTests/DmuxAgentProviderTests.swift`:

```swift
import XCTest
@testable import cmux

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
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(error:.*DmuxAgent|FAIL)"
```
Expected: Compilation error — types not defined.

**Step 3: Write the implementation**

Create `Sources/DmuxAgentProvider.swift`:

```swift
import Foundation

// MARK: - Agent Kind

enum AgentKind: String, Codable, Sendable {
    case claude
    case codex
}

// MARK: - Tracked Agent Session

/// Metadata about an agent session running in a dmux pane.
/// Stored on the panel at creation time — not read back from the live PTY.
struct TrackedAgentSession: Sendable {
    let agent: AgentKind
    let sessionId: String
    let cwd: String
    let transcriptPath: String?
    let workspaceId: UUID
    let panelId: UUID
    let pid: Int32
    var updatedAt: Date = Date()
}

// MARK: - Transfer Message

/// A normalized conversation message extracted from any agent's transcript.
struct TransferMessage: Sendable {
    let role: String    // "user" or "assistant"
    let content: String
}

// MARK: - Transfer Payload

/// The final payload to inject into a target pane.
enum TransferPayload: Sendable {
    case verbatim(String)
    case summarized(original: String, summary: String)
    case empty(reason: String)

    var text: String {
        switch self {
        case .verbatim(let t): return t
        case .summarized(_, let s):
            return """
            [Context summary transferred from another dmux pane]

            \(s)

            [End of transferred context]
            """
        case .empty(let reason): return "[\(reason)]"
        }
    }
}

// MARK: - Agent Context Provider Protocol

/// Protocol that agent-specific providers implement.
/// Each provider knows how to discover sessions, read transcripts,
/// and format context for its agent type.
@MainActor
protocol AgentContextProvider {
    /// Which agent this provider handles.
    var agentKind: AgentKind { get }

    /// Discover the active session for a given working directory.
    /// Returns nil if no session is found.
    func discoverSession(cwd: String) -> TrackedAgentSession?

    /// Extract normalized messages from a transcript file.
    func extractMessages(from path: String) -> [TransferMessage]

    /// Resolve the transcript path for a session.
    func resolveTranscriptPath(cwd: String, sessionId: String) -> String?
}

// MARK: - Session Registry

/// Shared registry of tracked agent sessions across all panes.
/// Used by app code and CLI hooks to register/lookup sessions.
@MainActor
final class AgentSessionRegistry: ObservableObject {
    static let shared = AgentSessionRegistry()

    @Published private(set) var sessions: [UUID: TrackedAgentSession] = [:]

    func register(_ session: TrackedAgentSession) {
        sessions[session.panelId] = session
    }

    func unregister(panelId: UUID) {
        sessions.removeValue(forKey: panelId)
    }

    func session(forPanelId panelId: UUID) -> TrackedAgentSession? {
        sessions[panelId]
    }

    func sessionsForWorkspace(_ workspaceId: UUID) -> [TrackedAgentSession] {
        sessions.values.filter { $0.workspaceId == workspaceId }
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```
Expected: All DmuxAgentProviderTests PASS.

**Step 5: Commit**

```bash
git add Sources/DmuxAgentProvider.swift cmuxTests/DmuxAgentProviderTests.swift
git commit -m "feat: add agent provider substrate — AgentKind, TrackedAgentSession, TransferPayload"
```

---

## Task 3: Claude Provider

Implements `AgentContextProvider` for Claude Code. Reads JSONL transcripts from `~/.claude/projects/<encoded-path>/<session-id>.jsonl`.

**Files:**
- Create: `Sources/DmuxClaudeProvider.swift`
- Test: `cmuxTests/DmuxClaudeProviderTests.swift`

**Step 1: Write the failing test**

Create `cmuxTests/DmuxClaudeProviderTests.swift`:

```swift
import XCTest
@testable import cmux

final class DmuxClaudeProviderTests: XCTestCase {

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

    func test_resolveTranscriptPath_encodesPathCorrectly() {
        let provider = ClaudeProvider()
        let path = provider.resolveTranscriptPath(cwd: "/Users/john/project", sessionId: "abc-123")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(path, "\(home)/.claude/projects/-Users-john-project/abc-123.jsonl")
    }

    func test_discoverSession_findsLatestJSONL() throws {
        let provider = ClaudeProvider()
        let tmpDir = NSTemporaryDirectory() + "dmux-test-\(UUID().uuidString)"
        let projectDir = tmpDir + "/.claude/projects/-tmp-testproject"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let older = projectDir + "/old-session.jsonl"
        let newer = projectDir + "/new-session.jsonl"
        try "old".write(toFile: older, atomically: true, encoding: .utf8)
        sleep(1)
        try "new".write(toFile: newer, atomically: true, encoding: .utf8)

        // discoverSession looks in ~/.claude/projects — this test verifies the path encoding
        // For unit testing, we test resolveTranscriptPath and extractMessages separately
        let resolved = provider.resolveTranscriptPath(cwd: "/tmp/testproject", sessionId: "new-session")
        XCTAssertNotNil(resolved)
    }
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(error:.*Claude|FAIL)"
```

**Step 3: Write the implementation**

Create `Sources/DmuxClaudeProvider.swift`:

```swift
import Foundation

/// AgentContextProvider for Claude Code sessions.
/// Reads JSONL transcripts from ~/.claude/projects/<encoded-path>/<session-id>.jsonl
@MainActor
final class ClaudeProvider: AgentContextProvider {

    let agentKind: AgentKind = .claude

    func discoverSession(cwd: String) -> TrackedAgentSession? {
        let projectDir = resolveProjectDir(cwd: cwd)
        guard let sessionId = findLatestSessionId(in: projectDir) else { return nil }
        let transcriptPath = resolveTranscriptPath(cwd: cwd, sessionId: sessionId)

        return TrackedAgentSession(
            agent: .claude,
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptPath,
            workspaceId: UUID(), // caller should set real value
            panelId: UUID(),     // caller should set real value
            pid: 0
        )
    }

    func extractMessages(from path: String) -> [TransferMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8)
        else { return [] }

        return content.split(separator: "\n").compactMap { line -> TransferMessage? in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let message = json["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { return nil }

            let content: String
            if let text = message["content"] as? String {
                content = text
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.compactMap { part -> String? in
                    guard part["type"] as? String == "text" else { return nil }
                    return part["text"] as? String
                }.joined(separator: "\n")
            } else {
                return nil
            }

            guard !content.isEmpty else { return nil }
            return TransferMessage(role: role, content: content)
        }
    }

    func resolveTranscriptPath(cwd: String, sessionId: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encodedPath = cwd.replacingOccurrences(of: "/", with: "-")
        return "\(home)/.claude/projects/\(encodedPath)/\(sessionId).jsonl"
    }

    // MARK: - Private

    private func resolveProjectDir(cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encodedPath = cwd.replacingOccurrences(of: "/", with: "-")
        return "\(home)/.claude/projects/\(encodedPath)"
    }

    private func findLatestSessionId(in projectDir: String) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }

        return contents
            .filter { $0.hasSuffix(".jsonl") && !$0.contains("subagent") }
            .compactMap { filename -> (name: String, date: Date)? in
                let path = (projectDir as NSString).appendingPathComponent(filename)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modDate = attrs[.modificationDate] as? Date
                else { return nil }
                return ((filename as NSString).deletingPathExtension, modDate)
            }
            .sorted { $0.date > $1.date }
            .first?.name
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```

**Step 5: Commit**

```bash
git add Sources/DmuxClaudeProvider.swift cmuxTests/DmuxClaudeProviderTests.swift
git commit -m "feat: add Claude provider — reads JSONL transcripts from ~/.claude/projects/"
```

---

## Task 4: Codex Provider

Implements `AgentContextProvider` for Codex CLI. Reads JSONL transcripts from `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`. Session index at `~/.codex/session_index.jsonl`.

**Files:**
- Create: `Sources/DmuxCodexProvider.swift`
- Test: `cmuxTests/DmuxCodexProviderTests.swift`

**Step 1: Write the failing test**

Create `cmuxTests/DmuxCodexProviderTests.swift`:

```swift
import XCTest
@testable import cmux

final class DmuxCodexProviderTests: XCTestCase {

    func test_extractMessages_parsesCodexFormat() {
        // Codex JSONL uses: session_meta, response_item (role: user/assistant/developer), turn_context, event_msg
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

        // Should skip session_meta, developer role, and event_msg
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].content, "Fix the login bug")
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertTrue(messages[1].content.contains("auth.rb"))
    }

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

    func test_sessionIndexParsing() {
        let indexLine = """
        {"id":"019ceb00-1e0b-7090-b394-f6299ae8b043","thread_name":"Rename cmux branding","updated_at":"2026-03-14T06:19:57Z"}
        """

        let data = indexLine.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["id"] as? String, "019ceb00-1e0b-7090-b394-f6299ae8b043")
        XCTAssertEqual(json["thread_name"] as? String, "Rename cmux branding")
    }
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(error:.*Codex|FAIL)"
```

**Step 3: Write the implementation**

Create `Sources/DmuxCodexProvider.swift`:

```swift
import Foundation

/// AgentContextProvider for Codex CLI sessions.
/// Reads JSONL from ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
/// Session index at ~/.codex/session_index.jsonl
@MainActor
final class CodexProvider: AgentContextProvider {

    let agentKind: AgentKind = .codex

    func discoverSession(cwd: String) -> TrackedAgentSession? {
        // Read session index and find the most recent session for this cwd
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let indexPath = "\(home)/.codex/session_index.jsonl"

        guard let data = FileManager.default.contents(atPath: indexPath),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        // Parse index entries, find latest by updated_at
        let entries: [(id: String, updatedAt: String)] = content.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = json["id"] as? String,
                  let updatedAt = json["updated_at"] as? String
            else { return nil }
            return (id, updatedAt)
        }

        guard let latest = entries.sorted(by: { $0.updatedAt > $1.updatedAt }).first else { return nil }

        // Find the actual session file
        let transcriptPath = findSessionFile(sessionId: latest.id)

        return TrackedAgentSession(
            agent: .codex,
            sessionId: latest.id,
            cwd: cwd,
            transcriptPath: transcriptPath,
            workspaceId: UUID(),
            panelId: UUID(),
            pid: 0
        )
    }

    func extractMessages(from path: String) -> [TransferMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8)
        else { return [] }

        return content.split(separator: "\n").compactMap { line -> TransferMessage? in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String
            else { return nil }

            // Handle turn_context (user messages)
            if type == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let userMessage = payload["user_message"] as? String,
               !userMessage.isEmpty {
                return TransferMessage(role: "user", content: userMessage)
            }

            // Handle response_item (user/assistant messages, skip developer/system)
            guard type == "response_item",
                  let payload = json["payload"] as? [String: Any],
                  let role = payload["role"] as? String,
                  (role == "user" || role == "assistant"),
                  let contentBlocks = payload["content"] as? [[String: Any]]
            else { return nil }

            let texts = contentBlocks.compactMap { block -> String? in
                let blockType = block["type"] as? String ?? ""
                guard blockType == "input_text" || blockType == "output_text" || blockType == "text" else { return nil }
                return block["text"] as? String
            }

            let combined = texts.joined(separator: "\n")
            guard !combined.isEmpty else { return nil }
            return TransferMessage(role: role, content: combined)
        }
    }

    func resolveTranscriptPath(cwd: String, sessionId: String) -> String? {
        findSessionFile(sessionId: sessionId)
    }

    // MARK: - Private

    private func findSessionFile(sessionId: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessionsDir = "\(home)/.codex/sessions"
        let fm = FileManager.default

        // Walk the date-organized directory structure
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return nil }

        for year in years.sorted().reversed() {
            let yearPath = "\(sessionsDir)/\(year)"
            guard let months = try? fm.contentsOfDirectory(atPath: yearPath) else { continue }
            for month in months.sorted().reversed() {
                let monthPath = "\(yearPath)/\(month)"
                guard let days = try? fm.contentsOfDirectory(atPath: monthPath) else { continue }
                for day in days.sorted().reversed() {
                    let dayPath = "\(monthPath)/\(day)"
                    guard let files = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
                    if let match = files.first(where: { $0.contains(sessionId) && $0.hasSuffix(".jsonl") }) {
                        return "\(dayPath)/\(match)"
                    }
                }
            }
        }
        return nil
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```

**Step 5: Commit**

```bash
git add Sources/DmuxCodexProvider.swift cmuxTests/DmuxCodexProviderTests.swift
git commit -m "feat: add Codex provider — reads JSONL from ~/.codex/sessions/"
```

---

## Task 5: Transfer Coordinator

Orchestrates context extraction and delivery. Asks source provider for normalized messages, decides verbatim vs summarized, hands result to target. Uses Anthropic API for summarization when conversations exceed the token threshold.

**Files:**
- Create: `Sources/DmuxTransferCoordinator.swift`
- Test: `cmuxTests/DmuxTransferCoordinatorTests.swift`

**Step 1: Write the failing test**

Create `cmuxTests/DmuxTransferCoordinatorTests.swift`:

```swift
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
    }
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(error:.*Transfer|FAIL)"
```

**Step 3: Write the implementation**

Create `Sources/DmuxTransferCoordinator.swift`:

```swift
import Foundation

/// Orchestrates context transfer between panes.
/// Reads from source provider, decides verbatim vs summarized, delivers to target.
enum DmuxTransferCoordinator {

    static let summarizationModel = "claude-haiku-4-5-20251001"
    static let apiEndpoint = "https://api.anthropic.com/v1/messages"
    static let verbatimTokenThreshold = 2000

    // MARK: - Payload Preparation

    static func preparePayload(messages: [TransferMessage]) async -> TransferPayload {
        guard !messages.isEmpty else {
            return .empty(reason: "No context available from source pane")
        }

        let formatted = formatMessages(messages)
        let tokens = estimateTokenCount(formatted)

        if tokens <= verbatimTokenThreshold {
            return .verbatim("""
            [Context transferred from another dmux pane]

            \(formatted)

            [End of transferred context]
            """)
        }

        // Summarize via Claude API
        do {
            let summary = try await summarize(messages: messages)
            return .summarized(original: formatted, summary: summary)
        } catch {
            // Fallback: truncate to last 10 messages
            let recent = Array(messages.suffix(10))
            let fallback = formatMessages(recent)
            return .verbatim("""
            [Context transferred from another dmux pane (truncated — summarization unavailable: \(error.localizedDescription))]

            \(fallback)

            [End of transferred context]
            """)
        }
    }

    /// Extract context from a tracked session and prepare the transfer payload.
    static func extractAndPrepare(
        session: TrackedAgentSession,
        provider: AgentContextProvider
    ) async -> TransferPayload {
        guard let path = session.transcriptPath else {
            return .empty(reason: "No transcript path for this session")
        }

        let messages = provider.extractMessages(from: path)
        return await preparePayload(messages: messages)
    }

    /// Inject a transfer payload into a terminal pane via PTY text input.
    @MainActor
    static func inject(payload: TransferPayload, into panel: TerminalPanel) {
        let text = payload.text + "\n"
        panel.surface.sendText(text)
    }

    // MARK: - Token Estimation

    static func estimateTokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    // MARK: - Summarization

    static func buildSummarizationRequest(messages: [TransferMessage]) -> [String: Any] {
        let conversationText = formatMessages(messages)

        let prompt = """
        Summarize this coding agent session concisely. Focus on:
        1. What files were discussed or modified
        2. What decisions were made
        3. What work is in progress or incomplete
        4. Key context another agent session would need to continue this work

        Keep the summary under 500 words. Be specific about file names and code changes.

        Session transcript:
        \(conversationText)
        """

        return [
            "model": summarizationModel,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]]
        ]
    }

    private static func summarize(messages: [TransferMessage]) async throws -> String {
        let apiKey = try resolveAPIKey()
        let requestBody = buildSummarizationRequest(messages: messages)

        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw TransferError.apiError(String(data: data, encoding: .utf8) ?? "unknown")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw TransferError.invalidResponse }

        let texts = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        guard !texts.isEmpty else { throw TransferError.noTextContent }
        return texts.joined(separator: "\n")
    }

    private static func resolveAPIKey() throws -> String {
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keyPath = "\(home)/.anthropic/api_key"
        if let fileKey = try? String(contentsOfFile: keyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !fileKey.isEmpty {
            return fileKey
        }
        throw TransferError.noAPIKey
    }

    // MARK: - Helpers

    private static func formatMessages(_ messages: [TransferMessage]) -> String {
        messages.map { "[\($0.role)]: \($0.content)" }.joined(separator: "\n\n")
    }

    enum TransferError: Error, LocalizedError {
        case noAPIKey, invalidResponse, noTextContent, apiError(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No Anthropic API key found. Set ANTHROPIC_API_KEY or create ~/.anthropic/api_key"
            case .invalidResponse: return "Invalid response from Claude API"
            case .noTextContent: return "No text content in API response"
            case .apiError(let msg): return "API error: \(msg)"
            }
        }
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```

**Step 5: Commit**

```bash
git add Sources/DmuxTransferCoordinator.swift cmuxTests/DmuxTransferCoordinatorTests.swift
git commit -m "feat: add transfer coordinator — verbatim/summarized context delivery"
```

---

## Task 6: Directional Split Shortcuts (Keyboard)

Add `Ctrl+Shift+Arrow` shortcuts for splitting in all four directions. Route through AppDelegate's existing `performSplitShortcut` machinery.

**Files:**
- Modify: `Sources/KeyboardShortcutSettings.swift:6-43` (add new actions)
- Modify: `Sources/AppDelegate.swift:8490-8508` (add shortcut routing)

**Step 1: Add actions to KeyboardShortcutSettings**

In `Sources/KeyboardShortcutSettings.swift`, add four new cases to the `Action` enum (around line 35):

```swift
case dmuxSplitLeft
case dmuxSplitRight
case dmuxSplitUp
case dmuxSplitDown
```

Add default shortcuts in the `defaultShortcut` computed property:

```swift
case .dmuxSplitLeft:
    return StoredShortcut(key: .leftArrow, command: false, shift: true, option: false, control: true)
case .dmuxSplitRight:
    return StoredShortcut(key: .rightArrow, command: false, shift: true, option: false, control: true)
case .dmuxSplitUp:
    return StoredShortcut(key: .upArrow, command: false, shift: true, option: false, control: true)
case .dmuxSplitDown:
    return StoredShortcut(key: .downArrow, command: false, shift: true, option: false, control: true)
```

**Step 2: Wire shortcuts in AppDelegate**

In `Sources/AppDelegate.swift`, after the existing split shortcut handling (around line 8508), add:

```swift
if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .dmuxSplitLeft)) {
    dlog("shortcut.action name=dmuxSplitLeft")
    _ = performSplitShortcut(direction: .left)
}
if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .dmuxSplitRight)) {
    dlog("shortcut.action name=dmuxSplitRight")
    _ = performSplitShortcut(direction: .right)
}
if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .dmuxSplitUp)) {
    dlog("shortcut.action name=dmuxSplitUp")
    _ = performSplitShortcut(direction: .up)
}
if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .dmuxSplitDown)) {
    dlog("shortcut.action name=dmuxSplitDown")
    _ = performSplitShortcut(direction: .down)
}
```

`performSplitShortcut(direction:)` at line 9155 already supports all four `SplitDirection` values (left/right/up/down are defined in TabManager.swift:4233-4247), so no changes needed in Workspace or TabManager.

**Step 3: Test**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```

**Step 4: Manual test**

Build, run. Press `Ctrl+Shift+Right` — verify split right. Press `Ctrl+Shift+Down` — verify split down. Verify that `Ctrl+Shift+Left` and `Ctrl+Shift+Up` also work. Verify existing `Cmd+Option+Arrow` focus navigation still works (no regression).

**Step 5: Commit**

```bash
git add Sources/KeyboardShortcutSettings.swift Sources/AppDelegate.swift
git commit -m "feat: add Ctrl+Shift+Arrow directional split shortcuts"
```

---

## Task 7: Workspace-Level Drag Coordinator

The core gesture engine. Lives at the workspace/window level, not per-pane. Tracks drag state, computes intent from distance/target, and coordinates with the animation overlay.

**Files:**
- Create: `Sources/DmuxDragCoordinator.swift`
- Test: `cmuxTests/DmuxDragCoordinatorTests.swift`

**Step 1: Write the failing test**

Create `cmuxTests/DmuxDragCoordinatorTests.swift`:

```swift
import XCTest
@testable import cmux

final class DmuxDragCoordinatorTests: XCTestCase {

    func test_dragIntent_belowThreshold_returnsNone() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()

        coordinator.beginDrag(at: NSPoint(x: 100, y: 100), sourcePanelId: sourceId, sourcePaneBounds: NSRect(x: 0, y: 0, width: 400, height: 400))

        let intent = coordinator.computeIntent(
            currentPoint: NSPoint(x: 110, y: 105),
            targetPanelId: nil
        )

        XCTAssertEqual(intent, .none)
    }

    func test_dragIntent_staysInsidePane_returnsSplit() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()
        let paneBounds = NSRect(x: 0, y: 0, width: 400, height: 400)

        coordinator.beginDrag(at: NSPoint(x: 100, y: 200), sourcePanelId: sourceId, sourcePaneBounds: paneBounds)

        // Drag right but stay inside pane bounds
        let intent = coordinator.computeIntent(
            currentPoint: NSPoint(x: 250, y: 200),
            targetPanelId: nil
        )

        if case .split(let dir) = intent {
            XCTAssertTrue(dir == .right)
        } else {
            XCTFail("Expected split intent, got \(intent)")
        }
    }

    func test_dragIntent_crossesIntoPaneB_returnsMerge() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()
        let targetId = UUID()
        let paneBounds = NSRect(x: 0, y: 0, width: 400, height: 400)

        coordinator.beginDrag(at: NSPoint(x: 200, y: 200), sourcePanelId: sourceId, sourcePaneBounds: paneBounds)

        // Drag past pane boundary into another pane
        let intent = coordinator.computeIntent(
            currentPoint: NSPoint(x: 500, y: 200),
            targetPanelId: targetId
        )

        if case .merge(let id) = intent {
            XCTAssertEqual(id, targetId)
        } else {
            XCTFail("Expected merge intent, got \(intent)")
        }
    }

    func test_dragIntent_crossesIntoEmptySpace_returnsFork() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()
        let paneBounds = NSRect(x: 0, y: 0, width: 400, height: 400)

        coordinator.beginDrag(at: NSPoint(x: 200, y: 200), sourcePanelId: sourceId, sourcePaneBounds: paneBounds)

        // Drag past pane boundary with no target
        let intent = coordinator.computeIntent(
            currentPoint: NSPoint(x: 500, y: 200),
            targetPanelId: nil
        )

        if case .fork(let dir) = intent {
            XCTAssertTrue(dir == .right)
        } else {
            XCTFail("Expected fork intent, got \(intent)")
        }
    }

    func test_splitDirection_vertical() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()
        let paneBounds = NSRect(x: 0, y: 0, width: 400, height: 400)

        coordinator.beginDrag(at: NSPoint(x: 200, y: 100), sourcePanelId: sourceId, sourcePaneBounds: paneBounds)

        // Drag down (stays in pane)
        let intent = coordinator.computeIntent(
            currentPoint: NSPoint(x: 200, y: 250),
            targetPanelId: nil
        )

        if case .split(let dir) = intent {
            XCTAssertTrue(dir == .down)
        } else {
            XCTFail("Expected vertical split, got \(intent)")
        }
    }
}
```

**Step 2: Run test to verify it fails**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(error:.*DragCoordinator|FAIL)"
```

**Step 3: Write the implementation**

Create `Sources/DmuxDragCoordinator.swift`:

```swift
import AppKit

/// Workspace-level drag gesture coordinator.
/// Determines intent from drag distance and target:
/// - Stays inside source pane → split (direction from drag vector)
/// - Crosses into another pane → merge
/// - Crosses into empty space → fork
@MainActor
final class DmuxDragCoordinator: ObservableObject {

    enum DragIntent: Equatable {
        case none
        case split(SplitDirection)
        case merge(targetPanelId: UUID)
        case fork(SplitDirection)
    }

    /// The modifier keys that activate dmux drag mode.
    static let activationModifiers: NSEvent.ModifierFlags = [.control, .shift]

    @Published private(set) var currentIntent: DragIntent = .none
    @Published private(set) var isDragging: Bool = false
    @Published private(set) var dragProgress: CGFloat = 0 // 0→1 for animation

    private(set) var sourcePanelId: UUID?
    private var dragStartPoint: NSPoint = .zero
    private var sourcePaneBounds: NSRect = .zero
    private let minDragThreshold: CGFloat = 30.0

    static func isActivated(event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(activationModifiers)
    }

    func beginDrag(at point: NSPoint, sourcePanelId: UUID, sourcePaneBounds: NSRect) {
        self.isDragging = true
        self.dragStartPoint = point
        self.sourcePanelId = sourcePanelId
        self.sourcePaneBounds = sourcePaneBounds
        self.currentIntent = .none
        self.dragProgress = 0
    }

    func computeIntent(currentPoint: NSPoint, targetPanelId: UUID?) -> DragIntent {
        guard isDragging, let sourceId = sourcePanelId else { return .none }

        let dx = currentPoint.x - dragStartPoint.x
        let dy = currentPoint.y - dragStartPoint.y
        let distance = max(abs(dx), abs(dy))

        guard distance >= minDragThreshold else {
            currentIntent = .none
            dragProgress = 0
            return .none
        }

        // Primary drag direction
        let direction: SplitDirection
        if abs(dx) > abs(dy) {
            direction = dx > 0 ? .right : .left
        } else {
            // macOS y-axis: up = positive
            direction = dy > 0 ? .up : .down
        }

        // Is the current point still inside the source pane bounds?
        let insideSource = sourcePaneBounds.contains(currentPoint)

        let intent: DragIntent
        if insideSource {
            // Drag stays inside pane → split
            let maxDrag = direction.isHorizontal ? sourcePaneBounds.width : sourcePaneBounds.height
            dragProgress = min(1.0, distance / (maxDrag * 0.5))
            intent = .split(direction)
        } else if let targetId = targetPanelId, targetId != sourceId {
            // Crossed into another pane → merge
            dragProgress = min(1.0, distance / 200.0)
            intent = .merge(targetPanelId: targetId)
        } else {
            // Crossed pane boundary into empty space → fork
            let maxDrag = direction.isHorizontal ? sourcePaneBounds.width : sourcePaneBounds.height
            dragProgress = min(1.0, distance / maxDrag)
            intent = .fork(direction)
        }

        currentIntent = intent
        return intent
    }

    func endDrag() -> (sourcePanelId: UUID?, intent: DragIntent) {
        let result = (sourcePanelId, currentIntent)
        isDragging = false
        sourcePanelId = nil
        currentIntent = .none
        dragProgress = 0
        return result
    }

    func cancelDrag() {
        isDragging = false
        sourcePanelId = nil
        currentIntent = .none
        dragProgress = 0
    }
}
```

**Step 4: Run tests**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```

**Step 5: Commit**

```bash
git add Sources/DmuxDragCoordinator.swift cmuxTests/DmuxDragCoordinatorTests.swift
git commit -m "feat: add workspace-level drag coordinator with distance-based intent detection"
```

---

## Task 8: Wire Drag Events to Coordinator

Connect mouse events from the terminal view to the workspace-level drag coordinator. GhosttyNSView detects drag start; the workspace overlay handles target detection, highlighting, and animation state.

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift:5376-5410` (mouseDown intercept)
- Modify: `Sources/ContentView.swift:503-563` (forwarding adds target detection)
- Modify: `Sources/Workspace.swift` (add drag coordinator property, merge/fork execution)
- Modify: `Sources/WorkspaceContentView.swift` (drag overlay)

**Step 1: Add drag coordinator to Workspace**

In `Sources/Workspace.swift`, add the coordinator as a property:

```swift
let dmuxDragCoordinator = DmuxDragCoordinator()
```

**Step 2: Intercept modifier+drag in GhosttyNSView**

In `Sources/GhosttyTerminalView.swift`, modify `mouseDown(with:)` around line 5376. Before passing the event to Ghostty, check for activation modifiers:

```swift
override func mouseDown(with event: NSEvent) {
    if DmuxDragCoordinator.isActivated(event: event) {
        // Notify workspace-level coordinator via delegate/notification
        // Pass: event location in window coordinates, this surface's panel ID, this pane's bounds
        NotificationCenter.default.post(
            name: .dmuxDragStarted,
            object: nil,
            userInfo: [
                "point": event.locationInWindow,
                "panelId": surface?.id.uuidString ?? "",
                "event": event
            ]
        )
        return // Don't pass to Ghostty terminal
    }
    // ... existing mouseDown logic
}
```

Similarly modify `mouseDragged(with:)` and `mouseUp(with:)` to forward events when a dmux drag is active.

Add notification name extension:

```swift
extension Notification.Name {
    static let dmuxDragStarted = Notification.Name("dmuxDragStarted")
    static let dmuxDragMoved = Notification.Name("dmuxDragMoved")
    static let dmuxDragEnded = Notification.Name("dmuxDragEnded")
}
```

**Step 3: Add drag overlay to WorkspaceContentView**

In `Sources/WorkspaceContentView.swift`, add a `ZStack` overlay that observes the drag coordinator's state and renders:
- Split preview line (when intent = split)
- Merge target highlight (when intent = merge)
- Fork direction indicator (when intent = fork)
- The animated pane shrink/card for merge
- The animated split growth for split/fork

The overlay reads from `workspace.dmuxDragCoordinator.currentIntent` and `workspace.dmuxDragCoordinator.dragProgress` to drive animations.

**Step 4: Add hit-test helper for target pane detection**

In `Sources/ContentView.swift`, add a method that the drag coordinator can call to determine which panel (if any) is under a given point:

```swift
func panelId(at windowPoint: NSPoint) -> UUID? {
    // Use the workspace's bonsplitController to find which pane contains the point
    // Then lookup the active panel in that pane
    guard let workspace = activeWorkspace else { return nil }
    // Convert window point to pane container coordinates
    // Use bonsplitController.pane(at:) or similar hit-test
    return nil // implementation depends on Bonsplit API
}
```

**Step 5: Wire merge/fork execution in Workspace**

In `Sources/Workspace.swift`, add methods that execute after drag release:

```swift
/// Execute a merge: extract context from source, inject into target, close source.
func executeMerge(sourcePanelId: UUID, targetPanelId: UUID) async {
    guard let sourcePanel = panels[sourcePanelId] as? TerminalPanel,
          let targetPanel = panels[targetPanelId] as? TerminalPanel
    else { return }

    // Look up tracked session
    let session = AgentSessionRegistry.shared.session(forPanelId: sourcePanelId)
    let provider: AgentContextProvider = (session?.agent == .codex) ? CodexProvider() : ClaudeProvider()

    let payload: TransferPayload
    if let session = session {
        payload = await DmuxTransferCoordinator.extractAndPrepare(session: session, provider: provider)
    } else {
        // No tracked session — try discovery from cwd
        let cwd = sourcePanel.directory
        if let discovered = provider.discoverSession(cwd: cwd) {
            payload = await DmuxTransferCoordinator.extractAndPrepare(session: discovered, provider: provider)
        } else {
            payload = .empty(reason: "No agent session found in source pane")
        }
    }

    // Inject into target
    DmuxTransferCoordinator.inject(payload: payload, into: targetPanel)

    // Close source only after successful injection
    _ = closePanel(sourcePanelId)
}

/// Execute a fork: create new split, extract context from source, inject into new pane.
func executeFork(sourcePanelId: UUID, direction: SplitDirection) async {
    guard let sourcePanel = panels[sourcePanelId] as? TerminalPanel else { return }

    // Create the split
    guard let newPanel = newTerminalSplit(
        from: sourcePanelId,
        orientation: direction.orientation,
        insertFirst: direction.insertFirst
    ) else { return }

    // Extract context
    let session = AgentSessionRegistry.shared.session(forPanelId: sourcePanelId)
    let provider: AgentContextProvider = (session?.agent == .codex) ? CodexProvider() : ClaudeProvider()

    let payload: TransferPayload
    if let session = session {
        payload = await DmuxTransferCoordinator.extractAndPrepare(session: session, provider: provider)
    } else {
        let cwd = sourcePanel.directory
        if let discovered = provider.discoverSession(cwd: cwd) {
            payload = await DmuxTransferCoordinator.extractAndPrepare(session: discovered, provider: provider)
        } else {
            payload = .empty(reason: "No agent session found in source pane")
        }
    }

    // Wait for shell startup, then inject
    try? await Task.sleep(nanoseconds: 500_000_000)
    DmuxTransferCoordinator.inject(payload: payload, into: newPanel)
}
```

**Step 6: Commit**

```bash
git add Sources/GhosttyTerminalView.swift Sources/ContentView.swift Sources/Workspace.swift Sources/WorkspaceContentView.swift
git commit -m "feat: wire drag events from terminal view to workspace-level coordinator"
```

---

## Task 9: Drag Animations

Render the live animations during drag — pane shrinking, split preview lines, merge target highlight, context card. All driven by `DmuxDragCoordinator.dragProgress` and `currentIntent`. Animation state is separate from close/inject operations so failure paths cancel safely.

**Files:**
- Create: `Sources/DmuxDragOverlayView.swift`
- Modify: `Sources/WorkspaceContentView.swift` (add overlay)

**Step 1: Create the drag overlay view**

Create `Sources/DmuxDragOverlayView.swift`:

```swift
import SwiftUI

/// Overlay view that renders drag animation state.
/// Driven entirely by DmuxDragCoordinator's published properties.
/// Renders above all panes but below the cursor.
struct DmuxDragOverlayView: View {
    @ObservedObject var coordinator: DmuxDragCoordinator
    let paneFrames: [UUID: CGRect] // panel ID → frame in workspace coordinates

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if coordinator.isDragging {
                    switch coordinator.currentIntent {
                    case .split(let direction):
                        splitPreview(direction: direction, progress: coordinator.dragProgress, in: geo)

                    case .merge(let targetId):
                        mergeHighlight(targetId: targetId, progress: coordinator.dragProgress)

                    case .fork(let direction):
                        forkPreview(direction: direction, progress: coordinator.dragProgress, in: geo)

                    case .none:
                        EmptyView()
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: coordinator.currentIntent)
    }

    // MARK: - Split Preview

    @ViewBuilder
    private func splitPreview(direction: SplitDirection, progress: CGFloat, in geo: GeometryProxy) -> some View {
        if let sourceId = coordinator.sourcePanelId,
           let frame = paneFrames[sourceId] {
            // Glowing split line at the drag position
            if direction.isHorizontal {
                Rectangle()
                    .fill(Color(hex: "818cf8"))
                    .frame(width: 2)
                    .frame(height: frame.height * min(1, progress + 0.3))
                    .position(x: frame.midX + (direction == .right ? frame.width * 0.5 * progress : -frame.width * 0.5 * progress),
                              y: frame.midY)
                    .shadow(color: Color(hex: "818cf8").opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            } else {
                Rectangle()
                    .fill(Color(hex: "c084fc"))
                    .frame(height: 2)
                    .frame(width: frame.width * min(1, progress + 0.3))
                    .position(x: frame.midX,
                              y: frame.midY + (direction == .down ? frame.height * 0.5 * progress : -frame.height * 0.5 * progress))
                    .shadow(color: Color(hex: "c084fc").opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            }
        }
    }

    // MARK: - Merge Highlight

    @ViewBuilder
    private func mergeHighlight(targetId: UUID, progress: CGFloat) -> some View {
        if let frame = paneFrames[targetId] {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange, lineWidth: 3)
                .shadow(color: Color.orange.opacity(0.4), radius: 20)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .opacity(Double(min(1, progress * 1.5)))
        }
    }

    // MARK: - Fork Preview

    @ViewBuilder
    private func forkPreview(direction: SplitDirection, progress: CGFloat, in geo: GeometryProxy) -> some View {
        if let sourceId = coordinator.sourcePanelId,
           let frame = paneFrames[sourceId] {
            // Similar to split but with green accent
            let color = Color(hex: "10b981")
            if direction.isHorizontal {
                Rectangle()
                    .fill(color)
                    .frame(width: 2)
                    .frame(height: frame.height)
                    .position(x: direction == .right ? frame.maxX : frame.minX,
                              y: frame.midY)
                    .shadow(color: color.opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            } else {
                Rectangle()
                    .fill(color)
                    .frame(height: 2)
                    .frame(width: frame.width)
                    .position(x: frame.midX,
                              y: direction == .down ? frame.maxY : frame.minY)
                    .shadow(color: color.opacity(0.5), radius: 12)
                    .opacity(Double(min(1, progress * 2)))
            }
        }
    }
}

// MARK: - Color Helper

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }
}
```

**Step 2: Add overlay to WorkspaceContentView**

In `Sources/WorkspaceContentView.swift`, add the overlay at the top of the workspace view hierarchy:

```swift
.overlay(
    DmuxDragOverlayView(
        coordinator: workspace.dmuxDragCoordinator,
        paneFrames: computePaneFrames()
    )
)
```

The `computePaneFrames()` method should query the workspace's bonsplit controller to get the current frame for each pane and map them to panel IDs.

**Step 3: Manual test**

Build, run. Hold Ctrl+Shift, drag right inside a pane — see the glowing purple split preview line. Drag past the pane boundary into another pane — see the orange merge highlight. Drag into empty space — see the green fork indicator. Release to execute.

**Step 4: Commit**

```bash
git add Sources/DmuxDragOverlayView.swift Sources/WorkspaceContentView.swift
git commit -m "feat: add live drag animation overlay — split/merge/fork visual feedback"
```

---

## Task 10: Context Card Animation

The context card that emerges from the source pane during merge drags. Pane progressively shrinks into the card which follows the cursor. Separate from the overlay — this is a positioned element that moves with the drag.

**Files:**
- Create: `Sources/DmuxContextCardView.swift`
- Modify: `Sources/DmuxDragOverlayView.swift` (integrate card)

**Step 1: Create the context card view**

Create `Sources/DmuxContextCardView.swift`:

```swift
import SwiftUI

/// Floating context card that appears during merge/fork drags.
/// Shows a preview of the context being transferred.
struct DmuxContextCardView: View {
    let contextPreview: String
    let transferType: TransferType
    let progress: CGFloat
    let position: CGPoint

    enum TransferType {
        case merge
        case fork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                Text(transferType == .merge ? "Context Transfer" : "Fork Context")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(accentColor)

            Text(contextPreview)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(3)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: accentColor.opacity(0.3), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.4), lineWidth: 1)
        )
        .frame(width: 200)
        .scaleEffect(0.5 + progress * 0.5)
        .opacity(Double(min(1, progress * 2)))
        .position(position)
    }

    private var accentColor: Color {
        transferType == .merge ? .orange : Color(hex: "10b981")
    }
}
```

**Step 2: Integrate into DmuxDragOverlayView**

Add the context card to the merge and fork branches of the overlay view. The card's position tracks the cursor location, which the drag coordinator provides.

**Step 3: Commit**

```bash
git add Sources/DmuxContextCardView.swift Sources/DmuxDragOverlayView.swift
git commit -m "feat: add floating context card that follows cursor during merge/fork drags"
```

---

## Task 11: Integration Tests and Edge Cases

End-to-end testing and edge case handling.

**Files:**
- Create: `cmuxTests/DmuxIntegrationTests.swift`
- Modify: `Sources/Workspace.swift` (edge case guards)

**Step 1: Write integration tests**

Create `cmuxTests/DmuxIntegrationTests.swift`:

```swift
import XCTest
@testable import cmux

final class DmuxIntegrationTests: XCTestCase {

    func test_claudeProvider_fullFlow() async {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"List models"},"sessionId":"t-123"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found User, Post in app/models/"}]},"sessionId":"t-123"}
        """

        let provider = ClaudeProvider()
        let tmpFile = NSTemporaryDirectory() + "test-flow-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)
        let payload = await DmuxTransferCoordinator.preparePayload(messages: messages)

        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("List models"))
            XCTAssertTrue(text.contains("User, Post"))
        } else {
            XCTFail("Expected verbatim for short conversation")
        }
    }

    func test_codexProvider_fullFlow() async {
        let jsonl = """
        {"timestamp":"2026-03-11T19:00:00Z","type":"session_meta","payload":{"id":"019cde3f","cwd":"/tmp"}}
        {"timestamp":"2026-03-11T19:00:01Z","type":"turn_context","payload":{"user_message":"Fix the bug"}}
        {"timestamp":"2026-03-11T19:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed in auth.rb"}]}}
        """

        let provider = CodexProvider()
        let tmpFile = NSTemporaryDirectory() + "test-codex-flow-\(UUID().uuidString).jsonl"
        try! jsonl.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let messages = provider.extractMessages(from: tmpFile)
        let payload = await DmuxTransferCoordinator.preparePayload(messages: messages)

        if case .verbatim(let text) = payload {
            XCTAssertTrue(text.contains("Fix the bug"))
            XCTAssertTrue(text.contains("auth.rb"))
        } else {
            XCTFail("Expected verbatim")
        }
    }

    func test_dragCoordinator_intentTransitions() {
        let coordinator = DmuxDragCoordinator()
        let sourceId = UUID()
        let targetId = UUID()
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 400)

        coordinator.beginDrag(at: NSPoint(x: 200, y: 200), sourcePanelId: sourceId, sourcePaneBounds: bounds)

        // Start: below threshold
        var intent = coordinator.computeIntent(currentPoint: NSPoint(x: 210, y: 200), targetPanelId: nil)
        XCTAssertEqual(intent, .none)

        // Move more: split
        intent = coordinator.computeIntent(currentPoint: NSPoint(x: 300, y: 200), targetPanelId: nil)
        if case .split = intent { } else { XCTFail("Expected split") }

        // Cross into target: merge
        intent = coordinator.computeIntent(currentPoint: NSPoint(x: 500, y: 200), targetPanelId: targetId)
        if case .merge = intent { } else { XCTFail("Expected merge") }

        // Cross into empty: fork
        intent = coordinator.computeIntent(currentPoint: NSPoint(x: 500, y: 200), targetPanelId: nil)
        if case .fork = intent { } else { XCTFail("Expected fork") }
    }
}
```

**Step 2: Add edge case guards**

In `Sources/Workspace.swift`, add guards to `executeMerge` and `executeFork`:
- Source is BrowserPanel (not terminal) → no-op, log warning
- Target is BrowserPanel → no-op
- Source == target → no-op
- Source pane already closed → no-op
- Transfer payload is `.empty` → still close source for merge (user intended to merge)

**Step 3: Run all tests**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit test 2>&1 | grep -E "(Test Suite|PASS|FAIL)"
```

**Step 4: Full manual test**

1. Build and run dmux
2. `Ctrl+Shift+Right` — verify horizontal split
3. `Ctrl+Shift+Down` — verify vertical split
4. Start `claude` in Pane A, have a conversation
5. `Ctrl+Shift` + drag right inside Pane A — see split preview
6. `Ctrl+Shift` + drag from Pane A into Pane B — see merge animation, context injected
7. `Ctrl+Shift` + drag from pane into empty space — see fork, new pane with context
8. Verify Pane A closes after merge, stays after fork

**Step 5: Commit**

```bash
git add cmuxTests/DmuxIntegrationTests.swift Sources/Workspace.swift
git commit -m "feat: integration tests and edge case handling for merge/fork/split"
```

---

## Dependency Graph

```
Task 1 (Rebrand) ─── unblocks everything

Task 2 (Agent Substrate)  ─── independent after Task 1
Task 3 (Claude Provider)  ─── depends on Task 2
Task 4 (Codex Provider)   ─── depends on Task 2
Task 5 (Transfer Coord)   ─── depends on Tasks 2, 3, 4

Task 6 (Keyboard Splits)  ─── independent after Task 1
Task 7 (Drag Coordinator) ─── independent after Task 1

Task 8 (Wire Drag Events) ─── depends on Tasks 5, 7
Task 9 (Drag Animations)  ─── depends on Task 7
Task 10 (Context Card)    ─── depends on Task 9

Task 11 (Integration)     ─── depends on everything
```

**Parallelizable groups after Task 1:**
- Group A: Tasks 2 → 3+4 (parallel) → 5
- Group B: Tasks 6, 7 (parallel)
- Group C: Tasks 8, 9 → 10 (after Groups A and B complete)
- Task 11 runs last

**Verification gate:** Run `git submodule update --init --recursive` and `./scripts/setup.sh` before any build. The repo cannot resolve local package dependencies while `vendor/bonsplit` is missing.
