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
    var agentKind: AgentKind { get }
    func discoverSession(cwd: String) -> TrackedAgentSession?
    func extractMessages(from path: String) -> [TransferMessage]
    func resolveTranscriptPath(cwd: String, sessionId: String) -> String?
}

// MARK: - Session Registry

/// Shared registry of tracked agent sessions across all panes.
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
