import Foundation
import SQLite3

/// A CXTasks project, read so the router can say which one a question is about.
struct RegisteredProject: Equatable {
    let name: String
    /// Repository folder names (not paths): enough to match a terminal or editor title.
    let repos: [String]
}

struct ProjectWorkspace {
    let project: String; let path: String
    /// A CXTasks project, as opposed to a git folder found under a code root. Only these route a handoff by topic.
    var registered = true
}

enum ProjectRegistry {
    static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.cxtasks.app/cxtasks.db").path
    private static let lock = NSLock()
    private static var cached: (at: Date, projects: [RegisteredProject])?

    /// Active projects, cached for five minutes. Read-only; an unavailable database is no projects.
    static func projects() -> [RegisteredProject] {
        lock.lock(); defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 300 { return cached.projects }
        let projects = read(path: databasePath)
        cached = (Date(), projects)
        return projects
    }

    static func read(path: String) -> [RegisteredProject] {
        var db: OpaquePointer?
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        let query = """
        SELECT p.name, group_concat(r.repo_path, char(31)) FROM projects p
        LEFT JOIN project_repos r ON r.project = p.name
        WHERE p.archived = 0 GROUP BY p.id ORDER BY p.sort_order, p.name LIMIT 40
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var projects: [RegisteredProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0).map({ String(cString: $0) }), !name.isEmpty else { continue }
            let repos = sqlite3_column_text(statement, 1).map { String(cString: $0) }?
                .split(separator: "\u{1F}").map { ($0 as NSString).lastPathComponent } ?? []
            projects.append(.init(name: name, repos: repos))
        }
        return projects
    }

    /// Exact saved folders stay local; the relevance router still receives names only.
    static func workspaces(path: String = databasePath) -> [ProjectWorkspace] {
        var db: OpaquePointer?
        guard FileManager.default.fileExists(atPath: path), sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        let sql = "SELECT p.name, r.repo_path FROM projects p JOIN project_repos r ON r.project = p.name WHERE p.archived = 0 LIMIT 120"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [ProjectWorkspace] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0), let folder = sqlite3_column_text(statement, 1) {
                results.append(.init(project: String(cString: name), path: String(cString: folder)))
            }
        }
        return results
    }

    /// Git repositories directly under the usual code roots, named by folder, so a handoff that names
    /// an unregistered repo ("with quickask") opens there instead of a blank session folder (2026-10-21).
    static func localRepos(roots: [URL] = ["Projects", "Projects/xcode", "clients"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }) -> [ProjectWorkspace] {
        roots.flatMap { root -> [ProjectWorkspace] in
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return children.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
                .map { .init(project: $0.lastPathComponent, path: $0.path, registered: false) }
        }
    }

    /// A live task's repository folder, by its T-number. Read-only; unknown is nil.
    static func taskRepo(_ shortID: Int) -> String? { taskRepo(shortID, path: databasePath) }
    static func taskRepo(_ shortID: Int, path: String) -> String? {
        var db: OpaquePointer?
        guard FileManager.default.fileExists(atPath: path), sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT repo_path FROM tasks WHERE short_id = ? AND deleted_at IS NULL AND repo_path <> '' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(shortID))
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
    }
}

/// Everything the router judges, built once per Auto-mode question.
struct RoutingInput {
    let question: String
    let history: [ChatMessage]
    let imageCount: Int
    /// Eligible windows on the dialog's display, frontmost first.
    let windows: [ContextWindow]
    /// The captured candidate window (labels, URL, document; text only without labels).
    let candidate: ContextSnapshot?
    let projects: [RegisteredProject]
    /// The answering provider can run as the user's own Claude session (My setup).
    var personalAvailable = false
    /// Tools the router may attach to any answer, screen or not. Never Margin, which
    /// attaches only when the user names it.
    var toolConnectors: [AppConnector] = [.vault, .cxtasks, .cxmail]

    var windowKeys: [String: ContextWindow] {
        Dictionary(uniqueKeysWithValues: windows.prefix(8).enumerated().map { ("w\($0.offset)", $0.element) })
    }
    var projectKeys: [String: RegisteredProject] {
        Dictionary(uniqueKeysWithValues: projects.prefix(40).enumerated().map { ("p\($0.offset)", $0.element) })
    }
    /// The question points at something the user built, hosts or named ("my local version",
    /// "I called it telly", "the one I built", "on my NAS") and not at the screen: only My setup
    /// can see it. A visible page about a public product of the same name made the router read
    /// "look at my local version" as the screen (2026-10-18).
    var refersToOwnThing: Bool { Self.refersToOwnThing(question) }

    static func refersToOwnThing(_ text: String) -> Bool {
        let own = [
            "\\bmy (?:own|local|self[- ]?hosted|home[- ]?made)\\b",
            "\\b(?:i|we)(?:'ve| have)? (?:called|named) (?:it|mine|ours|that|the (?:app|tool|project|repo))\\b(?! (?:a day|a night|quits|off)\\b)",
            "\\b(?:one|version|app|tool|thing|project|repo) (?:that )?(?:i|we)(?:'ve| have)? (?:built|made|wrote|coded|host|self[- ]?host|deployed|set up|run|named|called)\\b",
            "\\b(?:on|in) (?:my|our) (?:nas|server|home ?server|homelab|repos?|machine)\\b"
        ]
        // "My setup" names the user's whole environment, which no window shows, so a "this" beside it
        // ("is this worth it with my setup?") still means the topic, not the screen (2026-10-21). Any "my setup"
        // counts, not only after "for/with": "check my setup" and "is my setup good enough" ask the same thing.
        let setup = "\\bmy (?:current |own |home |whole )?(?:setup|set-up|config(?:uration)?|stack|homelab|home ?server|rig)\\b"
        if text.range(of: "(?i)" + setup, options: .regularExpression) != nil {
            return text.range(of: "(?i)\\b(?:on (?:my |the )?screen|this (?:page|window|tab|listing|site|screen))\\b", options: .regularExpression) == nil
        }
        guard own.contains(where: { text.range(of: "(?i)" + $0, options: .regularExpression) != nil }) else { return false }
        return text.range(of: "(?i)\\b(?:this|these|here|on (?:my |the )?screen)\\b", options: .regularExpression) == nil
    }

    /// Repository folder names that are words in their own right, so naming one isn't naming the repo
    /// ("change the margin", "the impact of…").
    static let ambiguousRepoNames: Set<String> = ["margin", "prism", "impact", "streaks", "godly", "frosty", "guide", "optimium"]

    /// A request to change one of the user's own repositories, named ("for quickask can we restyle the
    /// dropdown?"). Only My setup has the hands for that, and it looks at the screen itself, so the
    /// screenshots or "the example" that come with it don't make it a screen question: the screen route
    /// answered "I can't edit QuickAsk's code from here" (2026-10-23).
    static func asksToChange(_ text: String, inRepos repos: [String]) -> Bool {
        let names = Set(repos.map { $0.lowercased() }).filter { $0.count >= 4 && !ambiguousRepoNames.contains($0) }
        guard names.contains(where: { text.range(of: "(?i)(?<![\\w-])\(NSRegularExpression.escapedPattern(for: $0))(?![\\w-])", options: .regularExpression) != nil })
        else { return false }
        let change = "\\b(?:can (?:we|you|u)|could (?:we|you)|let'?s|please|fix|change|(?:re)?style|add|remove|update|implement|refactor|rename|redesign|tweak|clean up|wire|hook up)\\b"
        return text.range(of: "(?i)" + change, options: .regularExpression) != nil
    }

    var connectedApps: [AppConnector] {
        AppConnector.allCases.filter { connector in windows.prefix(8).contains { $0.bundleID == connector.bundleID } }
    }

    /// The router's state. Window and project IDs are short keys mapped back locally.
    var state: [String: Any] {
        var state: [String: Any] = [
            "question": question,
            "conversation": history.filter { $0.complete }.suffix(4).map { ["role": $0.role, "text": String($0.text.prefix(1200))] },
            "attached_images": imageCount,
            "visible_windows": windowKeys.sorted { $0.key < $1.key }.map { key, window -> [String: Any] in
                ["id": key, "app": window.appName, "title": String(window.title.prefix(200)), "candidate": window.id == candidate?.windowID]
            },
            // Onyx's page tools read only the page asked about, so Onyx is listed only when it is that window.
            "connected_apps": connectedApps.filter { $0 != .onyx || candidate?.connector == .onyx }.map { "\($0.title): \($0.tools.joined(separator: ", "))" }
        ]
        if let candidate { state["candidate_window"] = candidate.routingEvidence }
        if toolConnectors.contains(.meetingcopilot) {
            state["live_meeting"] = "Meeting Copilot is following a meeting the user is in right now. It has the meeting's live transcript, agenda and goals, and can coach, research and answer questions about it."
        }
        if !projects.isEmpty {
            state["projects"] = projectKeys.sorted { $0.key < $1.key }.map { key, project in
                ["id": key, "name": project.name, "repositories": project.repos]
            }
        }
        return state
    }
}

struct RoutingQuestion {
    enum Kind { case yesNo, choice([String: String]) }
    let name: String
    let kind: Kind
    let instructions: String

    static func all(for input: RoutingInput) -> [RoutingQuestion] {
        var questions: [RoutingQuestion] = [
            .init(name: "self_contained", kind: .yesNo, instructions: """
            The latest question can be fully answered from the question itself, any attached images and the \
            conversation so far, without anything on the user's screen. 'What is OAuth?' and 'How do I cook \
            lasagna?' are self-contained; 'Help me with this error' is not.
            """),
            .init(name: "needs_screen", kind: .yesNo, instructions: """
            Answering well requires the content of a window visible on the user's screen: words like 'this', \
            'here', 'this error', 'this page' or 'the email' that point at something visible, or a request about \
            the visible app's item. A product name alone does not mean the screen is needed. The user's own \
            version, app, server or project ('my local version', 'the one I built', something they named) is \
            not on screen unless they say it is, even when a page about a similar product is visible.\(input.candidate?.connector == .onyx ? """
             Onyx, the user's reader, is open on a page: 'this page', 'this doc', 'this article', 'this section', \
            'the highlighted part', the files or notes next to the page, or a question about what the page says \
            points at it.
            """ : "")\(input.connectedApps.contains(.studiocoach) ? """
             FL Studio is open with Studio Coach: a question about the song, beat, mix, vocal, hook, \
            arrangement or what to do next in the session points at it, even without 'this'.
            """ : "")\(input.imageCount > 0 ? """
             The user attached image(s) to this question: 'this image', 'this picture' or 'this screenshot' \
            refer to the attachment, not the screen, unless the question compares it with something visible.
            """ : "")
            """),
            .init(name: "needs_visual", kind: .yesNo, instructions: """
            The answer depends on seeing the screen itself (layout, colours, a chart, an image, a design, where \
            something is), not just reading its text.
            """)
        ]
        if input.personalAvailable {
            questions.append(.init(name: "about_my_work", kind: .yesNo, instructions: """
            The question is about the user's own work or life (their priorities, plans, projects, clients, \
            calls, meetings, deadlines, proposals, invoices, tasks, notes, schedule, repositories, apps, tools, \
            servers or self-hosted services they built, run or named, their setup ('with my setup'), or people they work with), so a good answer needs their personal setup (instructions, notes vault, task \
            list, email, project folders) rather than general knowledge. Judge this from the question and the \
            conversation alone: unrelated text on screen is not evidence against it. A client or company name \
            with 'we', 'our' or 'my' is enough, and so is a correction pointing at the user's own thing rather \
            than a public product of the same name ('no, look at my local version', 'the one I called Telly'). \
            'What should we focus on today?', 'Are we ready for the Acme call on Friday?' and 'Did Sam reply \
            about the proposal?' are; 'What is OAuth?' is not.\(input.toolConnectors.contains(.meetingcopilot) ? """
             The user is in a meeting right now (live_meeting): a question about what is being said or decided in \
            it is about that meeting, not this.
            """ : "")\(input.candidate?.connector == .onyx ? """
             A question that points at the page open in Onyx ('this page', 'this doc', 'the notes next to this \
            page') is about that page, not this, whatever its subject.
            """ : "")\(input.imageCount > 0 ? """
             A question about the attached image ('what code is in this image?') is about that image, not this, \
            unless it also asks about the user's own work.
            """ : "")
            """))
        }
        if input.imageCount > 0 {
            questions.append(.init(name: "about_attached_image", kind: .yesNo, instructions: """
            The question is about the image(s) the user attached to it, rather than about something on their screen.
            """))
        }
        if !input.connectedApps.isEmpty || !input.toolConnectors.isEmpty {
            questions.append(.init(name: "wants_app_action", kind: .yesNo, instructions: """
            The user asks to change something in a connected app or tool (archive, flag, move, draft or edit \
            a reply, file, complete, update or comment on a task, set a song's feeling or goal, record that a \
            suggestion helped), not just to read, find, explain, summarize or give feedback.
            """))
        }
        let toolQuestions: [AppConnector: String] = [
            .vault: "The user asks to search or check their notes vault, Obsidian notes, Onyx or Artifacts for something ('check our vault', 'do we have a doc on this').",
            .cxtasks: "The user asks about or to act on their CXTasks tasks or projects by reference (a T-number, 'my tasks', 'what's due'), beyond anything on screen.",
            .cxmail: "The user asks to find, read or draft email in CXMail beyond the email on screen ('find the thread with Sam', 'draft an email to…').",
            .meetingcopilot: "The user is in a meeting right now (live_meeting in the state). The question is about that meeting or something to use in it: what someone said, agreed or asked, prices or dates discussed, open questions, how the user is doing, what they missed, what to say next, research for the meeting, or a question for the copilot. Past tense about a person in the meeting ('what did Sam say', 'what price did we land on') means this meeting unless the question names another time or place. 'What did Sam say about pricing?', 'research their company', 'summarize so far' and 'what's still open?' are; 'what's on my calendar tomorrow?' is not."
        ]
        for connector in input.toolConnectors {
            guard let instructions = toolQuestions[connector] else { continue }
            questions.append(.init(name: "uses_\(connector.rawValue)", kind: .yesNo, instructions: instructions))
        }
        if input.history.contains(where: { $0.role == "assistant" && $0.complete }) {
            questions.append(.init(name: "follow_up", kind: .yesNo, instructions: """
            The question continues the previous exchange and depends on it (for example 'and the second one?').
            """))
        }
        var targets = input.windowKeys.mapValues { window in "\(window.appName)\(window.title.isEmpty ? "" : " · \(window.title.prefix(120))")" }
        targets["none"] = "The question is not about any visible window."
        questions.append(.init(name: "target", kind: .choice(targets), instructions: """
        Which visible window the question is about. Prefer the candidate window when the question points at \
        something on screen without naming an app. Choose none for questions that need no screen content.
        """))
        if !input.projects.isEmpty {
            var projects = input.projectKeys.mapValues { project in
                project.repos.isEmpty ? project.name : "\(project.name) (repositories: \(project.repos.joined(separator: ", ")))"
            }
            projects["none"] = "No specific project, or unclear."
            questions.append(.init(name: "project", kind: .choice(projects), instructions: """
            Which of the user's projects the question or the visible window is about, judged from the question, \
            window titles, paths and repository names. Choose none unless the evidence names or clearly implies one.
            """))
        }
        return questions
    }

    static func decisionsBody(_ questions: [RoutingQuestion]) -> [[String: Any]] {
        questions.map { question in
            switch question.kind {
            case .yesNo: return ["type": "predicate", "name": question.name, "instructions": question.instructions]
            case .choice(let options):
                return ["type": "choice", "name": question.name, "instructions": question.instructions,
                        "choices": options.keys.sorted().map { ["value": $0, "description": options[$0]!] }]
            }
        }
    }

    static func jevBody(_ questions: [RoutingQuestion]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: questions.map { question -> (String, Any) in
            switch question.kind {
            case .yesNo: return (question.name, ["type": "noul", "instructions": question.instructions])
            case .choice(let options): return (question.name, ["type": "choice", "instructions": question.instructions, "criteria": options])
            }
        })
    }
}

