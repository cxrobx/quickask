import Foundation

/// Uses invented windows, labels and questions only. Never captures the screen or opens an app MCP.
/// Expected outcome per sample: general, screen (that window, no tools), app (that window's tools),
/// app-write (write tools), or all (unclear; everything sent read-only).
@main struct RoutingEvaluation {
    /// `busy`: the front window is a terminal full of unrelated work (another agent session),
    /// which is what made own-work questions miss My setup on 2026-10-14.
    struct Sample { let front: String; let question: String; let expected: String; var images = 0; var visual = false; var busy = false; var meeting = false; var history: [ChatMessage] = []; var previous: RouteScope = .general }
    static let busyTerminal = String(repeating: "⏺ I'll build the cache for the whole library after launch (only running when the grid also reports which size it displays). The volume mount overlapped with baseline runs, so I'll check which runs were affected, then chain the benchmarks (baseline, then the second full decode) and a cache that's wiped on close. Next up is the viewer, the screen you open first. ", count: 14)

    static func main() async throws {
        let engine = RoutingEngine(rawValue: ProcessInfo.processInfo.environment["ROUTING_ENGINE"] ?? "decisions") ?? .decisions
        guard RoutingCredential.key(engine == .decisions ? "OPENAI_API_KEY" : "TYPESAFE_API_KEY") != nil else {
            print("Routing evaluation unavailable: no \(engine.rawValue) key is accessible. No requests sent.")
            exit(2)
        }
        let windows: [String: ContextWindow] = [
            "ghostty": .init(id: 1, pid: 101, bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "npm run build — ~/Projects/artisttracker", bounds: .zero),
            "zen": .init(id: 2, pid: 102, bundleID: "app.zen-browser.zen", appName: "Zen", title: "Stripe Docs — Webhooks signature verification", bounds: .zero),
            "onyx": .init(id: 3, pid: 103, bundleID: "com.cx.onyx", appName: "Onyx", title: "The Secure Handoff — explainer", bounds: .zero),
            "cxmail": .init(id: 4, pid: 104, bundleID: "com.cxmail.app", appName: "CXMail", title: "Inbox", bounds: .zero),
            "cxtasks": .init(id: 5, pid: 105, bundleID: "com.cxtasks.app", appName: "CXTasks", title: "Today", bounds: .zero),
            "docusign": .init(id: 7, pid: 107, bundleID: "app.zen-browser.zen", appName: "Zen", title: "Review and sign documents on Docusign | Docusign", bounds: .zero),
            "watcharr": .init(id: 6, pid: 106, bundleID: "app.zen-browser.zen", appName: "Zen", title: "Watcharr", bounds: .zero)
        ]
        let texts: [String: String] = [
            "ghostty": "$ npm run build\nType error: Property 'artistId' does not exist on type 'Report'.\n  at app/reports/page.tsx:42:18",
            "zen": "Verify webhook signatures. Stripe signs the webhook events it sends to your endpoints by including a signature in each event's Stripe-Signature header.",
            "onyx": "The Secure Handoff. Secrets never travel through chat. Save a key with sk NAME, then consume it with secret run.",
            "cxmail": "", "cxtasks": "", "docusign": "Docusign. Form 641 and Client Disclaimer. Finish. Other Actions.",
            "watcharr": "Watcharr. Profile. Watched: 412 shows, 1,038 movies. Ratings. Watchlist. Import from Trakt. Settings. Logout."
        ]
        let labels: [String: String] = ["cxmail": "Invoice for October · alex@example.test", "cxtasks": "T212 · Fix the invoice export"]
        let samples: [Sample] = [
            .init(front: "ghostty", question: "Help me with this error", expected: "screen"),
            .init(front: "ghostty", question: "What is OAuth?", expected: "general"),
            .init(front: "ghostty", question: "Why is this build failing?", expected: "screen"),
            .init(front: "ghostty", question: "How do I cook lasagna?", expected: "general"),
            .init(front: "zen", question: "Summarize this page", expected: "screen"),
            .init(front: "zen", question: "What's the capital of France?", expected: "general"),
            .init(front: "zen", question: "How do I implement what this describes in Python?", expected: "screen"),
            .init(front: "zen", question: "Explain quantum entanglement simply", expected: "general"),
            .init(front: "onyx", question: "Explain this document's argument", expected: "app"),
            .init(front: "onyx", question: "Who invented email?", expected: "general"),
            .init(front: "onyx", question: "What does this mean by sk NAME?", expected: "app"),
            .init(front: "onyx", question: "Write me a haiku about autumn", expected: "general"),
            .init(front: "cxmail", question: "Summarize this email", expected: "app"),
            .init(front: "cxmail", question: "Archive this email", expected: "app-write"),
            .init(front: "cxmail", question: "Draft a reply thanking the sender", expected: "app-write"),
            .init(front: "cxmail", question: "What does the word invoice mean?", expected: "general"),
            .init(front: "cxtasks", question: "Mark this task complete", expected: "app-write"),
            .init(front: "cxtasks", question: "What is this task's project?", expected: "app"),
            .init(front: "cxtasks", question: "How do I make an omelet?", expected: "general"),
            .init(front: "cxtasks", question: "Is this task blocked?", expected: "app"),
            .init(front: "ghostty", question: "What code is in this image?", expected: "general", images: 1),
            .init(front: "zen", question: "Does this screenshot match the page?", expected: "screen", images: 1),
            .init(front: "zen", question: "What colour is the button at the top right of this page?", expected: "screen", visual: true),
            .init(front: "ghostty", question: "Fix it", expected: "all"),
            .init(front: "zen", question: "What do you think we should focus on today?", expected: "personal"),
            .init(front: "ghostty", question: "Where did we leave the Acme proposal?", expected: "personal"),
            .init(front: "onyx", question: "What's on my plate this week?", expected: "personal"),
            .init(front: "ghostty", question: "are we all ready for the acme call on friday?", expected: "personal", busy: true),
            .init(front: "ghostty", question: "What should I focus on today?", expected: "personal", busy: true),
            .init(front: "ghostty", question: "did sam reply about the proposal?", expected: "personal", busy: true),
            .init(front: "ghostty", question: "What's left before we can invoice Northwind?", expected: "personal", busy: true),
            .init(front: "ghostty", question: "Why did these benchmark runs overlap?", expected: "screen", busy: true),
            .init(front: "ghostty", question: "How do I cook lasagna?", expected: "general", busy: true),
            .init(front: "ghostty", question: "What's the difference between a mutex and a semaphore?", expected: "general", busy: true),
            // 2026-10-16: a notes question over an Onyx page went to My setup; meeting questions about a
            // client went to My setup instead of the live meeting.
            .init(front: "onyx", question: "What's the approved budget in the notes file next to this page?", expected: "app"),
            .init(front: "ghostty", question: "What price did Sam and I land on, and what's still open?", expected: "meeting", meeting: true),
            .init(front: "ghostty", question: "what did sam say about the deadline?", expected: "meeting", meeting: true),
            .init(front: "zen", question: "summarize the meeting so far", expected: "meeting", meeting: true),
            .init(front: "ghostty", question: "What should we focus on today?", expected: "personal", meeting: true),
            .init(front: "ghostty", question: "What is OAuth?", expected: "general", meeting: true),
        ]
        // 2026-10-18: after two web answers about a public app named Telly, a correction pointing at the
        // user's own Telly went to General chat (web search) instead of My setup.
        let tellyHistory: [ChatMessage] = [
            .init(role: "user", text: "isnt telly and seerr both superior in our case?"),
            .init(role: "assistant", text: "They mostly don't compete with Watcharr. Watcharr keeps a record of what you've watched; Seerr handles requests. Telly: my search didn't turn up a watch-tracking app by that name. The Telly I know is an IPTV proxy."),
            .init(role: "user", text: "but telly has a logging feature"),
            .init(role: "assistant", text: "You're right, I mixed it up. There's a Telly: Track TV Shows & Movies app (by Telly Studios) that logs what you watch. It is a commercial phone app, not self-hosted.")
        ]
        let formHistory: [ChatMessage] = [
            .init(role: "user", text: "i want to take action for this email and fill out the form, i have it open in zen as well"),
            .init(role: "assistant", text: "I've filled in your name and email on the form, and I'm stopping there.\n\n[Tools this reply used: zen-ext · list_pages, zen-ext · fill_by_uid]"),
            .init(role: "user", text: "can u fill in the busines info?"),
            .init(role: "assistant", text: "The business section on page 2 is filled. I haven't signed or clicked Finish.\n\n[Tools this reply used: zen-ext · fill_form_by_uid, zen-ext · click_by_uid]")
        ]
        let ownSamples: [Sample] = [
            .init(front: "docusign", question: "i alreday filled out the disability question - please review the dock and ensure we didnt miss anything", expected: "personal", history: formHistory, previous: .personal),
            .init(front: "docusign", question: "did we miss anything?", expected: "personal", history: formHistory, previous: .personal),
            .init(front: "docusign", question: "check the form again", expected: "personal", history: formHistory, previous: .personal),
            .init(front: "docusign", question: "what does section 3 on this page mean?", expected: "personal", history: formHistory, previous: .personal),
            .init(front: "zen", question: "no - look at my local version (i called it telly)", expected: "personal", history: tellyHistory),
            .init(front: "watcharr", question: "no - look at my local version (i called it telly)", expected: "personal", history: tellyHistory),
            .init(front: "watcharr", question: "check my version instead, the one I named telly", expected: "personal", history: tellyHistory),
            .init(front: "watcharr", question: "what's on this profile page?", expected: "screen", history: tellyHistory),
            .init(front: "ghostty", question: "no, I mean the one I built, not the app store one", expected: "personal", history: tellyHistory),
            .init(front: "zen", question: "compare it with my own self-hosted tracker instead", expected: "personal", history: tellyHistory),
            .init(front: "zen", question: "does the app store one sync with Plex?", expected: "general", history: tellyHistory),
        ]
        let selected = ProcessInfo.processInfo.environment["ROUTING_ONLY"] == "own" ? ownSamples : samples + ownSamples
        var rows: [(sample: Sample, signals: RoutingSignals?, ms: Double)] = []
        for sample in selected {
            let front = windows[sample.front]!
            let others = windows.values.filter { $0.id != front.id }.sorted { $0.id < $1.id }.prefix(2)
            let label = labels[sample.front]
            let selection = label.map { AppSelection(pid: front.pid, bundleID: front.bundleID, windowLabel: "main", windowID: front.id, revision: "fixture", label: $0, records: [:]) }
            let snapshot = ContextSnapshot(displayID: 1, windowID: front.id, pid: front.pid, bundleID: front.bundleID, appName: front.appName,
                                           windowTitle: front.title, capturedAt: 0, launchTime: 0, selection: selection,
                                           text: sample.busy ? String(Self.busyTerminal.prefix(8000)) : texts[sample.front] ?? "", document: sample.front == "onyx" ? "/Users/x/Documents/Artifacts/handoff.html" : "",
                                           url: sample.front == "zen" ? "https://docs.stripe.com/webhooks/signature" : sample.front == "watcharr" ? "http://192.168.1.20:3080/profile" : "")
            var input = RoutingInput(question: sample.images > 0 ? "\(sample.question)\n[The user attached \(sample.images) image(s) to this question.]" : sample.question,
                                     history: sample.history, imageCount: sample.images, windows: [front] + others, candidate: snapshot,
                                     projects: [.init(name: "Artist Advisory", repos: ["artisttracker"]), .init(name: "Quick Ask", repos: ["quickask"])],
                                     personalAvailable: true)
            if sample.meeting { input.toolConnectors.append(.meetingcopilot) }
            let start = Date()
            let outcome = await ContextRouter.assess(input, engine: engine)
            if case .signals(let signals) = outcome { rows.append((sample, signals, Date().timeIntervalSince(start) * 1000)) }
            else { rows.append((sample, nil, Date().timeIntervalSince(start) * 1000)) }
        }
        func outcome(_ row: (sample: Sample, signals: RoutingSignals?, ms: Double), high: Double) -> String {
            guard let signals = row.signals else { return "failed" }
            let front = windows[row.sample.front]!
            let others = windows.values.filter { $0.id != front.id }.sorted { $0.id < $1.id }.prefix(2)
            var input = RoutingInput(question: row.sample.question, history: row.sample.history, imageCount: row.sample.images, windows: [front] + others,
                                     candidate: ContextSnapshot(displayID: 1, windowID: front.id, pid: front.pid, bundleID: front.bundleID, appName: front.appName,
                                                                windowTitle: front.title, capturedAt: 0, launchTime: 0, selection: nil, text: "", document: ""),
                                     projects: [.init(name: "Artist Advisory", repos: ["artisttracker"]), .init(name: "Quick Ask", repos: ["quickask"])],
                                     personalAvailable: true)
            if row.sample.meeting { input.toolConnectors.append(.meetingcopilot) }
            let plan = RoutePlan.make(signals, input: input, bars: .forEngine(engine, high: high), previous: row.sample.history.isEmpty ? nil : row.sample.previous)
            if plan.tools.contains(.meetingcopilot) { return "meeting" }
            switch plan.scope {
            case .general: return "general"
            case .personal: return "personal"
            case .all: return "all"
            case .screen:
                guard plan.window?.id == front.id else { return "wrong-window" }
                return plan.connector == nil ? "screen" : (plan.writes ? "app-write" : "app")
            }
        }
        // Missing context (General when context was needed) and unrequested write tools are the
        // costly errors; sending everything when unsure is the accepted fallback.
        func costly(_ expected: String, _ actual: String) -> Bool {
            (expected != "general" && actual == "general") || (actual == "app-write" && expected != "app-write") || actual == "wrong-window"
                || (actual == "personal" && expected != "personal")
                || (expected == "personal" && actual != "personal")
                || (expected == "meeting" && actual != "meeting")
        }
        func acceptable(_ expected: String, _ actual: String) -> Bool { actual == expected || (actual == "all" && expected != "general") }
        let calibration = rows.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let heldOut = rows.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        var chosen = 0.9, best = -1
        for high in stride(from: 0.6, through: 0.98, by: 0.02) {
            let bad = calibration.filter { costly($0.sample.expected, outcome($0, high: high)) }.count
            let exact = calibration.filter { outcome($0, high: high) == $0.sample.expected }.count
            if bad == 0 && exact > best { chosen = high; best = exact }
        }
        let latency = rows.map(\.ms).sorted()
        let perSample = rows.map { row -> [String: Any] in
            ["question": row.sample.question, "front": row.sample.front, "expected": row.sample.expected, "actual": outcome(row, high: 0.9),
             "signals": (row.signals?.yes ?? [:]).mapValues { ($0 * 100).rounded() / 100 },
             "target": row.signals?.choices["target"].map { "\($0.key) \(($0.confidence * 100).rounded() / 100)" } ?? "-"]
        }
        let summary: [String: Any] = [
            "engine": engine.rawValue,
            "fixture_type": "synthetic windows, labels and questions; no real screen content",
            "samples": rows.count, "router_failures": rows.filter { $0.signals == nil }.count,
            "suggested_high_bar": chosen,
            "held_out_count": heldOut.count,
            "held_out_exact": heldOut.filter { outcome($0, high: chosen) == $0.sample.expected }.count,
            "held_out_acceptable": heldOut.filter { acceptable($0.sample.expected, outcome($0, high: chosen)) }.count,
            "held_out_costly_errors": heldOut.filter { costly($0.sample.expected, outcome($0, high: chosen)) }.count,
            "median_ms": latency[latency.count / 2], "p95_ms": latency[Int(Double(latency.count - 1) * 0.95)],
            "latency_scope": "routing API only; excludes native screen capture",
            "shipped_bar": 0.9,
            "all_exact_at_shipped_bar": rows.filter { outcome($0, high: 0.9) == $0.sample.expected }.count,
            "all_acceptable_at_shipped_bar": rows.filter { acceptable($0.sample.expected, outcome($0, high: 0.9)) }.count,
            "all_costly_at_shipped_bar": rows.filter { costly($0.sample.expected, outcome($0, high: 0.9)) }.count,
            "production_calibration": false,
            "per_sample": perSample
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "build/routing-evaluation.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
