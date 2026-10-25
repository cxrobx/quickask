import Foundation

@MainActor
func verifyChatRecovery(check: (Bool, String) -> Void) throws {
    struct Export: Encodable {
        struct Session: Encodable {
            let id: UUID
            let customTitle: String?
            let messages: [ChatMessage]
            let draft: String
        }
        var format = ChatRecovery.formatIdentifier
        var activeSessionID: UUID
        var sessions: [Session]
    }
    let first = UUID(), active = UUID()
    let question = ChatMessage(role: "user", text: "Latest question 🌍")
    let partial = ChatMessage(role: "assistant", text: "An interrupted answer", provider: .claude, complete: false)
    var export = Export(activeSessionID: active, sessions: [
        .init(id: first, customTitle: "Earlier tab", messages: [.init(role: "user", text: "First question")], draft: "Earlier draft"),
        .init(id: active, customTitle: nil, messages: [question, partial, .init(role: "assistant", text: "", complete: false)], draft: "Unsent draft")
    ])
    let data = try JSONEncoder().encode(export)
    let recovery = try ChatRecovery.decode(data)
    let suite = "QuickAsk-recovery-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences)
    try model.restoreChats(recovery)
    check(model.messages.map(\.id) == [question.id, partial.id], "Recovery retains real messages and removes an empty interrupted reply")
    check(model.messages.last?.complete == false && model.messages.last?.text == partial.text, "Recovery keeps partial text marked incomplete")
    check(model.draft == "Unsent draft" && model.showsTabs, "Recovery restores the selected tab and its draft")
    check(!model.busy && model.canSwitchChats && !model.controlEnabled && model.targetApp == nil, "Recovery does not resume inference or desktop control")
    let restoredID = model.activeSessionID
    model.selectSession(model.sessions[0].id)
    check(model.title(of: model.sessions[0]) == "Earlier tab" && model.draft == "Earlier draft", "Recovery preserves other tabs and custom titles")
    model.selectSession(restoredID)
    check(model.messages.first?.text == question.text, "Recovered tabs can be switched normally")
    func rejected(_ action: () throws -> Void) -> Bool {
        do { try action(); return false } catch { return true }
    }
    check(rejected { try model.restoreChats(recovery) } && model.messages.first?.id == question.id, "Recovery cannot overwrite an existing conversation")
    export.format = "unsupported"
    check(rejected { _ = try ChatRecovery.decode(JSONEncoder().encode(export)) }, "Recovery rejects unsupported formats")
    export.format = ChatRecovery.formatIdentifier
    export.activeSessionID = UUID()
    check(rejected { _ = try ChatRecovery.decode(JSONEncoder().encode(export)) }, "Recovery rejects a missing selected tab")
    export.activeSessionID = active
    export.sessions.append(export.sessions[0])
    check(rejected { _ = try ChatRecovery.decode(JSONEncoder().encode(export)) }, "Recovery rejects duplicate session IDs")
    check(rejected { _ = try ChatRecovery.decode(Data(repeating: 0, count: ChatRecovery.maxBytes + 1)) }, "Recovery bounds the size of imported data")
    check(rejected { _ = try ChatRecovery.decode(Data("{invalid".utf8)) }, "Recovery rejects malformed JSON without exposing its contents")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-recovery-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("chat.json")
    try data.write(to: file)
    check(try ChatRecovery.load(from: file).sessions.count == 2, "Recovery can read a local export")
    check(rejected { _ = try ChatRecovery.load(from: folder.appendingPathComponent("missing")) }, "Missing recovery files fail safely")
}