/// The router's answers. Each question stands alone: a refused, missing or malformed
/// answer is no judgment for that question only.
struct RoutingSignals: Equatable {
    var yes: [String: Double] = [:]
    var choices: [String: Choice] = [:]
    struct Choice: Equatable { let key: String; let confidence: Double }

    static func parse(_ response: [String: Any], engine: RoutingEngine, questions: [RoutingQuestion]) -> RoutingSignals? {
        let answers: [String: [String: Any]]
        if engine == .decisions {
            var named: [String: [String: Any]] = [:], duplicates: Set<String> = []
            for answer in response["answers"] as? [[String: Any]] ?? [] {
                guard let name = answer["name"] as? String else { continue }
                if named[name] != nil { duplicates.insert(name) }
                named[name] = answer
            }
            duplicates.forEach { named.removeValue(forKey: $0) }
            answers = named
        } else { answers = response["answers"] as? [String: [String: Any]] ?? [:] }
        var signals = RoutingSignals()
        for question in questions {
            guard let answer = answers[question.name], answer["type"] as? String != "refusal" else { continue }
            switch question.kind {
            case .yesNo:
                if let value = probability(answer[engine == .decisions ? "probability" : "noul"]) { signals.yes[question.name] = value }
            case .choice(let options):
                guard let key = answer["choice"] as? String, options[key] != nil, let value = probability(answer["confidence"]) else { continue }
                signals.choices[question.name] = .init(key: key, confidence: value)
            }
        }
        return signals.yes.isEmpty && signals.choices.isEmpty ? nil : signals
    }

