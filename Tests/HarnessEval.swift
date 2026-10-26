import Foundation

/// The harness eval: real Quick Ask failures, paraphrased with no personal data, run through the whole
/// route decision (RouteDecision, then RoutePlan.make) the way AppModel.send runs it.
///
/// Where the decision falls to the router, the router is assumed wrong for that case: a request that needs
/// hands gets a router saying it is about the screen and not the user's work (needs_screen 0.94 on "look at
/// my local version", follow_up 0.56 on an obvious follow-up: both happened), and a request that doesn't
/// gets an honest one. So a passing case lands right whatever the router says about it.
///
/// `gap` marks a known miss, with why. A gap case that passes is reported so its `gap` can go; any other
/// failing case fails the suite. That makes the corpus a ratchet: fixes raise it, nothing lowers it.
enum HarnessEval {
    enum Front { case none, terminal, browser, preview, tasks }
    /// What the route can do. `appWrite`: a window's app with its write tools.
    enum Outcome: String { case herdr, task, personal, control, appWrite = "app-write", general, screen, meeting, noWindow = "no-window" }

    struct Case {
        let id: String
        let text: String
        var history: [ChatMessage] = []
        var previous: RouteScope? = nil
        var front: Front = .terminal
        var control = false
        var images = 0
        /// The request needs a route that can act: run something, read the user's own things, drive an app.
        let hands: Bool
        let want: Set<Outcome>
        var gap: String? = nil
    }

