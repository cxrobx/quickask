import Foundation

/// Explicit, local recovery of text exported from a stopped request. Importing a
/// chat never restores a request, desktop lease, app target, or pending action.
struct ChatRecovery: Decodable {
    struct Session: Decodable {
        let id: UUID
        let customTitle: String?
        let messages: [ChatMessage]
        let draft: String
    }

    static let formatIdentifier = "QuickAsk emergency text recovery v1"
    static let maxBytes = 5_000_000
    let activeSessionID: UUID
    let sessions: [Session]
    private let format: String

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes,
              let recovery = try? JSONDecoder().decode(Self.self, from: data),
              recovery.format == Self.formatIdentifier,
              (1...100).contains(recovery.sessions.count),
              Set(recovery.sessions.map(\.id)).count == recovery.sessions.count,
              recovery.sessions.contains(where: { $0.id == recovery.activeSessionID }),
              recovery.sessions.allSatisfy({ session in
                  session.messages.count <= 5_000 && session.draft.utf8.count <= 200_000
                      && Set(session.messages.map(\.id)).count == session.messages.count
                      && session.messages.allSatisfy {
                          ["user", "assistant"].contains($0.role) && $0.images.isEmpty && $0.cards.isEmpty
                      }
              }) else { throw RecoveryError.invalidFile }
        return recovery
    }

    static func load(from url: URL) throws -> Self {
        // Bound the read itself, including when a file grows after it is opened.
        guard let file = try? FileHandle(forReadingFrom: url) else { throw RecoveryError.unreadableFile }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maxBytes + 1) else { throw RecoveryError.unreadableFile }
        return try decode(data)
    }

    enum RecoveryError: LocalizedError {
        case invalidFile, unreadableFile, chatInUse
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "This isn't a supported QuickAsk text recovery file."
            case .unreadableFile: return "QuickAsk couldn't read the chat recovery file."
            case .chatInUse: return "Restore a chat in a fresh QuickAsk session."
            }
        }
    }
}
