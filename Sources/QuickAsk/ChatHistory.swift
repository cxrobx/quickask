import Foundation

/// The last few chats, kept on disk so one can be reopened in a tab and continued.
/// Each chat is one owner-only JSON file in an owner-only folder, holding everything
/// it showed: text, images and cards. Drafts, desktop targets and pending reviews
/// are never written.
struct ChatHistory {
    static let limit = 30

    struct Entry: Codable {
        let id: UUID
        var title: String
        var customTitle: String?
        var forkedFrom: UUID?
        var updated: Date
        var messages: [ChatMessage]
    }

    /// What the history list shows; read without keeping a chat's images in memory.
    struct Summary: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        var updated: Date
    }

    /// What a row in the history list shows beside the title.
    enum Mark: Equatable {
        case working, needsYou, unread, stillOnMe

        var label: String {
            switch self {
            case .working: "working"
            case .needsYou: "needs you"
            case .unread: "unread"
            case .stillOnMe: "still on me"
            }
        }
    }

    /// Chats answered while you weren't looking, and ones you've marked as still yours to act
    /// on. A small file beside the chats, so marking one never rewrites its messages and images.
    struct Marks: Codable, Equatable {
        var unread: Set<UUID> = []
        var stillOnMe: Set<UUID> = []
    }

    let directory: URL

    static var standard: ChatHistory? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { ChatHistory(directory: $0.appendingPathComponent("QuickAsk/History", isDirectory: true)) }
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    func save(_ entry: Entry) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = file(entry.id)
        try encoder.encode(entry).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune()
    }

    func marks() -> Marks {
        (try? Data(contentsOf: marksFile)).flatMap { try? JSONDecoder().decode(Marks.self, from: $0) } ?? Marks()
    }

    func saveMarks(_ marks: Marks) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(marks).write(to: marksFile, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marksFile.path)
    }

    /// Not `.json`, so it is never listed or pruned as a chat.
    private var marksFile: URL { directory.appendingPathComponent("marks.state") }

    func load(_ id: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? Self.decoder.decode(Entry.self, from: data)
    }

    /// Newest first, at most `limit`.
    func summaries() -> [Summary] {
        files().compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(Summary.self, from: $0) }
        }.sorted { $0.updated > $1.updated }.prefix(Self.limit).map { $0 }
    }

    /// Keeps the `limit` most recently written chats and deletes the rest.
    private func prune() {
        let dated = files().map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(Self.limit) { try? FileManager.default.removeItem(at: url) }
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