    private static func probability(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
}

/// Per engine: Decisions' yes/no probabilities run higher than Jev's (CXTasks, 2026-10-06),
/// so a bar tuned for one must not be borrowed by the other. Provisional until evaluated.
struct RoutingBars: Equatable {
    /// At or above: a yes.
    let high: Double
    /// At or below: a no.
    let low: Double
    /// A window or project pick needs this confidence.
    let target: Double
    /// My setup's own bar. Lower than `high` because the costs are lopsided: a false
    /// positive costs a few seconds in the user's own session, which still changes
    /// nothing unasked; a miss answers a question about their work with no access to it.
    let personal: Double
    static func forEngine(_ engine: RoutingEngine, high: Double) -> RoutingBars {
        engine == .decisions ? .init(high: high, low: 0.25, target: 0.8, personal: 0.7) : .init(high: min(high, 0.8), low: 0.3, target: 0.7, personal: 0.6)
    }
}

enum RouteScope: String { case general, screen, all, personal }

/// What a question gets, decided locally from the router's answers.
struct RoutePlan: Equatable {
    let scope: RouteScope
    /// The window whose content is sent (screen/all).
    let window: ContextWindow?
    /// Its connected app, if any: read tools always, write tools only when `writes`.
    let connector: AppConnector?
    let writes: Bool
    let screenshot: Bool
    let project: String?
    let explanation: String
    /// Tools attached beyond the window's own app, and whether they may write.
    var tools: [AppConnector] = []
    var toolWrites = false

