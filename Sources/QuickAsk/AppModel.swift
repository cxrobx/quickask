import AppKit
import Combine
import ApplicationServices
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var provider: Provider { didSet { preferences.set(provider.rawValue, forKey: "provider"); prewarm() } }
    @Published var draft = ""
    @Published var attachments: [ImageAttachment] = []
    @Published var messages: [ChatMessage] = []
    /// The requests in flight, one per tab at most, keyed by the tab they answer in. Each tab
    /// runs its own; another tab can come forward and send while one is still answering.
    @Published private var runs: [UUID: Run] = [:]
    /// Whether the tab showing has a request in flight. Setting it starts or ends a bare run
    /// in that tab (tests); ending one writes the chat to history.
    var busy: Bool {
        get { runs[activeSessionID] != nil }
        set {
            if newValue, runs[activeSessionID] == nil { _ = begin(control: controlEnabled) }
            else if !newValue, let run = runs[activeSessionID] { endRun(run) }
        }
    }
    /// Messages sent while a tab was answering, keyed by tab. They go as one message once that
    /// answer finishes, as Claude Code queues them; Stop (or Esc) puts them back in the draft.
    @Published private(set) var queued: [UUID: [QueuedMessage]] = [:]
    var queuedMessages: [QueuedMessage] { queued[activeSessionID] ?? [] }
    /// Whether Return queues rather than sends: the tab showing is answering, past routing (a
    /// question being routed still sits in the draft, so it can't be taken from there yet).
    /// `/fork` and `!cd` act on the chat, not in it, so they wait in the draft for the answer to end.
    var canQueue: Bool {
        guard let run = runs[activeSessionID], run.routing == nil, delegation == nil, herdrProposal == nil,
              Self.forkTitle(in: draft) == nil, Self.cdTarget(in: draft) == nil else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    /// Whether any tab has a request in flight.
    var anyBusy: Bool { !runs.isEmpty }
    var runningSessionIDs: Set<UUID> { Set(runs.keys) }
    /// Whether the popup is on screen; set by the app delegate. Showing it marks the tab in front seen.
    @Published var popupVisible = false { didSet { if popupVisible { markSeen(activeSessionID) } } }
    /// Chats whose answer finished while they weren't in front of you (the status feed's "answered",
    /// a blue dot in Recent chats). Kept on disk with the history, so it outlasts the tab and a relaunch.
    var unseenSessionIDs: Set<UUID> { marks.unread }
    @Published var status = "Ready when you are"
    @Published var error: String?
    @Published var showingSettings = false
    @Published var pinned = false
    @Published var focusToken = 0
    /// Voice mode is driving this chat: replies are written to be heard (Voice.swift).
    @Published var voiceActive = false
    lazy var voice = VoiceController(model: self)
    @Published var hotkeyStatus = "⌥ Space"
    @Published var controlEnabled = false
    @Published var targetApp: AppTarget?
    @Published var contextChoice: ContextChoice = .auto
    @Published var contextWindows: [ContextWindow] = []
    @Published var contextLabel = "Auto · No screen context"
    @Published var needsContextChoice = false
    @Published var routingMilliseconds: Int?
    /// Studio Coach findings whose outcome is being recorded.
    @Published var recordingOutcomes: Set<String> = []
    @Published var delegation: DelegationProposal?
    @Published var herdrProposal: HerdrProposal?
    @Published var herdrDetailsExpanded = false
    /// Where a handoff goes: the shared launcher and the private session folders. Tests point both at fixtures.
    var herdrRouter = HerdrHandoff.helperPath
    var herdrSessions = HerdrHandoff.sessionsDirectory
    private var lastReferencedDocument: String?
    private var lastDocumentMessageCount = 0
    @Published var lastTaskLink: String?
    /// The folder `!cd` set for the tab showing; its messages run My setup from there.
    @Published var directory: URL?
    private var handoffInFlight = false
    /// The previous answer's scope, so a follow-up isn't dropped to General chat.
    private var lastRouteScope: RouteScope?
    private var submittedHandoff: TaskHandoffRequest?
    @Published var routingEngine: String { didSet { preferences.set(routingEngine, forKey: "routingEngine") } }
    @Published var routingThreshold: Double { didSet { preferences.set(routingThreshold, forKey: "routingThreshold") } }
    /// Ask after each answer whether the chat is still on you (FollowUpCheck).
    @Published var followUpCheck: Bool { didSet { preferences.set(followUpCheck, forKey: "followUpCheck") } }
    @Published var cxmailMCPPath: String { didSet { preferences.set(cxmailMCPPath, forKey: "cxmailMCPPath") } }
    @Published var cxtasksMCPPath: String { didSet { preferences.set(cxtasksMCPPath, forKey: "cxtasksMCPPath") } }
    @Published var meetingcopilotMCPPath: String { didSet { preferences.set(meetingcopilotMCPPath, forKey: "meetingcopilotMCPPath") } }
    var contextDisplayID: UInt32?
    var candidateWindow: ContextWindow?
    var refreshScreenContext: (() -> Void)?
    var moveToFocusedApp: (() -> Void)?
    @Published var alternativeHotkey: Bool { didSet { preferences.set(alternativeHotkey, forKey: "alternativeHotkey") } }
    /// On by default; the app delegate applies it at launch, and the toggle applies it at once.
    @Published var openAtLogin: Bool {
        didSet { guard openAtLogin != oldValue else { return }; preferences.set(openAtLogin, forKey: "openAtLogin"); applyOpenAtLogin() }
    }
    @Published var codexPath: String { didSet { preferences.set(codexPath, forKey: "codexPath") } }
    @Published var claudePath: String { didSet { preferences.set(claudePath, forKey: "claudePath") } }
    @Published var codexModel: String { didSet { preferences.set(codexModel, forKey: "codexModel") } }
    @Published var claudeModel: String { didSet { preferences.set(claudeModel, forKey: "claudeModel") } }
    @Published var codexEffort: String { didSet { preferences.set(codexEffort, forKey: "codexEffort") } }
    @Published var claudeEffort: String { didSet { preferences.set(claudeEffort, forKey: "claudeEffort") } }
    /// The models the pill offers, comma-separated, as typed in Settings. Empty offers `Provider.defaultModels`.
    @Published var codexModelList: String { didSet { preferences.set(codexModelList, forKey: "codexModelList") } }
    @Published var claudeModelList: String { didSet { preferences.set(claudeModelList, forKey: "claudeModelList") } }
    /// The popup's chats, one per tab. The chat showing lives in the model's own fields
    /// (messages, draft, …); its entry here is brought up to date when another tab comes forward.
    @Published private(set) var sessions: [ChatSession]
    @Published private(set) var activeSessionID: UUID
    private let preferences: UserDefaults
    /// The last 30 chats on disk, newest first; nil keeps history off (tests).
    private let history: ChatHistory?
    /// Claude processes launched ahead of the question; nil starts every request cold (tests).
    private let warmPool: WarmPool?
    @Published private(set) var historySummaries: [ChatHistory.Summary] = []
    @Published private(set) var marks = ChatHistory.Marks()
    /// Each chat's messages as last written, so a request that changed nothing doesn't rewrite it.
    private var savedMessages: [UUID: [ChatMessage]] = [:]
    private static let historyQueue = DispatchQueue(label: "local.quickask.history", qos: .utility)
    /// Judges whether an answer leaves the chat on you; nil never asks (tests).
    private let followUpJudge: ((_ question: String, _ answer: String) async -> Bool?)?

    init(preferences: UserDefaults = .standard, history: ChatHistory? = nil, warmPool: WarmPool? = nil,
         followUpJudge: ((_ question: String, _ answer: String) async -> Bool?)? = nil) {
        self.preferences = preferences
        self.history = history
        self.warmPool = warmPool
        self.followUpJudge = followUpJudge
        historySummaries = history?.summaries() ?? []
        marks = history?.marks() ?? .init()
        provider = Provider(rawValue: preferences.string(forKey: "provider") ?? "claude") ?? .claude
        codexPath = preferences.string(forKey: "codexPath") ?? ""
        claudePath = preferences.string(forKey: "claudePath") ?? ""
        codexModel = preferences.string(forKey: "codexModel") ?? ""
        claudeModel = preferences.string(forKey: "claudeModel") ?? ""
        codexEffort = preferences.string(forKey: "codexEffort") ?? ""
        claudeEffort = preferences.string(forKey: "claudeEffort") ?? ""
        codexModelList = preferences.string(forKey: "codexModelList") ?? ""
        claudeModelList = preferences.string(forKey: "claudeModelList") ?? ""
        routingEngine = preferences.string(forKey: "routingEngine") ?? "decisions"
        routingThreshold = preferences.object(forKey: "routingThreshold") as? Double ?? 0.90
        followUpCheck = preferences.object(forKey: "followUpCheck") as? Bool ?? true
        cxmailMCPPath = preferences.string(forKey: "cxmailMCPPath") ?? ""
        cxtasksMCPPath = preferences.string(forKey: "cxtasksMCPPath") ?? ""
        meetingcopilotMCPPath = preferences.string(forKey: "meetingcopilotMCPPath") ?? ""
        alternativeHotkey = preferences.bool(forKey: "alternativeHotkey")
        openAtLogin = preferences.object(forKey: "openAtLogin") as? Bool ?? true
        let first = ChatSession()
        sessions = [first]; activeSessionID = first.id
    }

    /// The chat's layout mode is independent of the settings panel.
    var chatExpanded: Bool { !messages.isEmpty || error != nil || needsContextChoice || delegation != nil || herdrProposal != nil }
    var expanded: Bool { showingSettings || chatExpanded }
    var canSend: Bool { !busy && delegation == nil && herdrProposal == nil && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
    var canTransferToHerdr: Bool { !busy && delegation == nil && herdrProposal == nil && (canSend || messages.contains { $0.complete && (!$0.text.isEmpty || !$0.images.isEmpty) }) }
    func path(for provider: Provider) -> String? {
        ExecutableFinder.find(provider, customPath: provider == .codex ? codexPath : claudePath)
    }

    func send() {
        if busy { enqueue(); return }
        // Anything still queued (its answer ended while you were typing, or in another tab) goes first.
        if let items = queued.removeValue(forKey: activeSessionID) { mergeIntoDraft(items) }
        send(taskReview: false)
    }

    /// Return while the tab showing answers: the draft waits its turn.
    private func enqueue() {
        guard canQueue else {
            if runs[activeSessionID]?.routing != nil { status = "Still checking context. Send again once it’s answering." }
            else if Self.forkTitle(in: draft) != nil || Self.cdTarget(in: draft) != nil { status = "Finish or stop the current request first." }
            return
        }
        queued[activeSessionID, default: []].append(.init(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments))
        draft = ""; attachments = []
        status = "Queued. It goes when this answer finishes."
        focusToken += 1
    }

    func removeQueued(_ id: UUID) {
        queued[activeSessionID]?.removeAll { $0.id == id }
        if queued[activeSessionID]?.isEmpty == true { queued[activeSessionID] = nil }
    }

    /// Queued messages ahead of whatever the draft holds, in the order they were sent.
    private func mergeIntoDraft(_ items: [QueuedMessage]) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = (items.map(\.text) + [typed]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        attachments = Array((items.flatMap(\.attachments) + attachments).prefix(ImageAttachment.perMessage))
    }

    /// A tab's answer ended: its queue goes now if the tab is showing and nothing else needs you.
    /// Deferred a turn, because routing ends one run just before the answer begins the next.
    private func sendQueued(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, id == self.activeSessionID, self.runs[id] == nil, let items = self.queued[id], !items.isEmpty,
                  self.delegation == nil, self.herdrProposal == nil, !self.needsContextChoice else { return }
            guard self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.attachments.isEmpty else {
                self.status = items.count == 1 ? "Your queued message goes with your next one." : "Your \(items.count) queued messages go with your next one."
                return
            }
            self.send()
        }
    }
    func prepareTask() { send(taskReview: true) }
    func prepareHerdr() { send(taskReview: false, herdrReview: true) }
    private func send(taskReview: Bool, herdrReview: Bool = false) {
        guard canSend || (herdrReview && canTransferToHerdr) else { return }
        if !taskReview && !herdrReview, let title = Self.forkTitle(in: draft) { fork(title: title); return }
        if !taskReview && !herdrReview, let path = Self.cdTarget(in: draft) { changeDirectory(to: path); return }
        if let directory, !Self.isDirectory(directory) {
            status = "\(directory.path) is gone. Send !cd with another folder, or !cd alone to go back to your home folder."; focusToken += 1; return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownPage = MarkdownBlocks.latestPage(in: messages.last(where: { $0.role == "assistant" && $0.complete }).map { [$0.text] } ?? [])
        let message = RouteDecision.Message(text: text, history: messages, provider: provider, choice: contextChoice, control: controlEnabled,
                                            taskReview: taskReview, herdrReview: herdrReview, front: candidateWindow, shownPage: shownPage != nil)
        let gates = RouteDecision.gates(message)
        let truth = gates.truth, retried = gates.retried, link = gates.link
        if truth && Self.truthTarget(in: draft)!.isEmpty && attachments.isEmpty && !messages.contains(where: { $0.role == "assistant" && $0.complete && !$0.text.isEmpty }) {
            status = "Nothing to check yet. Put a claim, link or image after /truthcheck."; focusToken += 1; return
        }
        refreshScreenContext?()
        let attached = attachments.map(\.id)
        // The router sees text only; it is told an image came with the question.
        let question = attached.isEmpty ? text : "\(text)\n[The user attached \(attached.count) image(s) to this question.]"
        guard !controlEnabled || !runs.values.contains(where: \.control) else {
            status = "Another tab is controlling an app. Stop it or let it finish first."; return
        }
        let run = begin(control: controlEnabled)
        error = nil; needsContextChoice = false
        status = "Checking context…"
        let choice = contextChoice, window = candidateWindow, displayID = contextDisplayID, windows = contextWindows
        let turn = Turn(sessionID: activeSessionID, text: text, attachments: attachments, provider: provider, control: controlEnabled,
                        target: targetApp, history: messages, previousScope: lastRouteScope, directory: directory)
        let previous = turn.previousScope, provider = turn.provider, history = turn.history
        run.routing = Task { [weak self] in
            guard let self else { return }
            var turn = turn
            // A new chat about one of your projects starts in its folder, as if you had sent `!cd` there.
            var started: URL?
            if RouteDecision.looksForChatFolder(message, gates, directory: turn.directory) {
                let attachments = turn.attachments
                let (workspaces, imageText) = await Task.detached { (ProjectRegistry.workspaces() + ProjectRegistry.localRepos(), HerdrInference.imageText(attachments)) }.value
                started = HerdrInference.chatFolder(question: text, imageText: imageText, workspaces: workspaces).map { URL(fileURLWithPath: $0) }
                turn.directory = started
            }
            let snapshot: ContextSnapshot?
            if RouteDecision.readsScreen(message, gates, started: started), let window, let displayID {
                snapshot = await Task.detached { await ScreenContextCapture.snapshot(window, displayID: displayID) }.value
            } else { snapshot = nil }
            // A live Meeting Copilot meeting brings its tools to Auto, wherever its panel is.
            let meeting = RouteDecision.checksMeeting(message, gates) ? await MeetingCopilot.liveSession() : nil
            guard !Task.isCancelled, self.isCurrent(run) else { return }
            enum Next { case task, herdr, choose(String), answer(RoutePlan), meeting(String) }
            let next: Next
            let step = await RouteDecision.next(message, gates, started: started, directory: turn.directory, meeting: meeting != nil,
                                                images: attached.count, screen: snapshot != nil, routingOff: self.routingEngine == RoutingEngine.offTag,
                                                previous: previous) {
                await Task.detached { (ProjectRegistry.workspaces() + ProjectRegistry.localRepos()).map { ($0.path as NSString).lastPathComponent } }.value
            }
            switch step {
            case .herdr: next = .herdr
            case .task: next = .task
            case .meeting(let kind): next = .meeting(kind)
            case .answer(let plan): next = .answer(plan)
            case .noWindow: self.finishRouting(run); self.report("No screen context is available. Select General chat or a visible app.", in: turn.sessionID); return
            case .unrouted: next = .answer(.unrouted(windows: windows, candidate: snapshot))
            case .router:
                let started = Date()
                var input = RoutingInput(question: question, history: history, imageCount: attached.count, windows: windows,
                                         candidate: snapshot, projects: await Task.detached { ProjectRegistry.projects() }.value,
                                         personalAvailable: provider == .claude)
                if meeting != nil { input.toolConnectors.append(.meetingcopilot) }
                let engine = RoutingEngine(rawValue: self.routingEngine) ?? .decisions
                let outcome = await ContextRouter.assess(input, engine: engine)
                self.routingMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
                switch outcome {
                case .failed(let reason): next = .choose(reason)
                case .signals(let signals):
                    next = .answer(RoutePlan.make(signals, input: input, bars: .forEngine(engine, high: self.routingThreshold), previous: previous))
                }
            }
            guard !Task.isCancelled, self.isCurrent(run) else { return }
            // Routing finishes in the tab it was sent from, from that tab's saved draft when another is showing.
            guard self.draftUnchanged(turn) else {
                self.finishRouting(run); self.status = "Your question changed. Send it again to check its context."; return
            }
            if let started {
                if turn.sessionID == self.activeSessionID { self.directory = started }
                else if let index = self.sessions.firstIndex(where: { $0.id == turn.sessionID }) { self.sessions[index].directory = started }
            }
            // A review card or a context choice needs the tab in front; the question waits in its draft.
            switch next {
            case .herdr, .task, .choose:
                if self.activeSessionID != turn.sessionID {
                    self.finishRouting(run)
                    self.status = "“\(self.tabTitle(turn.sessionID))” needs you. Open it and send again."; return
                }
            default: break
            }
            switch next {
            case .herdr:
                let images = ImageAttachment.recent(in: self.messages.filter(\.complete) + [.init(role: "user", text: text, images: self.attachments)])
                let (projects, imageText) = await Task.detached { (ProjectRegistry.workspaces() + ProjectRegistry.localRepos(), HerdrInference.imageText(images)) }.value
                guard !Task.isCancelled, self.isCurrent(run) else { return }
                guard self.activeSessionID == turn.sessionID, self.draftUnchanged(turn) else {
                    self.finishRouting(run); self.status = "Your question changed. Send it again to prepare the transfer."; return
                }
                self.finishRouting(run); self.herdrDetailsExpanded = false
                var proposal = HerdrProposal.make(question: retried ?? text, history: self.messages, attachments: self.attachments, snapshot: snapshot, provider: self.provider,
                                                  previousDocument: self.lastReferencedDocument, workspaces: projects,
                                                  inferenceHistory: Array(self.messages.dropFirst(self.lastDocumentMessageCount)), imageText: imageText)
                // You asked for Herdr, so it opens now; the card is for a choice only you can make.
                proposal.direct = !proposal.needsTargetChoice
                self.herdrProposal = proposal
                if proposal.direct { self.confirmHerdr() }
                else { self.status = "Choose where the Herdr session should work." }
            case .choose(let reason):
                self.finishRouting(run)
                self.contextLabel = "Choose context"; self.needsContextChoice = true; self.status = reason
            case .task:
                self.finishRouting(run)
                self.submittedHandoff = nil
                self.delegation = .make(question: text, history: self.messages, snapshot: snapshot)
                self.status = attached.isEmpty ? "Review the task before creating it."
                    : "Review the task before creating it. Attached images aren’t included in the task."
            case .meeting(let kind):
                self.finishRouting(run)
                self.askMeetingCopilot(kind, turn: turn)
            case .answer(var plan):
                // Margin attaches only when the user names it, never by the router's judgment.
                if plan.scope != .personal && Self.mentionsMargin(text) && plan.connector != .margin && !plan.tools.contains(.margin) { plan.tools.append(.margin) }
                // Naming the copilot or "this meeting" while one is live brings its tools, router or not.
                if meeting != nil && MeetingCopilot.mentioned(text) && !plan.tools.contains(.meetingcopilot) {
                    if plan.scope == .personal && choice == .auto && !link { plan = .general("This is about your meeting in progress.") }
                    if plan.scope != .personal { plan.tools.append(.meetingcopilot) }
                }
                await self.answer(plan, snapshot: snapshot, windows: windows, displayID: displayID, run: run, turn: turn)
            }
        }
    }

    private func finishRouting(_ run: Run) {
        guard isCurrent(run) else { return }
        run.routing = nil; endRun(run)
    }

    /// Starts a run in a tab (the one showing by default), replacing any it already had.
    private func begin(in sessionID: UUID? = nil, control: Bool = false) -> Run {
        let run = Run(sessionID: sessionID ?? activeSessionID)
        run.control = control
        runs[run.sessionID] = run
        return run
    }

    /// Whether the tab a turn came from still holds its question: the live draft when the tab
    /// is showing, its saved draft when another tab is.
    private func draftUnchanged(_ turn: Turn) -> Bool {
        let (draft, attachments) = turn.sessionID == activeSessionID ? (self.draft, self.attachments)
            : sessions.first { $0.id == turn.sessionID }.map { ($0.draft, $0.attachments) } ?? ("", [])
        guard sessions.contains(where: { $0.id == turn.sessionID }) else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) == turn.text && attachments.map(\.id) == turn.attachments.map(\.id)
    }

    /// Clears a tab's draft once its question is sent, or puts it back after a failure.
    private func setDraft(of id: UUID, _ text: String, _ images: [ImageAttachment]) {
        if id == activeSessionID { draft = text; attachments = images }
        else if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].draft = text; sessions[index].attachments = images }
    }

    /// Records what a tab's answer was routed over, for its follow-ups.
    private func setRoute(of id: UUID, scope: RouteScope, document: String? = nil, messageCount: Int = 0) {
        if id == activeSessionID {
            lastRouteScope = scope
            if let document { lastReferencedDocument = document; lastDocumentMessageCount = messageCount }
        } else if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].lastRouteScope = scope
            if let document { sessions[index].lastReferencedDocument = document; sessions[index].lastDocumentMessageCount = messageCount }
        }
    }

    /// A problem with a tab's request: on its card when the tab is showing, in the status line otherwise.
    private func report(_ message: String, in id: UUID) {
        if id == activeSessionID { error = message } else { status = "“\(tabTitle(id))”: \(message)" }
    }

    private func tabTitle(_ id: UUID) -> String { sessions.first { $0.id == id }.map(title(of:)) ?? "another tab" }

    /// Whether `run` is still its tab's request (not stopped, timed out or replaced).
    private func isCurrent(_ run: Run) -> Bool { runs[run.sessionID] === run }

    /// Ends `run` and writes its chat to history.
    private func endRun(_ run: Run) {
        guard isCurrent(run) else { return }
        run.timeout?.cancel(); run.timeout = nil
        runs[run.sessionID] = nil
        if !(popupVisible && run.sessionID == activeSessionID) { updateMarks { $0.unread.insert(run.sessionID) } }
        recordChat(run.sessionID)
        checkFollowUp(run.sessionID)
        sendQueued(run.sessionID)
    }

    /// Gathers what the plan sends (the target window's content, a screenshot, the app's
    /// tools) and starts the answer.
    private func answer(_ plan: RoutePlan, snapshot: ContextSnapshot?, windows: [ContextWindow], displayID: UInt32?, run: Run, turn: Turn) async {
        var target = snapshot, screenshot: ImageAttachment?, note: String?
        let showing = { self.activeSessionID == turn.sessionID }
        if plan.scope == .personal {
            guard turn.provider == .claude else { finishRouting(run); report("My setup runs your Claude Code setup. Select Claude, then send again.", in: turn.sessionID); return }
            // A reply about a page carries a picture of it as it looks in the reply, as a screen question carries the screen.
            let page = MarkdownBlocks.latestPage(in: turn.history.last(where: { $0.role == "assistant" && $0.complete }).map { [$0.text] } ?? [])
            var shot: ImageAttachment?
            if let page { shot = await PageRegistry.shared.snapshot(of: page) }
            guard !Task.isCancelled, isCurrent(run) else { return }
            finishRouting(run)
            if showing() { contextLabel = plan.label }
            setRoute(of: turn.sessionID, scope: .personal)
            startAnswer(turn, context: nil, screenshot: shot, personal: true)
            return
        }
        if plan.scope != .general, let window = plan.window, window.id != snapshot?.windowID, let displayID {
            if showing() { status = "Reading \(window.appName)…" }
            target = await Task.detached { await ScreenContextCapture.snapshot(window, displayID: displayID) }.value
        }
        if plan.screenshot, let displayID {
            if showing() { status = "Capturing the screen…" }
            screenshot = await Task.detached { await ScreenContextCapture.displayScreenshot(displayID) }.value
            if screenshot == nil { note = "Screen Recording is off for Quick Ask, so only the screen’s text was sent." }
        }
        guard !Task.isCancelled, isCurrent(run) else { return }
        finishRouting(run)
        var context: GatewayConfiguration?, screen: ScreenPayload?
        if plan.scope != .general {
            guard let target else { report("No screen context is available. Select General chat or a visible app.", in: turn.sessionID); return }
            screen = ScreenPayload(snapshot: target, plan: plan, windows: windows, screenshotAttached: screenshot != nil)
        }
        // Onyx's page tools read a local file; a remote page gets its passage or excerpt only.
        let connectors = ((plan.scope == .general ? [] : plan.connector.map { [$0] } ?? []) + plan.tools)
            .filter { $0 != .onyx || target?.selection?.records["document_path"] != nil }
        if !connectors.isEmpty || (turn.control && plan.scope != .general) {
            var launches: [String: MCPLaunch] = [:]
            for connector in connectors {
                guard let launch = connector.launch(preferences: preferences) else {
                    report("\(connector.title) isn’t registered in your Claude config (~/.claude.json), so Quick Ask can’t start it.", in: turn.sessionID); return
                }
                launches[connector.rawValue] = launch
            }
            // Writes: the window's app per the plan; Margin always (it was named); other tools on a clear action.
            let readOnly = connectors.filter { connector in
                connector == plan.connector && plan.scope != .general ? !plan.writes : connector != .margin && !plan.toolWrites
            }
            let screenless = plan.scope == .general || target == nil
            context = GatewayConfiguration(snapshot: screenless ? Self.placeholderSnapshot(displayID: displayID) : target!, connectors: connectors,
                                           executables: launches.mapValues(\.command), desktopControl: turn.control && !screenless,
                                           writes: true, readOnly: readOnly, launches: launches, screenless: screenless)
        }
        // Onyx's window is always titled Onyx; its page's title says what was read.
        if showing() { contextLabel = plan.label(screenshotSent: screenshot != nil, item: target?.connector == .onyx && plan.connector == .onyx ? target?.selection?.label : nil) }
        setRoute(of: turn.sessionID, scope: plan.scope)
        startAnswer(turn, context: context, screen: screen, screenshot: screenshot)
        if plan.scope != .general, let document = target?.selection?.records["document_path"] ?? target?.document, !document.isEmpty {
            var count = 0
            withMessages(of: turn.sessionID) { count = $0.count }
            setRoute(of: turn.sessionID, scope: plan.scope, document: document, messageCount: count)
        }
        if let note, showing(), error == nil { status = note }
    }

    /// "Add this to Margin", "put it in my Margin", "a Margin note": the user names Margin.
    /// A bare "margin" (profit margin, CSS margin) does not attach it.
    nonisolated static func mentionsMargin(_ text: String) -> Bool {
        text.range(of: "(?i)\\b(?:to|in|into|on|from|my|the)\\s+(?:my\\s+|the\\s+)?margin\\b(?!\\s*(?:of|between|for error))", options: .regularExpression) != nil
            || text.range(of: "(?i)\\bmargin\\s+(?:notes?|notebook|folder|app)\\b", options: .regularExpression) != nil
    }

    /// "Just control my browser and search", "look it up in Zen": the user wants their browser driven,
    /// not a screen reading of it, which answered "I can't control your browser" (2026-10-21).
    /// A question about the browser itself ("how do I open devtools in Chrome", "find the setting in
    /// Chrome", "does this site work on Safari") is not a request to drive it.
    nonisolated static func asksToUseBrowser(_ text: String) -> Bool {
        let browser = "(?:browser|zen|chrome|safari|firefox)"
        let drive = "\\b(?:control|drive|operate|take over|go into|open up)\\s+(?:my|the)\\s+\(browser)\\b|\\b(?:use|open)\\s+(?:my\\s+|the\\s+)?\(browser)\\s+(?:to|and)\\b"
        let within = "\\b(?:search|look(?: it| that| them)? up|look for|find|browse|check|go|open|navigate|google|pull (?:it |that |them )?up)\\b.{0,40}\\b(?:in|on|with|through|using)\\s+(?:my\\s+|the\\s+)?\(browser)\\b"
        let aboutBrowser = "\\b(?:how (?:do|can|would|to)|where (?:is|are|do)|is there a way)\\b|\\b(?:settings?|preferences|devtools|developer tools|extensions?|cache|cookies)\\b|\\b(?:works?|working|supported|compatible|render(?:s|ing)?)\\s+(?:in|on|with)\\s+\(browser)"
        guard [drive, within].contains(where: { text.range(of: "(?i)" + $0, options: .regularExpression) != nil }) else { return false }
        return text.range(of: "(?i)" + aboutBrowser, options: .regularExpression) == nil
    }

    /// The last reply drove the user's browser (zen-ext) and the window in front is a browser: a question
    /// about it is a continuation, which only My setup can act on.
    nonisolated static func continuesBrowserWork(history: [ChatMessage], front: ContextWindow?) -> Bool {
        guard let front, ["app.zen-browser.zen", "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"].contains(front.bundleID),
              let last = history.last(where: { $0.role == "assistant" && $0.complete }) else { return false }
        return last.tools?.contains { $0.hasPrefix("zen-ext") } == true
    }

    /// A request for something to look at rather than read: a page, mockup, chart or artifact.
    nonisolated static func asksForPage(_ text: String) -> Bool {
        let thing = "(?:html|web ?page|page|site|artifact|mock-?ups?|wireframe|landing page|dashboard|one-pager|chart|graph|diagram|infographic|visuali[sz]ation|interactive|explainer|slides?|prototype)"
        // "Make a chart …", not "make this chart bigger", which is about something on screen.
        let make = "\\b(?:make|build|create|draft|design|generate|whip up|put together|render|code up|sketch)(?: me| us)? (?:a|an|some)\\b.{0,40}\\b\(thing)\\b"
        let mockUp = "\\bmock (?:me |us )?up\\b"
        let asOne = "\\b(?:as|in|into) (?:an? |the )?(?:html|artifact|web ?page|interactive page)\\b"
        return [make, mockUp, asOne].contains { text.range(of: "(?i)" + $0, options: .regularExpression) != nil }
    }

    /// A pasted link on its own ("https://…", "thoughts? https://…"), or a short request to
    /// open or read one. A link inside a longer pasted email or note does not count.
    nonisolated static func asksToOpenLink(_ text: String) -> Bool {
        let url = "(?i)\\bhttps?://[^\\s<>\"]+"
        guard text.range(of: url, options: .regularExpression) != nil else { return false }
        let rest = text.replacingOccurrences(of: url, with: " ", options: .regularExpression)
        let words = rest.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.count
        if words <= 4 { return true }
        return words <= 30 && rest.range(of: "(?i)\\b(?:open|read|fetch|visit|check(?: out)?|look at|go to|summari[sz]e|tl;?dr|what(?:'s| is| does)\\b.{0,20}\\b(?:this|that|it|link|post|page|article|thread)|is (?:this|that|it) (?:legit|true|real|bs|right|accurate|correct))\\b", options: .regularExpression) != nil
    }

    /// Stands in for a window on tool-only routes: Quick Ask itself, which the
    /// gateway's lease check can verify and which no tool ever acts on.
    nonisolated static func placeholderSnapshot(displayID: UInt32?) -> ContextSnapshot {
        let me = NSRunningApplication.current
        return ContextSnapshot(displayID: displayID ?? 0, windowID: 0, pid: me.processIdentifier, bundleID: me.bundleIdentifier ?? "local.quickask.desktop",
                               appName: "QuickAsk", windowTitle: "", capturedAt: Date().timeIntervalSince1970,
                               launchTime: me.launchDate?.timeIntervalSince1970 ?? 0, selection: nil, text: "", document: "")
    }

    /// The task review opens only when the user explicitly asks for a task ("create a task",
    /// "file this as a task", "turn this email into a task") or picks it from the context menu.
    /// The router never chooses it, and questions about tasks ("how do I create a task?") don't count.
    nonisolated static func requestsTaskCreation(_ text: String) -> Bool {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.range(of: "(?i)^(how|what|why|when|where|which|who)\\b", options: .regularExpression) != nil { return false }
        let article = "(?:a |an |new |another |the )*(?:cxtasks |tracked )?"
        return request.range(of: "(?i)\\b(?:create|file|add|make|open|log)\\s+(?:me\\s+)?\(article)tasks?\\b", options: .regularExpression) != nil
            || request.range(of: "(?i)\\b(?:into|as)\\s+\(article)tasks?\\b", options: .regularExpression) != nil
            || request.range(of: "(?i)\\b(?:create|file|add|make|log)\\b.*\\b(?:in|to) cxtasks\\b", options: .regularExpression) != nil
    }
    func cancelDelegation() {
        guard !busy else { return }
        delegation = nil; submittedHandoff = nil; error = nil; status = "Task creation cancelled. Your question is preserved."; focusToken += 1
    }
    func cancelHerdr() {
        guard !busy else { return }
        herdrProposal = nil; error = nil; status = "Transfer cancelled. Your chat and question are preserved."; focusToken += 1
    }
    /// My setup judged the request too big for Quick Ask and offered Herdr: the one review card you didn't ask for.
    func suggestHerdr(_ instruction: String, in sessionID: UUID) {
        Task { [weak self] in
            guard let images = self.map({ ImageAttachment.recent(in: $0.messages.filter(\.complete)) }) else { return }
            let (projects, imageText) = await Task.detached { (ProjectRegistry.workspaces() + ProjectRegistry.localRepos(), HerdrInference.imageText(images)) }.value
            guard let self, self.activeSessionID == sessionID, !self.busy, self.herdrProposal == nil, self.delegation == nil else { return }
            self.herdrDetailsExpanded = false
            self.herdrProposal = .make(question: instruction, history: self.messages, attachments: [], snapshot: nil, provider: self.provider,
                                       previousDocument: self.lastReferencedDocument, workspaces: projects,
                                       inferenceHistory: Array(self.messages.dropFirst(self.lastDocumentMessageCount)), imageText: imageText)
            self.status = "This is a bigger build. Continue it in Herdr?"
        }
    }
    func chooseHerdrFolder() {
        guard !busy, herdrProposal?.submissionAttempted == false else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { herdrProposal?.workspace = url.path; herdrProposal?.targetChoices = [] }
    }
    func chooseHerdrDocument() {
        guard !busy, herdrProposal?.submissionAttempted == false else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            herdrProposal?.referenceDocument = url.resolvingSymlinksInPath().path
            herdrProposal?.workspace = url.resolvingSymlinksInPath().deletingLastPathComponent().path
            herdrProposal?.targetChoices = []
        }
    }
    func selectHerdrTarget(_ target: HerdrTarget) {
        guard !busy else { return }
        herdrProposal?.workspace = target.folder; herdrProposal?.referenceDocument = target.document
        herdrProposal?.targetChoices = []
    }
    func confirmHerdr() {
        guard !busy, let proposal = herdrProposal, !proposal.submissionAttempted else { return }
        guard let executable = path(for: proposal.provider) else {
            herdrProposal?.direct = false; error = "\(proposal.provider.detail) is unavailable. Configure it in Settings."; return
        }
        let model = proposal.provider == .codex ? codexModel : claudeModel
        error = nil; status = "Checking the Herdr handoff…"
        let run = begin()
        run.routing = Task { [weak self] in
            guard let self else { return }
            do {
                self.refreshScreenContext?()
                let display = self.contextDisplayID
                try await Task.detached { try TaskDelegation.revalidate(proposal.snapshot, displayID: display) }.value
                try Task.checkCancellation()
                guard self.isCurrent(run), self.activeSessionID == run.sessionID else { return }
                self.handoffInFlight = true; self.herdrProposal?.submissionAttempted = true
                self.status = "Opening \(proposal.provider.title) in Herdr…"
                let router = self.herdrRouter, root = self.herdrSessions
                let result = try await Task.detached { try HerdrHandoff.launch(proposal, executable: executable, model: model, router: router, root: root) }.value
                if result.confirmed {
                    self.messages.append(.init(role: "user", text: proposal.instruction))
                    self.messages.append(.init(role: "assistant", text: result.message))
                    self.draft = ""; self.attachments = []; self.herdrProposal = nil
                } else { self.error = result.message; self.herdrProposal?.direct = false }
                self.status = result.message
            } catch {
                if self.isCurrent(run) {
                    self.error = error.localizedDescription; self.status = "Herdr handoff needs attention"; self.herdrProposal?.direct = false
                    self.herdrProposal?.submissionAttempted = FileManager.default.fileExists(atPath: self.herdrSessions.appendingPathComponent(proposal.id.uuidString.lowercased()).appendingPathComponent("attempt.json").path)
                }
            }
            self.handoffInFlight = false
            if self.isCurrent(run) { run.routing = nil; self.endRun(run); self.focusToken += 1 }
        }
    }
    func chooseTaskFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { delegation?.workspace = url.path }
    }
    func chooseTaskDocument() {
        guard !busy, delegation?.documentPath.isEmpty == true else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { delegation?.documentPath = url.path; delegation?.workspace = url.deletingLastPathComponent().path }
    }
    func confirmDelegation() {
        guard !busy, let proposal = delegation else { return }
        error = nil; status = "Checking the task source…"
        let run = begin()
        run.routing = Task { [weak self] in
            guard let self else { return }
            do {
                self.refreshScreenContext?()
                let display = self.contextDisplayID
                let reviewed: TaskHandoffRequest
                if let submitted = self.submittedHandoff { reviewed = submitted }
                else {
                    reviewed = try await Task.detached {
                        try TaskDelegation.revalidate(proposal.snapshot, displayID: display)
                        return try TaskDelegation.request(proposal)
                    }.value
                }
                try Task.checkCancellation()
                guard self.isCurrent(run), self.activeSessionID == run.sessionID else { return }
                let pid = try await TaskDelegation.ensureCXTasks(executable: AppConnector.cxtasks.executable(preferences: self.preferences))
                try Task.checkCancellation()
                guard self.isCurrent(run), self.activeSessionID == run.sessionID else { return }
                if self.submittedHandoff == nil { try await Task.detached { try TaskDelegation.revalidate(proposal.snapshot, displayID: display) }.value }
                try Task.checkCancellation()
                guard self.isCurrent(run), self.activeSessionID == run.sessionID else { return }
                self.handoffInFlight = true; self.delegation?.submissionAttempted = true
                self.submittedHandoff = reviewed
                self.lastTaskLink = "cxtasks://task/\(reviewed.request_id)"
                self.status = "Creating the tracked task…"
                let result = try await Task.detached { try TaskDelegation.submit(reviewed, pid: pid) }.value
                self.messages.append(.init(role: "user", text: proposal.question))
                self.messages.append(.init(role: "assistant", text: result.transcript))
                if result.task_id != nil { self.draft = ""; self.attachments = []; self.delegation = nil; self.submittedHandoff = nil }
                else { self.error = result.message }
                self.lastTaskLink = result.link
                self.status = result.message
            } catch {
                if self.isCurrent(run) { self.error = error.localizedDescription; self.status = "Task handoff needs attention" }
            }
            self.handoffInFlight = false
            if self.isCurrent(run) { run.routing = nil; self.endRun(run); self.focusToken += 1 }
        }
    }

    func selectContext(_ choice: ContextChoice) {
        guard !busy else { return }
        contextChoice = choice; needsContextChoice = false; error = nil; delegation = nil; submittedHandoff = nil; herdrProposal = nil
        if choice == .general { controlEnabled = false; contextLabel = "General chat" }
        else if choice == .personal { controlEnabled = false; contextLabel = "My setup" }
        else { refreshScreenContext?() }
    }

    func displayChanged() {
        if handoffInFlight { status = herdrProposal != nil ? "Herdr handoff was submitted. Waiting for its result." : "Task handoff was submitted. Waiting for CXTasks to confirm its result."; return }
        // Requests still deciding on context are dropped; answers already reading the screen lose its tools.
        // A plain chat answering in any tab carries on.
        for run in runs.values {
            if run.handle == nil { run.routing?.cancel(); run.routing = nil; endRun(run) }
            else if run.screen { run.handle?.revokeTools() }
        }
        if contextChoice != .general && contextChoice != .personal { contextChoice = .auto }
        needsContextChoice = false
        if delegation?.snapshot != nil { delegation = nil; submittedHandoff = nil }
        if herdrProposal?.snapshot != nil { herdrProposal = nil }
        status = "Screen context changed. Send a fresh request before another action."
    }

    /// The user approved the actions a reply's permission check refused: My setup runs again with a
    /// message that names each one. Claude's auto mode clears an action the user named themselves
    /// (an allow rule can't: it drops broad `ssh` rules, and an exact one misses a regenerated command).
    func approveBlocked(_ id: UUID) {
        guard !busy, delegation == nil, herdrProposal == nil,
              let actions = messages.first(where: { $0.id == id })?.blocked, !actions.isEmpty else { return }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else {
            status = "Send or clear your draft first, then approve."; return
        }
        guard path(for: .claude) != nil else { status = "Claude Code wasn’t found. Set its path in Settings."; return }
        let text = Self.approvalText(actions)
        withMessages(of: activeSessionID) { messages in
            if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].blocked = nil }
        }
        draft = text
        let turn = Turn(sessionID: activeSessionID, text: text, attachments: [], provider: .claude, control: false,
                        target: nil, history: messages, previousScope: lastRouteScope, directory: directory)
        setRoute(of: activeSessionID, scope: .personal)
        startAnswer(turn, context: nil, personal: true)
    }

    /// A reply on a route without hands said it couldn't: its question runs again on My setup, in its place.
    func runWithSetup(_ id: UUID) {
        guard !busy, delegation == nil, herdrProposal == nil, messages.last?.id == id,
              let index = messages.firstIndex(where: { $0.id == id }), index > 0, messages[index - 1].role == "user" else { return }
        guard path(for: .claude) != nil else { status = "Claude Code wasn’t found. Set its path in Settings."; return }
        let question = messages[index - 1]
        withMessages(of: activeSessionID) { $0.removeAll { $0.id == id || $0.id == question.id } }
        let turn = Turn(sessionID: activeSessionID, text: question.text, attachments: question.images, provider: .claude, control: false,
                        target: nil, history: messages, previousScope: lastRouteScope, directory: directory)
        setRoute(of: activeSessionID, scope: .personal)
        contextLabel = "My setup"
        startAnswer(turn, context: nil, personal: true, rerun: true)
    }

    nonisolated static func approvalText(_ actions: [String]) -> String {
        // A fence longer than any backtick run inside the commands, so none can close it early.
        let longest = actions.flatMap { $0.split(whereSeparator: { $0 != "`" }).map(\.count) }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let list = actions.map { "\(fence)\n\($0)\n\(fence)" }.joined(separator: "\n\n")
        return "I approve \(actions.count == 1 ? "this action" : "these actions") your permission check blocked. Run \(actions.count == 1 ? "it" : "them") again and carry on:\n\n\(list)"
    }

    /// `rerun`: the message was already sent and is running again elsewhere (Escalation), so the draft,
    /// which may hold your next message by now, is left alone.
    private func startAnswer(_ turn: Turn, context: GatewayConfiguration?, screen: ScreenPayload? = nil, screenshot: ImageAttachment? = nil, personal: Bool = false, rerun: Bool = false) {
        let tab = turn.sessionID, provider = turn.provider, controlEnabled = turn.control, targetApp = turn.target
        func fail(_ message: String) { report(message, in: tab) }
        if let context {
            for connector in context.connectors where !connector.isLocal {
                guard FileManager.default.isExecutableFile(atPath: context.launch(connector).command) else {
                    fail("\(connector.title) MCP is unavailable. Configure its executable path in Settings."); return
                }
            }
        }
        if controlEnabled {
            guard targetApp != nil else { fail("Open the app you want to control, then summon QuickAsk with Option–Space."); return }
            guard AXIsProcessTrusted() else { fail("Enable Accessibility for QuickAsk in System Settings → Privacy & Security, then retry. Permission buttons are in QuickAsk Settings."); return }
        }
        let executable = path(for: provider)
        guard let executable else {
            fail("\(provider.detail) wasn’t found. Install and sign in to the CLI, or set its absolute path in Settings.")
            return
        }
        guard rerun || draftUnchanged(turn) else { status = "Your question changed. Send it again to check its context."; return }
        let text = turn.text
        var messages: [ChatMessage] = []
        withMessages(of: tab) { messages = $0 }
        // A screenshot joins the message's images, so it shows in the chat and follow-ups can use it.
        let pending = ChatMessage(role: "user", text: text, images: turn.attachments + (screenshot.map { [$0] } ?? []))
        let images = ImageAttachment.recent(in: messages + [pending])
        // A chat answer without tools, app control or My setup may search the web, screen or not; Claude only.
        let web = provider == .claude && context == nil && !controlEnabled && !personal
        // A route without hands hands the request to My setup rather than refusing it; Claude only, since My setup is Claude.
        let escalate = provider == .claude && !personal && !controlEnabled
        // My setup can hand an image on only as a file; the answer still sees it without one.
        let imageFiles = personal && !images.isEmpty ? ImageAttachment.standardStore.flatMap { try? ImageAttachment.store(images, in: $0) } ?? [] : []
        let prompt: String
        let directory = personal ? turn.directory : nil
        do { prompt = try PromptBuilder.make(messages: messages + [pending], target: controlEnabled ? targetApp : nil, context: context, screen: screen, personal: personal, web: web, imageFiles: imageFiles, directory: directory, escalate: escalate) + (voiceActive ? PromptBuilder.voiceNote : "") }
        catch { fail(error.localizedDescription); return }
        guard prompt.utf8.count < 200_000 else {
            fail("This chat is too long to send. Copy what you need and start a new chat.")
            return
        }
        if !rerun { setDraft(of: tab, "", []) }
        if tab == activeSessionID { error = nil; status = "Connecting to \(provider.title)…" }
        let run = begin(in: tab, control: controlEnabled)
        run.screen = controlEnabled || context.map { !$0.screenless } == true
        let reply = ChatMessage(role: "assistant", text: "", provider: provider, complete: false)
        withMessages(of: tab) { $0.append(pending); $0.append(reply) }
        let onEvent: (ProviderEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(run) else { return }
                let showing = self.activeSessionID == run.sessionID
                switch event {
                case .text(let content):
                    // A reply passing the request to My setup is only its marker: nothing to show or say.
                    if escalate && Escalation.pending(content) { break }
                    if self.voiceActive { self.voice.received(content, for: reply.id) }
                    self.revealText(content, into: reply.id, run: run)
                    if showing { self.status = self.activity(of: reply.id, in: run.sessionID).current?.summary ?? "\(provider.title) is answering…" }
                case .status(let value):
                    if showing && self.activity(of: reply.id, in: run.sessionID).current == nil { self.status = value }
                case .activity(let step):
                    var log: [ActivityStep] = []
                    self.withMessages(of: run.sessionID) { messages in
                        guard let index = messages.firstIndex(where: { $0.id == reply.id }) else { return }
                        var steps = messages[index].activity ?? []
                        steps.upsert(step)
                        messages[index].activity = steps; log = steps
                    }
                    // The footer names the step under way; between steps, what the reply is doing.
                    if showing {
                        let answering = !run.reveal.target.isEmpty
                        self.status = log.current?.summary ?? (answering ? "\(provider.title) is answering…" : "Thinking with \(provider.title)…")
                    }
                case .tool(let name):
                    self.withMessages(of: run.sessionID) { messages in
                        if let index = messages.firstIndex(where: { $0.id == reply.id }), messages[index].tools?.contains(name) != true {
                            messages[index].tools = (messages[index].tools ?? []) + [name]
                        }
                    }
                case .card(let card):
                    self.withMessages(of: run.sessionID) { messages in if let index = messages.firstIndex(where: { $0.id == reply.id }) { messages[index].cards.append(card) } }
                case .blocked(let actions):
                    self.withMessages(of: run.sessionID) { messages in
                        if let index = messages.firstIndex(where: { $0.id == reply.id }) { messages[index].blocked = actions }
                    }
                case .failure(let message): if showing { self.error = message }
                }
            }
        }
        let onComplete: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(run) else { return }
                run.timeout?.cancel(); run.timeout = nil
                run.handle = nil
                switch result {
                case .success(let answer):
                    if escalate && Escalation.requested(answer) {
                        // This route has no hands for the request: the same message runs on My setup instead.
                        run.cancelReveal()
                        self.runs[run.sessionID] = nil
                        self.withMessages(of: run.sessionID) { $0.removeAll { $0.id == reply.id || $0.id == pending.id } }
                        self.setRoute(of: tab, scope: .personal)
                        if tab == self.activeSessionID { self.contextLabel = "My setup" }
                        self.startAnswer(turn, context: nil, personal: true, rerun: true)
                        return
                    }
                    let suggestion = HerdrHandoff.suggestion(in: answer)
                    let content = suggestion?.text ?? answer
                    // The last words finish revealing (a fraction of a second) before the
                    // answer is complete; Stop meanwhile keeps what is showing.
                    self.revealText(content, into: reply.id, run: run) { [weak self] in
                        guard let self, self.isCurrent(run) else { return }
                        self.withMessages(of: run.sessionID) { messages in
                            if let index = messages.firstIndex(where: { $0.id == reply.id }) {
                                messages[index].text = content; messages[index].complete = true
                                messages[index].activity?.settle(.done)
                                // It refused anyway: offer the route that can do it.
                                if escalate && Escalation.disowns(content) { messages[index].offersSetup = true }
                            }
                        }
                        let elsewhere = self.activeSessionID != run.sessionID
                        self.endRun(run) // last: ending the request writes the finished chat to history
                        self.status = elsewhere ? "Answered in “\(self.sessions.first { $0.id == run.sessionID }.map(self.title(of:)) ?? "another tab")”" : "Ready when you are"
                        if let suggestion, !elsewhere { self.suggestHerdr(suggestion.instruction, in: run.sessionID) }
                        self.focusToken += 1
                    }
                    return
                case .failure(let failure):
                    // Everything that arrived stays in the partial answer.
                    let target = run.reveal.target, revealing = run.revealMessageID == reply.id
                    self.withMessages(of: run.sessionID) { messages in
                        if revealing, let index = messages.firstIndex(where: { $0.id == reply.id }) { messages[index].text = target }
                        if let index = messages.firstIndex(where: { $0.id == pending.id }) { messages[index].complete = false }
                        if let index = messages.firstIndex(where: { $0.id == reply.id }) { messages[index].activity?.settle(.failed) }
                        // A reply that did work keeps its log, so what already ran stays visible.
                        messages.removeAll { $0.id == reply.id && $0.text.isEmpty && ($0.activity ?? []).isEmpty }
                    }
                    run.cancelReveal()
                    let showing = self.activeSessionID == run.sessionID
                    self.endRun(run)
                    if showing {
                        self.error = failure.localizedDescription
                        self.status = "Request failed"
                        if self.draft.isEmpty && self.attachments.isEmpty { self.draft = text; self.attachments = pending.images.filter { $0.id != screenshot?.id } }
                    } else {
                        if let index = self.sessions.firstIndex(where: { $0.id == tab }), self.sessions[index].draft.isEmpty, self.sessions[index].attachments.isEmpty {
                            self.setDraft(of: tab, text, pending.images.filter { $0.id != screenshot?.id })
                        }
                        self.status = "A request in another tab failed: \(failure.localizedDescription)"
                    }
                }
                self.focusToken += 1
            }
        }
        run.handle = CLIRunner.start(provider: provider, executable: executable,
                                  model: model(for: provider), effort: effort(for: provider), prompt: prompt, images: images, personal: personal, web: web, directory: directory,
                                  target: controlEnabled ? targetApp : nil,
                                  desktopExecutable: Bundle.main.executableURL?.path,
                                  context: context, pool: warmPool,
                                  onEvent: onEvent, onComplete: onComplete)
        // A My setup session can do multi-step work, so it gets longer than a chat answer, as
        // does app control (its lease is ten minutes); a Studio Coach answer measures audio and
        // asks its own model before this one replies.
        let minutes = personal ? 15 : controlEnabled ? Int(GatewayConfiguration.controlLeaseSeconds / 60)
            : context.map { $0.connectors.contains(.studiocoach) || $0.connectors.contains(.meetingcopilot) } == true ? 7 : 3
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(run) else { return }
            let showing = self.activeSessionID == run.sessionID
            self.stop(run)
            let message = "The request timed out after \(minutes) minutes. Changes it already made stay made; check before retrying."
            if showing { self.error = message } else { self.status = "A request in another tab timed out." }
        }
        run.timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(minutes * 60), execute: deadline)
    }

    /// Shows `content` (all the answer received so far) through the pacer. `finish` runs
    /// once all of it is showing.
    private func revealText(_ content: String, into message: UUID, run: Run, finish: (() -> Void)? = nil) {
        if run.revealMessageID != message { run.cancelReveal(); run.revealMessageID = message }
        run.reveal.receive(content)
        if let finish { run.reveal.finish(); run.finishReveal = finish }
        guard run.revealTimer == nil else { return }
        stepReveal(run)
        guard run.revealTimer == nil, !run.reveal.caughtUp else { return }
        let timer = Timer(timeInterval: StreamReveal.tick, repeats: true) { [weak self, weak run] _ in
            MainActor.assumeIsolated { if let run { self?.stepReveal(run) } }
        }
        // Common modes keep it revealing while the reader scrolls the transcript.
        RunLoop.main.add(timer, forMode: .common)
        run.revealTimer = timer
    }

    private func stepReveal(_ run: Run) {
        guard isCurrent(run) else { run.cancelReveal(); return }
        if let text = run.reveal.step(), let id = run.revealMessageID {
            withMessages(of: run.sessionID) { messages in if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text = text } }
        }
        guard run.reveal.caughtUp else { return }
        // Idle until more text arrives.
        run.revealTimer?.invalidate(); run.revealTimer = nil
        if let finish = run.finishReveal { run.finishReveal = nil; finish() }
    }

    /// "How am I doing?" during a live meeting: the copilot's own check-in, called on its MCP with
    /// no model in front, so it answers as fast as its button does. The reply is the copilot's.
    private func askMeetingCopilot(_ kind: String, turn: Turn) {
        guard let launch = AppConnector.meetingcopilot.launch(preferences: preferences), FileManager.default.isExecutableFile(atPath: launch.command) else {
            report("Meeting Copilot MCP is unavailable. Configure its executable path in Settings.", in: turn.sessionID); return
        }
        let text = turn.text
        let pending = ChatMessage(role: "user", text: text)
        let reply = ChatMessage(role: "assistant", text: "", source: AppConnector.meetingcopilot.rawValue, complete: false)
        setDraft(of: turn.sessionID, "", turn.attachments)
        let run = begin(in: turn.sessionID)
        withMessages(of: turn.sessionID) { $0.append(pending); $0.append(reply) }
        setRoute(of: turn.sessionID, scope: .general)
        if turn.sessionID == activeSessionID {
            error = nil; contextLabel = "Meeting Copilot · \(MeetingCopilot.pulseTitles[kind] ?? kind)"; status = "Meeting Copilot is checking…"
        }
        Task { [weak self] in
            let outcome: Result<String, Error> = await Task.detached { Result { try MeetingCopilot.pulse(kind, launch: launch) } }.value
            guard let self, self.isCurrent(run) else { return }
            let showing = self.activeSessionID == run.sessionID
            switch outcome {
            case .success(let answer):
                self.withMessages(of: run.sessionID) { messages in if let index = messages.firstIndex(where: { $0.id == reply.id }) { messages[index].text = answer; messages[index].complete = true } }
                self.endRun(run)
                self.status = showing ? "Ready when you are" : "Meeting Copilot answered in another tab"
            case .failure(let failure):
                self.withMessages(of: run.sessionID) { messages in
                    messages.removeAll { $0.id == reply.id }
                    if let index = messages.firstIndex(where: { $0.id == pending.id }) { messages[index].complete = false }
                }
                self.endRun(run)
                if showing { self.error = failure.localizedDescription; self.status = "Request failed"; if self.draft.isEmpty { self.draft = text } }
                else { self.status = "Meeting Copilot failed in another tab: \(failure.localizedDescription)" }
            }
            self.focusToken += 1
        }
    }

    /// A card's Helped / Didn't / On purpose button: recorded straight to the coach, no model involved.
    func recordOutcome(message: UUID, card: UUID, finding: String, outcome: String) {
        guard !recordingOutcomes.contains(finding),
              let cardValue = messages.first(where: { $0.id == message })?.cards.first(where: { $0.id == card }),
              let launch = AppConnector.studiocoach.launch(preferences: preferences) else { return }
        recordingOutcomes.insert(finding)
        Task { [weak self] in
            let failure: String? = await Task.detached {
                do { try StudioCoachOutcome.record(song: cardValue.song, finding: finding, outcome: outcome, launch: launch); return nil }
                catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.recordingOutcomes.remove(finding)
            if let failure { self.status = "Studio Coach: \(failure)"; return }
            guard let m = self.messages.firstIndex(where: { $0.id == message }),
                  let c = self.messages[m].cards.firstIndex(where: { $0.id == card }),
                  let f = self.messages[m].cards[c].findings?.firstIndex(where: { $0.id == finding }) else { return }
            self.messages[m].cards[c].findings?[f].outcome = outcome
            self.status = "Studio Coach noted it: \(CoachCard.outcomes.first { $0.value == outcome }?.title ?? outcome)"
        }
    }

    func stop() {
        if handoffInFlight { status = herdrProposal != nil ? "Herdr may already have accepted the handoff. Wait for its result; stop the session in Herdr." : "CXTasks may already have accepted this task. Wait for its result; stop agents in CXTasks."; return }
        if let run = runs[activeSessionID] { stop(run) }
        status = "Stopped"
        // Stopping means "not yet": what was queued comes back to the draft rather than sending.
        if let items = queued.removeValue(forKey: activeSessionID) {
            mergeIntoDraft(items); status = "Stopped. What you queued is back in the box."
        }
        focusToken += 1
    }

    /// Stops one tab's request; what it already showed stays.
    private func stop(_ run: Run) {
        run.routing?.cancel(); run.routing = nil
        run.handle?.cancel(); run.handle = nil
        run.cancelReveal()
        withMessages(of: run.sessionID) { messages in
            for index in messages.indices where !messages[index].complete { messages[index].activity?.settle(.stopped) }
            messages.removeAll { $0.role == "assistant" && $0.text.isEmpty && ($0.activity ?? []).isEmpty }
        }
        endRun(run)
    }

    /// Quitting: every tab's request stops, and the spares go with them.
    func stopAll() {
        for run in runs.values { stop(run) }
        warmPool?.drain()
    }

    /// The popup opened: with Claude selected, a plain chat and a My setup session launch now,
    /// so the question about to be asked doesn't wait for the CLI to start.
    func prewarm() {
        guard let warmPool, provider == .claude, let executable = path(for: .claude) else { return }
        CLIRunner.prepare(provider: .claude, executable: executable, model: claudeModel, effort: claudeEffort, web: true, pool: warmPool)
        CLIRunner.prepare(provider: .claude, executable: executable, model: claudeModel, effort: claudeEffort, personal: true, pool: warmPool)
    }

    func model(for provider: Provider) -> String { provider == .codex ? codexModel : claudeModel }
    func effort(for provider: Provider) -> String { provider == .codex ? codexEffort : claudeEffort }
    /// The pill's model menu: Settings' list, else the provider's defaults, with the current model kept in it.
    func models(for provider: Provider) -> [String] {
        let typed = (provider == .codex ? codexModelList : claudeModelList)
            .split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var list = typed.isEmpty ? provider.defaultModels : typed
        let current = model(for: provider).trimmingCharacters(in: .whitespaces)
        if !current.isEmpty && !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    /// A pick from the pill. `nil` keeps that part of the choice; an empty string is the CLI default.
    func choose(provider: Provider, model: String? = nil, effort: String? = nil) {
        if let model { if provider == .codex { codexModel = model } else { claudeModel = model } }
        if let effort { if provider == .codex { codexEffort = effort } else { claudeEffort = effort } }
        error = nil; focusToken += 1
        // The provider's didSet prewarms; a model or effort change alone needs its own.
        if self.provider != provider { self.provider = provider } else { prewarm() }
    }

    static let freshChatAfter: TimeInterval = 600

    /// Summoned after being hidden 10+ minutes: start a fresh chat. An answer still
    /// running and an unsent draft are kept.
    func startFreshIfIdle(hiddenFor seconds: TimeInterval) {
        guard seconds >= Self.freshChatAfter, !busy, !handoffInFlight, !messages.isEmpty || delegation != nil || herdrProposal != nil || error != nil else { return }
        let keptDraft = draft, keptAttachments = attachments
        // With several tabs open, the stale chats stay in their tabs and a blank one comes forward.
        if showsTabs { draft = ""; attachments = []; newTab(); error = nil }
        else { newChat() }
        draft = keptDraft; attachments = keptAttachments
    }

    func newChat() {
        guard !handoffInFlight else { return }
        stop()
        messages = []; error = nil; draft = ""; attachments = []; lastRouteScope = nil; showingSettings = false; delegation = nil; lastTaskLink = nil; herdrProposal = nil; directory = nil
        lastReferencedDocument = nil; lastDocumentMessageCount = 0; herdrDetailsExpanded = false
        controlEnabled = false
        selectContext(.auto)
        // A new chat is a new session: the tab keeps its place but not the old id or title.
        let fresh = ChatSession()
        if let index = sessions.firstIndex(where: { $0.id == activeSessionID }) { sessions[index] = fresh } else { sessions.append(fresh) }
        activeSessionID = fresh.id
        status = "Ready when you are"
    }

    // MARK: Tabs

    func restoreChats(_ recovery: ChatRecovery) throws {
        guard canSwitchChats, messages.isEmpty, draft.isEmpty, attachments.isEmpty,
              sessions.count == 1, delegation == nil, herdrProposal == nil else {
            throw ChatRecovery.RecoveryError.chatInUse
        }
        let restored = recovery.sessions.map { saved in
            var session = ChatSession()
            session.customTitle = saved.customTitle
            session.messages = saved.messages.filter { $0.role != "assistant" || !$0.text.isEmpty || !($0.activity ?? []).isEmpty }
            session.draft = saved.draft
            return session
        }
        guard let index = recovery.sessions.firstIndex(where: { $0.id == recovery.activeSessionID }) else {
            throw ChatRecovery.RecoveryError.invalidFile
        }
        sessions = restored
        loadSession(restored[index])
        controlEnabled = false; targetApp = nil
        status = "Chat restored. Previous requests remain stopped."
    }

    var showsTabs: Bool { sessions.count > 1 }
    /// A running answer streams into the chat showing, and a submitted handoff must be checked
    /// where it started, so neither lets another tab come forward.
    var canSwitchChats: Bool {
        !handoffInFlight && delegation?.submissionAttempted != true && herdrProposal?.submissionAttempted != true
    }

    func title(of session: ChatSession) -> String {
        session.customTitle ?? ChatSession.title(from: session.id == activeSessionID ? messages : session.messages)
    }

    /// "/fork" or "/fork <title>" sent as the whole message. Returns the title ("" for none),
    /// or nil when the message is something else ("/forklift", "how do I /fork?").
    nonisolated static func forkTitle(in text: String) -> String? { command("/fork", in: text) }

    /// "!cd <folder>" sent as the whole message: points this chat at a folder. Returns the path
    /// ("" for a bare "!cd", which goes back to the home folder), or nil for anything else
    /// ("!cdx", "run !cd later").
    nonisolated static func cdTarget(in text: String) -> String? { command("!cd", in: text) }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folder a `!cd` path names: `~` expanded, quotes and backslash-escapes removed,
    /// symlinks resolved. A relative path starts from the chat's current folder (home when unset).
    nonisolated static func resolveDirectory(_ path: String, from base: URL?) -> URL? {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
        else { value = value.replacingOccurrences(of: "\\ ", with: " ") }
        guard !value.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url: URL
        if value == "~" { url = home }
        else if value.hasPrefix("~/") { url = home.appendingPathComponent(String(value.dropFirst(2))) }
        else if value.hasPrefix("/") { url = URL(fileURLWithPath: value) }
        else { url = (base ?? home).appendingPathComponent(value) }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return isDirectory(resolved) ? resolved : nil
    }

    /// `!cd`: this chat's messages run My setup from `path` until it is changed or cleared.
    /// Not a message: nothing is sent to the model and nothing is added to the chat.
    private func changeDirectory(to path: String) {
        guard !busy else { status = "Wait for the current answer, or stop it, before changing folder."; return }
        draft = ""
        if path.isEmpty {
            directory = nil
            status = "Back to your home folder"
        } else if let url = Self.resolveDirectory(path, from: directory) {
            directory = url
            status = "This chat now runs from \(url.path)"
            if provider == .claude, let warmPool, let executable = self.path(for: .claude) {
                CLIRunner.prepare(provider: .claude, executable: executable, model: claudeModel, effort: claudeEffort, personal: true, directory: url, pool: warmPool)
            }
        } else {
            status = "No folder at \(path). The chat stays where it was."
        }
        saveActiveSession()
        focusToken += 1
    }

    /// "/truthcheck <anything>" (or "/tc …") sent as the whole message: a claim, pasted text, any
    /// link or an attached image to fact-check. Returns what follows ("" checks the last answer), or nil.
    nonisolated static func truthTarget(in text: String) -> String? { command("/truthcheck", in: text) ?? command("/tc", in: text) }

    nonisolated static func command(_ name: String, in text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix(name) else { return nil }
        let rest = value.dropFirst(name.count)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `/fork`: copies this chat's completed messages into a tab of its own, with a new session
    /// id and title, and brings it forward. The original tab is left as it was.
    func fork(title: String = "") {
        guard canSwitchChats, delegation == nil, herdrProposal == nil else { status = "Finish or stop the current request before forking."; return }
        let kept = messages.filter { $0.complete && (!$0.text.isEmpty || !$0.images.isEmpty) }
        draft = ""
        guard !kept.isEmpty else { status = "Nothing to fork yet. Ask something first."; focusToken += 1; return }
        saveActiveSession()
        guard let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        let source = sessions[index]
        var copy = ChatSession()
        copy.customTitle = title.isEmpty ? nextForkTitle(after: source) : title
        copy.forkedFrom = source.id
        copy.messages = kept
        copy.lastRouteScope = source.lastRouteScope
        copy.directory = source.directory
        copy.lastReferencedDocument = source.lastReferencedDocument
        copy.lastDocumentMessageCount = min(source.lastDocumentMessageCount, kept.count)
        sessions.insert(copy, at: index + 1)
        loadSession(copy)
        status = "Forked “\(self.title(of: source))”. This tab carries on separately."
    }

    /// "Plan the launch" forks to "Plan the launch · fork", then "· fork 2", and so on.
    private func nextForkTitle(after source: ChatSession) -> String {
        let base = title(of: source).replacingOccurrences(of: " · fork(?: \\d+)?$", with: "", options: .regularExpression)
        let taken = Set(sessions.map(title(of:)))
        var candidate = "\(base) · fork", number = 2
        while taken.contains(candidate) { candidate = "\(base) · fork \(number)"; number += 1 }
        return candidate
    }

    func selectSession(_ id: UUID) {
        guard id != activeSessionID, canSwitchChats, let session = sessions.first(where: { $0.id == id }) else { return }
        saveActiveSession()
        loadSession(session)
        status = "Ready when you are"
        // An answer that finished while this tab was behind another sends what was queued in it now.
        sendQueued(id)
    }

    /// ⌘⌥← / ⌘⌥→: the tab before or after the one showing, wrapping at either end.
    func cycleTab(by offset: Int) {
        guard showsTabs, let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        selectSession(sessions[(index + offset % sessions.count + sessions.count) % sessions.count].id)
    }

    /// The tab bar's +: a blank chat in a new tab, or an unused blank tab if there is one.
    func newTab() {
        guard canSwitchChats else { return }
        if messages.isEmpty && sessions.first(where: { $0.id == activeSessionID })?.customTitle == nil { focusToken += 1; return }
        saveActiveSession()
        if let blank = sessions.first(where: { $0.messages.isEmpty && $0.customTitle == nil && $0.draft.isEmpty && $0.attachments.isEmpty }) {
            loadSession(blank)
        } else {
            let fresh = ChatSession()
            sessions.append(fresh)
            loadSession(fresh)
        }
        status = "Ready when you are"
    }

    func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard id == activeSessionID else {
            queued[id] = nil
            if let run = runs[id] { stop(run) }
            rememberClosed(sessions.remove(at: index)); return
        }
        guard canSwitchChats else { return }
        guard sessions.count > 1 else { newChat(); return }
        saveActiveSession()
        rememberClosed(sessions.remove(at: index))
        loadSession(sessions[min(index, sessions.count - 1)])
        status = "Ready when you are"
    }

    /// Closed tabs, newest last, for ⇧⌘T. A blank tab isn't worth bringing back.
    private var closedSessions: [ChatSession] = []

    private func rememberClosed(_ session: ChatSession) {
        guard !session.messages.isEmpty || !session.draft.isEmpty || session.customTitle != nil else { return }
        closedSessions.append(session)
        if closedSessions.count > 20 { closedSessions.removeFirst() }
    }

    /// ⇧⌘T: the tab closed most recently comes back, its chat and draft as they were. An
    /// answer stopped by the close stays stopped; its empty reply is dropped.
    func reopenClosedTab() {
        guard canSwitchChats, var session = closedSessions.popLast() else { return }
        session.messages = session.messages.filter { $0.role != "assistant" || !$0.text.isEmpty || !$0.cards.isEmpty || !($0.activity ?? []).isEmpty }
        saveActiveSession()
        // A blank chat showing is replaced rather than left beside it.
        if messages.isEmpty, draft.isEmpty, attachments.isEmpty,
           let blank = sessions.firstIndex(where: { $0.id == activeSessionID }), sessions[blank].customTitle == nil {
            sessions[blank] = session
        } else {
            sessions.append(session)
        }
        loadSession(session)
        status = "Ready when you are"
    }

    // MARK: History

    /// Writes the chat showing to history, images and cards included. Empty answers left by
    /// a stopped request are dropped; a chat with no question in it isn't written.
    private func recordChat(_ id: UUID) {
        guard let history else { return }
        let source = id == activeSessionID ? messages : sessions.first { $0.id == id }?.messages ?? []
        let kept = source.filter { $0.role != "assistant" || !$0.text.isEmpty || !$0.cards.isEmpty || !($0.activity ?? []).isEmpty }
        guard kept.contains(where: { $0.role == "user" }), savedMessages[id] != kept else { return }
        let session = sessions.first { $0.id == id }
        let entry = ChatHistory.Entry(id: id, title: session?.customTitle ?? ChatSession.title(from: kept),
                                      customTitle: session?.customTitle, forkedFrom: session?.forkedFrom,
                                      updated: Date(), messages: kept)
        savedMessages[entry.id] = kept
        historySummaries.removeAll { $0.id == entry.id }
        historySummaries.insert(.init(id: entry.id, title: entry.title, updated: entry.updated), at: 0)
        historySummaries = Array(historySummaries.prefix(ChatHistory.limit))
        Self.historyQueue.async {
            guard (try? history.save(entry)) == nil else { return }
            Task { @MainActor [weak self] in self?.status = "Couldn't save this chat to history" }
        }
    }

    /// What a history row shows: what an open tab is doing now, else what was saved for the chat.
    func historyMark(of id: UUID) -> ChatHistory.Mark? {
        switch chatStates().first(where: { $0.id == id })?.state {
        case .working: return .working
        case .needsYou: return .needsYou
        case .answered: return .unread
        case .stillOnYou: return .stillOnMe
        case nil: return marks.unread.contains(id) ? .unread : marks.stillOnMe.contains(id) ? .stillOnMe : nil
        }
    }

    /// Marks a chat you've read but still have to act on, or clears that mark.
    func toggleStillOnMe(_ id: UUID) {
        updateMarks { if $0.stillOnMe.remove(id) == nil { $0.stillOnMe.insert(id) } }
    }

    /// Asks whether the answer that just landed leaves the chat on you, and sets or clears its
    /// ring. A verdict that returns after another message was added is dropped.
    private func checkFollowUp(_ id: UUID) {
        guard followUpCheck, let judge = followUpJudge else { return }
        var question = "", answer: ChatMessage?
        withMessages(of: id) { messages in
            answer = messages.last
            question = messages.last { $0.role == "user" }?.text ?? ""
        }
        guard let answer, answer.role == "assistant", answer.complete, !answer.text.isEmpty, !question.isEmpty else { return }
        // Only a handoff's confirmation has no provider: Herdr or CXTasks now holds the work.
        guard answer.provider != nil else { updateMarks { $0.stillOnMe.remove(id) }; return }
        Task { [weak self] in
            guard let onYou = await judge(question, answer.text), let self else { return }
            var last: UUID?
            self.withMessages(of: id) { last = $0.last?.id }
            guard (last ?? self.savedMessages[id]?.last?.id) == answer.id else { return }
            self.updateMarks { if onYou { $0.stillOnMe.insert(id) } else { $0.stillOnMe.remove(id) } }
        }
    }

    private func markSeen(_ id: UUID) {
        guard marks.unread.contains(id) else { return }
        updateMarks { $0.unread.remove(id) }
    }

    /// Changes the marks and writes them, keeping only chats that are open or still in history.
    private func updateMarks(_ change: (inout ChatHistory.Marks) -> Void) {
        var next = marks
        change(&next)
        let known = Set(historySummaries.map(\.id)).union(sessions.map(\.id))
        next.unread.formIntersection(known); next.stillOnMe.formIntersection(known)
        guard next != marks else { return }
        marks = next
        guard let history else { return }
        Self.historyQueue.async { try? history.saveMarks(next) }
    }

    /// Opens a chat from history in a tab, ready for a follow-up; one already open just comes forward.
    /// It replaces a blank tab rather than adding one beside it.
    func reopenChat(_ id: UUID) {
        if sessions.contains(where: { $0.id == id }) { selectSession(id); return }
        guard canSwitchChats, delegation == nil, herdrProposal == nil else { status = "Finish or stop the current request first."; return }
        guard let entry = history?.load(id) else {
            historySummaries.removeAll { $0.id == id }
            status = "That chat is no longer in history."; return
        }
        saveActiveSession()
        var session = ChatSession(id: entry.id)
        session.customTitle = entry.customTitle; session.forkedFrom = entry.forkedFrom; session.messages = entry.messages
        savedMessages[entry.id] = entry.messages
        let index = sessions.firstIndex { $0.id == activeSessionID }
        if let index, messages.isEmpty, draft.isEmpty, attachments.isEmpty, sessions[index].customTitle == nil {
            sessions[index] = session
        } else {
            sessions.insert(session, at: index.map { $0 + 1 } ?? sessions.count)
        }
        loadSession(session)
        status = "Reopened “\(entry.title)”. Ask a follow-up to carry on."
    }

    /// A tab's chat: the showing messages, or its saved copy when another tab is forward.
    private func activity(of message: UUID, in session: UUID) -> [ActivityStep] {
        var log: [ActivityStep] = []
        withMessages(of: session) { log = $0.first { $0.id == message }?.activity ?? [] }
        return log
    }

    private func withMessages(of id: UUID, _ body: (inout [ChatMessage]) -> Void) {
        if id != activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) { body(&sessions[index].messages) }
        else if id == activeSessionID { body(&messages) }
    }

    private func saveActiveSession() {
        guard let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        sessions[index].messages = messages; sessions[index].draft = draft; sessions[index].attachments = attachments
        sessions[index].lastRouteScope = lastRouteScope; sessions[index].lastTaskLink = lastTaskLink; sessions[index].directory = directory
        sessions[index].lastReferencedDocument = lastReferencedDocument; sessions[index].lastDocumentMessageCount = lastDocumentMessageCount
    }

    /// Brings a tab forward. Reviews still open (a task or Herdr card) belong to the chat
    /// being left, and are dropped with it; its draft is kept in its tab.
    private func loadSession(_ session: ChatSession) {
        activeSessionID = session.id
        messages = session.messages; draft = session.draft; attachments = session.attachments
        lastRouteScope = session.lastRouteScope; lastTaskLink = session.lastTaskLink; directory = session.directory
        lastReferencedDocument = session.lastReferencedDocument; lastDocumentMessageCount = session.lastDocumentMessageCount
        error = nil; delegation = nil; submittedHandoff = nil; herdrProposal = nil; herdrDetailsExpanded = false
        needsContextChoice = false; showingSettings = false
        if popupVisible { markSeen(session.id) }
        focusToken += 1
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied to clipboard"
    }

    func copyLatest() {
        if let message = messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) { copy(message.text) }
    }

    /// Adds pasted or dropped images. Returns false when there were none, so text paste proceeds.
    @discardableResult func addImages(_ images: [ImageAttachment]) -> Bool {
        guard !images.isEmpty else { return false }
        let room = ImageAttachment.perMessage - attachments.count
        attachments += images.prefix(max(room, 0))
        status = images.count > room ? "Up to \(ImageAttachment.perMessage) images per message" : "Image attached"
        focusToken += 1
        return true
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    func toggleControl() {
        guard !busy else { return }
        controlEnabled.toggle()
        // Control drives the app in front; General chat has no screen and My setup no hands for it.
        if controlEnabled && (contextChoice == .general || contextChoice == .personal) {
            contextChoice = .auto
            refreshScreenContext?()
        }
        if controlEnabled && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        // Chrome and Electron build their page tree only for a visible window, and the target is
        // still visible behind the popup now; once built it survives being covered.
        if controlEnabled, AXIsProcessTrusted(), let pid = targetApp?.pid {
            DispatchQueue.global(qos: .userInitiated).async { DesktopMCPServer.primeAccessibility(pid: pid) }
        }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    /// Registers or removes the app as a login item. A rebuilt bundle at the same path stays registered.
    func applyOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if openAtLogin, service.status != .enabled { try service.register() }
            else if !openAtLogin, service.status == .enabled { try service.unregister() }
        } catch {
            self.error = "Couldn’t change Open at login. Check System Settings → General → Login Items."
        }
        if openAtLogin, service.status == .requiresApproval {
            self.error = "Allow QuickAsk in System Settings → General → Login Items to open it at login."
        }
    }
}

