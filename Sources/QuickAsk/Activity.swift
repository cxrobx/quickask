import Foundation

/// One step of the work behind a reply: a tool call, a command, a stretch of thinking, a retry.
/// Rows are keyed by the provider's own id (a tool-use id, a Codex item id), so parallel calls
/// each keep their row and a later event for the same call updates it in place.
struct ActivityStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case command, read, edit, search, web, fetch, mcp, control, agent, thinking, retry, tool, look }
    enum State: String, Codable { case running, done, failed, stopped }

    let id: String
    var kind: Kind
    /// The tool as people read it ("zen-ext · open_url", "Bash").
    var name: String
    /// One short, masked line: the command, the file name, the query.
    var detail: String?
    var state: State
    /// The subagent call this step ran inside.
    var parent: String?
    var started: Date
    var ended: Date?
    /// A look at the screen: the small preview of what Claude saw, so the user sees it too.
    var image: String? = nil

    init(id: String, kind: Kind, name: String, detail: String? = nil, state: State = .running, parent: String? = nil, started: Date = Date()) {
        self.id = id; self.kind = kind; self.name = name; self.detail = detail.flatMap(Self.clean)
        self.state = state; self.parent = parent; self.started = started
        if state != .running { ended = started }
    }

    var verb: String? {
        let running = state == .running
        switch kind {
        case .command: return running ? "Running" : "Ran"
        case .read: return running ? "Reading" : "Read"
        case .edit: return running ? "Editing" : "Edited"
        case .search: return running ? "Searching" : "Searched"
        case .web: return running ? "Searching the web" : "Searched the web"
        case .fetch: return running ? "Fetching" : "Fetched"
        case .thinking: return running ? "Thinking" : "Thought"
        case .retry: return "Retrying"
        case .look: return running ? "Looking at the screen" : "Looked at the screen"
        case .agent: return "Agent"
        case .mcp, .control, .tool: return nil
        }
    }

    /// The footer line while this step runs: "Running wrangler d1 …", "zen-ext · open_url…".
    var summary: String {
        let head = verb ?? name
        guard let detail, !detail.isEmpty else { return head + "…" }
        return "\(head) \(detail.count > 48 ? String(detail.prefix(47)) + "…" : detail)"
    }

    /// From a tool call's name and input, in Claude's naming (`mcp__server__tool` for MCP).
    static func make(id: String, tool raw: String, input: [String: Any], parent: String? = nil) -> ActivityStep {
        let string = { (key: String) in (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let file = { (key: String) in string(key).map { ($0 as NSString).lastPathComponent } }
        let (kind, detail): (Kind, String?)
        switch raw {
        case "Bash": (kind, detail) = (.command, string("command"))
        case "Read": (kind, detail) = (.read, file("file_path"))
        case "Edit", "MultiEdit", "Write": (kind, detail) = (.edit, file("file_path"))
        case "NotebookEdit": (kind, detail) = (.edit, file("notebook_path"))
        case "Grep", "Glob": (kind, detail) = (.search, string("pattern"))
        case "WebSearch": (kind, detail) = (.web, string("query"))
        case "WebFetch": (kind, detail) = (.fetch, string("url").map { URL(string: $0)?.host ?? $0 })
        case "Agent", "Task": (kind, detail) = (.agent, string("description"))
        case "mcp__quickask__\(ScreenLookServer.toolName)": (kind, detail) = (.look, string("app"))
        default:
            let quickask = raw.hasPrefix("mcp__quickask__") ? String(raw.dropFirst("mcp__quickask__".count)) : nil
            // A script is shown by its first line, so the user sees what runs in their app.
            if quickask == "app_script", let script = string("script") { (kind, detail) = (.control, "app script: " + script) }
            else if let quickask, !quickask.contains("__") { (kind, detail) = (.control, quickask.replacingOccurrences(of: "_", with: " ")) }
            else if raw.hasPrefix("mcp__") { (kind, detail) = (.mcp, summarize(input)) }
            else { (kind, detail) = (.tool, summarize(input)) }
        }
        let name = kind == .control ? "Controlling app" : kind == .look ? "Screen" : EventDecoder.toolName(raw.hasPrefix("mcp__quickask__") && kind != .control ? "mcp__" + raw.dropFirst("mcp__quickask__".count) : raw)
        return ActivityStep(id: id, kind: kind, name: name, detail: detail, parent: parent)
    }

    /// The input value that says what an MCP or other tool call is about.
    static func summarize(_ input: [String: Any]) -> String? {
        for key in ["query", "q", "url", "command", "path", "file_path", "title", "task_id", "name", "text", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return key == "url" ? URL(string: value)?.host ?? value : value }
        }
        return input.keys.sorted().lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty && $0.count < 200 }
    }

    /// One line, capped, with anything credential-shaped masked. Details are shown and saved in
    /// chat history, and a command line is exactly where a pasted key turns up.
    static func clean(_ raw: String) -> String? {
        let line = raw.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var text = line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for (pattern, template) in masks {
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        if text.count > 140 { text = String(text.prefix(139)) + "…" }
        return text.isEmpty ? nil : text
    }

    private static let masks: [(String, String)] = [
        // KEY=value, --token value, password: value, Authorization: Bearer value
        (#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 •••"),
        (#"(\b[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|AUTH|CREDENTIALS?)[A-Z0-9_]*\s*[=:]\s*)(?!(?:Bearer|Basic) )("[^"]*"|'[^']*'|\S+)"#, "$1•••"),
        (#"(--?[a-z-]*(?:key|token|secret|password|auth)[a-z-]*[ =])("[^"]*"|'[^']*'|\S+)"#, "$1•••"),
        // Known key prefixes, then any long opaque run.
        (#"\b(?:sk|pk|rk|ghp|gho|ghs|github_pat|xox[abprs]|glpat|AKIA|AIza)[-_A-Za-z0-9]{12,}"#, "•••"),
        // A long run of letters and digits mixed together (paths and words have separators).
        (#"\b(?=[A-Za-z0-9_]*[0-9])(?=[A-Za-z0-9_]*[A-Za-z])[A-Za-z0-9_]{32,}\b"#, "•••"),
    ]
}

extension Array where Element == ActivityStep {
    /// Adds a step, or updates the one with its id; a new detail never erases a known one.
    mutating func upsert(_ step: ActivityStep) {
        guard let index = firstIndex(where: { $0.id == step.id }) else { append(step); return }
        var merged = self[index]
        merged.kind = step.kind; merged.name = step.name
        if step.detail != nil { merged.detail = step.detail }
        if step.image != nil { merged.image = step.image }
        if merged.state == .running || step.state != .running { merged.state = step.state }
        if merged.state != .running { merged.ended = merged.ended ?? step.ended ?? Date() }
        self[index] = merged
    }

    /// Closes whatever is still running when the reply ends: done, failed or stopped.
    mutating func settle(_ state: ActivityStep.State, at date: Date = Date()) {
        for index in indices where self[index].state == .running { self[index].state = state; self[index].ended = date }
    }

    /// The step the footer names: the latest one still running, the main assistant's first.
    var current: ActivityStep? {
        last { $0.state == .running && $0.parent == nil && $0.kind != .thinking } ?? last { $0.state == .running }
    }

    var elapsed: TimeInterval {
        guard let start = map(\.started).min() else { return 0 }
        let end = contains { $0.state == .running } ? Date() : compactMap(\.ended).max() ?? start
        return Swift.max(0, end.timeIntervalSince(start))
    }
}