    static func personal(_ explanation: String) -> RoutePlan {
        .init(scope: .personal, window: nil, connector: nil, writes: true, screenshot: false, project: nil, explanation: explanation)
    }

    /// Routing turned off: the router's own "unclear" answer, made without a request.
    /// The candidate window goes read-only; no screenshot, no extra tools.
    static func unrouted(windows: [ContextWindow], candidate: ContextSnapshot?) -> RoutePlan {
        let window = windows.first { $0.id == candidate?.windowID } ?? windows.first
        return .init(scope: .all, window: window, connector: window.flatMap { AppConnector.matching($0.bundleID) }, writes: false,
                     screenshot: false, project: nil, explanation: "Routing is off, so the screen context is included for the model to use or ignore.")
    }

    static func general(_ explanation: String) -> RoutePlan {
        .init(scope: .general, window: nil, connector: nil, writes: false, screenshot: false, project: nil, explanation: explanation)
    }

    /// The decision matrix. Clear answers pick General or one window; anything unclear
    /// sends all the context and lets the answering model decide what is useful.
    /// Uncertainty never adds write tools.
    static func make(_ signals: RoutingSignals, input: RoutingInput, bars: RoutingBars, previous: RouteScope?) -> RoutePlan {
        func yes(_ name: String) -> Bool { (signals.yes[name] ?? 0) >= bars.high }
        var plan = decide(signals, input: input, bars: bars, previous: previous)
        // A question about the meeting in progress is the copilot's, not My setup's.
        // Meeting tools are read-only and offered only while a meeting is live, and missing the meeting
        // leaves an answer that knows nothing of it, so they use My setup's lower bar.
        let meeting = input.toolConnectors.contains(.meetingcopilot) && (signals.yes["uses_meetingcopilot"] ?? 0) >= bars.personal
        if plan.scope == .personal && meeting {
            plan = .general("This is about your meeting in progress.")
        }
        guard plan.scope != .personal else { return plan }
        plan.tools = input.toolConnectors.filter { ($0 == .meetingcopilot ? meeting : yes("uses_\($0.rawValue)")) && $0 != plan.connector }
        plan.toolWrites = yes("wants_app_action")
        return plan
    }

