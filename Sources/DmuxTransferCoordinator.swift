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

        do {
            let summary = try await summarize(messages: messages)
            return .summarized(original: formatted, summary: summary)
        } catch {
            let recent = Array(messages.suffix(10))
            let fallback = formatMessages(recent)
            return .verbatim("""
            [Context transferred from another dmux pane (truncated — summarization unavailable: \(error.localizedDescription))]

            \(fallback)

            [End of transferred context]
            """)
        }
    }

    static func extractAndPrepare(
        session: TrackedAgentSession,
        provider: AgentContextProvider
    ) async -> TransferPayload {
        guard let path = session.transcriptPath else {
            return .empty(reason: "No transcript path for this session")
        }
        let messages = await provider.extractMessages(from: path)
        return await preparePayload(messages: messages)
    }

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
