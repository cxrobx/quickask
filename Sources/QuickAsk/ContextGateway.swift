import AppKit

struct GatewayConfiguration: Codable {
    let snapshot: ContextSnapshot
    let connectors: [AppConnector]
    let executables: [String: String]
    let desktopControl: Bool
    /// False on routes chosen under uncertainty: read tools only.
    var writes: Bool = true
    /// Connectors attached for reading only, even when `writes` is true.
    var readOnly: [AppConnector] = []
    /// Launch details for connectors not started from `executables` (Vault, Margin).
    var launches: [String: MCPLaunch] = [:]
    /// Tools only: the snapshot is a placeholder for Quick Ask itself, not a screen window.
    var screenless = false
    /// Where the gateway appends the cards app tools return (Studio Coach's answers), one JSON line
    /// each, for Quick Ask to draw. An owner-only file in the request's workspace.
    var cardsPath: String? = nil
    /// How long the request's tool lease lasts. A coach answer can take minutes, and app control
    /// runs multi-step tasks; the rest, three.
    var leaseSeconds: TimeInterval {
        max(connectors.contains(.studiocoach) || connectors.contains(.meetingcopilot) ? 420 : 180, desktopControl ? Self.controlLeaseSeconds : 0)
    }
    static let controlLeaseSeconds: TimeInterval = 600
    var readOnlyConnectors: [AppConnector] { writes ? connectors.filter { readOnly.contains($0) } : connectors }
    func allows(_ connector: AppConnector, _ tool: String) -> Bool {
        connector.tools.contains(tool) && (!connector.writes.contains(tool) || (writes && !readOnly.contains(connector)))
    }
    func launch(_ connector: AppConnector) -> MCPLaunch {
        launches[connector.rawValue] ?? MCPLaunch(command: executables[connector.rawValue] ?? "")
    }
    var toolNames: [String] {
        connectors.flatMap { connector in connector.tools.filter { allows(connector, $0) }.map { "\(connector.rawValue)__\($0)" } } + (desktopControl ? DesktopMCPServer.tools.compactMap { $0["name"] as? String } : [])
    }
    // Only identities enter the short-lived descriptor; content stays in memory.
    var handoff: GatewayConfiguration {
        let source = snapshot
        let selection = source.selection.map {
            AppSelection(pid: $0.pid, bundleID: $0.bundleID, windowLabel: $0.windowLabel, windowID: $0.windowID,
                         revision: $0.revision, label: "", records: $0.records)
        }
        let identity = ContextSnapshot(displayID: source.displayID, windowID: source.windowID, pid: source.pid,
                                       bundleID: source.bundleID, appName: source.appName, windowTitle: "",
                                       capturedAt: source.capturedAt, launchTime: source.launchTime, selection: selection,
                                       text: "", document: "")
        return .init(snapshot: identity, connectors: connectors, executables: executables, desktopControl: desktopControl,
                     writes: writes, readOnly: readOnly, launches: launches, screenless: screenless, cardsPath: cardsPath)
    }
}