    private static func decide(_ signals: RoutingSignals, input: RoutingInput, bars: RoutingBars, previous: RouteScope?) -> RoutePlan {
        func yes(_ name: String) -> Bool { (signals.yes[name] ?? 0) >= bars.high }
        let screenUnneeded = signals.yes["needs_screen"].map { $0 <= bars.low } ?? false
        let continues = yes("follow_up") && previous != nil && previous != .general
        let pickedWindow = signals.choices["target"].flatMap { $0.key != "none" && $0.confidence >= bars.target ? input.windowKeys[$0.key] : nil }
        let project = signals.choices["project"].flatMap { $0.key != "none" && $0.confidence >= bars.target ? input.projectKeys[$0.key]?.name : nil }
        let screenshot = yes("needs_visual")
        let noTarget = signals.choices["target"].map { $0.key == "none" && $0.confidence >= bars.target } ?? false

        // About the user's own work and not about the screen: their full Claude setup.
        let continuesPersonal = yes("follow_up") && previous == .personal
        let aboutWork = (signals.yes["about_my_work"] ?? 0) >= bars.personal
        // My setup can look at the screen itself (look_at_screen), so a follow-up to one of its replies stays
        // there even when it needs the screen: the screen route has no hands (2026-10-22, Docusign review).
        if input.personalAvailable && (continuesPersonal || (aboutWork && !yes("needs_screen") && !screenshot)) {
            return .personal("This is about your own work, so it runs with your Claude setup.")
        }
        // Something only the user's setup can see outranks a screen reading of "look at…".
        if input.personalAvailable && input.refersToOwnThing && !screenshot {
            return .personal("This points at something of your own, so it runs with your Claude setup.")
        }

        if screenUnneeded && !continues && !screenshot && (yes("self_contained") || yes("about_attached_image") || noTarget) {
            return .init(scope: .general, window: nil, connector: nil, writes: false, screenshot: false, project: project,
                         explanation: "This question doesn’t need your screen.")
        }
        if yes("needs_screen"), let window = pickedWindow {
            let connector = AppConnector.matching(window.bundleID)
            return .init(scope: .screen, window: window, connector: connector, writes: connector != nil && yes("wants_app_action"),
                         screenshot: screenshot, project: project, explanation: "This question is about \(window.appName).")
        }
        let window = pickedWindow ?? input.windows.first { $0.id == input.candidate?.windowID } ?? input.windows.first
        return .init(scope: .all, window: window, connector: window.flatMap { AppConnector.matching($0.bundleID) }, writes: false,
                     screenshot: screenshot, project: project,
                     explanation: "Relevance was unclear, so the screen context is included for the model to use or ignore.")
    }

