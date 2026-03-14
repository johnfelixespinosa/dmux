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
