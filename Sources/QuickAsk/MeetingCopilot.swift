import Foundation

/// Meeting Copilot's live meeting. Its tools attach while a meeting is live, whether or not its
/// panel is on screen; a check-in asked in so many words goes straight to the copilot, no model in
/// front, so the answer comes from the copilot's warm session as fast as its own button.
enum MeetingCopilot {
    static var port: Int { Int(ProcessInfo.processInfo.environment["COPILOT_PORT"] ?? "") ?? 17890 }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.4; config.timeoutIntervalForResource = 0.4
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The live session's id, from the copilot server's `/health`. Nil when it is down or idle.
    static func liveSession() async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64_000,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return liveSession(health: value)
    }

    static func liveSession(health: [String: Any]) -> String? {
        guard let session = health["session"] as? String, !session.isEmpty else { return nil }
        return session
    }

    /// "How am I doing?", "did I miss anything", "wrap up": the copilot's three check-ins, asked
    /// on their own. Anything longer is a question for the routed answer, which has the same tools.
    nonisolated static func pulseKind(_ text: String) -> String? {
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
        let phrase = words.joined(separator: " ")
        guard !words.isEmpty, words.count <= 8 else { return nil }
        let kinds: [(String, [String])] = [
            ("checkin", ["how am i doing", "how am i doing so far", "how's it going", "how is it going", "how's the meeting going",
                         "how is the meeting going", "how am i doing in this meeting", "how am i doing on this call", "check in", "checkin"]),
            ("missed", ["did i miss anything", "what did i miss", "missed anything", "anything i missed", "did i miss something",
                        "what have i missed", "have i missed anything"]),
            ("wrapup", ["wrap up", "wrapup", "wrap up check", "wrap-up check", "wrap it up", "are we ready to wrap up", "can we wrap up"])
        ]
        let trimmed = phrase.hasPrefix("copilot ") ? String(phrase.dropFirst(8)) : phrase
        return kinds.first { $0.1.contains(trimmed) }?.0
    }

    /// Names the copilot or the meeting itself, so its tools attach even without the router.
    nonisolated static func mentioned(_ text: String) -> Bool {
        text.range(of: "(?i)\\b(?:meeting\\s+)?co-?pilot\\b", options: .regularExpression) != nil
            || text.range(of: "(?i)\\b(?:this|the|my|our|current)\\s+(?:meeting|call)\\b", options: .regularExpression) != nil
    }

    static let pulseTitles = ["checkin": "How am I doing?", "missed": "Missed anything?", "wrapup": "Wrap-up check"]

    /// One check-in, called straight on the copilot's MCP. Returns its answer text.
    static func pulse(_ kind: String, launch: MCPLaunch, cancelled: @escaping () -> Bool = { false }) throws -> String {
        let client = try AppMCPClient(launch: launch, toolDeadline: AppConnector.meetingcopilot.toolDeadline, valid: { !cancelled() })
        defer { client.close() }
        let result = try client.rpc("tools/call", ["name": "pulse", "arguments": ["kind": kind]])
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        if result["isError"] as? Bool == true { throw ProviderRunError(message: text.isEmpty ? "Meeting Copilot couldn't answer." : text) }
        return text.isEmpty ? "Meeting Copilot returned no answer." : text
    }
}