    var label: String { label(screenshotSent: screenshot) }

    /// What was actually sent: a requested screenshot that couldn't be captured isn't claimed.
    func label(screenshotSent: Bool, item: String? = nil) -> String {
        var parts: [String]
        switch scope {
        case .general: parts = ["General chat"]
        case .personal: return "My setup"
        case .screen, .all:
            let title = item.flatMap { $0.isEmpty ? nil : $0 } ?? window?.title ?? ""
            let name = window.map { title.isEmpty ? $0.appName : "\($0.appName) · \(title.prefix(40))" } ?? "No screen context"
            parts = [scope == .all ? "Auto · all context" : (connector == nil ? "Screen" : "App"), name]
            if let connector, !connector.writes.isEmpty, !writes { parts.append("read-only") }
        }
        if screenshotSent { parts.append("screenshot") }
        parts += tools.map(\.title)
        if let project { parts.append(project) }
        return parts.joined(separator: " · ")
    }
}

/// Screen content for an answer without app tools, or alongside them.
struct ScreenPayload: Encodable {
    let app: String
    let windowTitle: String
    let url: String
    let document: String
    let selection: String
    let visibleText: String
    let otherWindows: [String]
    let project: String?
    let screenshotAttached: Bool
    let uncertain: Bool

    init(snapshot: ContextSnapshot, plan: RoutePlan, windows: [ContextWindow], screenshotAttached: Bool) {
        app = snapshot.appName; windowTitle = snapshot.windowTitle; url = snapshot.url; document = snapshot.document
        selection = snapshot.selection?.label ?? ""; visibleText = String(snapshot.text.prefix(8000))
        otherWindows = windows.filter { $0.id != snapshot.windowID }.prefix(8).map(\.label)
        project = plan.project; self.screenshotAttached = screenshotAttached; uncertain = plan.scope == .all
    }
}

/// Where one sent message goes, decided from facts gathered beforehand and nothing else, so the whole
/// chain runs in a test (Tests/HarnessEval.swift) as it runs in AppModel.send, which gathers the facts.
/// The order is the precedence: the first step that claims the message takes it.
enum RouteDecision {
    /// What is known when Send is pressed.
    struct Message {
        var text: String
        var history: [ChatMessage] = []
        var provider: Provider = .claude
        var choice: ContextChoice = .auto
        var control = false
        var taskReview = false
        var herdrReview = false
        /// The window Auto would read: the front one on the popup's display.
        var front: ContextWindow? = nil
        /// The last reply showed a page this chat is working on.
        var shownPage = false
    }