/// What a question was sent with, read from its tab at Send. Routing and the answer work from
/// this, never from whichever tab is showing when they finish. The screen is read at Send too,
/// so each turn sees the screen as it was then; the tab's history and last route carry its follow-ups.
struct Turn {
    let sessionID: UUID
    let text: String
    let attachments: [ImageAttachment]
    let provider: Provider
    let control: Bool
    let target: AppTarget?
    let history: [ChatMessage]
    let previousScope: RouteScope?
    /// The folder the tab was set to with `!cd` when this was sent.
    var directory: URL? = nil
}

/// One request in flight and everything it owns: its routing, its CLI process, its deadline
/// and its own pacer, so two tabs can answer at once without sharing any of it.
@MainActor
final class Run {
    let sessionID: UUID
    var routing: Task<Void, Never>?
    var handle: RequestHandle?
    var timeout: DispatchWorkItem?
    /// Drives an app; only one run at a time may.
    var control = false
    /// Reads the screen through its tools, which a display change revokes.
    var screen = false
    /// The answer streaming in, paced onto the screen a tick at a time.
    var reveal = StreamReveal()
    var revealTimer: Timer?
    var revealMessageID: UUID?
    /// Marks the answer complete once the last of it is showing.
    var finishReveal: (() -> Void)?

