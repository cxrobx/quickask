import Foundation

/// The reply half of the harness eval. Every HarnessEval case that lands on a route without hands is answered
/// for real: that route's prompt and CLI flags, the app's Claude model, once with the old prompt (explain how
/// to ask) and once with Escalation's (pass it to My setup). A request that needs hands should pass on; one
/// that doesn't should be answered. Uses the Claude CLI's own login; sends nothing else anywhere.
/// REPLY_EVAL_MODEL / REPLY_EVAL_EFFORT override the app's settings.
@main struct ReplyEval {
    enum Verdict: String { case passedOn = "passed on", refused, answered, failed }

    static func main() async {
        guard let executable = ExecutableFinder.find(.claude, customPath: "") else { print("Claude Code wasn't found."); exit(2) }
        let settings = UserDefaults(suiteName: "local.quickask.desktop")
        let environment = ProcessInfo.processInfo.environment
        let model = environment["REPLY_EVAL_MODEL"] ?? settings?.string(forKey: "claudeModel") ?? ""
        let effort = environment["REPLY_EVAL_EFFORT"] ?? settings?.string(forKey: "claudeEffort") ?? ""
        let results = await HarnessEval.run().filter { [.general, .screen].contains($0.outcome) }
        print("Reply eval: \(results.count) cases on a route without hands · model \(model.isEmpty ? "default" : model) \(effort)")
        var table: [(HarnessEval.Result, Verdict, Verdict)] = []
        for result in results {
            async let old = answer(result, escalate: false, executable: executable, model: model, effort: effort)
            async let new = answer(result, escalate: true, executable: executable, model: model, effort: effort)
            let row = (result, await old, await new)
            table.append(row)
            print("  \(result.item.hands ? "hands" : "none ") old \(row.1.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) new \(row.2.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(result.item.id)")
        }
        let hands = table.filter { $0.0.item.hands }, none = table.filter { !$0.0.item.hands }
        func count(_ rows: [(HarnessEval.Result, Verdict, Verdict)], _ old: Bool, _ verdict: Verdict) -> Int { rows.filter { (old ? $0.1 : $0.2) == verdict }.count }
        print("""
        Needs hands (\(hands.count)): old prompt refused \(count(hands, true, .refused)), answered anyway \(count(hands, true, .answered)); \
        new prompt passed on \(count(hands, false, .passedOn)), refused \(count(hands, false, .refused)), answered \(count(hands, false, .answered))
        Needs none (\(none.count)): new prompt passed on \(count(none, false, .passedOn)) (over-escalation), old prompt refused \(count(none, true, .refused))
        Failed runs: \(table.filter { $0.1 == .failed || $0.2 == .failed }.count)
        """)
    }

    static func answer(_ result: HarnessEval.Result, escalate: Bool, executable: String, model: String, effort: String) async -> Verdict {
        let item = result.item
        let messages = item.history + [ChatMessage(role: "user", text: item.text)]
        let screen = result.outcome == .screen ? HarnessEval.window(item.front).map { window in
            ScreenPayload(snapshot: ContextSnapshot(displayID: 1, windowID: window.id, pid: window.pid, bundleID: window.bundleID, appName: window.appName,
                                                    windowTitle: window.title, capturedAt: 0, launchTime: 0, selection: nil, text: visibleText(item.front), document: ""),
                          plan: .general(""), windows: [], screenshotAttached: false)
        } : nil
        guard let prompt = try? PromptBuilder.make(messages: messages, screen: screen, web: true, escalate: escalate) else { return .failed }
        let text: String? = await withCheckedContinuation { continuation in
            var handle: RequestHandle?
            handle = CLIRunner.start(provider: .claude, executable: executable, model: model, effort: effort, prompt: prompt, web: true,
                                     onEvent: { _ in }, onComplete: { outcome in
                _ = handle
                if case .success(let value) = outcome { continuation.resume(returning: value) } else { continuation.resume(returning: nil) }
            })
        }
        guard let text else { return .failed }
        if Escalation.requested(text) { return .passedOn }
        return Escalation.disowns(text) ? .refused : .answered
    }

    static func visibleText(_ front: HarnessEval.Front) -> String {
        switch front {
        case .terminal: return "$ docker compose up -d\nError response from daemon: driver failed programming external connectivity: port 8080 already allocated"
        case .browser: return "Example — a page. Welcome. Sign in to continue. Products, Pricing, Docs."
        default: return ""
        }
    }
}
