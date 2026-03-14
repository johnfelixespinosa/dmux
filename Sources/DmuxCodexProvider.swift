import Foundation

/// AgentContextProvider for Codex CLI sessions.
/// Reads JSONL from ~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl
/// Session index at ~/.codex/session_index.jsonl
@MainActor
final class CodexProvider: AgentContextProvider {

    let agentKind: AgentKind = .codex

    func discoverSession(cwd: String) -> TrackedAgentSession? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let indexPath = "\(home)/.codex/session_index.jsonl"

        guard let data = FileManager.default.contents(atPath: indexPath),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        let entries: [(id: String, updatedAt: String)] = content.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = json["id"] as? String,
                  let updatedAt = json["updated_at"] as? String
            else { return nil }
            return (id, updatedAt)
        }

        guard let latest = entries.sorted(by: { $0.updatedAt > $1.updatedAt }).first else { return nil }

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

            // Handle response_item (user/assistant, skip developer/system)
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

    private func findSessionFile(sessionId: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessionsDir = "\(home)/.codex/sessions"
        let fm = FileManager.default

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
