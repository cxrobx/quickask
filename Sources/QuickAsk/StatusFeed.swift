import Combine
import Foundation

/// What each open chat is doing, for tools outside QuickAsk (the Stream Deck plugin in
/// ~/Projects/cxdeck). Read-only to them; `quickask://chat/<id>` opens one.
enum ChatState: String, Codable {
    /// A request is in flight.
    case working
    /// QuickAsk is waiting on you: a task or Herdr review, or a context choice.
    case needsYou = "needs-you"
    /// The answer finished while that tab wasn't in front of you, and you haven't opened it since.
    case answered
    /// You've read it, but the chat still has the "still on me" ring: FollowUpCheck
    /// or your own right-click says you owe a next step. Open tab or not.
    case stillOnYou = "still-on-you"
}

struct ChatStatus: Codable, Equatable {
    let id: UUID
    let title: String
    let state: ChatState
    /// When the chat entered this state.
    let since: Date
}

extension AppModel {
    /// Every open tab that is doing something or waiting; idle, seen chats are left out.
    func chatStates() -> [(id: UUID, title: String, state: ChatState)] {
        let running = runningSessionIDs
        let pendingReview = delegation != nil || herdrProposal != nil || needsContextChoice
        return sessions.compactMap { session in
            let state: ChatState
            if session.id == activeSessionID && pendingReview { state = .needsYou }
            else if running.contains(session.id) { state = .working }
            else if unseenSessionIDs.contains(session.id) { state = .answered }
            else { return nil }
            return (session.id, title(of: session), state)
        }
    }

    /// What the feed publishes: `chatStates()` plus every chat with the "still on me" ring,
    /// open or only in Recent chats. Kept apart from `chatStates()`, which `historyMark`
    /// reads, so the two never call each other.
    func feedStates() -> [(id: UUID, title: String, state: ChatState)] {
        let open = chatStates()
        let listed = Set(open.map(\.id))
        let ringed = marks.stillOnMe.subtracting(listed).subtracting(marks.unread).compactMap { id -> (id: UUID, title: String, state: ChatState)? in
            let name = sessions.first { $0.id == id }.map { self.title(of: $0) } ?? historySummaries.first { $0.id == id }?.title
            return name.map { (id, $0, .stillOnYou) }
        }
        return open + ringed.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// Writes ~/Library/Application Support/QuickAsk/status.json whenever a chat's state
/// changes. The file is replaced atomically and carries QuickAsk's pid, so a reader can
/// tell a file left behind by a quit app from a live one.
@MainActor
final class StatusFeed {
    struct Payload: Codable, Equatable {
        var version = 1
        let pid: Int32
        let chats: [ChatStatus]
    }

    static var standardURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QuickAsk/status.json")
    }

    private let model: AppModel
    private let url: URL
    private var since: [UUID: (ChatState, Date)] = [:]
    private var written: [ChatStatus]?
    private var subscription: AnyCancellable?

    init(model: AppModel, url: URL) {
        self.model = model
        self.url = url
        // objectWillChange fires before the change lands; reading on the next turn sees it.
        subscription = model.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
        publish()
    }

    /// The statuses as they stand, each stamped with when it entered its state.
    func current(now: Date = Date()) -> [ChatStatus] {
        let states = model.feedStates()
        var next: [UUID: (ChatState, Date)] = [:]
        let chats = states.map { chat -> ChatStatus in
            let started = since[chat.id].flatMap { $0.0 == chat.state ? $0.1 : nil } ?? now
            next[chat.id] = (chat.state, started)
            return ChatStatus(id: chat.id, title: chat.title, state: chat.state, since: started)
        }
        since = next
        return chats
    }

    func publish() {
        let chats = current()
        guard chats != written else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(pid: ProcessInfo.processInfo.processIdentifier, chats: chats)) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            written = chats
        } catch {
            // Best effort: the feed is advisory and never blocks a chat.
        }
    }
}