    /// The decisions made before anything is gathered; they also say what to gather.
    struct Gates: Equatable {
        var truth = false
        /// A retry of the Herdr request this text names, when it is one ("try again").
        var retried: String? = nil
        var transfer = false
        var link = false
        var browse = false
        var page = false
        /// Herdr needs the screen too: the request points at what is on it.
        var transferNeedsScreen = false
    }

    nonisolated static func gates(_ m: Message) -> Gates {
        var g = Gates()
        let auto = m.choice == .auto && !m.control && m.provider == .claude
        g.truth = !m.taskReview && !m.herdrReview && AppModel.truthTarget(in: m.text) != nil
        g.retried = m.herdrReview || g.truth || m.taskReview ? nil : HerdrHandoff.retriedRequest(m.text, history: m.history)
        g.transfer = m.herdrReview || g.retried != nil
            || (!g.truth && !m.taskReview && HerdrHandoff.requestsTransfer(m.text) && !AppModel.requestsTaskCreation(m.text))
        g.transferNeedsScreen = HerdrHandoff.referencesScreen(m.text) || { if case .window = m.choice { return true }; return false }()
        // Only My setup can open a link (web fetch, and the user's browser for sites that refuse it).
        g.link = !g.truth && auto && AppModel.asksToOpenLink(m.text)
        // Only My setup drives the user's browser (zen-ext); with Control app off, every other route has no hands.
        // A question about the browser window right after a reply that drove it continues that work, whatever the router
        // scores: "review the dock and ensure we didn't miss anything" went to the screen route, which has no hands.
        g.browse = !g.truth && !g.link && auto
            && (AppModel.asksToUseBrowser(m.text) || AppModel.continuesBrowserWork(history: m.history, front: m.front))
        // Only My setup can write the page the reply shows, and edit it when the user asks for changes.
        g.page = !g.truth && !g.link && !g.browse && !m.taskReview && !g.transfer && auto && (m.shownPage || AppModel.asksForPage(m.text))
        return g
    }

