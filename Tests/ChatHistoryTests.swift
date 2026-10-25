import Foundation

@MainActor
func verifyChatHistory(check: (Bool, String) -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-history-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = ChatHistory(directory: directory)
    let image = ImageAttachment(id: UUID(), data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), mediaType: "image/png", pixelWidth: 3, pixelHeight: 1)

    // The store: everything round-trips, files are owner-only, and only the newest 10 stay.
    let first = ChatHistory.Entry(id: UUID(), title: "With a picture", customTitle: nil, forkedFrom: nil, updated: Date(),
                                  messages: [ChatMessage(role: "user", text: "What is this?", images: [image]),
                                             ChatMessage(role: "assistant", text: "A tiny PNG.", provider: .claude)])
    try history.save(first)
    let loaded = history.load(first.id)
    check(loaded?.messages == first.messages && loaded?.messages.first?.images.first?.data == image.data,
          "History keeps a chat's text and images")
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(first.id.uuidString).json").path)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    check((attributes[.posixPermissions] as? Int) == 0o600 && (folder[.posixPermissions] as? Int) == 0o700,
          "History files and their folder are owner-only")
    for number in 1...ChatHistory.limit {
        try await Task.sleep(nanoseconds: 10_000_000) // distinct modification dates for pruning
        try history.save(.init(id: UUID(), title: "Chat \(number)", customTitle: nil, forkedFrom: nil,
                               updated: Date().addingTimeInterval(Double(number)), messages: [ChatMessage(role: "user", text: "Q\(number)")]))
    }
    let summaries = history.summaries()
    check(summaries.count == ChatHistory.limit && history.load(first.id) == nil, "History keeps only the newest \(ChatHistory.limit) chats")
    check(summaries.first?.title == "Chat \(ChatHistory.limit)", "History lists the newest chat first")
    try history.saveMarks(.init(unread: [summaries[0].id], stillOnMe: [summaries[1].id]))
    check(history.marks() == .init(unread: [summaries[0].id], stillOnMe: [summaries[1].id]) && history.summaries().count == ChatHistory.limit,
          "Marks round-trip beside the chats and are never listed as one")

    // The model: a finished request writes the chat, and reopening it carries on with everything it had.
    let modelDirectory = directory.appendingPathComponent("model")
    let suite = "QuickAsk-history-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences, history: ChatHistory(directory: modelDirectory))
    let question = ChatMessage(role: "user", text: "Describe the screenshot", images: [image])
    let answer = ChatMessage(role: "assistant", text: "It shows a chart.", provider: .codex)
    model.busy = true
    model.messages = [question, answer]
    model.busy = false
    let chatID = model.activeSessionID
    check(model.historySummaries.first?.id == chatID && model.historySummaries.first?.title == "Describe the screenshot",
          "A finished request lists the chat in history")
    model.busy = true; model.busy = false
    check(model.historySummaries.count == 1, "A request that changed nothing doesn't add a second entry")
    var waited = 0
    while ChatHistory(directory: modelDirectory).load(chatID) == nil && waited < 200 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
    check(ChatHistory(directory: modelDirectory).load(chatID)?.messages == [question, answer], "History is written off the main thread")

    model.newChat()
    check(model.messages.isEmpty && model.activeSessionID != chatID, "A new chat starts empty")
    model.reopenChat(chatID)
    check(model.activeSessionID == chatID && model.messages == [question, answer] && model.sessions.count == 1,
          "Reopening fills the blank tab with the saved chat, images included")
    let prompt = try PromptBuilder.make(messages: model.messages + [ChatMessage(role: "user", text: "And the axis labels?")])
    check(prompt.contains("It shows a chart.") && prompt.contains("And the axis labels?"),
          "A follow-up in a reopened chat sends the earlier conversation")
    model.newTab()
    model.reopenChat(chatID)
    check(model.activeSessionID == chatID && model.sessions.filter { $0.id == chatID }.count == 1,
          "Reopening a chat that's already open brings its tab forward")
    // Marks: an answer you didn't see stays unread across a relaunch until you open the chat.
    model.popupVisible = false
    model.messages.append(ChatMessage(role: "user", text: "One more?"))
    model.busy = true; model.busy = false
    check(model.historyMark(of: chatID) == .unread, "Marks: an answer that finished unseen is unread")
    model.newChat(); model.closeSession(chatID)
    var relaunched = AppModel(preferences: preferences, history: ChatHistory(directory: modelDirectory))
    waited = 0
    while relaunched.historyMark(of: chatID) != .unread && waited < 200 {
        try await Task.sleep(nanoseconds: 10_000_000); waited += 1
        relaunched = AppModel(preferences: preferences, history: ChatHistory(directory: modelDirectory))
    }
    check(relaunched.historyMark(of: chatID) == .unread, "Marks: unread outlasts closing the tab and relaunching")
    relaunched.popupVisible = true
    relaunched.reopenChat(chatID)
    check(relaunched.historyMark(of: chatID) == nil, "Marks: opening the chat clears unread")
    relaunched.toggleStillOnMe(chatID)
    check(relaunched.historyMark(of: chatID) == .stillOnMe, "Marks: Still on Me sets a ring on a read chat")
    relaunched.toggleStillOnMe(chatID)
    check(relaunched.historyMark(of: chatID) == nil, "Marks: Still on Me toggles off")
    relaunched.needsContextChoice = true
    check(relaunched.historyMark(of: chatID) == .needsYou, "Marks: a pending choice in the open chat needs you")
    relaunched.needsContextChoice = false

    // Follow-up check: what is sent, how answers are read, and what the verdict does.
    let long = FollowUpCheck.body(question: "Q", answer: String(repeating: "a", count: 3000) + String(repeating: "b", count: 3000))
    let sent = (long["state"] as? [String: Any])?["assistant_answer"] as? String ?? ""
    check(sent.hasPrefix("aaa") && sent.hasSuffix("bbb") && sent.count < 4100 && (long["questions"] as? [String: Any])?[FollowUpCheck.questionName] != nil,
          "Follow-up: a long answer sends its start and its end, where a closing question sits")
    let name = FollowUpCheck.questionName
    check(FollowUpCheck.parse(["answers": [name: ["type": "noul", "noul": 0.9]]]) == 0.9, "Follow-up: Jev's noul is read")
    check(FollowUpCheck.parse(["answers": [name: ["type": "refusal"]]]) == nil && FollowUpCheck.parse(["answers": [name: ["noul": true]]]) == nil
          && FollowUpCheck.parse(["answers": [name: ["noul": 1.5]]]) == nil && FollowUpCheck.parse([:]) == nil,
          "Follow-up: a refusal or malformed answer is no judgment")

    final class Judge { var verdict: Bool? = true; var asked: [String] = [] }
    let judge = Judge()
    let judged = AppModel(preferences: preferences, history: ChatHistory(directory: directory.appendingPathComponent("judged")),
                          followUpJudge: { question, _ in judge.asked.append(question); return judge.verdict })
    judged.popupVisible = true
    func exchange(_ question: String, _ reply: ChatMessage) async throws {
        judged.busy = true
        judged.messages += [ChatMessage(role: "user", text: question), reply]
        judged.busy = false
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let judgedID = judged.activeSessionID
    try await exchange("Should we do this?", ChatMessage(role: "assistant", text: "I can do #1 now. Want me to?", provider: .claude))
    check(judge.asked == ["Should we do this?"] && judged.historyMark(of: judgedID) == .stillOnMe, "Follow-up: an answer that leaves you a step rings the chat")
    judge.verdict = false
    try await exchange("Go ahead", ChatMessage(role: "assistant", text: "Done.", provider: .claude))
    check(judged.historyMark(of: judgedID) == nil, "Follow-up: a finished answer clears the ring")
    judged.toggleStillOnMe(judgedID)
    try await exchange("Do it in Herdr", ChatMessage(role: "assistant", text: "Opened a fresh Claude tab in Herdr."))
    check(judge.asked.count == 2 && judged.historyMark(of: judgedID) == nil, "Follow-up: a handoff is never asked about and clears the ring")
    judged.followUpCheck = false
    try await exchange("One more", ChatMessage(role: "assistant", text: "Want more?", provider: .claude))
    check(judge.asked.count == 2, "Follow-up: off in Settings, nothing is sent")
    judged.followUpCheck = true
    judge.verdict = true
    judged.busy = true
    judged.messages += [ChatMessage(role: "user", text: "Q"), ChatMessage(role: "assistant", text: "Want me to?", provider: .claude)]
    judged.busy = false
    judged.messages.append(ChatMessage(role: "user", text: "Actually, never mind"))
    try await Task.sleep(nanoseconds: 50_000_000)
    check(judged.historyMark(of: judgedID) == nil, "Follow-up: a verdict that lands after you've written again is dropped")
    judged.followUpCheck = true

    let order = model.sessions.map(\.id)
    if order.count > 1 {
        let start = model.activeSessionID, at = order.firstIndex(of: start)!
        model.cycleTab(by: 1)
        check(model.activeSessionID == order[(at + 1) % order.count], "⌘⌥→ brings the next tab forward")
        model.cycleTab(by: -1)
        check(model.activeSessionID == start, "⌘⌥← goes back to the tab before")
        model.selectSession(order[0]); model.cycleTab(by: -1)
        check(model.activeSessionID == order.last, "⌘⌥← from the first tab wraps to the last")
    } else { check(false, "Expected several tabs open to test cycling") }
}