    static let repos = ["quickask", "telly", "artisttracker", "cxtasks"]
    static let workspaces = repos.map { ProjectWorkspace(project: $0, path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/\($0)").path) }

    static func window(_ front: Front) -> ContextWindow? {
        switch front {
        case .none: return nil
        case .terminal: return .init(id: 1, pid: 101, bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "~/Projects/notes — zsh", bounds: .zero)
        case .browser: return .init(id: 2, pid: 102, bundleID: "app.zen-browser.zen", appName: "Zen", title: "Example — a page", bounds: .zero)
        case .preview: return .init(id: 3, pid: 103, bundleID: "com.apple.Preview", appName: "Preview", title: "photo.jpg", bounds: .zero)
        case .tasks: return .init(id: 4, pid: 104, bundleID: "com.cxtasks.app", appName: "CXTasks", title: "Today", bounds: .zero)
        }
    }

    /// A My setup exchange: the reply ran tools, so the chat's last route was My setup.
    static func mySetup(_ question: String, _ answer: String, tools: [String] = ["Bash"]) -> [ChatMessage] {
        var reply = ChatMessage(role: "assistant", text: answer, provider: .claude)
        reply.tools = tools
        return [.init(role: "user", text: question), reply]
    }
    static func plain(_ question: String, _ answer: String) -> [ChatMessage] {
        [.init(role: "user", text: question), .init(role: "assistant", text: answer, provider: .claude)]
    }

    static let cases: [Case] = [
        // Herdr requests (handoff-miss, 2026-10-15 to 10-26).
        .init(id: "10-26 misspelled spawn", text: "can you spwn a herdr session to handle this", hands: true, want: [.herdr]),
        .init(id: "10-26 retry after a refusal", text: "try again to spawn it",
              history: plain("can you spwn a herdr session to handle this", "I can't spawn a Herdr session from here."), hands: true, want: [.herdr]),
        .init(id: "10-25 spawn to handle these", text: "can u spawn a herdr session to handle as many of these as possible?", hands: true, want: [.herdr]),
        .init(id: "10-21 do that in herdr", text: "yes lets do that in  a herdr session",
              history: plain("compare the two local models", "Should I pull the smaller one and test both?"), hands: true, want: [.herdr]),
        .init(id: "10-21 spin up and fix", text: "spin up a herdr session and figure out what happened here with quickask then fix it", hands: true, want: [.herdr]),
        .init(id: "10-15 start one addressed at", text: "text won't select across lines in quickask - can you start a herdr session addressed at fixing this", images: 1, hands: true, want: [.herdr]),
        .init(id: "10-24 spawn that creates", text: "spawn a herdr session that creates a stream deck plugin showing which agent session needs me", hands: true, want: [.herdr]),
        .init(id: "paraphrase: get another one", text: "could you get another herdr session on this", hands: true, want: [.herdr]),
        .init(id: "paraphrase: hand it to herdr", text: "hand this off to herdr", hands: true, want: [.herdr]),
        .init(id: "paraphrase: what's broken, then spawn", text: "what's broken here? spawn a herdr session to fix it", hands: true, want: [.herdr]),
        .init(id: "paraphrase: spawn one to explain", text: "can you spawn a herdr session to explain the codebase to a new hire", hands: true, want: [.herdr]),
        .init(id: "paraphrase: retry with go ahead", text: "go ahead",
              history: plain("please open a herdr session for the migration", "I can't open Herdr sessions."), hands: true, want: [.herdr]),
        .init(id: "paraphrase: have herdr do it", text: "have herdr do the cleanup", hands: true, want: [.herdr]),

        // Follow-ups in a My setup thread (wrong-route, 10-25: still open after the 10-22 fix).
        .init(id: "10-25 confirm it still works", text: "Just to confirm both services still work, right?",
              history: mySetup("tighten docker access for the two containers", "Done: the socket mount is gone from both."), previous: .personal,
              hands: true, want: [.personal]),
        .init(id: "10-25 confirm, nothing on screen", text: "Just to confirm both services still work, right?",
              history: mySetup("tighten docker access for the two containers", "Done: the socket mount is gone from both."), previous: .personal, front: .none,
              hands: true, want: [.personal]),
        .init(id: "10-25 cont after an empty reply", text: "cont",
              history: mySetup("add cmd z to the composer", ""), previous: .personal,
              hands: true, want: [.personal]),
        .init(id: "10-25 I dont get this", text: "I dont get this: how do those two containers have so much access?",
              history: mySetup("check my nas security sessions", "Two containers can drive Docker itself."), previous: .personal,
              hands: true, want: [.personal]),
        .init(id: "10-22 review after a browser turn", text: "review the dock and ensure we didn't miss anything",
              history: mySetup("fill the form in my browser", "Filled every field.", tools: ["zen-ext · fill"]), previous: .personal, front: .browser,
              hands: true, want: [.personal]),
        .init(id: "10-21 did you open them", text: "did you actually open those listings?",
              history: mySetup("open the three listings", "Opened all three.", tools: ["zen-ext · open_url"]), previous: .personal, front: .browser,
              hands: true, want: [.personal]),

        // The user's own things (wrong-route).
        .init(id: "10-21 drive my browser", text: "just control my browser and search", front: .browser, hands: true, want: [.personal]),
        .init(id: "10-21 worth it with my setup", text: "is this worth it for me with my setup?", hands: true, want: [.personal]),
        .init(id: "10-21 why can't you trigger my setup", text: "why cant u trigger my setup and look?", hands: true, want: [.personal]),
        .init(id: "10-18 my local version", text: "no - look at my local version (i called it telly)", front: .browser, hands: true, want: [.personal]),
        .init(id: "10-26 what we have saved", text: "how does the upgrade program compare to what we have saved on the phone buying decision?", front: .browser,
              hands: true, want: [.personal], gap: "\"what we have saved\" isn't one of the own-thing phrases; the router sent it to web search"),
        .init(id: "10-14 ready for the client call", text: "are we all ready for the acme call on friday?",
              hands: true, want: [.personal], gap: "only the router's about_my_work can see a client call; nothing guards it"),
        .init(id: "paraphrase: restart on my nas", text: "restart the media bot container on my nas", hands: true, want: [.personal]),
        .init(id: "paraphrase: restart on the nas", text: "restart the media bot container on the nas", hands: true, want: [.personal],
              gap: "\"on the nas\" misses the own-thing phrase, which needs \"my\""),
        .init(id: "paraphrase: upgrade a tool I run", text: "upgrade cloudflared everywhere I run it", hands: true, want: [.personal, .herdr],
              gap: "an action on the user's machines with no phrase the gates know"),
        .init(id: "paraphrase: my downloads", text: "what's in my downloads folder?", hands: true, want: [.personal],
              gap: "\"my downloads folder\" isn't one of the own-thing phrases"),
        .init(id: "10-25 did it go okay for this user", text: "did everything go okay for this user?", front: .browser, images: 1,
              hands: true, want: [.personal], gap: "only the router's about_my_work can tell a signup alert is the user's own product"),

        // Changes to the user's repos, links, pages.
        .init(id: "10-23 change a repo, mid-chat", text: "for quickask can we style the prev sessions drop down like the example?",
              history: plain("what's a good dropdown pattern?", "A popover with soft rows."), images: 1, hands: true, want: [.personal]),
        .init(id: "10-23 change a repo, new chat", text: "for quickask can we style the prev sessions drop down like the example?", images: 1, hands: true, want: [.personal]),
        .init(id: "paraphrase: run a repo's tests, new chat", text: "run the tests in quickask", hands: true, want: [.personal, .herdr]),
        .init(id: "paraphrase: run a repo's tests, mid-chat", text: "run the tests in quickask",
              history: plain("what does a flaky test look like?", "One that passes and fails on the same code."), hands: true, want: [.personal, .herdr],
              gap: "\"run\" isn't a change verb, so naming the repo mid-chat doesn't route it"),
        .init(id: "10-15 bare link", text: "https://example.com/some/post", hands: true, want: [.personal]),
        .init(id: "paraphrase: make a chart", text: "make me a chart of the spending by month", hands: true, want: [.personal]),

        // Control and tasks.
        .init(id: "10-24 control and select", text: "Control my computer and select it.", front: .preview, control: true, hands: true, want: [.control]),
        .init(id: "10-24 you can control my screen", text: "You can control my screen.", front: .preview, control: true, hands: true, want: [.control]),
        .init(id: "10-24 research with control on", text: "I took over from here, but can you investigate how to speed this up? feel free to do web research",
              front: .preview, control: true, hands: true, want: [.personal, .general],
              gap: "Control on catches every message, a research request included; its route has no web"),
        .init(id: "10-16 close a task", text: "help me understand t187, can we close it?", front: .tasks, hands: true, want: [.personal, .appWrite],
              gap: "\"can we close it\" needs the router's wants_app_action; read-only otherwise"),
        .init(id: "paraphrase: file a task", text: "file this as a task", hands: true, want: [.task]),

        // Requests that need no hands: the gates must leave them alone.
        .init(id: "neg: what is herdr", text: "What is a herdr session?", hands: false, want: [.general, .screen]),
        .init(id: "neg: explain herdr", text: "Explain how to start a herdr session", hands: false, want: [.general, .screen]),
        .init(id: "neg: herdr is great", text: "Herdr sessions are great", hands: false, want: [.general, .screen]),
        .init(id: "neg: don't spawn", text: "Don't spawn a herdr session, just answer here", hands: false, want: [.general, .screen, .personal]),
        .init(id: "neg: a session crashed", text: "I had a herdr session crash yesterday, what usually causes that?", hands: false, want: [.general, .screen, .personal]),
        .init(id: "neg: can you explain", text: "can you explain a herdr session?", hands: false, want: [.general, .screen]),
        .init(id: "neg: start by explaining", text: "start by explaining what a tab is in herdr", hands: false, want: [.general, .screen]),
        .init(id: "neg: let me know", text: "let me know if herdr supports split panes", hands: false, want: [.general, .screen]),
        .init(id: "neg: should I move", text: "Should I move to herdr from tmux?", hands: false, want: [.general, .screen]),
        .init(id: "neg: try again after chat", text: "try again", history: plain("write a haiku about rain", "Rain on tin roofs..."), hands: false, want: [.general, .screen]),
        .init(id: "neg: lasagna", text: "How do I cook lasagna?", hands: false, want: [.general]),
        .init(id: "neg: oauth, no window", text: "What is OAuth?", front: .none, hands: false, want: [.general]),
        .init(id: "neg: devtools", text: "how do I open devtools in chrome", front: .browser, hands: false, want: [.general, .screen]),
        .init(id: "neg: called it a day", text: "I called it a day after the second season, is it worth finishing?", hands: false, want: [.general, .screen]),
        .init(id: "neg: make this chart bigger", text: "make this chart bigger", front: .browser, hands: false, want: [.screen, .general]),
        .init(id: "neg: task in another app", text: "How do I create a task in Linear?", hands: false, want: [.general, .screen]),
        .init(id: "neg: summarize this page", text: "Summarize this page", front: .browser, hands: false, want: [.screen]),
        // Over-escalation probes: about machines and commands, but answered from knowledge or as code to run yourself.
        .init(id: "neg: write a script", text: "write a bash script that renames every .jpeg in a folder to .jpg", hands: false, want: [.general, .screen]),
        .init(id: "neg: backup advice", text: "what's a good backup strategy for a home NAS?", hands: false, want: [.general, .screen]),
        .init(id: "neg: explain this error", text: "what does this error mean?", hands: false, want: [.screen, .general]),
        .init(id: "neg: docker health how-to", text: "how do I check if a docker container is healthy?", hands: false, want: [.general, .screen]),
        .init(id: "neg: topic switch in a My setup chat", text: "What's the capital of France?",
              history: mySetup("check the nas", "All healthy."), previous: .personal, hands: false, want: [.general, .personal]),
    ]

    struct Result { let item: Case; let outcome: Outcome; let routed: Bool }

    @MainActor static func run() async -> [Result] {
        var results: [Result] = []
        for item in cases {
            let front = window(item.front)
            let message = RouteDecision.Message(text: item.text, history: item.history, provider: .claude, choice: .auto, control: item.control, front: front)
            let gates = RouteDecision.gates(message)
            let started = RouteDecision.looksForChatFolder(message, gates, directory: nil)
                ? HerdrInference.chatFolder(question: item.text, imageText: "", workspaces: workspaces, taskRepo: { _ in nil }).map { URL(fileURLWithPath: $0) } : nil
            let screen = front != nil && RouteDecision.readsScreen(message, gates, started: started)
            let step = await RouteDecision.next(message, gates, started: started, images: item.images, screen: screen, previous: item.previous) { repos }
            switch step {
            case .herdr: results.append(.init(item: item, outcome: .herdr, routed: false))
            case .task: results.append(.init(item: item, outcome: .task, routed: false))
            case .meeting: results.append(.init(item: item, outcome: .meeting, routed: false))
            case .noWindow: results.append(.init(item: item, outcome: .noWindow, routed: false))
            case .answer(let plan): results.append(.init(item: item, outcome: outcome(plan, control: item.control), routed: false))
            case .unrouted, .router:
                let plan = RoutePlan.make(router(for: item, front: front), input: input(item, front: front), bars: .forEngine(.decisions, high: 0.9), previous: item.previous)
                results.append(.init(item: item, outcome: outcome(plan, control: item.control), routed: true))
            }
        }
        return results
    }

    static func outcome(_ plan: RoutePlan, control: Bool) -> Outcome {
        switch plan.scope {
        case .personal: return .personal
        case .general: return .general
        case .screen, .all:
            if control { return .control }
            return plan.writes || plan.toolWrites ? .appWrite : .screen
        }
    }

    static func input(_ item: Case, front: ContextWindow?) -> RoutingInput {
        let snapshot = front.map { ContextSnapshot(displayID: 1, windowID: $0.id, pid: $0.pid, bundleID: $0.bundleID, appName: $0.appName, windowTitle: $0.title,
                                                   capturedAt: 0, launchTime: 0, selection: nil, text: "", document: "") }
        return RoutingInput(question: item.text, history: item.history, imageCount: item.images, windows: front.map { [$0] } ?? [], candidate: snapshot,
                            projects: [], personalAvailable: true)
    }

    /// Wrong for a request that needs hands (it's about the screen, not the user's work, not a follow-up);
    /// honest for one that doesn't.
    static func router(for item: Case, front: ContextWindow?) -> RoutingSignals {
        let target = RoutingSignals.Choice(key: front == nil ? "none" : "w0", confidence: 0.95)
        if item.hands {
            return .init(yes: ["needs_screen": front == nil ? 0.1 : 0.94, "self_contained": 0.3, "needs_visual": 0.1, "about_my_work": 0.3,
                               "follow_up": 0.56, "wants_app_action": 0.2, "about_attached_image": 0.5], choices: ["target": target])
        }
        let screen = item.want.contains(.screen) && !item.want.contains(.general)
        return .init(yes: ["needs_screen": screen ? 0.95 : 0.05, "self_contained": screen ? 0.1 : 0.95, "needs_visual": 0.05, "about_my_work": 0.1,
                           "follow_up": 0.1, "wants_app_action": 0.05],
                     choices: ["target": screen ? target : .init(key: "none", confidence: 0.95)])
    }

    /// The scorecard, and the cases that fail outside their known gaps.
    static func report(_ results: [Result]) -> (lines: [String], regressions: [String], closed: [String]) {
        let pass = results.filter { $0.item.want.contains($0.outcome) }
        let hands = results.filter(\.item.hands), handsPass = hands.filter { $0.item.want.contains($0.outcome) }
        let negatives = results.filter { !$0.item.hands }, negativesPass = negatives.filter { $0.item.want.contains($0.outcome) }
        let deadEnds = hands.filter { [.general, .screen].contains($0.outcome) }
        let lines = [
            "Harness eval: \(pass.count)/\(results.count) land right even when the router misses them",
            "  needs hands: \(handsPass.count)/\(hands.count) reach a route that can act; \(deadEnds.count) dead-end on a route with no hands",
            "  needs none:  \(negativesPass.count)/\(negatives.count) left alone by the gates",
        ] + results.filter { !$0.item.want.contains($0.outcome) }.map {
            "  \($0.item.gap == nil ? "FAIL" : "gap ") \($0.item.id): \($0.outcome.rawValue)\($0.routed ? " (router)" : ""), wanted \($0.item.want.map(\.rawValue).sorted().joined(separator: "/"))"
        }
        let regressions = results.filter { $0.item.gap == nil && !$0.item.want.contains($0.outcome) }.map(\.item.id)
        let closed = results.filter { $0.item.gap != nil && $0.item.want.contains($0.outcome) }.map(\.item.id)
        return (lines, regressions, closed)
    }
}