    /// A new chat about one of your projects starts in its folder: worth looking for one.
    nonisolated static func looksForChatFolder(_ m: Message, _ g: Gates, directory: URL?) -> Bool {
        directory == nil && m.history.isEmpty && !m.control && m.provider == .claude && m.choice == .auto && !g.truth && !g.link && !g.transfer && !m.taskReview
    }
    nonisolated static func readsScreen(_ m: Message, _ g: Gates, started: URL?) -> Bool {
        started == nil && !g.truth && m.choice != .general && m.choice != .personal && !g.link && !g.browse && (!g.transfer || g.transferNeedsScreen)
    }
    nonisolated static func checksMeeting(_ m: Message, _ g: Gates) -> Bool {
        m.choice == .auto && !m.control && !g.link && !g.browse && !g.transfer && !m.taskReview && !g.truth
    }

    enum Step {
        case herdr, task, meeting(String), answer(RoutePlan)
        /// Control or a chosen window, and no window to use.
        case noWindow
        /// Routing is off: everything on screen goes, for the model to use or ignore.
        case unrouted
        /// The router decides (ContextRouter.assess, then RoutePlan.make).
        case router
    }

    /// `started`: the folder a new chat about a project starts in. `directory`: the chat's own (`!cd`).
    /// `screen`: the front window was captured. `repos` is read only when the step that needs it is reached.
    nonisolated static func next(_ m: Message, _ g: Gates, started: URL? = nil, directory: URL? = nil, meeting: Bool = false,
                                 images: Int = 0, screen: Bool, routingOff: Bool = false, repos: () async -> [String]) async -> Step {
        if g.transfer { return .herdr }
        // A truth check reads whatever it is given, so with Claude it runs where links open.
        if g.truth { return .answer(m.provider == .claude ? .personal("A truth check runs with your Claude setup, so it can read any link.")
                                                        : .general("A truth check with Codex uses what it already knows.")) }
        if m.taskReview || AppModel.requestsTaskCreation(m.text) { return .task }
        if meeting, images == 0, let kind = MeetingCopilot.pulseKind(m.text) { return .meeting(kind) }
        // A chat set to a folder runs My setup from it; with Codex selected the answer says to pick Claude.
        if let started { return .answer(.personal("This chat is about \(started.lastPathComponent), so it starts there with your Claude setup. Send !cd to change that.")) }
        if let directory, !m.control { return .answer(.personal("This chat is in \(directory.lastPathComponent), so it runs with your Claude setup there.")) }
        if g.link { return .answer(.personal("This message is a link to open, so it runs with your Claude setup.")) }
        if g.browse { return .answer(.personal("This is about your browser, so it runs with your Claude setup.")) }
        if g.page { return .answer(.personal(m.shownPage ? "This chat is working on a page, so it runs with your Claude setup."
                                                         : "This asks for a page, so it runs with your Claude setup.")) }
        if m.choice == .general { return .answer(.general("Selected General chat.")) }
        // With Control on, the control route below has the hands; My setup has none (2026-10-24, "You can control my screen").
        if m.choice == .personal && !m.control { return .answer(.personal("Selected My setup.")) }
        if m.control || m.choice != .auto {
            // Desktop control or an explicitly chosen window: exactly that window, all its tools.
            guard let window = m.front else { return .noWindow }
            return .answer(.init(scope: .screen, window: window, connector: AppConnector.matching(window.bundleID), writes: true,
                                 screenshot: false, project: nil, explanation: "Selected \(window.appName)."))
        }
        // A change to one of the user's repos, by name: only My setup can make it, screen or not.
        if m.provider == .claude, RoutingInput.asksToChange(m.text, inRepos: await repos()) {
            return .answer(.personal("This asks to change one of your repositories, so it runs with your Claude setup."))
        }
        // Nothing on screen to route over, but only My setup can see the user's own things.
        if !screen && m.provider == .claude && RoutingInput.refersToOwnThing(m.text) {
            return .answer(.personal("This points at something of your own, so it runs with your Claude setup."))
        }
        if !screen {
            // Nothing on screen to route over; a live meeting still brings its read-only tools.
            var plan = RoutePlan.general("No screen context is visible.")
            if meeting { plan.tools = [.meetingcopilot] }
            return .answer(plan)
        }
        return routingOff ? .unrouted : .router
    }
}