    init(sessionID: UUID) { self.sessionID = sessionID }

    /// Stops pacing at once; the message keeps exactly what was showing.
    func cancelReveal() {
        revealTimer?.invalidate(); revealTimer = nil
        reveal = StreamReveal(); revealMessageID = nil; finishReveal = nil
    }
}

/// A message sent while its tab was still answering.
struct QueuedMessage: Identifiable {
    let id = UUID()
    var text: String
    var attachments: [ImageAttachment]
}

/// One chat in the popup: a tab. Its messages are written to ChatHistory when a request ends.
struct ChatSession: Identifiable {
    let id: UUID
    /// Set for a fork (from `/fork <title>`, or "… · fork"); otherwise the title is the first question.
    var customTitle: String?
    var forkedFrom: UUID?
    var messages: [ChatMessage] = []
    var draft = ""
    var attachments: [ImageAttachment] = []
    fileprivate var lastRouteScope: RouteScope?
    fileprivate var lastReferencedDocument: String?
    fileprivate var lastDocumentMessageCount = 0
    fileprivate var lastTaskLink: String?
    var directory: URL?

    init(id: UUID = UUID()) { self.id = id }

    static func title(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == "user" }) else { return "New chat" }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.isEmpty { return first.images.isEmpty ? "New chat" : "Image" }
        return words.count > 40 ? String(words.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : words
    }
}