/// Serial stdio client; callbacks drain stdout/stderr while the server waits.
final class AppMCPClient {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let condition = NSCondition()
    private var framing = JSONLineFramer(), responses: [Int: [String: Any]] = [:]
    private var sequence = 0, disconnected = false
    private let valid: () -> Bool
    private let toolDeadline: TimeInterval
    init(launch: MCPLaunch, toolDeadline: TimeInterval = 60, valid: @escaping () -> Bool) throws {
        self.valid = valid; self.toolDeadline = toolDeadline
        let executable = launch.command
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw ProviderRunError(message: "The app MCP executable is unavailable. Configure its path in Settings.") }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = launch.arguments
        process.environment = ExecutableFinder.environment(for: executable).merging(launch.environment) { _, configured in configured }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard let self else { return }
            self.condition.lock(); defer { self.condition.unlock() }
            if data.isEmpty { self.disconnected = true; self.condition.broadcast(); return }
            for line in self.framing.append(data) {
                guard line.count < 24_000_000, let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { self.disconnected = true; continue }
                if let id = value["id"] as? Int { self.responses[id] = value }
            }
            self.condition.broadcast()
        }
        errors.fileHandleForReading.readabilityHandler = { file in _ = file.availableData }
        try process.run()
        do {
            _ = try rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "QuickAsk", "version": "0.5.0"]])
            try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() {
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    private func write(_ object: [String: Any]) throws {
        guard valid() else { throw ProviderRunError(message: "Context access has stopped or expired.") }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    func rpc(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        sequence += 1; let id = sequence
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(method == "tools/call" ? toolDeadline : 8)
        condition.lock(); defer { condition.unlock() }
        while responses[id] == nil && !disconnected && Date() < deadline {
            guard valid() else { throw ProviderRunError(message: "Context access stopped. An app operation already accepted may still complete.") }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        guard let response = responses.removeValue(forKey: id), response["error"] == nil,
              let result = response["result"] as? [String: Any] else { throw ProviderRunError(message: "The app MCP disconnected, rejected the request, or timed out. No success was confirmed.") }
        return result
    }
}

enum GatewayPolicy {
    /// Studio Coach's writes: the song card's own words, and an outcome for a finding.
    static let coachFields: [String: Set<String>] = ["set_card": ["song", "feeling", "goal", "reference"], "record_outcome": ["song", "finding", "result"]]
    static let taskFields: Set<String> = ["task_id", "title", "why", "body", "status", "blocked_reason", "priority", "project", "due_at", "defer_until", "recurrence", "tags", "new_tags", "decision", "blocked_by", "section", "result", "kind"]
    static func safeMove(destination: String, folderOutput: String) -> Bool {
        let matches = folderOutput.components(separatedBy: "\n").compactMap { line -> (String, String)? in
            let fields = line.components(separatedBy: " | ")
            guard fields.count == 3 else { return nil }
            return (fields[1], fields[2].components(separatedBy: " (").first ?? "")
        }.filter { $0.0 == destination }
        let banned = ["trash", "junk", "spam", "deleted"]
        return !matches.isEmpty && matches.allSatisfy { name, role in !banned.contains(where: { name.lowercased().contains($0) || role.lowercased().contains($0) }) }
    }
    static func validate(connector: AppConnector, tool: String, arguments: [String: Any], selection: AppSelection?) throws {
        guard connector.tools.contains(tool) else { throw ProviderRunError(message: "This app action is unavailable from Quick Ask.") }
        guard connector.writes.contains(tool) else { return }
        // File attachments would give an app MCP arbitrary local file access.
        if arguments["attachments"] != nil { throw ProviderRunError(message: "File attachments are unavailable from Quick Ask in this release.") }
        if connector == .studiocoach {
            guard let allowed = coachFields[tool], arguments.keys.allSatisfy(allowed.contains) else { throw ProviderRunError(message: "Studio Coach can only set the song's feeling, goal or reference, or record an outcome, from Quick Ask.") }
        } else if connector == .cxtasks {
            let prohibited = arguments.keys.contains { !taskFields.contains($0) }
            guard !prohibited, arguments["status"] as? String != "queued" else { throw ProviderRunError(message: "Background execution and repository changes are unavailable from Quick Ask.") }
            if tool != "file_task" {
                guard let task = arguments["task_id"] as? String,
                      task == selection?.records["task_id"] || task.lowercased() == selection?.records["task_ref"]?.lowercased() else { throw ProviderRunError(message: "This write does not target the selected task. Select it and send a fresh request.") }
            }
        } else if connector == .cxmail {
            if tool == "move_email" {
                // A folder can have any localized name. Its actual special-use role is
                // checked against list_folders by the gateway before forwarding.
                guard let folder = arguments["to_folder"] as? String, !folder.isEmpty else { throw ProviderRunError(message: "Select an existing destination folder.") }
            }
            if ["archive_email", "flag_email", "move_email"].contains(tool) {
                guard arguments["account_id"] as? String == selection?.records["account_id"],
                      String((arguments["uid"] as? NSNumber)?.uint32Value ?? 0) == selection?.records["uid"],
                      (arguments[tool == "move_email" ? "from_folder" : "folder"] as? String) == selection?.records["folder"] else { throw ProviderRunError(message: "This write does not target the selected email. Select it and send a fresh request.") }
            }
        }
    }
}

final class ContextGateway {
    let configuration: GatewayConfiguration
    private var clients: [AppConnector: AppMCPClient] = [:]
    private var catalog: [[String: Any]]?
    private var createdDrafts: Set<String> = []
    /// Onyx's page tools, served here over the page in the snapshot.
    private var onyxPage: OnyxPage?
    private let valid: () -> Bool
    init(configuration: GatewayConfiguration, valid: @escaping () -> Bool) { self.configuration = configuration; self.valid = valid }
    func tools() throws -> [[String: Any]] {
        if let catalog { return catalog }
        var result: [[String: Any]] = []
        for connector in configuration.connectors {
            if connector == .onyx {
                guard configuration.snapshot.connector == .onyx, let page = OnyxPage(records: configuration.snapshot.selection?.records ?? [:]) else { throw ProviderRunError(message: "Onyx's page tools need a local document open in Onyx.") }
                onyxPage = page
                result += OnyxPage.definitions.map { tool in
                    var tool = tool
                    tool["name"] = "onyx__\(tool["name"] as! String)"; tool["description"] = "Onyx: \(tool["description"] as! String)"
                    return tool
                }
                continue
            }
            let client = try AppMCPClient(launch: configuration.launch(connector), toolDeadline: connector.toolDeadline, valid: valid)
            clients[connector] = client
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                let page = try client.rpc("tools/list", cursor.map { ["cursor": $0] } ?? [:])
                for var tool in page["tools"] as? [[String: Any]] ?? [] {
                    guard let name = tool["name"] as? String, configuration.allows(connector, name) else { continue }
                    tool["name"] = "\(connector.rawValue)__\(name)"
                    tool["description"] = "\(connector.title): \(tool["description"] as? String ?? name)"
                    if connector == .cxtasks, connector.writes.contains(name), var schema = tool["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any] {
                        schema["properties"] = properties.filter { GatewayPolicy.taskFields.contains($0.key) }
                        schema["additionalProperties"] = false; tool["inputSchema"] = schema
                    }
                    tool.removeValue(forKey: "_meta"); result.append(tool)
                }
                cursor = page["nextCursor"] as? String
                if let cursor {
                    guard seenCursors.insert(cursor).inserted, seenCursors.count < 8 else { throw ProviderRunError(message: "Invalid app tool pagination.") }
                }
                guard result.count < 100 else { throw ProviderRunError(message: "Invalid app tool catalog.") }
            } while cursor != nil
            guard result.contains(where: { ($0["name"] as? String)?.hasPrefix(connector.rawValue + "__") == true }) else { throw ProviderRunError(message: "\(connector.title) offers no supported Quick Ask tools.") }
        }
        catalog = result; return result
    }
    func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        guard valid() else { throw ProviderRunError(message: "Context access stopped or expired.") }
        let parts = name.components(separatedBy: "__")
        guard parts.count == 2, let connector = AppConnector(rawValue: parts[0]), configuration.connectors.contains(connector) else { throw ProviderRunError(message: "This tool is outside the selected app context.") }
        let tool = parts[1], snapshot = configuration.snapshot
        guard configuration.allows(connector, tool) else { throw ProviderRunError(message: "This request is read-only: Quick Ask wasn’t sure enough to allow changes. Ask again directly to make the change.") }
        try GatewayPolicy.validate(connector: connector, tool: tool, arguments: arguments, selection: snapshot.connector == connector ? snapshot.selection : nil)
        // Identity checks apply to the app on screen; tool connectors have no selection.
        if connector.writes.contains(tool) && snapshot.connector == connector && connector.hasSelection {
            guard let app = NSRunningApplication(processIdentifier: snapshot.pid), app.bundleIdentifier == snapshot.bundleID,
                  abs((app.launchDate?.timeIntervalSince1970 ?? 0) - snapshot.launchTime) < 0.01,
                  DisplayContext.windows(on: snapshot.displayID).contains(where: { $0.id == snapshot.windowID && $0.pid == snapshot.pid }),
                  let expected = snapshot.selection, let current = SelectionReader.read(snapshot.connector!, pid: snapshot.pid),
                  expected.sameTarget(as: current) else { throw ProviderRunError(message: "The selected app item changed or its context interface is unavailable. Send a fresh request before writing.") }
        }
        _ = try tools()
        if connector == .onyx {
            guard onyxPage != nil else { throw ProviderRunError(message: "This app tool is unavailable.") }
            return try onyxPage!.call(tool, arguments)
        }
        guard catalog?.contains(where: { $0["name"] as? String == name }) == true, let client = clients[connector] else { throw ProviderRunError(message: "This app tool is unavailable.") }
        if connector == .cxmail && tool == "move_email" { try validateMove(arguments, client: client) }
        if connector == .cxmail && tool == "edit_draft" {
            guard let draft = arguments["draft_id"] as? String,
                  draft == snapshot.selection?.records["draft_id"] || createdDrafts.contains("\(arguments["account_id"] as? String ?? ""):\(draft)") else { throw ProviderRunError(message: "Edit only the selected draft or a draft created by this request, using its stable draft_id.") }
        }
        let result = try client.rpc("tools/call", ["name": tool, "arguments": arguments])
        if connector == .studiocoach { recordCard(result) }
        if connector == .cxmail && tool == "compose_draft", result["isError"] as? Bool != true {
            for block in result["content"] as? [[String: Any]] ?? [] {
                guard let text = block["text"] as? String, let range = text.range(of: "draft_id [0-9a-fA-F-]{36}", options: .regularExpression) else { continue }
                let draft = String(text[range].dropFirst(9))
                createdDrafts.insert("\(arguments["account_id"] as? String ?? ""):\(draft)")
            }
        }
        return result
    }
    /// Hands a coach answer's card to Quick Ask's UI. The model reads `content`; the card is for the user.
    private func recordCard(_ result: [String: Any]) {
        guard result["isError"] as? Bool != true, let path = configuration.cardsPath,
              let card = (result["structuredContent"] as? [String: Any])?["card"] as? [String: Any],
              let line = try? JSONSerialization.data(withJSONObject: card), line.count < 512_000 else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data([10]))
    }
    private func validateMove(_ arguments: [String: Any], client: AppMCPClient) throws {
        let folders = try client.rpc("tools/call", ["name": "list_folders", "arguments": ["account_id": arguments["account_id"] ?? ""]])
        let texts = (folders["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        guard let destination = arguments["to_folder"] as? String else { throw ProviderRunError(message: "Missing destination folder.") }
        guard GatewayPolicy.safeMove(destination: destination, folderOutput: texts.joined(separator: "\n")), folders["isError"] as? Bool != true else { throw ProviderRunError(message: "Moving into Trash/Junk or an unverified folder is unavailable from Quick Ask.") }
    }
}
