import Foundation

@MainActor
func verifyStatusFeed(check: (Bool, String) -> Void) throws {
    let suite = "QuickAsk-status-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences)
    func state(_ id: UUID) -> ChatState? { model.chatStates().first { $0.id == id }?.state }
    let first = model.activeSessionID

    check(model.chatStates().isEmpty, "Status: an idle, seen chat isn't listed")
    model.busy = true
    check(state(first) == .working, "Status: a request in flight is working")
    model.busy = false
    check(state(first) == .answered, "Status: an answer that finished with the popup hidden is answered")
    model.popupVisible = true
    check(state(first) == nil, "Status: showing the popup marks the tab in front seen")
    model.busy = true; model.busy = false
    check(state(first) == nil, "Status: an answer you watched finish is never answered")

    // A chat answered while another tab is in front stays answered until that tab is opened.
    model.popupVisible = false
    model.messages = [ChatMessage(role: "user", text: "Q")]
    model.busy = true; model.busy = false
    model.newTab()
    let second = model.activeSessionID
    model.popupVisible = true
    check(second != first && state(first) == .answered, "Status: a chat behind another tab stays answered")
    model.selectSession(first)
    check(state(first) == nil, "Status: opening the answered tab clears it")

    // The "still on me" ring: published for a read chat, never over a live state.
    func fed(_ id: UUID) -> ChatState? { model.feedStates().first { $0.id == id }?.state }
    model.toggleStillOnMe(first)
    check(fed(first) == .stillOnYou && state(first) == nil, "Status: a ringed chat is still on you, outside chatStates")
    model.busy = true
    check(fed(first) == .working, "Status: a running chat shows working, not its ring")
    model.busy = false
    model.selectSession(first)
    model.toggleStillOnMe(first)
    check(fed(first) == nil, "Status: clearing the ring drops the chat")

    model.needsContextChoice = true
    check(state(first) == .needsYou, "Status: a pending context choice needs you")
    model.needsContextChoice = false

    // The file: QuickAsk's pid, ISO dates, and a since that holds while the state does.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-status-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("status.json")
    let feed = StatusFeed(model: model, url: url)
    model.popupVisible = false
    model.busy = true
    feed.publish()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let written = try decoder.decode(StatusFeed.Payload.self, from: Data(contentsOf: url))
    check(written.pid == ProcessInfo.processInfo.processIdentifier && written.chats.map(\.state) == [.working],
          "Status file carries the pid and the working chat")
    let entered = feed.current().first?.since ?? .distantPast
    check(abs((written.chats.first?.since ?? .distantPast).timeIntervalSince(entered)) < 1, "Status file stamps when the chat entered its state")
    check(feed.current(now: Date().addingTimeInterval(60)).first?.since == entered, "Status keeps when a chat entered its state")
    model.busy = false
    let answered = feed.current(now: Date().addingTimeInterval(120)).first
    check(answered?.state == .answered && answered?.since != entered, "Status restamps since when the state changes")
}