/// Paces a streamed answer onto the screen. The CLIs deliver text unevenly (Claude sends a
/// few words every ~50 ms, then stalls and catches up in a burst; Codex sends whole messages),
/// so each tick reveals a share of what has arrived but isn't showing yet. The reveal trails
/// the stream by about `lag` and never holds text back beyond that; it can't invent text
/// during an upstream stall, only ease into and out of it.
struct StreamReveal {
    static let tick: TimeInterval = 1.0 / 30
    static let lag: TimeInterval = 0.2
    /// Once the answer is complete, the rest drains at an even pace within this many ticks
    /// (about a quarter second), so completion isn't held up and the end doesn't jump.
    static let finishingTicks = 8

    private(set) var target = ""
    private var characters: [Character] = []
    private(set) var shownCount = 0
    private(set) var finishing = false
    private var finishingStep = 0

    var shown: String { shownCount == characters.count ? target : String(characters[..<shownCount]) }
    var caughtUp: Bool { shownCount == characters.count }

    /// Takes the full text received so far. Text the provider revised (a Claude `result`, a
    /// Codex snapshot, an emoji whose grapheme grew) is cut back to what still matches.
    mutating func receive(_ text: String) {
        guard text != target else { return }
        let next = Array(text)
        var common = 0
        let limit = min(shownCount, next.count)
        while common < limit && characters[common] == next[common] { common += 1 }
        target = text; characters = next; shownCount = common
    }

    /// The answer is complete: reveal what's left at an even pace.
    mutating func finish() {
        finishing = true
        let backlog = characters.count - shownCount
        finishingStep = max(3, (backlog + Self.finishingTicks - 1) / Self.finishingTicks)
    }

    /// Advances one tick; returns the text to show when it changed.
    mutating func step() -> String? {
        let backlog = characters.count - shownCount
        guard backlog > 0 else { return nil }
        let share = finishing ? finishingStep : max(1, Int((Double(backlog) * Self.tick / Self.lag).rounded(.up)))
        shownCount += min(backlog, share)
        return shown
    }
}
