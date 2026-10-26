import PDFKit
import AppKit

@main
struct ProviderTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
    }
    static func event(_ value: String, into decoder: EventDecoder) { _ = decoder.decode(Data(value.utf8)) }

    /// Replays a recorded CLI stream and folds its work-log events the way the app does.
    static func replay(_ fixture: String, _ provider: Provider) throws -> (log: [ActivityStep], text: String) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(fixture)")
        let decoder = EventDecoder(provider: provider)
        var log: [ActivityStep] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            for case .activity(let step) in decoder.decode(Data(line.utf8)) { log.upsert(step) }
        }
        return (log, decoder.text)
    }

    /// The work log: recorded Claude and Codex streams, parallel calls, masking, persistence.
    static func verifyActivity() throws {
        let claude = try replay("claude-tools.jsonl", .claude)
        let tools = claude.log.filter { $0.kind != .thinking }
        check(tools.map(\.kind) == [.command, .command, .read] && tools.map(\.detail) == ["ls /tmp | head -3", "false", "hosts"],
              "Claude tool calls become rows with their command or file, in order")
        check(tools.map(\.state) == [.done, .failed, .done], "A tool result closes its row; is_error marks it failed")
        check(claude.log.filter { $0.kind == .thinking }.count == 2 && claude.log.allSatisfy { $0.state != .running && $0.ended != nil },
              "Thinking blocks get rows that close when the block ends")
        check(claude.text.hasPrefix("Done."), "The work log doesn't disturb the answer text")

        let agent = try replay("claude-subagent.jsonl", .claude)
        let parent = agent.log.first { $0.kind == .agent }
        check(parent?.detail == "Run echo hi" && parent?.state == .done, "A subagent call is one Agent row, closed by its result")
        check(agent.log.contains { $0.parent == parent?.id && $0.detail == "echo hi" && $0.state == .done }, "A subagent's own steps sit under its Agent row")

        let codex = try replay("codex-commands.jsonl", .codex)
        check(codex.log.map(\.detail) == ["ls /tmp | head -3", "false"] && codex.log.map(\.state) == [.done, .failed],
              "Codex commands become rows, unwrapped from the shell, failed by exit status")
        let mcp = EventDecoder(provider: .codex)
        _ = mcp.decode(Data(#"{"type":"item.started","item":{"id":"m1","type":"mcp_tool_call","server":"zen-ext","tool":"open_url","arguments":{"url":"https://example.com/a"},"status":"in_progress"}}"#.utf8))
        let mcpDone = mcp.decode(Data(#"{"type":"item.completed","item":{"id":"m1","type":"mcp_tool_call","server":"zen-ext","tool":"open_url","arguments":{"url":"https://example.com/a"},"status":"failed","error":{"message":"no"}}}"#.utf8))
        check(mcpDone.contains { if case .activity(let s) = $0 { return s.name == "zen-ext · open_url" && s.detail == "example.com" && s.state == .failed }; return false },
              "Codex MCP calls are named by server and tool and fail with their status")
        check(EventDecoder.unwrapShell(#"/bin/zsh -lc 'echo '\''hi'\'''"#) == "echo 'hi'", "Quoted shell commands unwrap")

        // Parallel calls: two rows, each closed by its own result whatever the order.
        let parallel = EventDecoder(provider: .claude)
        var log: [ActivityStep] = []
        for line in [#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"mcp__vault__search_vault","input":{}}}}"#,
                     #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"b","name":"WebSearch","input":{}}}}"#,
                     #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"mcp__vault__search_vault","input":{"query":"ebike"}},{"type":"tool_use","id":"b","name":"WebSearch","input":{"query":"news"}}]}}"#,
                     #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b","content":"x"}]}}"#] {
            for case .activity(let step) in parallel.decode(Data(line.utf8)) { log.upsert(step) }
        }
        check(log.count == 2 && log[0].name == "vault · search_vault" && log[0].detail == "ebike" && log[0].state == .running && log[1].state == .done,
              "Parallel calls keep their own rows, keyed by tool-use id")
        check(log.current?.id == "a" && log.current?.summary == "vault · search_vault ebike", "The footer names the step still running")
        log.upsert(ActivityStep(id: "b", kind: .web, name: "WebSearch", state: .running))
        check(log[1].state == .done, "A late event never reopens a finished row")
        log.settle(.stopped)
        check(log[0].state == .stopped && log[0].ended != nil, "Stopping closes what was still running")
        let control = ActivityStep.make(id: "c", tool: "mcp__quickask__click_element", input: [:])
        let gateway = ActivityStep.make(id: "g", tool: "mcp__quickask__vault__search_vault", input: ["query": "x"])
        check(control.kind == .control && gateway.kind == .mcp && gateway.name == "vault · search_vault", "App control and gateway calls are told apart")
        // My setup's screen tool: its step, its preview, and where a preview may come from.
        let lookStep = ActivityStep.make(id: "l", tool: "mcp__quickask__look_at_screen", input: ["app": "Figma"])
        check(lookStep.kind == .look && lookStep.name == "Screen" && lookStep.detail == "Figma" && lookStep.summary == "Looking at the screen Figma",
              "A look at the screen is its own kind of step, not app control")
        check(EventDecoder.toolStatus("mcp__quickask__look_at_screen") == "Looking at your screen…", "Looking has its own status")
        let preview = ScreenLookServer.previewFolder.appendingPathComponent("look-test.jpg").path
        let looker = EventDecoder(provider: .claude)
        var looks: [ActivityStep] = []
        for line in [#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"L1","name":"mcp__quickask__look_at_screen","input":{}}]}}"#,
                     #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"L1","content":[{"type":"text","text":"Captured the screen.\n\#(ScreenLookServer.previewPrefix)\#(preview)"},{"type":"image","source":{}}]}]}}"#,
                     #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"L2","name":"mcp__quickask__look_at_screen","input":{}}]}}"#,
                     #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"L2","content":"\#(ScreenLookServer.previewPrefix)/etc/passwd"}]}}"#,
                     #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"B1","name":"Bash","input":{"command":"ls"}}]}}"#,
                     #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"B1","content":"\#(ScreenLookServer.previewPrefix)\#(preview)"}]}}"#] {
            for case .activity(let step) in looker.decode(Data(line.utf8)) { looks.upsert(step) }
        }
        check(looks.first { $0.id == "L1" }?.image == preview && looks.first { $0.id == "L1" }?.state == .done, "A look's step carries its preview")
        check(looks.first { $0.id == "L2" }?.image == nil && looks.first { $0.id == "B1" }?.image == nil,
              "Only a look, and only a preview in Quick Ask's own folder, puts a picture in the work log")
        let savedLook = try JSONDecoder().decode(ActivityStep.self, from: JSONEncoder().encode(looks.first { $0.id == "L1" }!))
        check(savedLook.image == preview && savedLook.kind == .look, "A look's preview survives saving the chat")

        let setupArgs = Provider.claude.arguments(model: "", personal: true)
        let mcpConfig = setupArgs.firstIndex(of: "--mcp-config").map { setupArgs[$0 + 1] } ?? ""
        check(mcpConfig.contains("--screen-mcp") && mcpConfig.contains(#""quickask""#) && !setupArgs.contains("--strict-mcp-config")
              && setupArgs.firstIndex(of: "--allowedTools").map { setupArgs[$0 + 1] } == "mcp__quickask__look_at_screen",
              "My setup gets the screen tool beside the user's own MCP servers, pre-approved")
        // A Swift dictionary's key order follows its storage address, so the same config could
        // serialize differently on each call: every My setup turn was a new pool key, started
        // cold and left an idle spare behind. Comparing two calls in a loop reuses the address
        // and passes anyway; only a fixed (sorted) key order proves the launch can't drift.
        let canonical = (try? JSONSerialization.jsonObject(with: Data(mcpConfig.utf8)))
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) }
        check(canonical == mcpConfig && (0..<50).allSatisfy { _ in Provider.claude.arguments(model: "", personal: true) == setupArgs },
              "My setup's launch is the same every time, so a warm spare matches")
        check(!Provider.claude.arguments(model: "").joined().contains("--screen-mcp") && !Provider.codex.arguments(model: "").joined().contains("--screen-mcp"),
              "Only My setup can look at the screen")
        let screenServer = ScreenLookServer(ownerPID: ProcessInfo.processInfo.processIdentifier)
        let hello = screenServer.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let listed = (screenServer.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let wrong = (screenServer.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "click_element"]])?["result"] as? [String: Any])
        check(((hello?["result"] as? [String: Any])?["instructions"] as? String)?.contains("look_at_screen") == true
              && listed?.map { $0["name"] as? String } == ["look_at_screen"] && wrong?["isError"] as? Bool == true
              && screenServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil,
              "The screen server offers one read-only tool and nothing else")
        let deadOwner = ScreenLookServer(ownerPID: 999_999)
        let orphan = deadOwner.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "look_at_screen", "arguments": [:]]])?["result"] as? [String: Any]
        check(orphan?["isError"] as? Bool == true && "\(orphan?["content"] ?? "")".contains("Quick Ask closed"), "The screen tool stops working once Quick Ask is gone")
        let retry = EventDecoder(provider: .claude)
        let retried = retry.decode(Data(#"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":800,"error_status":529}"#.utf8))
        let resumed = retry.decode(Data(#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#.utf8))
        check(retried.contains { if case .activity(let s) = $0 { return s.kind == .retry && s.detail == "attempt 2 of 10 · 529" && s.state == .running }; return false }
              && resumed.contains { if case .activity(let s) = $0 { return s.id == "retry" && s.state == .done }; return false },
              "An API retry shows until the next message starts")

        // A permission check's refusals reach the reply, verbatim and once each, with the answer intact.
        let denied = EventDecoder(provider: .claude)
        let refused = denied.decode(Data(#"{"type":"result","subtype":"success","is_error":false,"result":"Blocked.","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"ssh prod-x 'psql' <<'SQL'\nSELECT count(*);\nSQL\n"}},{"tool_name":"Bash","tool_input":{"command":"ssh prod-x 'psql' <<'SQL'\nSELECT count(*);\nSQL"}},{"tool_name":"Write","tool_input":{"file_path":"/etc/hosts"}},{"tool_name":"mcp__zen-ext__click","tool_input":{}}]}"#.utf8))
        check(refused.contains { if case .blocked(let a) = $0 { return a == ["ssh prod-x 'psql' <<'SQL'\nSELECT count(*);\nSQL", "Write /etc/hosts", "zen-ext · click"] }; return false }
              && refused.contains { if case .text("Blocked.") = $0 { return true }; return false },
              "Permission denials become one approvable action each, beside the answer")
        check(EventDecoder(provider: .claude).decode(Data(#"{"type":"result","is_error":false,"result":"ok","permission_denials":[]}"#.utf8))
              .allSatisfy { if case .blocked = $0 { return false }; return true }, "No denials, no approval card")
        let approval = AppModel.approvalText(["echo ```hi```"])
        check(approval.hasPrefix("I approve this action") && approval.contains("````\necho ```hi```\n````"),
              "The approval names the command inside a fence its backticks can't close")

        // Masking: details are shown and saved, so credentials never are.
        let masked = [ActivityStep.clean("curl -H 'Authorization: Bearer abcdef0123456789xyz' https://api.example.com")!,
                      ActivityStep.clean("CF_API_KEY=abc123def456 wrangler deploy")!,
                      ActivityStep.clean("tool --api-token s3cr3tvalue run")!,
                      ActivityStep.clean("echo sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA")!,
                      ActivityStep.clean("deploy a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7")!]
        let joined = masked.joined()
        check(!joined.contains("abcdef0123") && !joined.contains("abc123def456") && !joined.contains("s3cr3t")
              && !joined.contains("AAAAAAAAAAAA") && !joined.contains("a1B2c3D4") && masked.allSatisfy { $0.contains("•••") },
              "Credential-shaped values are masked: \(masked)")
        check(ActivityStep.clean("ls /Users/someone/Projects/quickask/Sources/QuickAsk/Provider.swift") == "ls /Users/someone/Projects/quickask/Sources/QuickAsk/Provider.swift",
              "Ordinary paths are left alone")
        check(ActivityStep.clean("line one\nline two") == "line one" && ActivityStep.clean(String(repeating: "ab ", count: 200))!.count == 140,
              "Details are one capped line")

        // Saved chats: the log round-trips, and older chats without one still load.
        var message = ChatMessage(role: "assistant", text: "x", provider: .claude)
        message.activity = claude.log
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        check(restored.activity?.count == claude.log.count && restored.activity?.first?.detail == claude.log.first?.detail, "The work log is saved with the chat")
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"64DAC619-F9A3-4936-A5F5-04DD4FBA7276","role":"assistant","text":"x","provider":"claude","complete":true,"images":[],"cards":[]}"#.utf8))
        check(old.activity == nil, "Saved chats from before the work log still load")
        check(WorkLogView.clock(14) == "14s" && WorkLogView.clock(94) == "1:34", "Elapsed time reads as seconds, then minutes")
    }

    /// app_script's guard: what it refuses outright, what needs the user's go-ahead, and the dictionary.
    static func scriptingChecks() throws {
        let refused = [
            "tell application \"Finder\" to delete every file",
            "tell app \"System Events\" to keystroke \"x\"",
            "set f to |application|",
            "do shell script \"rm -rf ~\"",
            "run script \"x\"",
            "«event aevtodoc» \"x\"",
            "use framework \"Foundation\"",
            "get system attribute \"HOME\"",
            "set the clipboard to \"x\"",
            "read POSIX file \"/etc/hosts\"",
            "display dialog \"hi\"",
            "on run\nend run",
            // A quote inside a comment must not hide the code after it.
            "-- \"\ndo shell script \"x\" --\"",
            "(* \" *) do shell script \"x\"",
            "set x to \"unterminated",
        ]
        for script in refused { check(AppScripting.refusal(script) != nil, "app_script refuses: \(script.prefix(40))") }
        let allowed = [
            "export front document to file \"/tmp/QuickAsk-out.jpg\" as JPEG with properties {compression factor:80}",
            "tell front document to crop bounds {0, 0, 1000, 1000}",
            "resize image front document width 1000 height 1000 -- shell scripts and app names in comments are fine",
            "set n to name of front document & \" do shell script application\"",
        ]
        for script in allowed { check(AppScripting.refusal(script) == nil, "app_script allows: \(script.prefix(40))") }

        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-existing-\(UUID()).jpg")
        try Data().write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }
        check(AppScripting.confirmationReason("export front document to file \"\(existing.path)\" as JPEG") != nil, "Writing over an existing file needs the user's go-ahead")
        check(AppScripting.confirmationReason("export front document to file \"/tmp/QuickAsk-new-\(UUID()).jpg\" as JPEG") == nil, "Exporting to a new file doesn't")
        check(AppScripting.confirmationReason("save front document") != nil, "Saving over the open file needs the go-ahead")
        check(AppScripting.confirmationReason("close front document saving no") != nil && AppScripting.confirmationReason("delete layer 2 of front document") != nil
              && AppScripting.confirmationReason("quit") != nil, "Deleting, closing and quitting need the go-ahead")
        check(AppScripting.confirmationReason("remove background of front document") == nil, "An undoable edit inside the document doesn't")
        let boot = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        check(AppScripting.hfsToPOSIX("\(boot):Users:me:a.jpg") == "/Users/me/a.jpg" && AppScripting.hfsToPOSIX("Backup:a.jpg") == "/Volumes/Backup/a.jpg", "HFS paths map to POSIX")
        check(AppScripting.safeBundleID("com.pixelmatorteam.pixelmator.x") != nil && AppScripting.safeBundleID("x\" to do shell script \"y") == nil, "Only plain bundle IDs go into the tell")
        check(AppScripting.wrapped("get name", bundleID: "com.example.app").contains("tell application id \"com.example.app\"\nget name\nend tell"), "Scripts run inside the selected app's tell block")

        // TextEdit has no .sdef file, so this also covers the `sdef` fallback.
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        check(AppScripting.isScriptable(bundle: textEdit), "TextEdit is scriptable")
        let items = try AppScripting.dictionary(bundle: textEdit)
        let overview = AppScripting.render(items, query: nil)
        check(overview.contains("Commands:") && overview.contains("Classes:") && overview.contains("document"), "The dictionary overview lists names by kind")
        check(AppScripting.render(items, query: "document").contains("class document"), "A query returns the full entry")
        check(ActivityStep.make(id: "1", tool: "mcp__quickask__app_script", input: ["script": "export front document\nto file \"x\""]).detail == "app script: export front document",
              "The work log shows a script's first line")
    }

    /// Per-app memory and the manual index, in a throwaway knowledge root.
    static func knowledgeChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-knowledge-\(UUID())")
        setenv("QUICKASK_KNOWLEDGE_ROOT", root.path, 1)
        defer { unsetenv("QUICKASK_KNOWLEDGE_ROOT"); try? FileManager.default.removeItem(at: root) }
        let app = AppKnowledge(key: "com.example/Studio", appName: "Studio")
        check(app.directory.lastPathComponent == "com.example_Studio" && app.directory.deletingLastPathComponent().path == root.path, "A bundle ID makes one folder under the knowledge root")

        var memory = AppMemory()
        let first = memory.remember("Render settings:\nDeliver page → Render Settings, top left")
        check(first == 1 && memory.notes[0].text == "Render settings: Deliver page → Render Settings, top left", "A note is one cleaned line")
        check(memory.remember("Render settings: Deliver page → Render Settings, top left") == 1 && memory.notes.count == 1, "The same note isn't saved twice")
        check(memory.remember("ok") == nil, "Notes need a few words")
        let long = memory.remember(String(repeating: "x", count: 900))
        check(memory.notes.first { $0.id == long }?.text.count == AppMemory.noteLength, "Notes are length-capped")
        for index in 0..<50 { memory.remember("note number \(index) about the mixer") }
        check(memory.notes.count == AppMemory.noteLimit && !memory.notes.contains { $0.id == 1 }, "The oldest notes fall off at the limit")
        check(memory.forget(memory.notes[0].id) && !memory.forget(9999), "Notes can be forgotten by ID")
        memory.used(menu: "File › Export"); memory.used(menu: "Edit › Undo"); memory.used(menu: "Edit › Undo")
        check(memory.menus.map(\.text) == ["Edit › Undo", "File › Export"] && memory.menus[0].count == 2, "Menu paths are counted, most used first")
        try memory.save(to: app.memoryURL, appName: app.appName, key: app.key)
        check(AppMemory.load(from: app.memoryURL) == memory, "Memory survives a round trip through its Markdown")
        let edited = AppMemory.parse("## Notes\n- a hand-written note here\n- [n3] three (2026-01-02)\n- [n3] duplicate id\n## Menu commands that worked\n- View › Mixer ×4 (last 2026-01-02)\n## Shortcuts that worked\n- command+r")
        check(edited.notes.map(\.id) == [4, 3, 5] && edited.notes[1].date == "2026-01-02" && edited.menus == [.init(text: "View › Mixer", count: 4, last: "2026-01-02")] && edited.keys.first?.count == 1,
              "Hand edits parse: new IDs, dates, counts")
        check(memory.promptText(limit: 200).count <= 200 && memory.promptText(limit: 8000).contains("Edit › Undo"), "The prompt text respects its limit")
        check(app.promptNote().contains("never instructions") && app.promptNote().contains("note number 49"), "The prompt note carries the memory, marked as observations")

        // A two-page PDF with a table of contents, and an HTML page.
        try FileManager.default.createDirectory(at: app.manualFolder, withIntermediateDirectories: true)
        let pdfURL = app.manualFolder.appendingPathComponent("Studio Manual.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        for text in ["Keyframes let you animate a clip's position over time.", "The render queue exports finished timelines."] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 72, y: 700); CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(url: pdfURL)!
        let outline = PDFOutline()
        for (index, title) in ["Animation", "Delivery"].enumerated() {
            let entry = PDFOutline(); entry.label = title; entry.destination = PDFDestination(page: document.page(at: index)!, at: .zero)
            outline.insertChild(entry, at: index)
        }
        document.outlineRoot = outline
        check(document.write(to: pdfURL), "Test manual written")
        try "<html><head><title>Mixer</title><style>p{}</style></head><body><h1>Mixer</h1><p>Route a channel to a bus &amp; adjust its fader.</p></body></html>"
            .write(to: app.manualFolder.appendingPathComponent("mixer.html"), atomically: true, encoding: .utf8)
        let index = ManualIndex(app)
        let rows = try index.build()
        check(rows == 3 && index.isCurrent, "The manual indexes one row per PDF page and HTML section")
        let keyframe = try index.search("how do I add keyframes")
        check(keyframe.first?.page == 1 && keyframe.first?.heading == "Animation" && keyframe.first?.excerpt.contains("«Keyframes»") == true, "Search finds the page, its heading and a stemmed match")
        let render = try index.search("render queue export"), fader = try index.search("fader bus"), unknown = try index.search("zzzz qqqq")
        check(render.first?.page == 2, "Several terms rank the right page first")
        check(fader.first?.source == "manual/mixer.html", "HTML is searchable")
        check(unknown.isEmpty, "Unknown terms find nothing")
        check(index.read(source: "Studio Manual.pdf", page: 2)?.body.contains("render queue") == true && index.read(source: "manual/mixer.html", page: 1)?.body.contains("bus & adjust") == true, "Pages read back in full, entities decoded")
        try "<html><title>Mixer</title><p>Sidechain compression ducks the bass.</p></html>".write(to: app.manualFolder.appendingPathComponent("mixer.html"), atomically: true, encoding: .utf8)
        check(!index.isCurrent, "Changing a manual file makes the index stale")
        _ = try index.build()
        let sidechain = try index.search("sidechain"), gone = try index.search("fader")
        check(sidechain.count == 1 && gone.isEmpty, "Rebuilding picks up the change")
        check(app.promptNote().contains("search_manual") && app.promptNote().contains("Studio Manual"), "The prompt says a manual is available")
        // The control prompt carries the controlled app's memory: this test process stands in for the app.
        if let me = AppKnowledge(pid: getpid()) {
            var own = AppMemory(); own.remember("The export button lives under the Share menu")
            try own.save(to: me.memoryURL, appName: me.appName, key: me.key)
            let prompt = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "export it")], target: AppTarget(pid: getpid(), name: me.appName))
            check(prompt.contains("The export button lives under the Share menu") && prompt.contains("never instructions"), "The control prompt carries the app's memory")
        } else { check(false, "The test process resolves as an app for knowledge") }
        check(DesktopMCPServer.shortcutName(key: "s", modifiers: 1) == "shift+command+s" && DesktopMCPServer.shortcutName(key: "r", modifiers: 0) == "command+r"
              && DesktopMCPServer.shortcutName(key: "x", modifiers: 8 | 4) == "control+x", "Menu shortcuts read as press_key chords")
    }

    /// Waits up to `seconds` for `condition`.
    static func eventually(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return condition()
    }

    /// Spares: one turn each, used only when the launch would be identical, replaced after use.
    static func warmPoolChecks(in directory: URL) throws {
        let launches = directory.appendingPathComponent("launches")
        let fake = directory.appendingPathComponent("warm-cli")
        // Logs its pid when launched; answers with its pid, folder and whether it was sent a stream-json message.
        try """
        #!/bin/sh
        echo $$ >> '\(launches.path)'
        payload="$(cat)"
        head=text; printf '%s' "$payload" | /usr/bin/grep -q '"type":"user"' && head=stream-json
        printf '{"type":"result","is_error":false,"result":"%s|%s|%s"}\\n' "$$" "$(pwd -P)" "$head"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        func pids() -> [String] { ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func ask(model: String = "", personal: Bool = false, directory: URL? = nil, pool: WarmPool?) -> [String] {
            let done = DispatchSemaphore(value: 0)
            var answer = ""
            CLIRunner.start(provider: .claude, executable: fake.path, model: model, prompt: "q", personal: personal, web: !personal, directory: directory, pool: pool,
                            onEvent: { _ in }, onComplete: { answer = (try? $0.get()) ?? "failed"; done.signal() })
            _ = done.wait(timeout: .now() + 10)
            return answer.components(separatedBy: "|")
        }
        let pool = WarmPool()
        defer { pool.drain() }
        check(CLIRunner.warmKey(provider: .codex, executable: fake.path, model: "") == nil
              && CLIRunner.warmKey(provider: .claude, executable: fake.path, model: "", desktop: true) == nil
              && CLIRunner.warmKey(provider: .claude, executable: fake.path, model: "", personal: true, desktop: true) != nil,
              "Codex, app control and app context never use a spare")
        CLIRunner.prepare(provider: .claude, executable: fake.path, model: "", web: true, pool: pool)
        check(eventually { pids().count == 1 && pool.count == 1 }, "A spare launches before the question")
        let spare = pids()[0]
        let warm = ask(pool: pool)
        check(warm.first == spare, "The question goes to the waiting spare")
        check(warm.last == "stream-json", "A spare is sent the prompt as a stream-json message")
        check(warm.count == 3 && eventually { !FileManager.default.fileExists(atPath: warm[1]) }, "The spare's empty folder is removed after its answer")
        check(eventually { pids().count == 2 && pool.count == 1 }, "A used spare is replaced")
        let replacement = pids()[1]
        let other = ask(model: "other", pool: pool)
        check(other.first != replacement && kill(pid_t(replacement)!, 0) == 0, "A different model starts cold and leaves the spare waiting")
        check(eventually { pool.count == 2 }, "The other model gets a spare of its own")
        kill(pid_t(replacement)!, SIGKILL)
        check(eventually { pool.count == 1 }, "An exited spare isn't counted")
        let afterDeath = ask(pool: pool)
        check(afterDeath.first != replacement && afterDeath.first.map { pids().contains($0) } == true, "An exited spare is skipped and the request starts cold")
        check(eventually { pool.count == 2 }, "A request with no spare leaves one for the next")
        let personal = ask(personal: true, pool: pool)
        check(personal.count == 3 && personal[1] == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path, "My setup runs from the home folder")
        check(eventually { pool.count == 3 }, "My setup keeps its own spare")
        // A chat set to a folder with !cd: My setup starts there, cold or from a spare made for that folder.
        let chatFolderURL = directory.appendingPathComponent("chat folder")
        try FileManager.default.createDirectory(at: chatFolderURL, withIntermediateDirectories: true)
        let chatFolder = URL(fileURLWithPath: String(cString: realpath(chatFolderURL.path, nil)))  // pwd -P's spelling: /private/var, not /var
        let inFolder = ask(personal: true, directory: chatFolder, pool: pool)
        check(inFolder.count == 3 && inFolder[1] == chatFolder.path && inFolder[2] == "stream-json", "A chat in a !cd folder runs My setup from it")
        check(FileManager.default.fileExists(atPath: chatFolder.path), "The chat's folder is left alone afterwards")
        check(ask(personal: true, pool: pool)[1] == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path, "A chat with no folder still runs from home, never the last chat's folder")
        CLIRunner.prepare(provider: .claude, executable: fake.path, model: "", personal: true, directory: chatFolder, pool: pool)
        let folderSpare = pids().count
        let warmFolder = ask(personal: true, directory: chatFolder, pool: pool)
        check(eventually { pids().count > folderSpare - 1 } && warmFolder[1] == chatFolder.path, "A spare made for the folder answers from it")
        let cold = ask(pool: nil)
        check(cold.last == "stream-json", "Without a pool, the prompt is still a stream-json message")
        let waiting = Set(pids())
        pool.drain()
        check(pool.count == 0 && eventually { waiting.allSatisfy { kill(pid_t($0)!, 0) != 0 } }, "Draining ends every spare")
        let idle = WarmPool()
        idle.idleLimit = 0.3
        idle.prepare(CLIRunner.warmKey(provider: .claude, executable: fake.path, model: "", web: true)!)
        check(idle.count == 1 && eventually(3) { idle.count == 0 }, "Spares go once idle")
    }

    @MainActor static func main() async throws {
        verifyPopupLayout { condition, name in check(condition, name) }
        try verifyChatRecovery { condition, name in check(condition, name) }
        try verifyStreaming { condition, name in check(condition, name) }
        try await verifyChatHistory { condition, name in check(condition, name) }
        try verifyStatusFeed { condition, name in check(condition, name) }
        try verifyVoice { condition, name in check(condition, name) }
        let codex = EventDecoder(provider: .codex)
        event(#"{"type":"item.updated","item":{"id":"a","type":"agent_message","text":"Hi"}}"#, into: codex)
        event(#"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"Hi 🌍"}}"#, into: codex)
        check(codex.text == "Hi 🌍", "Codex snapshots replace rather than duplicate")
        event(#"{"type":"item.completed","item":{"id":"b","type":"reasoning","text":"hidden"}}"#, into: codex)
        check(codex.text == "Hi 🌍", "Reasoning is excluded")
        event(#"{"type":"item.completed","item":{"id":"c","type":"agent_message","text":"Second"}}"#, into: codex)
        check(codex.text == "Hi 🌍\n\nSecond", "Distinct messages are retained")
        event(#"{"type":"turn.failed","error":{"message":"Limit reached"}}"#, into: codex)
        check(codex.failure == "Limit reached", "Codex structured errors")

        let claude = EventDecoder(provider: .claude)
        event(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"delta":{"type":"text_delta","text":"Hello "}}}"#, into: claude)
        event(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"🌍"}}}"#, into: claude)
        event(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello 🌍"}]}}"#, into: claude)
        check(claude.text == "Hello 🌍", "Claude partial events and snapshot deduplication")
        event(#"{"type":"stream_event","parent_tool_use_id":"child","event":{"delta":{"type":"text_delta","text":"hidden"}}}"#, into: claude)
        check(claude.text == "Hello 🌍", "Subagent messages are excluded")
        event(#"{"type":"result","is_error":false,"result":"Final 🌍"}"#, into: claude)
        check(claude.text == "Final 🌍", "Final result is authoritative")
        let fallback = EventDecoder(provider: .claude)
        event(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Answer"}]}}"#, into: fallback)
        check(fallback.text == "Answer", "Claude non-partial fallback")
        event(#"{"type":"result","is_error":true,"errors":["Sign in first"]}"#, into: fallback)
        check(fallback.failure == "Sign in first", "Claude structured errors")
        event("not JSON", into: fallback)
        check(fallback.text == "Answer", "Unknown output doesn't enter transcript")

        let shownDir = FileManager.default.temporaryDirectory.appendingPathComponent("quickask-shown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shownDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shownDir) }
        let shot = shownDir.appendingPathComponent("My Shot.png"), clip = shownDir.appendingPathComponent("clip.mp4")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shot); try Data().write(to: clip)
        let shower = EventDecoder(provider: .claude)
        event(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Here it is."}}}"#, into: shower)
        let showCall = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__show-your-work__show_image","input":{"path":"\#(shot.path)","title":"Home [v2]"}}]}}"#
        event(showCall, into: shower); event(showCall, into: shower)
        check(shower.text == "Here it is.\n\n![Home (v2)](\(shot.absoluteString))\n\n", "show_image puts the picture in the reply, once")
        check(MarkdownBlocks.parse(shower.text).last?.kind == .image(shot, alt: "Home (v2)"), "A shown picture renders as a local image")
        event(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"mcp__show-your-work__show_video","input":{"path":"\#(clip.path)"}}]}}"#, into: shower)
        check(shower.text.contains("![clip.mp4](\(clip.absoluteString))") && MarkdownBlocks.parse(shower.text).last?.kind == .video(clip, alt: "clip.mp4"),
              "show_video plays the video in the reply")
        event(#"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"tool_use","id":"t3","name":"mcp__show-your-work__show_image","input":{"path":"\#(shot.path)"}}]}}"#, into: shower)
        event(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"mcp__show-your-work__show_image","input":{"path":"/no/such/gone.png"}}]}}"#, into: shower)
        check(shower.text.components(separatedBy: shot.absoluteString).count == 2 && !shower.text.contains("gone.png"), "A subagent's pictures and missing files stay out of the reply")
        event(#"{"type":"result","is_error":false,"result":"Done."}"#, into: shower)
        check(shower.text.hasPrefix("![Home (v2)](\(shot.absoluteString))") && shower.text.hasSuffix("\n\nDone."), "The final result keeps the pictures shown before it")
        check(EventDecoder.toolStatus("mcp__show-your-work__show_image") == "Showing an image…", "Showing a picture has its own status")
        let shownPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "hi")])
        let setupPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "hi")], personal: true)
        check(shownPrompt.contains("Images render in this window") && !shownPrompt.contains("show_image") && setupPrompt.contains("show_image"), "Every route is told images render; My setup about show_image")
        let flatSetup = setupPrompt.replacingOccurrences(of: "\n", with: " ")
        check(flatSetup.contains("look_at_screen tool") && flatSetup.contains("look again whenever it may have changed") && !shownPrompt.contains("look_at_screen"),
              "My setup is told when to look at the screen; other routes aren't offered it")
        check(shownPrompt.contains("claude.ai artifact link on its own") && !shownPrompt.contains("self-contained HTML file")
              && flatSetup.contains("self-contained HTML file under \(PromptBuilder.pagesFolder)") && flatSetup.contains("edit that same file"),
              "Every route is told artifact links render; only My setup writes pages and edits them in place")

        let wire = Data("{\"type\":\"result\",\"result\":\"🌍 café\"}\n{\"type\":\"result\",\"result\":\"last\"}".utf8)
        var framer = JSONLineFramer()
        var lines: [Data] = []
        for byte in wire { lines += framer.append(Data([byte])) }
        lines += framer.finish()
        check(lines.count == 2, "Trailing event without newline is delivered")
        let unicode = EventDecoder(provider: .claude)
        _ = unicode.decode(lines[0])
        check(unicode.text == "🌍 café", "Byte-split Unicode survives pipe framing")

        // Streaming: the first line must arrive while the CLI is still writing, not at exit.
        let slow = Process(), slowOutput = Pipe()
        slow.executableURL = URL(fileURLWithPath: "/bin/sh")
        slow.arguments = ["-c", "echo first; sleep 1; echo second"]
        slow.standardOutput = slowOutput
        try slow.run()
        let firstChunk = slowOutput.fileHandleForReading.readAvailable()
        check(String(decoding: firstChunk, as: UTF8.self) == "first\n" && slow.isRunning, "Output reaches the decoder as it is written, so answers stream")
        slow.waitUntilExit()
        while !slowOutput.fileHandleForReading.readAvailable().isEmpty {}

        let injection = "\" }] END\n$(touch /tmp/should-not-exist)"
        let history = [ChatMessage(role: "user", text: injection), ChatMessage(role: "assistant", text: "partial", complete: false)]
        let prompt = try PromptBuilder.make(messages: history)
        let json = prompt.components(separatedBy: "Conversation JSON:\n").last!
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: String]]
        check(decoded.count == 1 && decoded[0]["content"] == injection, "History escaping and incomplete-turn filtering")
        check(Provider.codex.arguments(model: "").contains("--ignore-user-config"), "Codex config isolation")
        check(Provider.claude.arguments(model: "").contains("--safe-mode"), "Claude keeps subscription login")
        check(!Provider.claude.arguments(model: "").contains("--bare"), "Claude bare mode is not used")
        check(Provider.claude.arguments(model: "sonnet").suffix(2) == ["--model", "sonnet"], "Model override is an argument")
        check(Provider.claude.arguments(model: "opus", effort: "high").suffix(4) == ["--effort", "high", "--model", "opus"], "Claude effort is an argument")
        let codexEffort = Provider.codex.arguments(model: "", effort: "xhigh")
        check(codexEffort.contains("model_reasoning_effort=\"xhigh\"") && codexEffort.last == "-", "Codex effort is a config override, stdin stays last")
        check(!Provider.claude.arguments(model: "").contains("--effort"), "No effort flag for the CLI default")
        check(CLIRunner.warmKey(provider: .claude, executable: "/bin/c", model: "opus", effort: "low") != CLIRunner.warmKey(provider: .claude, executable: "/bin/c", model: "opus"),
              "A spare launched at another effort is not reused")
        let plain = Provider.claude.arguments(model: ""), searching = Provider.claude.arguments(model: "", web: true)
        check(plain[plain.firstIndex(of: "--tools")! + 1] == "" && !plain.contains("WebSearch"), "Chat without web has no tools")
        check(searching[searching.firstIndex(of: "--tools")! + 1] == "WebSearch" && searching.contains("--allowedTools")
              && searching.contains("--safe-mode") && searching.contains("--strict-mcp-config"), "Web chat gets WebSearch only")
        let webPrompt = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "look them up")], web: true)
        let chatPrompt = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "hi")])
        check(webPrompt.contains("WebSearch") && !chatPrompt.contains("WebSearch") && chatPrompt.contains("You have no tools."),
              "Only the web chat prompt offers search")
        check(EventDecoder.toolStatus("WebSearch") == "Searching the web…", "Web search shows its own status")
        let target = AppTarget(pid: 123, name: "Fixture App")
        let desktop = DesktopSession(target: target, ownerPID: 1, executable: "/tmp/Quick Ask", lease: "/tmp/control-lease")
        let codexControl = Provider.codex.arguments(model: "", desktop: desktop)
        check(codexControl.contains("mcp_servers.quickask.command=\"/tmp/Quick Ask\""), "Codex MCP executable is TOML escaped")
        check(codexControl.contains("mcp_servers.quickask.required=true"), "Control can't silently run without its MCP server")
        let claudeControl = Provider.claude.arguments(model: "", desktop: desktop)
        check(claudeControl.contains("--restricted") && !claudeControl.contains("--safe-mode"), "Claude control mode explicitly loads only the request MCP")
        let configIndex = claudeControl.firstIndex(of: "--mcp-config")!
        let config = try JSONSerialization.jsonObject(with: Data(claudeControl[configIndex + 1].utf8)) as! [String: Any]
        let servers = config["mcpServers"] as! [String: Any]
        check(servers.count == 1 && servers["quickask"] != nil, "Only QuickAsk's MCP is exposed")
        check(DesktopMCPServer.tools.count == 20, "Complete desktop tool catalog")
        try knowledgeChecks()
        try scriptingChecks()
        check(DesktopMCPServer.userTookOver(targetIsFront: true, idleSeconds: 0.4), "Control pauses while the user works in the app")
        check(!DesktopMCPServer.userTookOver(targetIsFront: false, idleSeconds: 0.1), "The user typing in another app doesn't stop background control")
        check(!DesktopMCPServer.userTookOver(targetIsFront: true, idleSeconds: 5), "An idle front app keeps control going")
        check(DesktopMCPServer.menuTitle("Export…") == DesktopMCPServer.menuTitle("export...") && DesktopMCPServer.menuTitle(" Save ") == "save", "Menu paths ignore case and ellipses")
        check((try? DesktopMCPServer.parseKey("f5"))?.0 == 96 && (try? DesktopMCPServer.parseKey("command+="))?.0 == 24, "Function and punctuation keys parse")
        let key = try DesktopMCPServer.parseKey("command+shift+s")
        check(key.0 == 1 && key.1.contains(.maskCommand) && key.1.contains(.maskShift), "Key chord parsing")
        do { _ = try DesktopMCPServer.parseKey("unknown+Return"); check(false, "Invalid modifiers rejected") }
        catch { check(true, "Invalid modifiers rejected") }
        let controlPrompt = try PromptBuilder.make(messages: history, target: target)
        check(controlPrompt.contains("Fixture App") && !controlPrompt.contains("do not inspect"), "Control prompt enables scoped tools")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fake-cli")
        try """
        #!/bin/sh
        payload="$(cat)"
        test -n "$payload" || exit 3
        # A full stderr pipe must not deadlock stdout handling.
        /usr/bin/awk 'BEGIN { for (i=0; i<6000; i++) print "diagnostic diagnostic" }' >&2
        printf '%s\\n' '{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Process 🌍"}}}'
        printf '%s' '{"type":"result","is_error":false,"result":"Process 🌍"}'
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let complete = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
        CLIRunner.start(provider: .claude, executable: fixture.path, model: "", prompt: injection,
                        onEvent: { _ in }, onComplete: { result = $0; complete.signal() })
        check(complete.wait(timeout: .now() + 10) == .success, "Process completes despite large stderr")
        check((try? result?.get()) == "Process 🌍", "End-to-end CLI decoding")
        let sleeper = directory.appendingPathComponent("sleeper")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
        let stopped = DispatchSemaphore(value: 0)
        let handle = CLIRunner.start(provider: .claude, executable: sleeper.path, model: "", prompt: "",
                                    onEvent: { _ in }, onComplete: { _ in stopped.signal() })
        try await Task.sleep(nanoseconds: 150_000_000)
        handle.cancel()
        check(stopped.wait(timeout: .now() + 5) == .success, "Cancellation releases a running process")
        try warmPoolChecks(in: directory)
        check(ExecutableFinder.find(.claude, customPath: directory.path + "/missing") == nil, "Invalid custom paths don't silently fall back")
        let regions = [DisplayRegion(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)), DisplayRegion(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800))]
        check(DisplayContext.display(for: CGRect(x: 900, y: 20, width: 500, height: 200), regions: regions)?.id == 2, "Largest popup overlap determines display")
        check(DisplayContext.display(for: CGRect(x: 900, y: 20, width: 200, height: 200), regions: regions)?.id == 2, "Popup center breaks equal overlap")
        let local = ContextWindow(id: 7, pid: 20, bundleID: "com.cxmail.app", appName: "CXMail", title: "Mail", bounds: .zero)
        check(DisplayContext.candidate([local], preferredPID: 90, preferredWindow: 80)?.id == 7, "Focus on another display cannot override local window")
        check(DisplayContext.candidate([], preferredPID: 90) == nil, "Empty display has no context")
        check(DisplayContext.display(for: CGRect(x: -9000, y: -9000, width: 100, height: 100), regions: regions) == nil, "Off-display popup cannot select another screen")
        let selection = AppSelection(pid: 20, bundleID: "com.cxmail.app", windowLabel: "main", windowID: 7, revision: "r1", label: "Invoice · sender", records: ["account_id": "a", "folder": "INBOX", "uid": "9"])
        let snapshot = ContextSnapshot(displayID: 1, windowID: 7, pid: 20, bundleID: "com.cxmail.app", appName: "CXMail", windowTitle: "Mail", capturedAt: 0, launchTime: 0, selection: selection, text: "Private full body", document: "")
        check(snapshot.routingEvidence["visible_text"] == nil, "Routing omits body text when selection labels exist")
        check(snapshot.routingEvidence["selection_labels"] as? String == selection.label, "Routing includes bounded selection labels")
        // Router: one call, several questions, combined locally.
        let mailWindow = ContextWindow(id: 7, pid: 20, bundleID: "com.cxmail.app", appName: "CXMail", title: "Mail", bounds: .zero)
        let termWindow = ContextWindow(id: 8, pid: 21, bundleID: "com.mitchellh.ghostty", appName: "Ghostty", title: "~/Projects/quickask", bounds: .zero)
        let routing = RoutingInput(question: "Help me with this error", history: [], imageCount: 0, windows: [termWindow, mailWindow],
                                   candidate: snapshot, projects: [.init(name: "Quick Ask", repos: ["quickask"])])
        let state = routing.state
        let stateText = String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self)
        check((state["visible_windows"] as? [[String: Any]])?.count == 2 && stateText.contains("Ghostty") && stateText.contains("quickask"), "Router state lists every visible window and project repositories")
        check(!stateText.contains("Private full body"), "Router state omits body text when selection labels exist")
        check((state["connected_apps"] as? [String])?.count == 1, "Router state names only connected apps that are visible")
        let questions = RoutingQuestion.all(for: routing)
        let questionNames = Set(questions.map(\.name))
        check(questionNames.isSuperset(of: ["self_contained", "needs_screen", "needs_visual", "wants_app_action", "target", "project"]) && !questionNames.contains("about_attached_image") && !questionNames.contains("follow_up"), "Questions match the situation")
        check(RoutingQuestion.all(for: RoutingInput(question: "q", history: [.init(role: "assistant", text: "a")], imageCount: 1, windows: [termWindow], candidate: nil, projects: []))
              .map(\.name).contains("about_attached_image"), "Image and follow-up questions are asked when relevant")
        check(RoutingQuestion.decisionsBody(questions).count == questions.count && RoutingQuestion.jevBody(questions).count == questions.count, "Both engines get every question in one request")
        func answers(_ yes: [String: Double], target: (String, Double)? = nil, project: (String, Double)? = nil) -> [String: Any] {
            var list: [[String: Any]] = yes.map { ["type": "predicate", "name": $0.key, "probability": $0.value] }
            if let target { list.append(["type": "choice", "name": "target", "choice": target.0, "confidence": target.1]) }
            if let project { list.append(["type": "choice", "name": "project", "choice": project.0, "confidence": project.1]) }
            return ["answers": list]
        }
        let bars = RoutingBars.forEngine(.decisions, high: 0.9)
        func plan(_ response: [String: Any], previous: RouteScope? = nil, input: RoutingInput? = nil) -> RoutePlan? {
            RoutingSignals.parse(response, engine: .decisions, questions: questions).map { RoutePlan.make($0, input: input ?? routing, bars: bars, previous: previous) }
        }
        let general = plan(answers(["self_contained": 0.97, "needs_screen": 0.05], target: ("none", 0.9)))
        check(general?.scope == .general && general?.window == nil && general?.label == "General chat", "Self-contained and screen-free → General chat")
        check(plan(answers(["self_contained": 0.86, "needs_screen": 0.0], target: ("none", 0.99)))?.scope == .general, "Screen-free with no target is General even when self-contained is just under the bar")
        check(plan(answers(["self_contained": 0.86, "needs_screen": 0.4], target: ("none", 0.99)))?.scope == .all, "An unsure screen need still sends context")
        let screen = plan(answers(["self_contained": 0.1, "needs_screen": 0.96, "needs_visual": 0.1], target: ("w0", 0.92), project: ("p0", 0.9)))
        check(screen?.scope == .screen && screen?.window == termWindow && screen?.connector == nil && screen?.project == "Quick Ask" && screen?.screenshot == false, "Clear screen need with a clear target → that window's content")
        check(screen?.label == "Screen · Ghostty · ~/Projects/quickask · Quick Ask", "The label says what was sent")
        let action = plan(answers(["needs_screen": 0.95, "wants_app_action": 0.95], target: ("w1", 0.9)))
        check(action?.connector == .cxmail && action?.writes == true, "A clear action on a clear connected app gets write tools")
        let readOnly = plan(answers(["needs_screen": 0.95, "wants_app_action": 0.5], target: ("w1", 0.9)))
        check(readOnly?.connector == .cxmail && readOnly?.writes == false && readOnly?.label.contains("read-only") == true, "An unclear action stays read-only")
        let unsure = plan(answers(["self_contained": 0.5, "needs_screen": 0.6, "wants_app_action": 0.97], target: ("w1", 0.6)))
        check(unsure?.scope == .all && unsure?.window == mailWindow && unsure?.writes == false, "Uncertainty sends all context from the candidate, never write tools")
        let visual = plan(answers(["needs_screen": 0.95, "needs_visual": 0.95], target: ("w0", 0.9)))
        check(visual?.screenshot == true && visual?.label.contains("screenshot") == true, "A visual question adds a screenshot")
        check(visual?.label(screenshotSent: false).contains("screenshot") == false, "A screenshot that couldn't be captured isn't claimed")
        let followInput = RoutingInput(question: "and the second one?", history: [.init(role: "user", text: "Explain this error"), .init(role: "assistant", text: "It means…")],
                                       imageCount: 0, windows: [termWindow, mailWindow], candidate: snapshot, projects: [])
        let followSignals = RoutingSignals.parse(answers(["self_contained": 0.97, "needs_screen": 0.05, "follow_up": 0.95]), engine: .decisions, questions: RoutingQuestion.all(for: followInput))!
        check(RoutePlan.make(followSignals, input: followInput, bars: bars, previous: .screen).scope == .all, "A follow-up to a screen answer isn't dropped to General")
        check(RoutePlan.make(followSignals, input: followInput, bars: bars, previous: .general).scope == .general, "A follow-up to a general answer stays general")
        let imageInput = RoutingInput(question: "What code is this?", history: [], imageCount: 1, windows: [termWindow], candidate: snapshot, projects: [])
        let imageQuestions = RoutingQuestion.all(for: imageInput)
        let imagePlan = RoutingSignals.parse(answers(["about_attached_image": 0.95, "needs_screen": 0.1, "self_contained": 0.4]), engine: .decisions, questions: imageQuestions)
            .map { RoutePlan.make($0, input: imageInput, bars: bars, previous: nil) }
        check(imagePlan?.scope == .general, "A question about the attached image → General chat")
        check(plan(answers(["needs_screen": 0.95], target: ("w9", 0.99)))?.scope == .all, "An unoffered window is no pick")
        check(plan(["answers": [["type": "refusal", "name": "needs_screen"], ["type": "predicate", "name": "self_contained", "probability": true],
                                ["type": "predicate", "name": "needs_visual", "probability": 1.5]]]) == nil, "Refused or malformed answers are no judgment; none at all is a router failure")
        let duplicated = RoutingSignals.parse(["answers": [["type": "predicate", "name": "needs_screen", "probability": 0.9], ["type": "predicate", "name": "needs_screen", "probability": 0.1], ["type": "predicate", "name": "self_contained", "probability": 0.2]]], engine: .decisions, questions: questions)
        check(duplicated?.yes["needs_screen"] == nil && duplicated?.yes["self_contained"] == 0.2, "A question answered twice is no judgment")
        let jev = RoutingSignals.parse(["answers": ["needs_screen": ["type": "noul", "noul": 0.9], "target": ["type": "choice", "choice": "w0", "confidence": 0.8]]], engine: .jev, questions: questions)
        check(jev?.yes["needs_screen"] == 0.9 && jev?.choices["target"]?.key == "w0", "Jev answers use the same questions")
        // My setup: a normal Claude session from the home folder
        let personalArgs = Provider.claude.arguments(model: "", personal: true)
        check(!personalArgs.contains("--safe-mode") && !personalArgs.contains("--tools") && !personalArgs.contains("--strict-mcp-config")
              && !personalArgs.contains("--permission-mode") && !personalArgs.contains("--disable-slash-commands") && !personalArgs.contains("--restricted"),
              "My setup loads CLAUDE.md, MCP servers, tools and the user's own permission mode")
        check(personalArgs.contains("--no-session-persistence") && Provider.claude.arguments(model: "", imagePaths: [""], personal: true).contains("--input-format"), "My setup keeps streaming and image input")
        check(Provider.codex.arguments(model: "", personal: true).contains("--ignore-user-config"), "Codex is unaffected by My setup")
        let personalPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "What should we focus on today?")], personal: true)
        check(personalPrompt.contains("home folder") && !personalPrompt.contains("You have no tools") && !personalPrompt.contains("do not inspect"), "My setup prompt doesn't forbid tools")
        let personalInput = RoutingInput(question: "What should we focus on today?", history: [], imageCount: 0, windows: [termWindow], candidate: snapshot, projects: [], personalAvailable: true)
        let personalQuestions = RoutingQuestion.all(for: personalInput)
        check(personalQuestions.contains { $0.name == "about_my_work" } && !RoutingQuestion.all(for: routing).contains { $0.name == "about_my_work" }, "The My setup question is asked only when Claude is selected")
        func personalPlan(_ yes: [String: Double], previous: RouteScope? = nil) -> RoutePlan? {
            RoutingSignals.parse(answers(yes, target: ("none", 0.95)), engine: .decisions, questions: personalQuestions).map { RoutePlan.make($0, input: personalInput, bars: bars, previous: previous) }
        }
        check(personalPlan(["about_my_work": 0.95, "needs_screen": 0.05, "self_contained": 0.9])?.scope == .personal, "About your own work → My setup, even when self-contained")
        check(personalPlan(["about_my_work": 0.95, "needs_screen": 0.95])?.scope != .personal, "A question about the screen isn't sent to My setup")
        check(personalPlan(["about_my_work": 0.4, "needs_screen": 0.05, "self_contained": 0.95])?.scope == .general, "Unclear personal relevance stays general")
        check(personalPlan(["about_my_work": 0.75, "needs_screen": 0.35, "self_contained": 0.3])?.scope == .personal, "My setup has its own lower bar (0.7 on Decisions)")
        check(personalPlan(["about_my_work": 0.65, "needs_screen": 0.35, "self_contained": 0.3])?.scope != .personal, "Below My setup's bar it isn't chosen")
        check(RoutePlan.personal("x").label == "My setup" && RoutePlan.personal("x").window == nil, "My setup sends no screen content")
        // 2026-10-18: with Watcharr open in Zen, "look at my local version" scored needs_screen 0.94 and was
        // answered from the page with no tools ("I can't see your local Telly").
        let tellyHistory: [ChatMessage] = [.init(role: "user", text: "but telly has a logging feature"),
                                           .init(role: "assistant", text: "There's a Telly app by Telly Studios that logs what you watch.")]
        for (question, own) in [("no - look at my local version (i called it telly)", true), ("check my version instead, the one I named telly", true),
                                ("no, I mean the one I built, not the app store one", true), ("compare it with my own self-hosted tracker", true),
                                ("what's running on my NAS for this?", false), ("is this my local version?", false), ("What is OAuth?", false),
                                ("I called it a day after the second season", false), ("what should I call it?", false), ("is the one on the App Store any good?", false), ("I called Sam about the invoice", false)] {
            check(RoutingInput.refersToOwnThing(question) == own, "\(own ? "Points" : "Doesn't point") at the user's own thing: \(question)")
        }
        // 2026-10-21: "is this worth it for me with my setup?" (after a Usenet question) was read as the Ghostty
        // window on screen ("I can't see your Usenet setup").
        for (question, own) in [("is this worth it for me with my setup?", true), ("would that work with my current config?", true),
                                ("does it fit my stack", true), ("what's best for my homelab", true),
                                ("is it worth it given my setup?", true), ("check my setup", true), ("what about my setup?", true),
                                ("is my setup good enough", true), ("help me set up my router", false), ("is the gear on this page right for my rig", false),
                                ("does this listing work with my setup?", false), ("is what's on the screen right for my setup", false),
                                ("what's a good home server setup?", false), ("set up my account", false)] {
            check(RoutingInput.refersToOwnThing(question) == own, "\(own ? "Points" : "Doesn't point") at the user's setup: \(question)")
        }
        // 2026-10-23: "for quickask can we style the prev sessions drop down…" with example screenshots went to a
        // route with no tools ("I can't edit QuickAsk's code from here").
        let repos = ["quickask", "cxtasks", "telly", "Margin", "impact", "finance-app"]
        for (question, change) in [("for quickask can we style the prev sessions drop down a bit better and remove the blue", true),
                                   ("fix the sync bug in cxtasks", true), ("can you add a watchlist export to telly", true),
                                   ("please update finance-app's budget page", true), ("what is quickask?", false),
                                   ("can we change the margin on this page", false), ("what's the impact of fixing this?", false),
                                   ("fix this error", false), ("can you explain cxtasksd", false)] {
            check(RoutingInput.asksToChange(question, inRepos: repos) == change, "\(change ? "Asks" : "Doesn't ask") to change a named repo: \(question)")
        }
        let tellyInput = RoutingInput(question: "no - look at my local version (i called it telly)", history: tellyHistory, imageCount: 0, windows: [termWindow],
                                      candidate: snapshot, projects: [], personalAvailable: true)
        let tellyPlan = RoutingSignals.parse(answers(["about_my_work": 0.88, "needs_screen": 0.94, "self_contained": 0.2, "follow_up": 0.95], target: ("w0", 0.9)),
                                             engine: .decisions, questions: RoutingQuestion.all(for: tellyInput))
            .map { RoutePlan.make($0, input: tellyInput, bars: bars, previous: .general) }
        check(tellyPlan?.scope == .personal, "A correction pointing at the user's own Telly goes to My setup, even over a page about another one")
        let screenshotInput = RoutingInput(question: "look at my local version", history: [], imageCount: 0, windows: [termWindow], candidate: snapshot, projects: [], personalAvailable: true)
        check(RoutingSignals.parse(answers(["needs_screen": 0.95, "needs_visual": 0.95], target: ("w0", 0.9)), engine: .decisions, questions: RoutingQuestion.all(for: screenshotInput))
              .map { RoutePlan.make($0, input: screenshotInput, bars: bars, previous: nil) }?.scope != .personal, "A question that needs to see the screen isn't sent to My setup")
        check(RoutingSignals.parse(answers(["needs_screen": 0.95], target: ("w0", 0.9)), engine: .decisions, questions: RoutingQuestion.all(for: routing))
              .map { RoutePlan.make($0, input: RoutingInput(question: "look at my local version", history: [], imageCount: 0, windows: [termWindow], candidate: snapshot, projects: [], personalAvailable: false), bars: bars, previous: nil) }?.scope != .personal,
              "Without Claude, an own-thing reference doesn't choose My setup")
        let unrouted = RoutePlan.unrouted(windows: [termWindow, mailWindow], candidate: snapshot)
        check(unrouted.scope == .all && unrouted.window == mailWindow && unrouted.connector == .cxmail && !unrouted.writes && !unrouted.screenshot && unrouted.tools.isEmpty,
              "Routing off sends the candidate window read-only, with no screenshot or extra tools")
        check(RoutePlan.unrouted(windows: [termWindow], candidate: nil).window == termWindow, "Routing off falls back to the front window")
        check(RoutingEngine(rawValue: RoutingEngine.offTag) == nil, "Off is not an engine, so no request can be built for it")
        check(RoutingSignals.parse(answers(["about_my_work": 0.95, "needs_screen": 0.05], target: ("none", 0.95)), engine: .decisions, questions: personalQuestions)
              .map { RoutePlan.make($0, input: RoutingInput(question: "q", history: [], imageCount: 0, windows: [termWindow], candidate: snapshot, projects: [], personalAvailable: false), bars: bars, previous: nil) }?.scope != .personal,
              "Without Claude, My setup is never chosen")
        let claudeDecoder = EventDecoder(provider: .claude)
        event(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Checking your notes."}}}"#, into: claudeDecoder)
        event(#"{"type":"stream_event","event":{"type":"message_start"}}"#, into: claudeDecoder)
        event(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Focus on Acme."}}}"#, into: claudeDecoder)
        check(claudeDecoder.text == "Checking your notes.\n\nFocus on Acme.", "Turns before and after tool use stay separate")
        check(claudeDecoder.decode(Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__vault__search_vault"}]}}"#.utf8)).contains { if case .status(let s) = $0 { return s == "Using vault · search_vault…" }; return false }, "Tool use shows which tool is running")
        let toolRouting = RoutingInput(question: "Check our vault for a doc on this", history: [], imageCount: 0, windows: [termWindow], candidate: snapshot, projects: [])
        let toolRoutingQuestions = RoutingQuestion.all(for: toolRouting)
        check(Set(toolRoutingQuestions.map(\.name)).isSuperset(of: ["uses_vault", "uses_cxtasks", "uses_cxmail", "wants_app_action"]) && !toolRoutingQuestions.contains { $0.name.contains("margin") }, "The router is asked about each tool except Margin")
        let vaultPlan = RoutingSignals.parse(answers(["uses_vault": 0.97, "needs_screen": 0.05, "self_contained": 0.95, "wants_app_action": 0.1], target: ("none", 0.95)), engine: .decisions, questions: toolRoutingQuestions)
            .map { RoutePlan.make($0, input: toolRouting, bars: bars, previous: .general) }
        check(vaultPlan?.scope == .general && vaultPlan?.tools == [.vault] && vaultPlan?.toolWrites == false && vaultPlan?.label == "General chat · Vault", "A general chat gains the vault when asked to check it")
        let taskPlan = RoutingSignals.parse(answers(["uses_cxtasks": 0.95, "wants_app_action": 0.95, "needs_screen": 0.05, "self_contained": 0.95], target: ("none", 0.95)), engine: .decisions, questions: toolRoutingQuestions)
            .map { RoutePlan.make($0, input: toolRouting, bars: bars, previous: .general) }
        check(taskPlan?.tools == [.cxtasks] && taskPlan?.toolWrites == true, "A clear action on a tool may write")
        check(EventDecoder.toolStatus("mcp__quickask__vault__search_vault") == "Using vault · search_vault…" && EventDecoder.toolStatus("vault__search_vault") == "Using vault · search_vault…", "Gateway tool calls are named")
        check(EventDecoder.toolStatus("mcp__quickask__click_element") == "Controlling app…" && EventDecoder.toolStatus("Bash") == "Using Bash…", "Desktop control and built-in tools keep their status")
        check(RoutingBars.forEngine(.jev, high: 0.9).high == 0.8 && RoutingBars.forEngine(.decisions, high: 0.9).high == 0.9, "Bars are per engine")
        let projectDB = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-projects-\(UUID()).db")
        let sql = Process(); sql.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sql.arguments = [projectDB.path, "CREATE TABLE projects (id TEXT, name TEXT, sort_order INTEGER, archived INTEGER); CREATE TABLE project_repos (project TEXT, repo_path TEXT); INSERT INTO projects VALUES ('1','Quick Ask',0,0),('2','Old',1,1); INSERT INTO project_repos VALUES ('Quick Ask','/Users/x/Projects/quickask');"]
        try sql.run(); sql.waitUntilExit()
        check(ProjectRegistry.read(path: projectDB.path) == [.init(name: "Quick Ask", repos: ["quickask"])], "Projects are read with repo folder names; archived ones are skipped")
        check(ProjectRegistry.read(path: "/nonexistent/cxtasks.db").isEmpty, "A missing CXTasks database is no projects")
        check(ProjectRegistry.workspaces(path: projectDB.path).first?.path == "/Users/x/Projects/quickask", "Handoff inference reads exact registered folders locally")
        try? FileManager.default.removeItem(at: projectDB)
        let screenPayload = ScreenPayload(snapshot: snapshot, plan: unsure!, windows: [termWindow, mailWindow], screenshotAttached: true)
        let screenPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "Help me with this error")], screen: screenPayload)
        check(screenPrompt.contains("You have no tools") && screenPrompt.contains("Private full body") && screenPrompt.contains("wasn't sure") && screenPrompt.contains("screenshot of the user's display") && screenPrompt.contains("Ghostty"), "Screen answers get the window content, the notes, and no tools")
        let webScreenPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "Research this")], screen: screenPayload, web: true)
        check(webScreenPrompt.contains("WebSearch") && !webScreenPrompt.contains("You have no tools") && webScreenPrompt.contains("Ghostty"),
              "A Claude screen answer may search the web and still sees the window")
        func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        check(rejected { try GatewayPolicy.validate(connector: .cxmail, tool: "delete_email", arguments: ["confirmed": true], selection: selection) }, "Model confirmation cannot expose deletion")
        check(rejected { try GatewayPolicy.validate(connector: .cxmail, tool: "send_email", arguments: [:], selection: selection) }, "Email sending excluded")
        check(rejected { try GatewayPolicy.validate(connector: .cxtasks, tool: "archive_task", arguments: [:], selection: nil) }, "Task archiving excluded")
        check(rejected { try GatewayPolicy.validate(connector: .cxtasks, tool: "file_task", arguments: ["bg_allowed": true], selection: nil) }, "Task tools cannot launch background execution")
        check(rejected { try GatewayPolicy.validate(connector: .cxtasks, tool: "file_task", arguments: ["tripwire": "agent:run"], selection: nil) }, "Task tools cannot arm automated tripwires")
        check(rejected { try GatewayPolicy.validate(connector: .cxtasks, tool: "complete_task", arguments: ["task_id": "T99"], selection: nil) }, "Missing selected task blocks writes")
        check(rejected { try GatewayPolicy.validate(connector: .cxmail, tool: "archive_email", arguments: ["account_id": "a", "folder": "INBOX", "uid": 10], selection: selection) }, "Wrong email target blocks writes")
        try GatewayPolicy.validate(connector: .cxmail, tool: "flag_email", arguments: ["account_id": "a", "folder": "INBOX", "uid": 9, "flag": "read"], selection: selection)
        check(true, "Selected email accepts supported mutation")
        check(GatewayPolicy.safeMove(destination: "Invoices", folderOutput: "me | Invoices | other (0 unread)"), "Verified ordinary destination allowed")
        check(!GatewayPolicy.safeMove(destination: "Papierkorb", folderOutput: "me | Papierkorb | trash (0 unread)"), "Localized Trash role rejected")
        check(!GatewayPolicy.safeMove(destination: "Courrier", folderOutput: "me | Courrier | junk (0 unread)"), "Localized Junk role rejected")
        check(!GatewayPolicy.safeMove(destination: "Unknown", folderOutput: "me | INBOX | inbox (0 unread)"), "Unverified folder rejected")
        let fakeMCP = directory.appendingPathComponent("fixture-mcp")
        try #"""
        #!/usr/bin/python3
        import sys,json
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            if q['method']=='initialize': r={'protocolVersion':'2025-06-18','capabilities':{'tools':{}}}
            elif q['method']=='tools/list': r={'tools':[{'name':n,'inputSchema':{'type':'object','properties':{}}} for n in ['read_email','move_email','delete_email','send_email','complete_task','archive_task']]}
            else: r={'content':[{'type':'text','text':'fixture result'}],'isError':False}
            print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
        """#.write(to: fakeMCP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeMCP.path)
        let configuration = GatewayConfiguration(snapshot: snapshot, connectors: [.cxmail], executables: ["cxmail": fakeMCP.path], desktopControl: false)
        let handoff = String(decoding: try JSONEncoder().encode(configuration.handoff), as: UTF8.self)
        check(!handoff.contains("Private full body") && !handoff.contains("Invoice · sender"), "IPC descriptor omits screen text and selection labels")
        check(configuration.handoff.snapshot.selection?.sameTarget(as: selection) == true, "IPC metadata retains the frozen record identity")
        var valid = true
        let gateway = ContextGateway(configuration: configuration, valid: { valid })
        let names = try gateway.tools().compactMap { $0["name"] as? String }
        check(names.sorted() == ["cxmail__move_email", "cxmail__read_email"], "Discovery filters and namespaces the downstream catalog")
        let readOnlyGateway = ContextGateway(configuration: GatewayConfiguration(snapshot: snapshot, connectors: [.cxmail], executables: ["cxmail": fakeMCP.path], desktopControl: false, writes: false), valid: { true })
        let readOnlyNames = try readOnlyGateway.tools().compactMap { $0["name"] as? String }
        check(readOnlyNames == ["cxmail__read_email"], "A read-only route lists no write tools")
        check(rejected { _ = try readOnlyGateway.call("cxmail__move_email", arguments: ["account_id": "a", "uid": 9, "from_folder": "INBOX", "to_folder": "Archive"]) }, "A read-only route refuses write calls")
        check(!GatewayConfiguration(snapshot: snapshot, connectors: [.cxmail], executables: [:], desktopControl: false, writes: false).toolNames.contains("cxmail__archive_email"), "Read-only tool allowlist excludes writes")
        let readOnlyPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "archive it")], context: GatewayConfiguration(snapshot: snapshot, connectors: [.cxmail], executables: [:], desktopControl: false, writes: false))
        check(readOnlyPrompt.contains("This request is read-only"), "The model is told a route is read-only")
        // Tool connectors: launched from the Claude config by name, attachable without a window
        let toolMCP = directory.appendingPathComponent("tool-mcp")
        try #"""
        #!/usr/bin/python3
        import sys,json,os
        names=os.environ.get('FIXTURE_TOOLS','').split(',')
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            if q['method']=='initialize': r={'protocolVersion':'2025-06-18','capabilities':{'tools':{}}}
            elif q['method']=='tools/list': r={'tools':[{'name':n,'inputSchema':{'type':'object','properties':{}}} for n in names]}
            else: r={'content':[{'type':'text','text':'launched '+' '.join(sys.argv[1:])+' '+os.environ.get('FIXTURE_MARK','')}],'isError':False}
            print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
        """#.write(to: toolMCP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolMCP.path)
        let claudeConfig = directory.appendingPathComponent("claude.json")
        try JSONSerialization.data(withJSONObject: ["mcpServers": [
            "margin": ["type": "stdio", "command": toolMCP.path, "args": ["--margin-flag"], "env": ["FIXTURE_TOOLS": "list_folders,create_note,append_note,trash_note,update_note", "FIXTURE_MARK": "margin-env"]],
            "vault": ["type": "stdio", "command": toolMCP.path, "args": [], "env": ["FIXTURE_TOOLS": "search_vault,related_notes,reindex_vault"]],
            "remote": ["type": "http", "url": "https://example.test"]]]).write(to: claudeConfig)
        let marginLaunch = AppConnector.margin.launch(claudeConfig: claudeConfig)
        check(marginLaunch?.command == toolMCP.path && marginLaunch?.arguments == ["--margin-flag"] && marginLaunch?.environment["FIXTURE_MARK"] == "margin-env", "Margin launches exactly as the Claude config registers it")
        check(AppConnector.vault.launch(claudeConfig: directory.appendingPathComponent("missing.json")) == nil, "An unregistered tool server is reported, not guessed")
        check(AppConnector.cxmail.launch(claudeConfig: claudeConfig)?.command == AppConnector.cxmail.executable(), "CXMail keeps its app path and Settings override")
        check(AppConnector.matching("") == nil && AppConnector.vault.bundleID.isEmpty, "Tool connectors never match a screen window")
        let placeholder = AppModel.placeholderSnapshot(displayID: 1)
        let toolConfig = GatewayConfiguration(snapshot: placeholder, connectors: [.margin, .vault], executables: [:], desktopControl: false,
                                              readOnly: [], launches: ["margin": marginLaunch!, "vault": AppConnector.vault.launch(claudeConfig: claudeConfig)!], screenless: true)
        let toolGateway = ContextGateway(configuration: toolConfig, valid: { true })
        let toolNames = try toolGateway.tools().compactMap { $0["name"] as? String }.sorted()
        check(toolNames == ["margin__append_note", "margin__create_note", "margin__list_folders", "vault__related_notes", "vault__search_vault"], "Only allowlisted Margin and vault tools are exposed (no trash, update or reindex)")
        let created = try toolGateway.call("margin__create_note", arguments: ["title": "x", "source": "Claude"])
        check(((created["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("--margin-flag margin-env") == true, "A screenless Margin write runs with the configured arguments and environment")
        check(rejected { _ = try toolGateway.call("margin__trash_note", arguments: [:]) }, "Margin deletion is unavailable")
        let readOnlyTools = GatewayConfiguration(snapshot: placeholder, connectors: [.margin, .cxtasks], executables: [:], desktopControl: false, readOnly: [.cxtasks])
        check(readOnlyTools.allows(.margin, "create_note") && !readOnlyTools.allows(.cxtasks, "file_task") && readOnlyTools.allows(.cxtasks, "get_task"), "Writes are allowed per connector")
        check(readOnlyTools.readOnlyConnectors == [.cxtasks], "The prompt is told exactly which tools are read-only")
        let toolPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "add this to margin")], context: toolConfig)
        check(toolPrompt.contains("no screen context") && toolPrompt.contains("set source"), "Screenless tool answers are told so, and how to write to Margin")
        for phrase in ["Add this to Margin", "put that in my margin", "Add this as a note in Margin", "save it to the Margin notes", "make a margin note"] {
            check(AppModel.mentionsMargin(phrase), "Margin is attached when named: \(phrase)")
        }
        for phrase in ["What's a healthy profit margin?", "Fix the CSS margin on this card", "Note it in the margin of the page", "Add this as a note", "What's the margin between them?"] {
            check(!AppModel.mentionsMargin(phrase), "Margin is not attached without being named: \(phrase)")
        }
        for phrase in ["https://www.reddit.com/r/StructuralEngineering/s/WZ37V2nHYH", "thoughts? https://example.com/post",
                       "Is this legit? https://example.com/a", "can you read this article for me https://example.com/a", "summarize https://example.com"] {
            check(AppModel.asksToOpenLink(phrase), "A pasted link or a request to read one goes where links open: \(phrase)")
        }
        // 2026-10-21: "just control my browser and search" went to a screen reading that answered "I can't control your browser".
        for phrase in ["just control my browser and search", "use my browser to find it", "search for it in my browser",
                       "look it up in Zen", "go check the listing on my browser", "take over the browser and open amazon",
                       "use zen to find it", "pull it up in zen", "google it for me in my browser", "can you open it in my browser"] {
            check(AppModel.asksToUseBrowser(phrase), "A request to drive the browser goes to My setup: \(phrase)")
        }
        for phrase in ["which browser is best?", "is this page safe?", "why is my browser slow", "clear the cache in Chrome settings?", "what does this tab say",
                       "find the setting in chrome", "how do I open devtools in chrome", "check if this site works on safari",
                       "go to settings in firefox and clear cache", "should I use chrome or safari"] {
            check(!AppModel.asksToUseBrowser(phrase), "Not a request to drive the browser: \(phrase)")
        }
        // 2026-10-22: after My setup filled a Docusign form in Zen, "review the dock and ensure we didn't miss anything"
        // scored needs_screen 0.98 and went to the screen route ("I can't open or read the Docusign page").
        let zenWindow = ContextWindow(id: 9, pid: 22, bundleID: "app.zen-browser.zen", appName: "Zen", title: "Review and sign documents on Docusign", bounds: .zero)
        func zenReply(_ tools: [String]?) -> [ChatMessage] {
            var reply = ChatMessage(role: "assistant", text: "Filled the business section.")
            reply.tools = tools
            return [.init(role: "user", text: "fill in the business info"), reply]
        }
        check(AppModel.continuesBrowserWork(history: zenReply(["zen-ext · list_pages", "zen-ext · fill_form_by_uid"]), front: zenWindow), "A question about the browser after a reply that drove it continues that work")
        check(!AppModel.continuesBrowserWork(history: zenReply(["WebSearch"]), front: zenWindow), "A reply that only searched the web doesn't pin the next question to My setup")
        check(!AppModel.continuesBrowserWork(history: zenReply(nil), front: zenWindow), "A reply with no tools doesn't pin the next question")
        check(!AppModel.continuesBrowserWork(history: zenReply(["zen-ext · open_url"]), front: termWindow), "A terminal in front isn't browser work, whatever the last reply did")
        check(!AppModel.continuesBrowserWork(history: zenReply(["zen-ext · open_url"]), front: nil), "No front window, no continuation")
        check(!AppModel.continuesBrowserWork(history: [], front: zenWindow), "A fresh chat has nothing to continue")
        let formInput = RoutingInput(question: "did we miss anything?", history: zenReply(["zen-ext · fill_form_by_uid"]), imageCount: 0, windows: [zenWindow], candidate: snapshot, projects: [], personalAvailable: true)
        func formPlan(_ yes: [String: Double], previous: RouteScope) -> RoutePlan? {
            RoutingSignals.parse(answers(yes, target: ("w0", 0.95)), engine: .decisions, questions: RoutingQuestion.all(for: formInput)).map { RoutePlan.make($0, input: formInput, bars: bars, previous: previous) }
        }
        for (yesAnswers, label) in [(["about_my_work": 0.75, "follow_up": 0.94, "needs_screen": 0.98], "Docusign review"),
                                    (["about_my_work": 0.91, "follow_up": 0.95, "needs_screen": 0.98], "did we miss anything"),
                                    (["about_my_work": 0.17, "follow_up": 0.95, "needs_screen": 1.0], "this page")] as [([String: Double], String)] {
            check(formPlan(yesAnswers, previous: .personal)?.scope == .personal, "A follow-up to a My setup reply stays there even when it needs the screen: \(label)")
        }
        check(formPlan(["about_my_work": 0.17, "follow_up": 0.3, "needs_screen": 1.0], previous: .personal)?.scope != .personal, "A new screen question after a My setup reply still reads the screen")
        check(formPlan(["about_my_work": 0.17, "follow_up": 0.95, "needs_screen": 1.0], previous: .screen)?.scope != .personal, "A follow-up to a screen reply isn't pulled into My setup")
        for phrase in ["make me an html page comparing the three plans", "build a dashboard of my sleep data", "can you mock up the settings screen",
                       "put together an interactive explainer on DNS", "show that as an artifact", "turn this into an html page"] {
            check(AppModel.asksForPage(phrase), "A request for a page goes to My setup: \(phrase)")
        }
        for phrase in ["what's on this page?", "summarize the chart on screen", "how do I make a pie in excel", "which page of the book was it", "make this page shorter", "make the chart on screen bigger"] {
            check(!AppModel.asksForPage(phrase), "Not a request for a page: \(phrase)")
        }
        let pastedEmail = "Hi Chris, following up on the proposal we discussed last week. The team reviewed the scope and would like to move the kickoff to Monday if that works for everyone involved. Read more at https://example.com/unsubscribe"
        for phrase in ["What's a good URL shortener?", "Summarize this email", pastedEmail] {
            check(!AppModel.asksToOpenLink(phrase), "No link to open: \(phrase.prefix(40))")
        }
        let personalLinkPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "https://example.com")], personal: true)
        check(personalLinkPrompt.contains("zen-ext"), "My setup is told to read refused sites through the browser")
        let generalLinkPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "https://example.com")])
        check(generalLinkPrompt.contains("You can't open"), "General chat says where links open instead of only refusing")
        // 2026-10-21: a reply that drove Zen was followed by a no-tools reply that "corrected" it ("I can't
        // control your browser, so I didn't actually open those listings"). The capability text is pinned.
        check(PromptBuilder.noHandsNote == """
         This reply can't act in apps or drive the user's browser. If the user asks for that, say Quick Ask \
        does it with Control app (the cursor button), or in their Zen browser when they ask with Claude \
        selected in Auto ("search for it in my browser").
        """, "The no-hands capability text is pinned")
        check(PromptBuilder.earlierRepliesNote == """


        Each reply runs with only the tools its route allows, and the route can change from one message \
        to the next. An earlier assistant message marked [Tools this reply used: …] really ran those \
        tools, so what it reports doing (browsing in Zen, opening pages, controlling an app) happened. \
        Never retract, correct or disown it because this reply lacks those tools.
        """, "The earlier-replies capability text is pinned")
        var browsed = ChatMessage(role: "assistant", text: "I searched Amazon in your Zen browser.", provider: .claude)
        browsed.tools = ["zen-ext · open_url", "zen-ext · get_page_text"]
        let followUp: [ChatMessage] = [.init(role: "user", text: "try again to control my browser"), browsed, .init(role: "user", text: "why is it so expensive?")]
        let routes: [(String, String)] = [
            ("general", try PromptBuilder.make(messages: followUp)),
            ("web", try PromptBuilder.make(messages: followUp, web: true)),
            ("screen", try PromptBuilder.make(messages: followUp, screen: screenPayload, web: true)),
            ("personal", try PromptBuilder.make(messages: followUp, personal: true)),
            ("control", try PromptBuilder.make(messages: followUp, target: AppTarget(pid: 123, name: "Fixture App"))),
            ("app", try PromptBuilder.make(messages: followUp, context: GatewayConfiguration(snapshot: snapshot, connectors: [.cxmail], executables: [:], desktopControl: false, writes: false))),
        ]
        for (name, routePrompt) in routes {
            let replayed = try JSONSerialization.jsonObject(with: Data(routePrompt.components(separatedBy: "Conversation JSON:\n").last!.utf8)) as! [[String: String]]
            check(routePrompt.contains(PromptBuilder.earlierRepliesNote), "Every route says earlier replies' tools were real: \(name)")
            check(replayed[1]["content"] == "I searched Amazon in your Zen browser.\n[Tools this reply used: zen-ext · open_url, zen-ext · get_page_text]",
                  "The history marks a reply that used tools: \(name)")
            check(routePrompt.contains(PromptBuilder.noHandsNote) == ["general", "web", "screen"].contains(name), "Only routes without hands say so, scoped to this reply: \(name)")
            check(!routePrompt.contains("You can't act in apps"), "No route denies app control outright: \(name)")
        }
        check(PromptBuilder.toolsNote(.init(role: "assistant", text: "plain")) == "", "A reply without tools carries no note")
        let oldHistory = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"64DAC619-F9A3-4936-A5F5-04DD4FBA7276","role":"assistant","text":"x","provider":"claude","complete":true,"images":[],"cards":[]}"#.utf8))
        check(oldHistory.tools == nil, "Saved chats from before tool marks still load")
        let toolDecoder = EventDecoder(provider: .claude)
        let toolEvents = toolDecoder.decode(Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"z1","name":"mcp__zen-ext__open_url","input":{}},{"type":"tool_use","id":"w1","name":"WebSearch","input":{}}]}}"#.utf8))
        check(toolEvents.compactMap { if case .tool(let n) = $0 { return n }; return nil } == ["zen-ext · open_url", "WebSearch"], "Claude tool calls are recorded by name")
        let codexTools = EventDecoder(provider: .codex).decode(Data(#"{"type":"item.started","item":{"id":"i1","type":"mcp_tool_call","server":"quickask","tool":"inspect_ui"}}"#.utf8))
        check(codexTools.compactMap { if case .tool(let n) = $0 { return n }; return nil } == ["quickask · inspect_ui"], "Codex tool calls are recorded by server and name")
        try verifyActivity()
        // Answers render as Markdown blocks.
        let parsed = MarkdownBlocks.parse("Intro\n\n## Body basics\n\n- **Walk** daily\n- Sleep\n  - nested\n\n1. First\n2. Second\n\n> Quote\n\n```bash\necho hi\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\n---\n\n![Chart](https://example.com/c.png)\n\nSee [the guide](https://example.com).")
        let kinds = parsed.map(\.kind)
        check(kinds.first == .paragraph && kinds.contains(.heading(2)), "Paragraphs and headings are blocks, not raw ## text")
        check(parsed.contains { $0.kind == .listItem(ordinal: nil, depth: 1, marker: true) && $0.plain == "Walk daily" }, "Bullets keep inline bold as styling, not asterisks")
        check(kinds.contains(.listItem(ordinal: nil, depth: 2, marker: true)) && kinds.contains(.listItem(ordinal: 2, depth: 1, marker: true)), "Nested bullets and numbered items keep depth and number")
        check(parsed.contains { $0.kind == .code(language: "bash") && $0.plain == "echo hi" } && kinds.contains(.quote) && kinds.contains(.rule), "Code blocks keep their language; quotes and rules are recognized")
        if case .table(let header, let rows)? = kinds.first(where: { if case .table = $0 { return true }; return false }) {
            check(header.map { String($0.characters) } == ["A", "B"] && rows.map { $0.map { String($0.characters) } } == [["1", "2"], ["3", "4"]], "A table gathers its header and rows")
        } else { check(false, "A table gathers its header and rows") }
        check(kinds.contains(.image(URL(string: "https://example.com/c.png")!, alt: "Chart")), "A Markdown image becomes an image block")
        check(TableLayout.widths(natural: [100, 200], available: 500) == [100, 200], "A table that fits keeps its natural column widths")
        check(TableLayout.widths(natural: [120, 900], available: 600) == [120, 480], "A short column keeps its width and the long one wraps into the rest")
        check(TableLayout.widths(natural: [800, 900], available: 600) == [300, 300], "Two long columns split a narrow window evenly")
        check(parsed.last.map { $0.text.runs.contains { $0.link != nil } } == true, "Links stay clickable")
        // One drag selects across a reply's prose: everything up to the table is one text view.
        let segments = MarkdownProse.segments(parsed)
        check(segments.first?.blocks.count == parsed.firstIndex { if case .table = $0.kind { return true }; return false },
              "Paragraphs, headings, lists, quotes and code share one selectable text view")
        let prose = MarkdownProse.attributed(segments[0].blocks, color: .white, accent: .white)
        check(prose.string.contains("Intro\nBody basics\n\t•\tWalk daily") && prose.string.contains("Quote\nbash\necho hi"),
              "The shared text keeps each block on its own line, with bullets and code in order")
        check(prose.attribute(.link, at: 0, effectiveRange: nil) == nil
              && MarkdownProse.attributed([parsed.last!], color: .white, accent: .white).attribute(.link, at: 4, effectiveRange: nil) != nil,
              "Links in the shared text stay links")
        let gaps = MarkdownBlocks.parse("| | Cost | CO2 |\n|---|---|---|\n| Bike | $0.80 | 0.5 kg |\n| Train | | 1.1 kg |")
        if case .table(let header, let rows) = gaps.first?.kind {
            check(header.map { String($0.characters) } == ["", "Cost", "CO2"] && rows.map { $0.map { String($0.characters) } } == [["Bike", "$0.80", "0.5 kg"], ["Train", "", "1.1 kg"]],
                  "Empty table cells keep their column, in the header and the body")
        } else { check(false, "A table with empty cells still parses as a table") }
        let looseItem = MarkdownBlocks.parse("- First paragraph\n\n  Second paragraph\n- Next")
        check(looseItem.map(\.kind) == [.listItem(ordinal: nil, depth: 1, marker: true), .listItem(ordinal: nil, depth: 1, marker: false), .listItem(ordinal: nil, depth: 1, marker: true)], "A list item's second paragraph has no bullet of its own")
        let localImage = FileManager.default.temporaryDirectory.appendingPathComponent("quickask-md-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: localImage)
        defer { try? FileManager.default.removeItem(at: localImage) }
        check(MarkdownBlocks.parse("Saved:\n\n\(localImage.path)").last?.kind == .image(localImage, alt: localImage.lastPathComponent), "A bare path to a local image renders the image")
        check(MarkdownBlocks.parse("/no/such/file.png").first?.kind == .paragraph && MarkdownBlocks.fileURL(URL(string: "https://x.com/a.png")!) == nil, "Missing files stay text; remote images are never treated as local")
        let mediaDir = FileManager.default.temporaryDirectory.appendingPathComponent("quickask-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDir) }
        let movie = mediaDir.appendingPathComponent("run.webm"), page = mediaDir.appendingPathComponent("Plan v2.html")
        try Data().write(to: movie); try Data("<h1>hi</h1>".utf8).write(to: page)
        check(MarkdownBlocks.parse("Recorded:\n\n\(movie.path)").last?.kind == .video(movie, alt: "run.webm"), "A bare path to a local video plays it")
        check(MarkdownBlocks.parse("Here:\n\n\(page.path)\n\nTell me what to change.").map(\.kind)
              == [.paragraph, .page(page, alt: "Plan v2.html"), .paragraph], "A bare path to a local HTML file renders the page between its paragraphs")
        check(MarkdownBlocks.parse("![Plan](\(page.absoluteString))").first?.kind == .page(page, alt: "Plan"), "A Markdown image pointing at a page renders the page")
        check(MarkdownBlocks.parse("I saved it to \(page.path) for you.").first?.kind == .paragraph, "A path mentioned in a sentence stays text")
        let artifact = URL(string: "https://claude.ai/artifact/RUvpSL4KC7nLspwXE8kfgY")!
        check(MarkdownBlocks.parse(artifact.absoluteString).first?.kind == .page(artifact, alt: ""), "An artifact link on its own line opens the artifact")
        check(MarkdownBlocks.parse("[The First Minute](\(artifact.absoluteString))").first?.kind == .page(artifact, alt: "The First Minute"), "A titled artifact link on its own opens the artifact")
        check(MarkdownBlocks.parse("See [this](\(artifact.absoluteString)) when you can.").first?.kind == .paragraph
              && MarkdownBlocks.parse("https://claude.ai/chat/abc").first?.kind == .paragraph
              && MarkdownBlocks.artifactURL("https://claude.ai.evil.com/artifact/x") == nil, "Artifact links inside sentences, chats and look-alike hosts stay links")
        check(MarkdownBlocks.artifactURL("https://claude.ai/code/artifact/0b5f-77aa") != nil, "Claude Code artifact links count too")
        check(MarkdownBlocks.latestPage(in: ["old \(page.path)", "Done:\n\n\(page.path)"]) == page && MarkdownBlocks.latestPage(in: ["no page"]) == nil
              && MarkdownBlocks.latestPage(in: [artifact.absoluteString]) == nil, "A follow-up knows the local page the chat last showed")
        check(MediaLinks.artifacts(in: ["look at https://claude.ai/artifact/RUvpSL4KC7nLspwXE8kfgY/ please"]) == ["RUvpSL4KC7nLspwXE8kfgY"], "Artifacts the user pasted are recognised by id")
        check(PageKind.allows("claude.ai", signingIn: false) && PageKind.allows("c6419379.frame.claudeusercontent.com", signingIn: false)
              && !PageKind.allows("evilclaude.ai", signingIn: false) && !PageKind.allows("accounts.google.com", signingIn: false)
              && PageKind.allows("accounts.google.com", signingIn: true), "Artifact views stay on claude.ai's hosts; Google sign-in only in the sign-in window")
        check(PageRules.json.contains(#"^https://cdnjs\\.cloudflare\\.com/"#) && (try? JSONSerialization.jsonObject(with: Data(PageRules.json.utf8))) != nil,
              "Local pages' network rules are valid JSON and allow only the listed CDNs")
        check(ComposerTextView.commandRange(in: "/fork shorter") == NSRange(location: 0, length: 5) && ComposerTextView.commandRange(in: "  /fork") == NSRange(location: 2, length: 5)
              && ComposerTextView.commandRange(in: "/forklift") == nil && ComposerTextView.commandRange(in: "how do I /fork?") == nil, "The composer marks /fork exactly when sending would fork")
        let read = try gateway.call("cxmail__read_email", arguments: [:])
        check((read["content"] as? [[String: String]])?.first?["text"] == "fixture result", "Gateway forwards supported read results")
        check(rejected { _ = try gateway.call("cxtasks__get_task", arguments: [:]) }, "Unattached connectors are blocked")
        valid = false
        check(rejected { _ = try gateway.call("cxmail__read_email", arguments: [:]) }, "Revocation blocks subsequent proxy calls")
        let customSession = DesktopSession(target: .init(pid: 20, name: "CXMail"), ownerPID: 30, executable: "/tmp/Quick Ask", lease: "/tmp/lease", gatewayPath: "/tmp/context.json", toolNames: configuration.toolNames)
        let customArguments = Provider.claude.arguments(model: "", desktop: customSession)
        check(customArguments.contains(configuration.toolNames.map { "mcp__quickask__\($0)" }.joined(separator: ",")), "Claude receives only gateway capabilities")
        check(customSession.arguments.contains("--gateway-config"), "Gateway travels through the existing MCP server")
        let stateModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        check(stateModel.provider == .claude && stateModel.models(for: .claude) == Provider.claude.defaultModels, "A fresh install starts on Claude with the default models")
        stateModel.claudeModelList = "opus, sonnet"; stateModel.choose(provider: .claude, model: "fable", effort: "max")
        check(stateModel.models(for: .claude) == ["fable", "opus", "sonnet"] && stateModel.effort(for: .claude) == "max", "The pill keeps the current model in its list")
        stateModel.choose(provider: .codex, effort: "low")
        check(stateModel.provider == .codex && stateModel.model(for: .claude) == "fable" && stateModel.codexEffort == "low", "Each provider keeps its own model and effort")
        stateModel.provider = .claude
        check(PopupView.modelName("opus") == "Opus" && PopupView.modelName("gpt-6.1-sol") == "gpt-6.1-sol", "Aliases read capitalised; full ids stay as typed")
        stateModel.selectContext(.general); stateModel.displayChanged()
        check(stateModel.contextChoice == .general && !stateModel.controlEnabled, "Moving General chat cannot enable capture or routing")
        stateModel.selectContext(.window(7)); stateModel.displayChanged()
        check(stateModel.contextChoice == .auto, "Moving a selected window invalidates its previous display context")
        stateModel.needsContextChoice = true
        check(stateModel.expanded, "Ambiguous context has room for its inline picker")
        check(!Set(RoutingQuestion.all(for: routing).map(\.name)).contains("delegate"), "The router is never asked about task review")
        for phrase in ["Create a task to shorten the intro", "file a task for this", "Turn this email into a task", "Add this as a CXTasks task",
                       "make me a new task to follow up", "Log this in CXTasks", "please create tasks for these"] {
            check(AppModel.requestsTaskCreation(phrase), "Explicit task request opens the review: \(phrase)")
        }
        for phrase in ["Kick off a sub-agent to update this document", "Start a background agent to revise this", "How do I create a task?",
                       "What tasks are due today?", "Mark this task complete", "Add a note to this task", "Summarize this email",
                       "Draft a reply about the task force", "Start work on the invoice"] {
            check(!AppModel.requestsTaskCreation(phrase), "No task review without an explicit request: \(phrase)")
        }
        var proposal = DelegationProposal.make(question: "Kick off a sub-agent to update this document", history: [.init(role: "user", text: "Feedback: shorten the intro.")], snapshot: nil)
        check(proposal.mode == .herdr && proposal.instructions.contains("shorten the intro"), "Handoff carries feedback and selects the existing Herdr flow")
        check(DelegationProposal.make(question: "File a task to review this", history: [], snapshot: nil).mode == .file, "Filing does not implicitly launch an agent")
        check(DelegationProposal.make(question: "Start a background agent", history: [], snapshot: nil).mode == .background, "Background execution is an explicit distinct mode")
        check(DelegationProposal.make(question: "Start a background agent to revise this document", history: [], snapshot: nil).writesAllowed, "An explicit edit request proposes the required permission for human review")
        stateModel.draft = proposal.question; stateModel.delegation = proposal
        check(!stateModel.canSend && stateModel.expanded, "Review blocks a second answer before confirmation")
        stateModel.selectContext(.general); stateModel.delegation = proposal; stateModel.displayChanged()
        check(stateModel.delegation != nil, "Moving a General-chat review cannot invent or invalidate screen context")
        stateModel.cancelDelegation()
        check(stateModel.delegation == nil && stateModel.draft == proposal.question, "Cancelling the review preserves the question")
        let reviewed = try TaskDelegation.request(proposal)
        check(reviewed.user_confirmed && reviewed.request_id == proposal.id.uuidString.lowercased(), "Confirmation carries a stable task ID")
        check(!reviewed.writes_allowed && !reviewed.start_queue_once, "Background permissions and queue pass are not implied")
        let wireHandoff = try JSONEncoder().encode(reviewed)
        check(!String(decoding: wireHandoff, as: UTF8.self).contains("bg_mcp_servers"), "Handoff grants no arbitrary extra tools")
        proposal.mode = .background
        check(rejected { _ = try TaskDelegation.request(proposal) }, "Unbounded background work is rejected")
        let document = directory.appendingPathComponent("feedback.md")
        try "Before".write(to: document, atomically: true, encoding: .utf8)
        HerdrInference.workRoots.append(directory.resolvingSymlinksInPath().path)
        let revision = try TaskDelegation.fileRevision(document.path)
        let onyxSelection = AppSelection(pid: 40, bundleID: "com.cx.onyx", windowLabel: "main", windowID: 10, revision: revision, label: "Feedback", records: ["document_path": document.path, "document_revision": revision, "editing": "false"])
        let onyx = ContextSnapshot(displayID: 1, windowID: 10, pid: 40, bundleID: "com.cx.onyx", appName: "Onyx", windowTitle: "Onyx", capturedAt: 0, launchTime: 0, selection: onyxSelection, text: "", document: document.path)
        let documentProposal = DelegationProposal.make(question: "Launch Claude to update this document", history: [], snapshot: onyx)
        stateModel.delegation = documentProposal; stateModel.displayChanged()
        check(stateModel.delegation == nil, "A screen-bound document review is invalidated on display change")
        let documentRequest = try TaskDelegation.request(documentProposal)
        check(documentRequest.document_path == document.resolvingSymlinksInPath().path && documentRequest.document_revision == revision, "Confirmed task carries exact canonical document and shown revision")
        try "After: changed content".write(to: document, atomically: true, encoding: .utf8)
        check(rejected { _ = try TaskDelegation.request(documentProposal) }, "A changed document cannot launch against the old review")
        var escaped = proposal; escaped.workspace = directory.path; escaped.documentPath = "/etc/hosts"
        check(rejected { _ = try TaskDelegation.request(escaped) }, "Working folder cannot silently grant a source outside its boundary")
        check(!AppConnector.cxtasks.tools.contains("dispatch_foreground") && !AppConnector.cxtasks.tools.contains("queue_background"), "Model MCP tools cannot bypass host confirmation")
        let openEditor = AppSelection(pid: 40, bundleID: "com.cx.onyx", windowLabel: "main", windowID: 10, revision: "editing", label: "Feedback", records: ["document_path": document.path, "editing": "true"])
        let unsaved = ContextSnapshot(displayID: 1, windowID: 10, pid: 40, bundleID: "com.cx.onyx", appName: "Onyx", windowTitle: "Onyx", capturedAt: 0, launchTime: 0, selection: openEditor, text: "", document: document.path)
        check(rejected { _ = try TaskDelegation.request(.make(question: "Update this document", history: [], snapshot: unsaved)) }, "An open Onyx editor must be saved and closed first")
        let queued = TaskHandoffResult(task_id: reviewed.request_id, task_ref: "T42", state: "queued", message: "Queued; runner paused.")
        check(queued.transcript.contains("T42") && queued.transcript.contains("runner paused") && !queued.transcript.contains("running"), "Queued and paused results are reported without claiming work started")
        // Image attachments
        let codexImages = Provider.codex.arguments(model: "", imagePaths: ["/w/image-1.png", "/w/image-2.jpg"])
        check(codexImages.last == "-" && codexImages.suffix(3).dropLast() == ["--image=/w/image-1.png", "--image=/w/image-2.jpg"], "Codex images use --image= and keep stdin last")
        check(!Provider.codex.arguments(model: "").contains { $0.hasPrefix("--image") }, "No image flags without images")
        let codexControlImages = Provider.codex.arguments(model: "", desktop: desktop, imagePaths: ["/w/a.png"])
        check(codexControlImages.last == "-" && codexControlImages.contains("--image=/w/a.png"), "Codex images work with desktop control")
        let claudeImages = Provider.claude.arguments(model: "", imagePaths: [""])
        check(claudeImages.contains("--input-format") && claudeImages[claudeImages.firstIndex(of: "--input-format")! + 1] == "stream-json" && claudeImages.contains("--safe-mode"), "Claude images switch to stream-json input")
        check(Provider.claude.arguments(model: "", desktop: desktop, imagePaths: [""]).contains("--input-format"), "Claude images work with desktop control")
        check(Provider.claude.arguments(model: "") == Provider.claude.arguments(model: "", imagePaths: [""]) && Provider.claude.arguments(model: "", personal: true).contains("stream-json"),
              "Claude always reads stream-json input, so a spare launched before the question can take it")

        let wide = NSImage(size: NSSize(width: 3000, height: 1000))
        wide.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!)
        let scaled = ImageAttachment.make(from: wide)!
        check(scaled.pixelWidth == 2000 && scaled.pixelHeight == 667 && scaled.data.count <= ImageAttachment.maxBytes, "Large images are downscaled to 2000 px")

        let payload = try JSONSerialization.jsonObject(with: ImageAttachment.claudeInput(prompt: "Describe", images: [scaled]).dropLast()) as! [String: Any]
        let content = ((payload["message"] as! [String: Any])["content"] as! [[String: Any]])
        let source = content.last!["source"] as! [String: String]
        check(payload["type"] as? String == "user" && content.first!["text"] as? String == "Describe" && source["type"] == "base64"
              && source["media_type"] == scaled.mediaType && Data(base64Encoded: source["data"]!) == scaled.data, "Claude stdin carries prompt and base64 image")

        let board = NSPasteboard(name: .init("QuickAsk-test-\(UUID().uuidString)"))
        board.clearContents(); board.setData(scaled.data, forType: .png)
        check(ImageAttachment.read(from: board).count == 1 && ImageAttachment.available(on: board), "Pasted image data becomes an attachment")
        board.clearContents(); board.setString("plain text", forType: .string)
        check(ImageAttachment.read(from: board).isEmpty && !ImageAttachment.available(on: board), "Text paste is left to the text view")
        let imageFile = directory.appendingPathComponent("shot.png"), textFile = directory.appendingPathComponent("notes.txt")
        try scaled.data.write(to: imageFile); try "x".write(to: textFile, atomically: true, encoding: .utf8)
        board.clearContents(); board.writeObjects([textFile as NSURL])
        check(ImageAttachment.read(from: board).isEmpty && !ImageAttachment.available(on: board), "A copied non-image file does not attach its icon")
        board.clearContents(); board.writeObjects([imageFile as NSURL])
        check(ImageAttachment.read(from: board).count == 1 && ImageAttachment.available(on: board), "A copied image file attaches the image")
        board.releaseGlobally()

        let workspace = directory.appendingPathComponent("image-workspace"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let written = try ImageAttachment.write([scaled], to: workspace)
        let mode = (try FileManager.default.attributesOfItem(atPath: written[0])[.posixPermissions] as? NSNumber)?.intValue
        check(FileManager.default.contents(atPath: written[0]) == scaled.data && mode == 0o600, "Codex image files are owner-only in the request workspace")
        // 2026-10-18: a My setup session saw the screenshot but couldn't hand it to the Herdr agent it started.
        let store = directory.appendingPathComponent("image-store")
        let stale = store.appendingPathComponent("old.png")
        let stored = try ImageAttachment.store([scaled], in: store)
        try Data([1]).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ImageAttachment.storeLifetime - 60)], ofItemAtPath: stale.path)
        let storeMode = (try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber)?.intValue
        let storedMode = (try FileManager.default.attributesOfItem(atPath: stored[0])[.posixPermissions] as? NSNumber)?.intValue
        check(FileManager.default.contents(atPath: stored[0]) == scaled.data && storeMode == 0o700 && storedMode == 0o600, "My setup's images are saved owner-only")
        let restored = try ImageAttachment.store([scaled], in: store)
        check(restored == stored && !FileManager.default.fileExists(atPath: stale.path), "An image is saved once, and week-old ones are dropped")
        let filedPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "pass this to a Herdr agent", images: [scaled])], personal: true, imageFiles: stored)
        check(filedPrompt.contains(stored[0]) && filedPrompt.contains("pass its path"), "My setup's prompt lists the image files so it can hand them on")
        let unfiledPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "q", images: [scaled])], personal: false, imageFiles: stored)
        check(!unfiledPrompt.contains(stored[0]), "Only My setup is given image paths")

        let many = (0..<7).map { _ in ImageAttachment(id: UUID(), data: scaled.data, mediaType: scaled.mediaType, pixelWidth: 1, pixelHeight: 1) }
        let older = ChatMessage(role: "user", text: "first", images: Array(many.prefix(3)))
        let imageOnly = ChatMessage(role: "user", text: "", images: Array(many.suffix(4)))
        check(ImageAttachment.recent(in: [older, imageOnly]).map(\.id) == Array(many.suffix(5)).map(\.id), "Only the five most recent images are resent")
        let imagePrompt = try PromptBuilder.make(messages: [older, imageOnly])
        check(imagePrompt.contains("an earlier image no longer attached") && imagePrompt.contains("attached image 5") && !imagePrompt.contains("attached image 6"), "History numbers the images actually sent")
        check(imagePrompt.contains("[Images: attached image 2, attached image 3, attached image 4, attached image 5]"), "An image-only message stays in the history")

        let imageModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        check(!imageModel.canSend, "Empty composer cannot send")
        check(imageModel.addImages(many) && imageModel.attachments.count == ImageAttachment.perMessage, "Attachments are capped per message")
        check(imageModel.canSend, "An image alone can be sent")
        imageModel.removeAttachment(imageModel.attachments[0].id)
        check(imageModel.attachments.count == 4 && !imageModel.addImages([]), "Attachments can be removed; no images leaves paste to text")
        let composer = ComposerTextView(); composer.isRichText = false
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let savedClipboard = NSPasteboard.general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem(); item.types.forEach { if let data = item.data(forType: $0) { copy.setData(data, forType: $0) } }; return copy } ?? []
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(scaled.data, forType: .png)
        composer.onImages = { imageModel.addImages($0) }
        check(composer.validateUserInterfaceItem(pasteItem), "⌘V stays enabled when the clipboard holds only an image")
        let before = imageModel.attachments.count
        composer.paste(nil)
        check(imageModel.attachments.count == before + 1 && composer.string.isEmpty, "Pasting an image attaches it instead of inserting text")
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(savedClipboard)
        imageModel.newChat()
        check(imageModel.attachments.isEmpty, "New chat clears attachments")

        // ⌘Z in the composer: typing undoes in steps, a send is one step, and each chat keeps its own history.
        let undoEditor = ComposerTextView(); undoEditor.isRichText = false; undoEditor.allowsUndo = true
        let undo = ComposerUndo()
        final class UndoSource: NSObject, NSTextViewDelegate {
            let undo: ComposerUndo
            init(_ undo: ComposerUndo) { self.undo = undo }
            func undoManager(for view: NSTextView) -> UndoManager? { MainActor.assumeIsolated { undo.current } }
        }
        let undoSource = UndoSource(undo); undoEditor.delegate = undoSource
        func settle() { undoEditor.undoManager?.groupsByEvent = false }
        let chatA = UUID(), chatB = UUID()
        undo.show("", for: chatA, in: undoEditor); settle()
        func typed(_ text: String) {
            undoEditor.undoManager?.beginUndoGrouping(); undoEditor.insertText(text, replacementRange: undoEditor.selectedRange()); undoEditor.undoManager?.endUndoGrouping()
            undoEditor.breakUndoCoalescing()
        }
        typed("hello "); typed("world")
        undoEditor.undoManager?.undo()
        check(undoEditor.string == "hello ", "⌘Z takes back the last thing typed")
        undoEditor.undoManager?.redo()
        check(undoEditor.string == "hello world", "⇧⌘Z puts it back")
        undoEditor.undoManager?.beginUndoGrouping(); undo.show("", for: chatA, in: undoEditor); undoEditor.undoManager?.endUndoGrouping()
        check(undoEditor.string.isEmpty && undoEditor.undoManager?.canUndo == true, "Sending clears the composer as one undo step")
        undoEditor.undoManager?.undo()
        check(undoEditor.string == "hello world", "⌘Z after sending brings the draft back")
        undo.show("", for: chatB, in: undoEditor); settle()
        check(undoEditor.string.isEmpty && undoEditor.undoManager?.canUndo == false, "Another chat starts with its own empty history")
        typed("other")
        undo.show("hello world", for: chatA, in: undoEditor)
        check(undoEditor.string == "hello world" && undoEditor.undoManager?.canUndo == true, "Coming back to a chat keeps its history")
        undoEditor.undoManager?.undo()
        check(undoEditor.string == "hello ", "Its steps still apply after switching away and back")
        undo.show("put back", for: chatB, in: undoEditor)
        check(undoEditor.undoManager?.canUndo == false, "A draft changed while its chat was away drops the stale history")
        let idleModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        idleModel.messages = [.init(role: "user", text: "old"), .init(role: "assistant", text: "answer")]
        idleModel.startFreshIfIdle(hiddenFor: 9 * 60)
        check(idleModel.messages.count == 2, "Reopening within 10 minutes keeps the chat")
        idleModel.draft = "unsent"
        idleModel.startFreshIfIdle(hiddenFor: 10 * 60)
        check(idleModel.messages.isEmpty && idleModel.draft == "unsent", "After 10 minutes hidden, a fresh chat starts and the unsent draft is kept")
        idleModel.messages = [.init(role: "user", text: "q")]; idleModel.busy = true
        idleModel.startFreshIfIdle(hiddenFor: 3600)
        check(idleModel.messages.count == 1, "An answer still running is never cleared")

        // /fork: the chat so far goes to a tab of its own with a new session id and title.
        check(AppModel.forkTitle(in: "/fork") == "" && AppModel.forkTitle(in: "  /FORK  ") == "", "A bare /fork is a fork with no title")
        check(AppModel.forkTitle(in: "/fork try the shorter intro") == "try the shorter intro", "Text after /fork names the fork")
        for phrase in ["/forklift", "how do I /fork?", "fork this", "/for"] {
            check(AppModel.forkTitle(in: phrase) == nil, "Not a fork command: \(phrase)")
        }
        // /truthcheck (alias /tc): a fact-check of whatever follows, or of the last answer.
        check(AppModel.truthTarget(in: "/truthcheck https://example.com/a") == "https://example.com/a" && AppModel.truthTarget(in: " /TC  weed is safe ") == "weed is safe", "/truthcheck and /tc take what follows")
        check(AppModel.truthTarget(in: "/tc") == "" && AppModel.truthTarget(in: "/truthchecker x") == nil && AppModel.truthTarget(in: "/tcp") == nil && AppModel.truthTarget(in: "is /tc true?") == nil, "Only the whole-message command is a truth check")
        check(ComposerTextView.commandRange(in: " /tc claim") == NSRange(location: 1, length: 3) && ComposerTextView.commandRange(in: "/truthcheck") == NSRange(location: 0, length: 11), "The composer marks /truthcheck and /tc")
        check(ComposerTextView.completion(for: "/") == "truthcheck" && ComposerTextView.completion(for: "/f") == "ork" && ComposerTextView.completion(for: "/TR") == "uthcheck", "Typing / offers the rest of a command")
        check(ComposerTextView.completion(for: "/fork") == nil && ComposerTextView.completion(for: "/x") == nil && ComposerTextView.completion(for: "/t a") == nil && ComposerTextView.completion(for: "hi /") == nil, "No completion once the command is whole or the draft isn't one")
        // !cd: points the chat at a folder; only the whole-message command counts.
        check(AppModel.cdTarget(in: "!cd /Users/x/Projects/app") == "/Users/x/Projects/app" && AppModel.cdTarget(in: " !CD  ~/a b ") == "~/a b", "!cd takes the path after it")
        check(AppModel.cdTarget(in: "!cd") == "" && AppModel.cdTarget(in: "!cdx") == nil && AppModel.cdTarget(in: "run !cd later") == nil && AppModel.cdTarget(in: "!ls") == nil, "Only the whole-message !cd is a folder change")
        check(ComposerTextView.commandRange(in: "!cd /tmp") == NSRange(location: 0, length: 3) && ComposerTextView.completion(for: "!") == "cd" && ComposerTextView.completion(for: "!cd") == nil, "The composer marks and completes !cd")
        let cdRoot = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-cd-\(UUID().uuidString)")
        let cdFolder = cdRoot.appendingPathComponent("my repo/sub")
        try FileManager.default.createDirectory(at: cdFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cdRoot) }
        let cdReal = cdFolder.resolvingSymlinksInPath()
        check(AppModel.resolveDirectory(cdFolder.path, from: nil) == cdReal, "An absolute folder resolves")
        check(AppModel.resolveDirectory("\"\(cdFolder.path)\"", from: nil) == cdReal && AppModel.resolveDirectory(cdFolder.path.replacingOccurrences(of: " ", with: "\\ "), from: nil) == cdReal, "Quoted and backslash-escaped paths resolve")
        check(AppModel.resolveDirectory("sub", from: cdFolder.deletingLastPathComponent().resolvingSymlinksInPath()) == cdReal && AppModel.resolveDirectory("..", from: cdReal) == cdReal.deletingLastPathComponent(), "A relative path starts from the chat's folder")
        check(AppModel.resolveDirectory("~", from: nil) == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath(), "~ is the home folder")
        check(AppModel.resolveDirectory(cdFolder.appendingPathComponent("nope").path, from: nil) == nil && AppModel.resolveDirectory("", from: nil) == nil, "A missing folder does not resolve")
        let cdModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        cdModel.draft = "!cd \(cdFolder.path)"; cdModel.send()
        check(cdModel.directory == cdReal && cdModel.messages.isEmpty && cdModel.draft.isEmpty && !cdModel.busy, "!cd sets the folder without sending a message")
        let cdTab = cdModel.activeSessionID
        cdModel.newTab(); cdModel.draft = "hello"
        check(cdModel.directory == cdReal, "A blank tab is the same chat, so it keeps the folder")
        cdModel.draft = "!cd \(cdRoot.appendingPathComponent("missing").path)"; cdModel.send()
        check(cdModel.directory == cdReal && cdModel.status.contains("No folder"), "A bad !cd leaves the folder as it was")
        cdModel.draft = "!cd"; cdModel.send()
        check(cdModel.directory == nil && cdModel.activeSessionID == cdTab, "A bare !cd goes back to the home folder")
        cdModel.draft = "!cd \(cdFolder.path)"; cdModel.send()
        cdModel.messages = [ChatMessage(role: "user", text: "hi"), ChatMessage(role: "assistant", text: "hello", provider: .claude, complete: true)]
        cdModel.fork(title: "copy")
        check(cdModel.directory == cdReal, "A fork keeps the folder")
        cdModel.newChat()
        check(cdModel.directory == nil, "A new chat starts in the home folder")
        let setupKey = WarmPool.Key(executable: "/bin/claude", arguments: ["a"], personal: true)
        check(setupKey != WarmPool.Key(executable: "/bin/claude", arguments: ["a"], personal: true, directory: cdReal)
              && CLIRunner.warmKey(provider: .claude, executable: "/bin/claude", model: "", personal: false, directory: cdReal)?.directory == nil,
              "A spare started in one folder is never handed to a chat in another")
        let cdPrompt = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "pwd")], personal: true, directory: cdReal)
        check(cdPrompt.contains("the folder \(cdReal.path)") && !cdPrompt.contains("started from their home folder"), "The prompt says where the session started")
        let truthPrompt = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "/tc the moon is cheese")], personal: true)
        check(truthPrompt.contains("/truthcheck command") && truthPrompt.contains("verify each against sources"), "A truth check asks for sourced verification")
        let offlineTruth = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "/tc x")])
        let plainPrompt = try PromptBuilder.make(messages: [ChatMessage(role: "user", text: "hi")])
        check(offlineTruth.contains("ran no searches"), "Without search, a truth check says it ran none")
        check(!plainPrompt.contains("/truthcheck"), "Ordinary messages carry no truth-check note")
        let truthModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        truthModel.draft = "/tc"; truthModel.send()
        check(!truthModel.busy && truthModel.messages.isEmpty && truthModel.status.contains("Nothing to check"), "A bare /tc with no answer yet sends nothing")
        let forkModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        forkModel.draft = "/fork"; forkModel.send()
        check(forkModel.sessions.count == 1 && forkModel.draft.isEmpty && !forkModel.busy, "Forking an empty chat makes no tab and sends nothing")
        check(!forkModel.showsTabs, "One chat shows no tab bar")
        forkModel.messages = [.init(role: "user", text: "Plan the launch\nwith details"), .init(role: "assistant", text: "Here is a plan"),
                              .init(role: "assistant", text: "partial", complete: false)]
        let original = forkModel.activeSessionID
        forkModel.draft = "/fork"; forkModel.send()
        check(forkModel.sessions.count == 2 && forkModel.showsTabs && forkModel.activeSessionID != original, "/fork opens a new session in a new tab")
        check(forkModel.messages.count == 2 && forkModel.messages.map(\.text) == ["Plan the launch\nwith details", "Here is a plan"], "The fork carries the completed messages only")
        check(forkModel.title(of: forkModel.sessions[1]) == "Plan the launch · fork" && forkModel.sessions[1].forkedFrom == original, "The fork gets its own title and remembers its source")
        check(forkModel.title(of: forkModel.sessions[0]) == "Plan the launch", "The source tab keeps the first question as its title")
        check(!forkModel.busy && forkModel.draft.isEmpty, "/fork is never sent to a provider")
        forkModel.messages.append(.init(role: "user", text: "Only in the fork"))
        forkModel.draft = "half-typed"
        forkModel.selectSession(original)
        check(forkModel.messages.count == 3 && forkModel.draft.isEmpty, "Switching back shows the original chat, untouched by the fork")
        forkModel.draft = "/fork"; forkModel.send()
        check(forkModel.title(of: forkModel.sessions[1]) == "Plan the launch · fork 2", "A second fork of the same chat is numbered")
        check(forkModel.sessions.firstIndex { $0.id == forkModel.activeSessionID } == 1, "A fork opens beside its source")
        forkModel.draft = "/fork Shorter intro"; forkModel.send()
        check(forkModel.title(of: forkModel.sessions.first { $0.id == forkModel.activeSessionID }!) == "Shorter intro", "/fork <title> names the new tab")
        let firstFork = forkModel.sessions[3].id
        forkModel.selectSession(firstFork)
        check(forkModel.messages.last?.text == "Only in the fork" && forkModel.draft == "half-typed", "Each tab keeps its own messages and draft")
        forkModel.busy = true
        forkModel.selectSession(original)
        check(forkModel.activeSessionID == original, "Tabs switch while an answer is running")
        forkModel.selectSession(firstFork)
        check(forkModel.activeSessionID == firstFork && forkModel.messages.last?.text == "Only in the fork", "Switching back shows the tab's own chat")
        forkModel.draft = "/fork"; forkModel.send()
        check(forkModel.sessions.count == 4, "No fork while an answer is running")
        forkModel.busy = false
        forkModel.closeSession(firstFork)
        check(forkModel.sessions.count == 3 && forkModel.activeSessionID != firstFork && !forkModel.messages.isEmpty, "Closing the tab showing brings a neighbour forward")
        forkModel.reopenClosedTab()
        check(forkModel.sessions.count == 4 && forkModel.activeSessionID == firstFork && forkModel.messages.last?.text == "Only in the fork" && forkModel.draft == "/fork", "⇧⌘T brings the closed tab back with its chat and draft")
        forkModel.reopenClosedTab()
        check(forkModel.sessions.count == 4, "⇧⌘T with nothing left closed does nothing")
        forkModel.closeSession(firstFork)
        forkModel.newTab()
        check(forkModel.sessions.count == 4 && forkModel.messages.isEmpty && forkModel.title(of: forkModel.sessions[3]) == "New chat", "+ opens a blank tab")
        forkModel.newTab()
        check(forkModel.sessions.count == 4, "+ on a blank tab doesn't stack blank tabs")
        forkModel.selectSession(original); forkModel.draft = "unsent"
        forkModel.startFreshIfIdle(hiddenFor: 3600)
        check(forkModel.sessions.count == 4 && forkModel.messages.isEmpty && forkModel.draft == "unsent", "After 10 minutes hidden with tabs open, the blank tab comes forward and the tabs stay")
        check(forkModel.sessions.first { $0.id == original }?.messages.count == 3, "The stale chat stays in its tab")
        for session in forkModel.sessions where session.id != forkModel.activeSessionID { forkModel.closeSession(session.id) }
        check(forkModel.sessions.count == 1 && !forkModel.showsTabs, "Closing the other tabs returns to the plain popup")
        let lastID = forkModel.activeSessionID
        forkModel.messages = [.init(role: "user", text: "q")]
        forkModel.closeSession(lastID)
        check(forkModel.sessions.count == 1 && forkModel.messages.isEmpty && forkModel.activeSessionID != lastID, "Closing the last tab starts a new session")

        // Onyx's tab strip: pills share it, the hovered one widens, the strip never changes width.
        func total(_ widths: [CGFloat?]) -> CGFloat { widths.compactMap { $0 }.reduce(0, +) }
        let rest = TabStripLayout.widths(count: 3, active: 0, hovered: nil, natural: nil, available: 520)
        check(rest.allSatisfy { $0 == 172 }, "Three pills share 520 pt below the 180 pt cap: \(rest)")
        check(TabStripLayout.widths(count: 2, active: 0, hovered: nil, natural: nil, available: 600).allSatisfy { $0 == 180 }, "Pills stop at 180 pt with room to spare")
        let widened = TabStripLayout.widths(count: 3, active: 0, hovered: 1, natural: 300, available: 520)
        check(widened[1] == 300 && abs(total(widened) - total(rest)) < 0.01, "The hovered pill widens to its title and the strip keeps its width: \(widened)")
        check(widened[0] == widened[2] && widened[0]! >= TabStripLayout.floor, "The others give way equally, never below the floor")
        let long = TabStripLayout.widths(count: 3, active: 0, hovered: 2, natural: 900, available: 900)
        check(long[2] == TabStripLayout.widest, "A widened pill stops at 360 pt and rolls the rest of its title")
        let crowded = TabStripLayout.widths(count: 6, active: 0, hovered: 3, natural: 400, available: 528)
        check(crowded.compactMap { $0 }.allSatisfy { $0 >= TabStripLayout.floor - 0.01 } && crowded[3]! < 400, "In a crowded strip the hovered pill takes only what the others can give")
        check(TabStripLayout.widths(count: 3, active: 0, hovered: 1, natural: 100, available: 520) == rest, "A title that already fits doesn't widen its pill")
        let spill = TabStripLayout.widths(count: 10, active: 8, hovered: nil, natural: nil, available: 450)
        check(spill.compactMap { $0 }.count == 5 && spill[8] != nil && spill[0] == nil, "Past what fits at 88 pt, the pills furthest from the active one are left out: \(spill.map { $0 == nil ? 0 : 1 })")

        // Direct continuation: the completed chat goes to a new Herdr tab without a task.
        check(HerdrHandoff.requestsTransfer("lets transfer this session to herdr and have it do x"), "The requested mid-chat transfer wording opens direct Herdr review")
        check(HerdrHandoff.requestsTransfer("Can you continue this conversation in Herdr?"), "An explicit polite transfer request is recognized")
        check(!HerdrHandoff.requestsTransfer("How do I transfer a session to Herdr?") && !HerdrHandoff.requestsTransfer("Explain how to transfer to Herdr") && !HerdrHandoff.requestsTransfer("Don't transfer this session to Herdr"), "Informational and negated Herdr mentions do not open a transfer")
        for phrase in ["start a herdr session to give quickask the ability to open links in this context", "Open a new Herdr tab and keep going",
                       "continue this in a new herdr tab", "spin up a Herdr session for this",
                       "spawn a herdr session fixing quickask, it should have auto went to \"my setup\" to search for telly", "fire up a new herdr agent for this",
                       "yes lets do that in  a herdr session", "ok do it in herdr", "let's fix this in a new Herdr tab",
                       "can you spwn a herdr session to handle this", "could you get another herdr session on this"] {
            check(HerdrHandoff.requestsTransfer(phrase), "Starting a Herdr session is a transfer request: \(phrase)")
        }
        for phrase in ["What is a herdr session?", "Explain how to start a herdr session", "Don't start a herdr session", "Don't spawn a herdr session", "Herdr sessions are great",
                       "Is this possible in herdr?", "Don't do that in a herdr session", "I had a herdr session crash yesterday", "can you explain a herdr session?"] {
            check(!HerdrHandoff.requestsTransfer(phrase), "Asking about or declining Herdr is not a transfer: \(phrase)")
        }
        // 2026-10-26: "try again to spawn it" after a Herdr request that didn't open re-sends that request.
        let asked: [ChatMessage] = [.init(role: "user", text: "can you spwn a herdr session to handle this", complete: true),
                                    .init(role: "assistant", text: "I can't spawn a Herdr session from here.", complete: true)]
        check(HerdrHandoff.retriedRequest("try again to spawn it", history: asked) == "can you spwn a herdr session to handle this"
              && HerdrHandoff.retriedRequest("ok do it", history: asked) != nil && HerdrHandoff.retriedRequest("go ahead", history: asked) != nil,
              "A retry right after a Herdr request sends that request again")
        let unrelated: [ChatMessage] = [.init(role: "user", text: "what's the weather", complete: true), .init(role: "assistant", text: "Sunny.", complete: true)]
        check(HerdrHandoff.retriedRequest("try again", history: unrelated) == nil && HerdrHandoff.retriedRequest("don't try again", history: asked) == nil
              && HerdrHandoff.retriedRequest("try again but explain why the tunnel fails and what the logs say about it", history: asked) == nil
              && HerdrHandoff.retriedRequest("try again", history: []) == nil,
              "A retry opens Herdr only right after a Herdr request, and never negated or as a longer new question")
        let noToolsPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "spawn a herdr session")])
        check(noToolsPrompt.contains("[[herdr:") && noToolsPrompt.contains("never say you can't"), "Every route knows Quick Ask opens Herdr and how to offer it")
        // 2026-10-24: asking for Herdr opens it; only My setup's own offer for a bigger build shows the review card.
        let offered = HerdrHandoff.suggestion(in: "That touches the router, the card and the tests.\n\n[[herdr: Add a Herdr suggestion card to Quick Ask]]\n")
        check(offered?.instruction == "Add a Herdr suggestion card to Quick Ask" && offered?.text == "That touches the router, the card and the tests.", "A reply's Herdr offer line becomes the card's instruction and leaves the reply")
        check(HerdrHandoff.suggestion(in: "Done. The [[herdr: x]] marker belongs on its own last line, as here.") == nil && HerdrHandoff.suggestion(in: "Fixed the typo.") == nil && HerdrHandoff.suggestion(in: "ok\n[[herdr: ]]") == nil,
              "Only a non-empty offer on the reply's last line counts")
        let mySetup = try PromptBuilder.make(messages: [.init(role: "user", text: "build a sync engine")], personal: true)
        let unscopedPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "build a sync engine")])
        check(mySetup.contains("larger build") && !unscopedPrompt.contains("larger build"), "Only My setup, which could start the build, is told to offer Herdr for one unasked")
        check(!HerdrProposal.make(question: "spawn a herdr session", history: [], attachments: [], snapshot: nil, provider: .claude).direct, "A proposal starts as a card; the router marks the ones you asked for direct")
        check(!HerdrHandoff.referencesScreen("transfer this session to herdr") && HerdrHandoff.referencesScreen("transfer to Herdr and edit this document"), "A generic transfer does not collect unrelated screen content")
        let conversation = (0..<12).map { ChatMessage(role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0): keep this constraint.") }
        var herdr = HerdrProposal.make(question: "Transfer this session to Herdr and shorten the introduction", history: conversation + [.init(role: "assistant", text: "unfinished output", complete: false)], attachments: [scaled], snapshot: nil, provider: .codex)
        check(herdr.history.count == 12 && herdr.provider == .codex && herdr.images.count == 1, "Direct continuation retains full completed history, selected provider, and recent images")
        let sessionRoot = directory.appendingPathComponent("direct-herdr")
        let fakeCLI = directory.appendingPathComponent("fake cli's binary")
        try "#!/usr/bin/python3\nimport os,json,sys\nopen(os.environ['QA_TEST_CAPTURE'],'w').write(json.dumps(sys.argv[1:]))\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        let shellMarker = directory.appendingPathComponent("must-not-be-created")
        herdr.instruction += "\nLiteral: $(touch '\(shellMarker.path)') `touch '\(shellMarker.path)'` \" café"
        let missingGeneral = directory.appendingPathComponent("no-projects-folder")
        let prepared = try HerdrHandoff.prepare(herdr, executable: fakeCLI.path, model: "fixture model", root: sessionRoot, general: missingGeneral)
        check(prepared.prompt.contains("Message 0") && prepared.prompt.contains("Message 11") && !prepared.prompt.contains("unfinished output"), "Full conversation is carried over rather than the last few messages")
        check(prepared.workingDirectory == prepared.directory && !prepared.workingDirectory.path.contains("cxtasks"), "Without a general folder, Herdr falls back to its own private folder, not a task workspace")
        // 2026-10-21: a handoff naming three repos opened in the home folder, whose trust Claude Code never saves, so it asked again.
        let generalFolder = directory.appendingPathComponent("projects-root")
        try FileManager.default.createDirectory(at: generalFolder, withIntermediateDirectories: true)
        let unscoped = HerdrProposal.make(question: "Continue in Herdr", history: conversation, attachments: [], snapshot: nil, provider: .claude)
        let inGeneral = try HerdrHandoff.prepare(unscoped, executable: fakeCLI.path, model: "fixture model", root: sessionRoot, general: generalFolder)
        let generalLaunch = try String(contentsOf: inGeneral.launch, encoding: .utf8)
        check(inGeneral.workingDirectory == generalFolder.resolvingSymlinksInPath().standardizedFileURL && inGeneral.directory != inGeneral.workingDirectory
              && generalLaunch.contains("cd '\(inGeneral.workingDirectory.path)'"), "No single repo opens in the trusted general folder, context kept in the private one")
        let launchText = try String(contentsOf: prepared.launch, encoding: .utf8)
        check(!launchText.contains("dangerously") && !launchText.contains("mcp-config") && !launchText.contains("exec --json") && launchText.contains("unset OPENAI_API_KEY"), "Interactive continuation adds no bypass flags, task server, print mode, or paid API fallback")
        check(HerdrHandoff.interactiveArguments(provider: .codex, model: "", imagePaths: ["/private/image.png"]) == ["--image=/private/image.png"], "Codex terminal session receives its images directly")
        let capture = directory.appendingPathComponent("captured-herdr-arguments.json")
        let launchProcess = Process(); launchProcess.executableURL = prepared.launch
        var launchEnvironment = ProcessInfo.processInfo.environment; launchEnvironment["QA_TEST_CAPTURE"] = capture.path; launchProcess.environment = launchEnvironment
        launchProcess.standardOutput = FileHandle.nullDevice; launchProcess.standardError = FileHandle.nullDevice
        try launchProcess.run(); launchProcess.waitUntilExit()
        let captured = try JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as! [String]
        check(launchProcess.terminationStatus == 0 && captured.last == prepared.prompt && captured.prefix(2) == ["--model", "fixture model"], "Generated launch script delivers the exact Unicode prompt and model as arguments")
        check(!FileManager.default.fileExists(atPath: shellMarker.path), "Conversation text cannot execute shell substitutions")
        let permissions = try FileManager.default.attributesOfItem(atPath: prepared.directory.appendingPathComponent("prompt.txt").path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600, "Exported chat is stored owner-only")
        let fakeRouter = directory.appendingPathComponent("fixture-herdr-router")
        try #"""
        #!/usr/bin/python3
        import json,sys,pathlib
        args=dict(zip(sys.argv[1::2],sys.argv[2::2]))
        count=pathlib.Path(__file__).with_suffix('.count')
        count.write_text(str(int(count.read_text())+1) if count.exists() else '1')
        print(json.dumps({'workspace_id':'fixture-space','tab_id':'fixture-tab','warning':'fixture focus warning'}))
        """#.write(to: fakeRouter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeRouter.path)
        let opened = try HerdrHandoff.launch(herdr, executable: fakeCLI.path, model: "fixture model", router: fakeRouter.path, root: sessionRoot)
        check(opened.confirmed && opened.workspaceID == "fixture-space" && opened.message.contains("No CXTasks task was created"), "A confirmed Herdr receipt reports the direct session despite a focus warning")
        _ = try HerdrHandoff.launch(herdr, executable: fakeCLI.path, model: "fixture model", router: fakeRouter.path, root: sessionRoot)
        let calls = try String(contentsOf: fakeRouter.deletingPathExtension().appendingPathExtension("count"), encoding: .utf8)
        check(calls == "1", "Duplicate confirmation cannot open another Herdr tab")
        var changedTransfer = herdr; changedTransfer.instruction += " altered after submission"
        check(rejected { _ = try HerdrHandoff.launch(changedTransfer, executable: fakeCLI.path, model: "fixture model", router: fakeRouter.path, root: sessionRoot) }, "An attempted continuation cannot be replaced by new instructions")
        let missingRouter = directory.appendingPathComponent("no-herdr")
        check(rejected { _ = try HerdrHandoff.launch(herdr, executable: fakeCLI.path, model: "", router: missingRouter.path, root: sessionRoot) }, "Missing Herdr integration does not fall back to another terminal")
        var invalidFolder = HerdrProposal.make(question: "Continue in Herdr", history: conversation, attachments: [], snapshot: nil, provider: .claude)
        invalidFolder.workspace = directory.appendingPathComponent("missing-folder").path
        check(rejected { _ = try HerdrHandoff.prepare(invalidFolder, executable: fakeCLI.path, model: "", root: sessionRoot) }, "A missing chosen folder is not replaced with a parent or home directory")
        let failedRouter = directory.appendingPathComponent("fixture-failed-herdr-router")
        try "#!/bin/sh\nexit 1\n".write(to: failedRouter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failedRouter.path)
        let failing = HerdrProposal.make(question: "Continue in Herdr", history: conversation, attachments: [], snapshot: nil, provider: .claude)
        let failedHandoff = try HerdrHandoff.launch(failing, executable: fakeCLI.path, model: "", router: failedRouter.path, root: sessionRoot)
        check(!failedHandoff.confirmed && failedHandoff.message.contains("did not confirm"), "An unconfirmed direct launch does not claim a session opened")
        let transferModel = AppModel(preferences: UserDefaults(suiteName: "QuickAsk-test-\(UUID().uuidString)")!)
        transferModel.selectContext(.general); transferModel.messages = conversation
        check(transferModel.canTransferToHerdr && !transferModel.canSend, "The menu can transfer an existing chat without requiring a new draft")
        // Never the real launcher: a test once opened a live Herdr tab from these fixtures.
        transferModel.claudePath = fakeCLI.path; transferModel.herdrRouter = fakeRouter.path
        transferModel.herdrSessions = directory.appendingPathComponent("model-herdr")
        let routerCount = fakeRouter.deletingPathExtension().appendingPathExtension("count")
        func launches() -> Int { Int((try? String(contentsOf: routerCount, encoding: .utf8)) ?? "0") ?? 0 }
        let launchedBefore = launches()
        transferModel.draft = "lets transfer this session to herdr and have it do x"
        transferModel.send()
        for _ in 0..<300 { if transferModel.messages.count == conversation.count + 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(launches() == launchedBefore + 1 && transferModel.herdrProposal == nil && transferModel.delegation == nil && transferModel.draft.isEmpty
              && transferModel.messages.suffix(2).first?.text == "do x" && transferModel.messages.last?.text.contains("Opened a fresh Claude tab in Herdr in ") == true,
              "Asking for Herdr opens it straight away, no review card, no task, and says where it opened")
        transferModel.messages = conversation
        transferModel.draft = "lets transfer this session to herdr and have it do x"
        transferModel.prepareTask()
        for _ in 0..<50 { if transferModel.delegation != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(transferModel.delegation != nil && transferModel.herdrProposal == nil && launches() == launchedBefore + 1, "The explicit Create task menu action takes precedence over transfer wording")
        transferModel.cancelDelegation(); transferModel.draft = ""; transferModel.prepareHerdr()
        for _ in 0..<300 { if transferModel.messages.count == conversation.count + 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(launches() == launchedBefore + 2 && transferModel.herdrProposal == nil && transferModel.messages.suffix(2).first?.text == "Continue this conversation in Herdr.",
              "The menu transfers the existing chat with an empty composer, straight away")
        // Quick Ask's own offer is the one card you didn't ask for; Cancel keeps the chat.
        transferModel.messages = conversation
        transferModel.suggestHerdr("Build the sync engine", in: transferModel.activeSessionID)
        for _ in 0..<50 { if transferModel.herdrProposal != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(transferModel.herdrProposal?.direct == false && transferModel.herdrProposal?.instruction == "Build the sync engine" && launches() == launchedBefore + 2,
              "My setup's Herdr offer shows the review card and launches nothing")
        transferModel.displayChanged()
        check(transferModel.herdrProposal != nil, "A screenless suggested continuation survives display changes")
        transferModel.cancelHerdr()
        check(transferModel.herdrProposal == nil && transferModel.messages.count == conversation.count, "Cancel preserves the conversation")
        // A choice only you can make still shows the card.
        transferModel.messages = []; transferModel.draft = "open herdr and shorten the introduction of the document"
        transferModel.send()
        for _ in 0..<50 { if transferModel.herdrProposal != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        check(transferModel.herdrProposal?.needsDocument == true && transferModel.herdrProposal?.direct == false && launches() == launchedBefore + 2,
              "A request that needs a document chosen opens the card instead of launching blind")
        transferModel.cancelHerdr(); transferModel.messages = [imageOnly]
        check(transferModel.canTransferToHerdr, "An image-only conversation can also be continued in Herdr")
        check(HerdrInference.instruction("lets transfer this session to herdr and have it shorten the introduction") == "shorten the introduction", "The confirmation infers the next action without repeating the transfer request")
        check(HerdrInference.instruction("Continue in Herdr and fix the wording") == "fix the wording", "A direct and-action also becomes the next instruction")
        check(HerdrInference.instruction("can u spawn a herdr session to handle as many of these as possible?") == "handle as many of these as possible?",
              "The new session gets the work, not the request to spawn a session, so it doesn't open another")
        let seeded = try HerdrHandoff.seed(HerdrProposal.make(question: "spawn a herdr session to fix it", history: conversation, attachments: [], snapshot: nil, provider: .claude), imagePaths: [])
        check(seeded.contains("don't open another Herdr session"),
              "The seed tells the session it is the Herdr session")
        let sourceDirectory = directory.resolvingSymlinksInPath()
        let projectFolders = [ProjectWorkspace(project: "Sample Project", path: sourceDirectory.path)]
        let inferred = HerdrProposal.make(question: "transfer this session to Herdr", history: [.init(role: "assistant", text: "The document is [feedback](\(document.path):12).")], attachments: [], snapshot: nil, provider: .claude, workspaces: projectFolders)
        check(inferred.referenceDocument == document.resolvingSymlinksInPath().path && inferred.workspace == sourceDirectory.path, "An exact conversation document resolves its known project folder")
        let remembered = HerdrProposal.make(question: "continue in Herdr", history: conversation, attachments: [], snapshot: nil, provider: .codex, previousDocument: document.path)
        check(remembered.referenceDocument == document.resolvingSymlinksInPath().path && remembered.provider == .codex, "Prior document context and the current provider are inferred without another form")
        let namedProject = HerdrProposal.make(question: "transfer to Herdr and have it fix Sample Project", history: conversation, attachments: [], snapshot: nil, provider: .claude, workspaces: projectFolders)
        check(namedProject.workspace == sourceDirectory.path, "A concrete registered project name resolves an existing folder")
        // 2026-10-21: "spin up a herdr session and figure out what happened here with quickask" opened in a blank session folder.
        let repoFolders = [ProjectWorkspace(project: "quickask", path: sourceDirectory.path)]
        for phrase in ["spin up a herdr session and figure out what happened here with quickask then fix it", "open herdr and fix Quick Ask"] {
            check(HerdrProposal.make(question: phrase, history: [], attachments: [], snapshot: nil, provider: .claude, workspaces: repoFolders).workspace == sourceDirectory.path,
                  "A repo named in any spelling opens in its folder: \(phrase)")
        }
        let otherRepo = directory.appendingPathComponent("other-repo"); try FileManager.default.createDirectory(at: otherRepo, withIntermediateDirectories: true)
        let twoRepos = HerdrProposal.make(question: "update quickask and other-repo in a herdr session", history: [], attachments: [], snapshot: nil, provider: .claude,
                                          workspaces: repoFolders + [ProjectWorkspace(project: "other-repo", path: otherRepo.resolvingSymlinksInPath().path)])
        check(!twoRepos.needsTargetChoice && twoRepos.workspace.isEmpty, "Several named repos open in the general folder instead of asking which one")
        check(!HerdrInference.names("ask a quick question", "quickask") && !HerdrInference.names("open the app", "apify"), "Word order and short names don't make a match")
        // 2026-10-25: a screenshot of the "New Artist Advisory signup" alert opened in ~/Projects instead of the product's repo.
        let webRepo = directory.appendingPathComponent("artisttracker"), iosRepo = directory.appendingPathComponent("xcode/artistadvisory")
        for repo in [webRepo, iosRepo] { try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true) }
        let product = [ProjectWorkspace(project: "Artist Advisory", path: webRepo.path), ProjectWorkspace(project: "Artist Advisory", path: iosRepo.path),
                       ProjectWorkspace(project: "artistadvisory", path: iosRepo.path, registered: false)] + repoFolders
        let web = webRepo.resolvingSymlinksInPath().path, ios = iosRepo.resolvingSymlinksInPath().path
        check(HerdrProposal.make(question: "spawn a herdr session to fix the Artist Advisory signup alert", history: [], attachments: [], snapshot: nil, provider: .claude, workspaces: product).workspace == web,
              "A product with web and iOS repos opens the web repo")
        check(HerdrProposal.make(question: "spawn a herdr session to fix the Artist Advisory iOS paywall", history: [], attachments: [], snapshot: nil, provider: .claude, workspaces: product).workspace == ios,
              "Saying iOS opens the product's iOS repo")
        check(HerdrProposal.make(question: "update artist advisory and quickask in a herdr session", history: [], attachments: [], snapshot: nil, provider: .claude, workspaces: product).workspace.isEmpty,
              "Two products still open the general folder")
        let alert = NSImage(size: NSSize(width: 900, height: 160)); alert.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 160).fill()
        ("New Artist Advisory signup" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 44), .foregroundColor: NSColor.black])
        alert.unlockFocus()
        let alertText = HerdrInference.imageText([ImageAttachment.make(from: alert)!])
        check(HerdrInference.names(alertText, "Artist Advisory"), "Text is read from an attached image: \(alertText)")
        check(HerdrProposal.make(question: "spawn a herdr session to look into this", history: [], attachments: [], snapshot: nil, provider: .claude, workspaces: product, imageText: alertText).workspace == web,
              "A screenshot that names a project opens its repo")
        let earlier: [ChatMessage] = [.init(role: "user", text: "the artist advisory signup emails look off"), .init(role: "assistant", text: "Quickask could check that.")]
        check(HerdrProposal.make(question: "continue in herdr", history: earlier, attachments: [], snapshot: nil, provider: .claude, workspaces: product).workspace == web,
              "A project your earlier message named opens its repo")
        check(HerdrProposal.make(question: "continue in herdr", history: [.init(role: "user", text: "quickask feels slow")], attachments: [], snapshot: nil, provider: .claude,
                                 workspaces: [ProjectWorkspace(project: "quickask", path: sourceDirectory.path, registered: false)]).workspace.isEmpty,
              "An unregistered repo folder named in passing doesn't route by topic")
        // A new chat starts in the project it is about, as if you had sent `!cd` there.
        check(HerdrInference.chatFolder(question: "who is this?", imageText: alertText, workspaces: product) == web, "A screenshot that names a project starts the chat in its repo")
        check(HerdrInference.chatFolder(question: "why is the artist advisory iOS paywall blank?", imageText: "", workspaces: product) == ios, "A chat about the iOS app starts in the iOS repo")
        try "Readme".write(to: webRepo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        check(HerdrInference.chatFolder(question: "what does `\(webRepo.path)/README.md` say?", imageText: "", workspaces: product) == web, "A file in a project starts the chat in that project")
        check(HerdrInference.chatFolder(question: "what's the weather tomorrow?", imageText: "", workspaces: product) == nil, "A question about nothing of yours stays where it was")
        check(HerdrInference.chatFolder(question: "quickask feels slow", imageText: "", workspaces: [ProjectWorkspace(project: "quickask", path: sourceDirectory.path, registered: false)]) == nil,
              "Naming an unregistered repo folder doesn't move the chat")
        let harness = [ProjectWorkspace(project: "Harness", path: webRepo.path)]
        check(HerdrInference.chatFolder(question: "what's a good harness for a dog?", imageText: "", workspaces: harness) == nil
              && HerdrInference.chatFolder(question: "tidy up the Harness hooks", imageText: "", workspaces: harness) == web, "A one-word project that is an ordinary word needs its capitals")
        check(HerdrInference.chatFolder(question: "compare artist advisory and quickask", imageText: "", workspaces: product) == nil, "Two projects pick neither")
        check(HerdrInference.chatFolder(question: "summarize `\(NSTemporaryDirectory())`", imageText: "", workspaces: product) == nil, "A folder outside your projects doesn't move the chat")
        let localRoot = directory.appendingPathComponent("code-root")
        try FileManager.default.createDirectory(at: localRoot.appendingPathComponent("repo-a/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localRoot.appendingPathComponent("not-a-repo"), withIntermediateDirectories: true)
        check(ProjectRegistry.localRepos(roots: [localRoot]).map(\.project) == ["repo-a"], "Only git repositories under a code root are offered")
        let taskRef = HerdrInference.targets(question: "continue in Herdr", history: [.init(role: "user", text: "can we close t187?")], snapshot: nil, previousDocument: nil, workspaces: projectFolders, taskRepo: { $0 == 187 ? sourceDirectory.path : nil })
        check(taskRef.map(\.folder) == [sourceDirectory.path] && taskRef.first?.document == nil, "A T-number in the chat opens the task's own repository")
        check(HerdrInference.targets(question: "continue in Herdr", history: [.init(role: "user", text: "T4 and T999")], snapshot: nil, previousDocument: nil, workspaces: [], taskRepo: { _ in nil }).isEmpty, "Single-digit or unknown T-numbers pick no folder")
        // 2026-10-24: a reply naming `/Applications/Synology Drive Client.app` opened two Herdr sessions inside the bundle.
        let bundle = directory.appendingPathComponent("Fixture Drive Client.app/Contents"); try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let bundleReply: [ChatMessage] = [.init(role: "assistant", text: "In the picker, press ⌘⇧G and paste `\(bundle.deletingLastPathComponent().path)`."), .init(role: "assistant", text: "Or open `\(bundle.path)`.")]
        let fixThis = HerdrProposal.make(question: "Spawn a herdr session to fix this.", history: bundleReply, attachments: [], snapshot: nil, provider: .claude)
        check(fixThis.workspace.isEmpty && !fixThis.needsTargetChoice, "An app bundle a reply mentioned is not a working folder; the session opens in the general folder")
        check(HerdrInference.targets(question: "open `\(bundle.deletingLastPathComponent().path)` in herdr", history: [], snapshot: nil, previousDocument: nil, workspaces: []).isEmpty, "Not even when the request names the bundle itself")
        check(HerdrInference.targets(question: "continue in herdr", history: [.init(role: "user", text: "look at `/Applications`")], snapshot: nil, previousDocument: nil, workspaces: []).isEmpty, "A folder outside the home folder is not a working folder")
        let looseFolder = directory.appendingPathComponent("loose-folder"); try FileManager.default.createDirectory(at: looseFolder, withIntermediateDirectories: true)
        let folderReply: [ChatMessage] = [.init(role: "assistant", text: "Saved it to `\(looseFolder.path)`.")]
        check(HerdrInference.targets(question: "continue in herdr", history: folderReply, snapshot: nil, previousDocument: nil, workspaces: []).isEmpty, "A bare folder from a reply needs a known workspace")
        check(HerdrInference.targets(question: "continue in herdr", history: folderReply, snapshot: nil, previousDocument: nil, workspaces: projectFolders).map(\.folder) == [sourceDirectory.path], "Inside a known workspace, a reply's folder opens that workspace")
        check(HerdrInference.targets(question: "continue in herdr", history: [.init(role: "user", text: "work in `\(looseFolder.path)`")], snapshot: nil, previousDocument: nil, workspaces: []).map(\.folder) == [looseFolder.resolvingSymlinksInPath().path], "A folder the user names still opens there")
        let secondDocument = directory.appendingPathComponent("another-feedback.md")
        try "another introduction".write(to: secondDocument, atomically: true, encoding: .utf8)
        let ambiguous = HerdrProposal.make(question: "Continue in Herdr", history: [.init(role: "assistant", text: "Compare `\(document.path)` and `\(secondDocument.path)`.")], attachments: [], snapshot: nil, provider: .claude)
        check(ambiguous.needsTargetChoice && ambiguous.targetChoices.count == 2 && ambiguous.workspace.isEmpty, "Two plausible documents produce one targeted question instead of a guessed target")
        transferModel.herdrProposal = ambiguous; transferModel.selectHerdrTarget(ambiguous.targetChoices[0])
        check(transferModel.herdrProposal?.needsTargetChoice == false && transferModel.herdrProposal?.referenceDocument != nil, "Choosing the target resolves the inline question")
        let unknown = HerdrProposal.make(question: "transfer to Herdr and have it shorten the introduction", history: [], attachments: [], snapshot: nil, provider: .claude)
        check(unknown.needsDocument, "A document edit with no chat or source asks only for the missing document")
        check(rejected { _ = try HerdrHandoff.prepare(ambiguous, executable: fakeCLI.path, model: "", root: sessionRoot) }, "An ambiguous target cannot be launched before it is chosen")
        // Studio Coach: FL Studio's connector, served by the Studio Coach app, with cards for the UI
        check(AppConnector.matching("com.image-line.flstudio") == .studiocoach && !AppConnector.studiocoach.hasSelection, "FL Studio's window brings Studio Coach, which publishes no selection")
        check(AppConnector.studiocoach.launch(claudeConfig: directory.appendingPathComponent("missing.json")) == MCPLaunch(command: "/Applications/Studio Coach.app/Contents/MacOS/StudioCoach", arguments: ["--mcp"]), "Studio Coach launches from its app, not the Claude config")
        check(SelectionReader.read(bundleID: "com.image-line.flstudio", pid: 1) == nil, "No selection socket is tried for FL Studio")
        check(AppConnector.studiocoach.toolDeadline == 300 && AppConnector.cxmail.toolDeadline == 60, "Only coach calls get a long deadline")
        let flWindow = ContextWindow(id: 31, pid: 40, bundleID: "com.image-line.flstudio", appName: "FL Studio", title: "blessings.flp", bounds: .zero)
        let flInput = RoutingInput(question: "is the low end too much?", history: [], imageCount: 0, windows: [flWindow], candidate: nil, projects: [])
        check(flInput.connectedApps == [.studiocoach] && RoutingQuestion.all(for: flInput).first { $0.name == "needs_screen" }?.instructions.contains("Studio Coach") == true, "The router is told a session question points at FL")
        check(RoutingQuestion.all(for: RoutingInput(question: "q", history: [], imageCount: 0, windows: [termWindow], candidate: nil, projects: [])).first { $0.name == "needs_screen" }?.instructions.contains("Studio Coach") == false, "The FL hint appears only with FL visible")
        let flSnapshot = ContextSnapshot(displayID: 1, windowID: 31, pid: ProcessInfo.processInfo.processIdentifier, bundleID: "com.image-line.flstudio", appName: "FL Studio", windowTitle: "blessings.flp", capturedAt: Date().timeIntervalSince1970, launchTime: 0, selection: nil, text: "", document: "")
        check(rejected { try GatewayPolicy.validate(connector: .studiocoach, tool: "set_card", arguments: ["feeling": "warm", "path": "/etc"], selection: nil) }, "Coach writes accept only their own fields")
        check(rejected { try GatewayPolicy.validate(connector: .studiocoach, tool: "delete_song", arguments: [:], selection: nil) }, "Tools outside the coach allowlist are refused")
        try GatewayPolicy.validate(connector: .studiocoach, tool: "record_outcome", arguments: ["song": "blessings", "finding": "e1-1", "result": "helped"], selection: nil)
        check(true, "An outcome with its own fields is accepted")
        let coachMCP = directory.appendingPathComponent("coach-mcp")
        try #"""
        #!/usr/bin/python3
        import sys,json
        card={'kind':'assess','song':'blessings','entry_id':'e1','label':'Mix advice','question':'','source':{'kind':'live clip','seconds':75,'heard':False,'fallback':None},'summary':'The vocal sits low in the hook.','findings':[{'id':'e1-1','title':'Vocal under the beat','measured':'4 LU below','might_mean':'buried','try':'+2 dB','checked':True,'outcome':None}],'left_alone':'the drums','ask_chris':'Is the hook meant to feel distant?'}
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            if q['method']=='initialize': r={'protocolVersion':'2025-06-18','capabilities':{'tools':{}}}
            elif q['method']=='tools/list': r={'tools':[{'name':n,'inputSchema':{'type':'object','properties':{}}} for n in ['status','assess','set_card','record_outcome','delete_song']]}
            elif q['params']['name']=='assess': r={'content':[{'type':'text','text':json.dumps(card)}],'structuredContent':{'card':card},'isError':False}
            else: r={'content':[{'type':'text','text':'ok '+q['params']['name']}],'isError':False}
            print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
        """#.write(to: coachMCP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: coachMCP.path)
        let cardsPath = directory.appendingPathComponent("coach-cards.jsonl").path
        var coachConfig = GatewayConfiguration(snapshot: flSnapshot, connectors: [.studiocoach], executables: [:], desktopControl: false,
                                               readOnly: [.studiocoach], launches: ["studiocoach": MCPLaunch(command: coachMCP.path, arguments: ["--mcp"])])
        coachConfig.cardsPath = cardsPath
        check(coachConfig.leaseSeconds == 420 && configuration.leaseSeconds == 180, "A coach request's lease outlasts a coach answer")
        check(coachConfig.handoff.cardsPath == cardsPath, "The descriptor carries the card file to the gateway")
        let coachGateway = ContextGateway(configuration: coachConfig, valid: { true })
        let coachTools = try coachGateway.tools().compactMap { $0["name"] as? String }.sorted()
        check(coachTools == ["studiocoach__assess", "studiocoach__status"], "A read-only FL route lists assess but not the coach's writes")
        check(rejected { _ = try coachGateway.call("studiocoach__set_card", arguments: ["feeling": "warm"]) }, "A read-only FL route refuses set_card")
        let tail = CardTail(path: cardsPath)
        check(tail.poll().isEmpty, "No card before the coach answers")
        _ = try coachGateway.call("studiocoach__status", arguments: [:])
        _ = try coachGateway.call("studiocoach__assess", arguments: ["action": "mix"])
        let drawn = tail.poll()
        check(drawn.count == 1 && drawn[0].findings?.first?.tryThis == "+2 dB" && drawn[0].entryId == "e1", "The coach's answer reaches the UI as a card")
        check(drawn.first?.sourceLabel == "live 1:15", "The card says which audio was used")
        check(tail.poll().isEmpty, "A card is drawn once")
        check(((try? FileManager.default.attributesOfItem(atPath: cardsPath)[.posixPermissions]) as? NSNumber)?.intValue == 0o600, "The card file is owner-only")
        var writable = coachConfig; writable.readOnly = []
        let writeGateway = ContextGateway(configuration: writable, valid: { true })
        check((try? writeGateway.call("studiocoach__set_card", arguments: ["feeling": "warm"]))?["isError"] as? Bool == false, "A clear request may set the song card without an FL selection")
        let bounce = CoachCard.decode(Data(#"{"kind":"lines","song":"blessings","label":"Compare to the floor","source":{"kind":"bounce","file":"blessings v4.wav"},"summary":"clears 5 of 7","lines":["a","b"]}"#.utf8))
        check(bounce?.sourceLabel == "bounce · blessings v4.wav" && bounce?.lines == ["a", "b"] && bounce?.entryId == nil, "Floor checks draw as lines from a bounce")
        var coached = ChatMessage(role: "assistant", text: "The vocal is the thing.", provider: .claude)
        coached.cards = drawn
        let coachHistory = try PromptBuilder.make(messages: [.init(role: "user", text: "how's the mix"), coached, .init(role: "user", text: "the first one helped")], context: coachConfig)
        check(coachHistory.contains("finding e1-1") && coachHistory.contains("studiocoach__assess") && !coachHistory.contains("4 LU below"), "Follow-ups can name a finding; the prompt explains the coach without its numbers")
        let coachDesktop = DesktopSession(target: AppTarget(pid: 40, name: "FL Studio"), ownerPID: 1, executable: "/bin/qa", lease: "/tmp/l", toolTimeout: 400)
        check(Provider.codex.arguments(model: "", desktop: coachDesktop).contains("mcp_servers.quickask.tool_timeout_sec=400"), "Codex waits for a coach answer")
        check(!Provider.codex.arguments(model: "", desktop: DesktopSession(target: AppTarget(pid: 40, name: "x"), ownerPID: 1, executable: "/bin/qa", lease: "/tmp/l")).contains { $0.contains("tool_timeout_sec") }, "Other requests keep Codex's tool timeout")
        // Onyx: the page Onyx shows, read like its ask box, with tools to read more
        check(AppConnector.matching("com.cx.onyx") == .onyx && AppConnector.onyx.publishesSelection && !AppConnector.onyx.hasSelection && AppConnector.onyx.writes.isEmpty, "Onyx's window brings its read-only page tools")
        let onyxReply = #"{"pid":7,"bundleID":"com.cx.onyx","windowLabel":"main","windowID":9,"revision":"r","label":"Guide","records":{"document_path":"/x/g.html"},"passage":"the hook","surrounding":"Why the hook works","page":2}"#
        let onyxBridged = try JSONDecoder().decode(AppSelection.self, from: Data(onyxReply.utf8))
        check(onyxBridged.passage == "the hook" && onyxBridged.surrounding == "Why the hook works" && onyxBridged.page == 2, "Onyx's bridge reply carries the passage and its surroundings")
        let unselected = AppSelection(pid: 7, bundleID: "com.cx.onyx", windowLabel: "main", windowID: 9, revision: "r", label: "Guide", records: ["document_path": "/x/g.html"])
        check(onyxBridged.sameTarget(as: unselected), "A changed highlight is not a different target")
        let pageFolder = directory.appendingPathComponent("onyx-page"), pageFile = pageFolder.appendingPathComponent("guide.html")
        try FileManager.default.createDirectory(at: pageFolder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let body = (1...40).map { "<p>Paragraph \($0) about mixing &amp; levels.</p>" }.joined()
        try "<html><head><title>T</title><style>p{}</style></head><body><script>var secret=1</script><h1>The Guide</h1>\(body)<h2>Low end</h2><p>Sidechain the bass under the kick.</p></body></html>".write(to: pageFile, atomically: true, encoding: .utf8)
        try "# Notes\nThe kick sits at 55 Hz.".write(to: pageFolder.appendingPathComponent("notes/kick.md"), atomically: true, encoding: .utf8)
        try "TOKEN=abc".write(to: pageFolder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "x".write(to: directory.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: pageFolder.appendingPathComponent("escape.md"), withDestinationURL: directory.appendingPathComponent("outside.md"))
        let pageRevision = try TaskDelegation.fileRevision(pageFile.resolvingSymlinksInPath().path)
        let pageSelection = AppSelection(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "com.cx.onyx", windowLabel: "main", windowID: 9, revision: "r", label: "The Guide",
                                         records: ["document_path": pageFile.path, "document_revision": pageRevision, "editing": "false"], passage: "", surrounding: "The Guide Paragraph 1", page: nil)
        let onyxSnapshot = ContextSnapshot(displayID: 1, windowID: 9, pid: ProcessInfo.processInfo.processIdentifier, bundleID: "com.cx.onyx", appName: "Onyx", windowTitle: "", capturedAt: Date().timeIntervalSince1970, launchTime: 0, selection: pageSelection, text: "", document: pageFile.path)
        let onyxConfig = GatewayConfiguration(snapshot: onyxSnapshot, connectors: [.onyx], executables: [:], desktopControl: false, writes: false)
        check(onyxConfig.handoff.snapshot.selection?.passage == nil && onyxConfig.handoff.snapshot.selection?.surrounding == nil && onyxConfig.handoff.snapshot.selection?.records["document_path"] != nil, "The descriptor carries the page's identity, never its text")
        check(onyxConfig.toolNames.sorted() == ["onyx__read_nearby", "onyx__read_page", "onyx__search_page"], "A read-only Onyx route keeps all three page tools")
        let onyxGateway = ContextGateway(configuration: onyxConfig.handoff, valid: { true })
        let onyxToolNames = try onyxGateway.tools().compactMap { $0["name"] as? String }.sorted()
        check(onyxToolNames == ["onyx__read_nearby", "onyx__read_page", "onyx__search_page"], "Onyx's tools are served by the gateway, with no server to start")
        func onyxText(_ tool: String, _ arguments: [String: Any]) -> String {
            guard let result = try? onyxGateway.call(tool, arguments: arguments), result["isError"] as? Bool == false else { return "ERROR" }
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        let pageChunk = onyxText("onyx__read_page", ["limit": 200])
        check(pageChunk.contains("# The Guide") && pageChunk.contains("mixing & levels") && !pageChunk.contains("secret") && !pageChunk.contains("p{}") && pageChunk.contains("More follows: read_page with offset 200"), "The page reads as text in chunks: headings marked, scripts and styles dropped")
        let found = onyxText("onyx__search_page", ["query": "sidechain"])
        check(found.contains("1 match") && found.contains("under the kick") && found.contains("[offset "), "search_page finds a passage with its offset")
        check(onyxText("onyx__search_page", ["query": "bass compression trick"]).contains("match its words"), "A phrase with no exact match falls back to its words")
        let listing = onyxText("onyx__read_nearby", ["path": ""])
        check(listing.contains("guide.html") && listing.contains("notes/") && !listing.contains(".env"), "read_nearby lists the page's folder without hidden files")
        check(onyxText("onyx__read_nearby", ["path": "notes/kick.md"]).contains("55 Hz"), "read_nearby reads a file beside the page")
        check(onyxText("onyx__read_nearby", ["path": "../outside.md"]) == "ERROR", "read_nearby refuses a path out of the folder")
        check(onyxText("onyx__read_nearby", ["path": "escape.md"]) == "ERROR", "read_nearby refuses a symlink out of the folder")
        check(onyxText("onyx__read_nearby", ["path": ".env"]) == "ERROR", "read_nearby refuses hidden and key files")
        check(rejected { _ = try onyxGateway.call("onyx__write_page", arguments: [:]) }, "Only the three read tools exist")
        try "<p>changed</p>".write(to: pageFile, atomically: true, encoding: .utf8)
        let staleGateway = ContextGateway(configuration: onyxConfig.handoff, valid: { true })
        check((try? staleGateway.call("onyx__read_page", arguments: [:])) == nil, "A page changed on disk since Onyx showed it is refused")
        var remoteSelection = pageSelection; remoteSelection = AppSelection(pid: 1, bundleID: "com.cx.onyx", windowLabel: "main", windowID: 9, revision: "r", label: "Web", records: ["source_url": "https://example.com"])
        let remoteSnapshot = ContextSnapshot(displayID: 1, windowID: 9, pid: 1, bundleID: "com.cx.onyx", appName: "Onyx", windowTitle: "", capturedAt: 0, launchTime: 0, selection: remoteSelection, text: "", document: "")
        check(rejected { _ = try ContextGateway(configuration: GatewayConfiguration(snapshot: remoteSnapshot, connectors: [.onyx], executables: [:], desktopControl: false), valid: { true }).tools() }, "A remote page has no page tools")
        let onyxPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "what is this page arguing?")], context: onyxConfig)
        check(onyxPrompt.contains("onyx__search_page") && onyxPrompt.contains("selection.passage") && onyxPrompt.contains("The Guide Paragraph 1") && !onyxPrompt.contains("Onyx are unavailable"), "The prompt sends the excerpt and explains reading more only as needed")
        let onyxWindow = ContextWindow(id: 9, pid: 7, bundleID: "com.cx.onyx", appName: "Onyx", title: "The Guide", bounds: .zero)
        let onyxInput = RoutingInput(question: "summarize this page", history: [], imageCount: 0, windows: [onyxWindow], candidate: onyxSnapshot, projects: [])
        check(RoutingQuestion.all(for: onyxInput).first { $0.name == "needs_screen" }?.instructions.contains("Onyx") == true, "The router is told 'this page' points at Onyx")
        check(onyxSnapshot.routingEvidence["has_highlighted_passage"] as? Bool == false && onyxSnapshot.routingEvidence["visible_text"] == nil, "The router learns whether text is highlighted, not the text")
        check(OnyxPage.htmlText("<ul><li>a</li><li>b &mdash; c</li></ul>") == "- a\n- b — c", "Lists and entities read naturally")

        // Meeting Copilot: tools while a meeting is live, and the check-in straight from the copilot
        check(MeetingCopilot.pulseKind("How am I doing?") == "checkin" && MeetingCopilot.pulseKind("did I miss anything") == "missed" && MeetingCopilot.pulseKind("Wrap up") == "wrapup" && MeetingCopilot.pulseKind("copilot, how am I doing") == "checkin", "The three check-ins are recognized as asked")
        check(MeetingCopilot.pulseKind("how am I doing on the budget for the Acme proposal this quarter") == nil && MeetingCopilot.pulseKind("what did Sam say about pricing?") == nil, "Longer questions go through the routed answer")
        check(MeetingCopilot.mentioned("ask the copilot what they think") && MeetingCopilot.mentioned("summarize this meeting") && !MeetingCopilot.mentioned("GitHub Copilot pricing".replacingOccurrences(of: "Copilot", with: "Co pilot")), "Naming the copilot or the meeting brings its tools")
        check(MeetingCopilot.liveSession(health: ["status": "ok", "session": "s1"]) == "s1" && MeetingCopilot.liveSession(health: ["status": "ok", "session": NSNull()]) == nil, "A meeting is live only when the copilot reports a session")
        check(AppConnector.meetingcopilot.writes.isEmpty && AppConnector.meetingcopilot.toolDeadline == 130, "Asking the copilot changes nothing and may take two minutes")
        var meetingInput = RoutingInput(question: "what did Sam say about pricing?", history: [], imageCount: 0, windows: [], candidate: nil, projects: [], personalAvailable: true)
        check(RoutingQuestion.all(for: meetingInput).first { $0.name == "uses_meetingcopilot" } == nil, "No meeting question without a live meeting")
        meetingInput.toolConnectors.append(.meetingcopilot)
        check(RoutingQuestion.all(for: meetingInput).first { $0.name == "uses_meetingcopilot" } != nil, "A live meeting adds the meeting question")
        let meetingPlan = RoutePlan.make(RoutingSignals(yes: ["about_my_work": 0.95, "uses_meetingcopilot": 0.97, "needs_screen": 0.1]), input: meetingInput, bars: .forEngine(.decisions, high: 0.9), previous: nil)
        check(meetingPlan.scope == .general && meetingPlan.tools == [.meetingcopilot] && meetingPlan.label == "General chat · Meeting Copilot", "A question about the meeting goes to the copilot, not My setup")
        let nearBar = RoutePlan.make(RoutingSignals(yes: ["uses_meetingcopilot": 0.8, "needs_screen": 0.1]), input: meetingInput, bars: .forEngine(.decisions, high: 0.9), previous: nil)
        check(nearBar.tools == [.meetingcopilot], "Meeting tools use My setup's lower bar")
        let offBar = RoutePlan.make(RoutingSignals(yes: ["uses_meetingcopilot": 0.4, "uses_vault": 0.8]), input: meetingInput, bars: .forEngine(.decisions, high: 0.9), previous: nil)
        check(offBar.tools.isEmpty, "A low meeting score, and the vault below its own bar, attach nothing")
        let meetingMCP = directory.appendingPathComponent("meeting-mcp")
        try #"""
        #!/usr/bin/python3
        import sys,json
        for line in sys.stdin:
            q=json.loads(line)
            if 'id' not in q: continue
            if q['method']=='initialize': r={'protocolVersion':'2025-06-18','capabilities':{'tools':{}}}
            elif q['method']=='tools/list': r={'tools':[{'name':n,'inputSchema':{'type':'object','properties':{}}} for n in ['status','transcript','ask','pulse','suggest','research','session_stop']]}
            elif q['params']['name']=='pulse': r={'content':[{'type':'text','text':'You are doing well: '+q['params']['arguments'].get('kind','')}],'isError':False}
            else: r={'content':[{'type':'text','text':'ok '+q['params']['name']}],'isError':False}
            print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
        """#.write(to: meetingMCP, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingMCP.path)
        let meetingConfig = GatewayConfiguration(snapshot: AppModel.placeholderSnapshot(displayID: nil), connectors: [.meetingcopilot], executables: [:], desktopControl: false,
                                                 writes: false, launches: ["meetingcopilot": MCPLaunch(command: meetingMCP.path)], screenless: true)
        let meetingGateway = ContextGateway(configuration: meetingConfig, valid: { true })
        let meetingToolNames = try meetingGateway.tools().compactMap { $0["name"] as? String }.sorted()
        check(meetingToolNames == ["meetingcopilot__ask", "meetingcopilot__pulse", "meetingcopilot__research", "meetingcopilot__status", "meetingcopilot__suggest", "meetingcopilot__transcript"], "A read-only route keeps every meeting tool, and only those")
        check(rejected { _ = try meetingGateway.call("meetingcopilot__session_stop", arguments: [:]) }, "Tools outside the copilot allowlist are refused")
        let askResult = try meetingGateway.call("meetingcopilot__ask", arguments: ["question": "q"])
        check((askResult["content"] as? [[String: Any]])?.first?["text"] as? String == "ok ask", "A question reaches the copilot through the gateway")
        check(meetingConfig.leaseSeconds == 420, "A meeting request's lease outlasts a cold check-in")
        check((try? MeetingCopilot.pulse("checkin", launch: MCPLaunch(command: meetingMCP.path))) == "You are doing well: checkin", "The fast check-in calls the copilot directly")
        let meetingPrompt = try PromptBuilder.make(messages: [.init(role: "user", text: "q")], context: meetingConfig)
        check(meetingPrompt.contains("meetingcopilot__pulse"), "The prompt explains the copilot's tools")
        check(ChatMessage(role: "assistant", text: "a", source: "meetingcopilot").provider == "meetingcopilot", "A check-in reply is labeled as the copilot's")
        // The harness eval: real failures through the whole route decision, with the router assumed wrong.
        let scorecard = HarnessEval.report(await HarnessEval.run())
        scorecard.lines.forEach { print($0) }
        check(scorecard.regressions.isEmpty, "Harness eval: every case outside a known gap lands right; failing: \(scorecard.regressions.joined(separator: ", "))")
        check(scorecard.closed.isEmpty, "Harness eval: these gaps now pass, so remove their gap note: \(scorecard.closed.joined(separator: ", "))")
        print("PASS: \(count) provider and transport checks")
    }
}
