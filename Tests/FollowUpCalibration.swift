import Foundation

/// Scores the last answer of every saved chat with each follow-up judge, so a bar can be set
/// from real chats. Sends each answer's text to the judges named in FOLLOW_UP_JUDGES
/// (default "claude,codex"); Jev is asked only when it's named there. Prints scores and the
/// answer's last line, for labelling by hand. FOLLOW_UP_ALL=1 scores every exchange, not only
/// each chat's last.
@main struct FollowUpCalibration {
    static func main() async {
        guard let history = ChatHistory.standard else { print("No chat history."); exit(2) }
        let names = (ProcessInfo.processInfo.environment["FOLLOW_UP_JUDGES"] ?? "claude,codex").split(separator: ",")
        let judges = names.compactMap { FollowUpCheck.Judge(rawValue: String($0)) }
        print(["chat"] + judges.map(\.rawValue) + ["answer ends"] as [String])
        for summary in history.summaries() {
            guard let messages = history.load(summary.id)?.messages else { continue }
            let all = ProcessInfo.processInfo.environment["FOLLOW_UP_ALL"] == "1"
            for (index, answer) in messages.enumerated() where all ? index > 0 : index == messages.count - 1 {
            guard answer.role == "assistant", answer.complete, answer.provider != nil, !answer.text.isEmpty,
                  let question = messages[..<index].last(where: { $0.role == "user" })?.text, !question.isEmpty else { continue }
            var scores: [String] = []
            for judge in judges {
                let start = Date()
                let score = await FollowUpCheck.score(judge, question: question, answer: answer.text)
                scores.append(score.map { String(format: "%.2f (%.1fs)", $0, Date().timeIntervalSince(start)) } ?? "none")
            }
            let ending = answer.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            print(summary.id.uuidString.prefix(8), index, scores.joined(separator: "  "), "|", String(ending.suffix(140)))
            }
        }
    }
}
