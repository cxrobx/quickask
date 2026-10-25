import AppKit

/// End-to-end: QuickAsk's desktop MCP server (`--mcp`, exactly as a CLI starts it) driving the
/// control fixture while another app stays in front. After every step it checks the user's
/// front app and cursor never changed, then reads the fixture's state back from its title.
///
///   desktop-control-e2e <QuickAsk.app> <control-fixture> [--chrome <pid>] [--shots <dir>]
///
/// `--chrome` also drives a Chrome window showing Tests/E2E/control-page.html (an isolated
/// profile; see scripts/e2e-desktop.sh). Prints one line per check; exits 1 on any failure.
@main
struct DesktopControlE2E {
    static var failures = 0
    static var fixture: Process?
    /// `exit` skips `defer`, so the fixture is stopped here.
    static func finish(_ code: Int32) -> Never { fixture?.terminate(); exit(code) }
    static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print(ok ? "PASS" : "FAIL", name, ok || detail.isEmpty ? "" : "— \(detail.prefix(2500))")
        if !ok { failures += 1 }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { print("usage: desktop-control-e2e <QuickAsk.app> <control-fixture> [--chrome <pid>] [--shots <dir>]"); finish(2) }
        func option(_ name: String) -> String? { arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        let executable = URL(fileURLWithPath: arguments[1]).appendingPathComponent("Contents/MacOS/QuickAsk").path
        let shots = option("--shots")

        guard let user = NSWorkspace.shared.frontmostApplication else { print("No front app"); finish(2) }
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: arguments[2])
        let out = Pipe(); fixture.standardOutput = out
        try fixture.run()
        Self.fixture = fixture
        guard let line = readLine(from: out.fileHandleForReading), UInt32(line) != nil else { print("Fixture did not start"); finish(2) }
        // The fixture activates itself on launch; hand the front back, as if it had been in the background all along.
        user.activate(options: [])
        let deadline = Date().addingTimeInterval(3)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != user.processIdentifier, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == user.processIdentifier, "\(user.localizedName ?? "User app") is in front, the fixture behind")

        // A throwaway knowledge root with a small manual for the fixture.
        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-e2e-knowledge-\(UUID().uuidString)")
        setenv("QUICKASK_KNOWLEDGE_ROOT", knowledge.path, 1)
        let fixtureFolder = knowledge.appendingPathComponent("exec.\(URL(fileURLWithPath: arguments[2]).lastPathComponent)")
        try FileManager.default.createDirectory(at: fixtureFolder.appendingPathComponent("manual"), withIntermediateDirectories: true)
        try "# Fixture manual\n\n## Resetting\n\nTo zero every counter, choose Fixture › Reset Counters from the menu bar.\n"
            .write(to: fixtureFolder.appendingPathComponent("manual/fixture.md"), atomically: true, encoding: .utf8)
        let memoryFile = fixtureFolder.appendingPathComponent("memory.md")
        func memory() -> String { (try? String(contentsOf: memoryFile, encoding: .utf8)) ?? "" }

        let session = try Session(executable: executable, target: fixture.processIdentifier, user: user)
        defer { session.stop() }
        let window = AXUIElementCreateApplication(fixture.processIdentifier)
        func state() -> String {
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXWindowsAttribute as CFString, &windows)
            guard let first = (windows as? [AXUIElement])?.first else { return "" }
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(first, kAXTitleAttribute as CFString, &title)
            return title as? String ?? ""
        }
        func expect(_ name: String, _ result: Session.Result, _ fragment: String) {
            let now = state()
            check(!result.error && now.contains(fragment), name, "state “\(now)”, result: \(result.text)")
            session.assertUntouched(name)
        }

        check(session.toolCount == 20, "Twenty desktop tools", "\(session.toolCount)")
        let tree = session.call("inspect_ui")
        func id(_ pattern: String, in text: String) -> Int? {
            guard let match = text.range(of: "\\[(\\d+)\\] \(pattern)", options: .regularExpression) else { return nil }
            return Int(text[match].dropFirst().prefix { $0.isNumber })
        }
        guard let button = id("AXButton · “Increment”", in: tree.text), let field = id("AXTextField", in: tree.text),
              let slider = id("AXSlider", in: tree.text), let format = id("AXPopUpButton", in: tree.text) else { check(false, "Inspect lists the fixture's controls", tree.text); finish(1) }
        check(!tree.text.contains("AXMenuBar"), "Inspect leaves the menu bar to select_menu")

        expect("click_element presses a button in the background", session.call("click_element", ["element_id": button]), "p=1 ")
        let pressed = session.call("click_element", ["element_id": button])
        check(pressed.text.contains("~ [") && pressed.text.contains("“p=2 ") && !pressed.text.contains("AXTextField"),
              "Actions report only what changed (the window title)", pressed.text)
        expect("The same element ID still works after the tree refreshed", pressed, "p=2 ")
        expect("type_text focuses a field and types into it", session.call("type_text", ["element_id": field, "text": "héllo ✓"]), "t=héllo ✓")
        let typed = session.call("type_text", ["element_id": field, "text": "!"])
        check(typed.text.contains("“héllo ✓!”"), "The change report carries the field's new value", typed.text)
        expect("set_value sets a slider", session.call("set_value", ["element_id": slider, "value": 40]), "s=40 ")
        expect("choose_option picks a popup item in the background", session.call("choose_option", ["element_id": format, "option": "jpeg"]), "f=JPEG ")
        let noOption = session.call("choose_option", ["element_id": format, "option": "TIFF"])
        check(noOption.error && noOption.text.contains("PNG, JPEG, HEIF") && state().contains("f=JPEG "), "choose_option lists the options when none matches, and leaves the popup alone", noOption.text)
        session.assertUntouched("choose_option")
        let batch = session.call("batch_actions", ["steps": [
            ["tool": "set_value", "arguments": ["element_id": slider, "value": 70]],
            ["tool": "choose_option", "arguments": ["element_id": format, "option": "HEIF"]],
            ["tool": "click_element", "arguments": ["element_id": button]]]])
        expect("batch_actions runs its steps in order", batch, "p=3 ")
        check(state().contains("s=70 ") && state().contains("f=HEIF ") && batch.text.components(separatedBy: "Changes:").count == 2 && batch.text.contains("3. click_element"),
              "…and reports what changed once, at the end", batch.text)
        let stopped = session.call("batch_actions", ["steps": [
            ["tool": "set_value", "arguments": ["element_id": slider, "value": 70]],
            ["tool": "click_element", "arguments": ["element_id": button]]]])
        check(stopped.text.contains("Stopped") && state().contains("p=3 "), "A batch stops at a step that changed nothing", stopped.text)
        let nested = session.call("batch_actions", ["steps": [["tool": "click_coordinates", "arguments": ["x": 1, "y": 1]]]])
        check(nested.error, "Coordinate actions can't be batched", nested.text)
        let script = session.call("app_script", ["script": "get name of front window"])
        check(script.error && script.text.contains("no AppleScript dictionary"), "app_script refuses an app without a dictionary", script.text)
        session.assertUntouched("batch_actions")

        let shot = session.call("take_screenshot")
        check(!shot.error && shot.images == 1 && shot.text.contains("[\(button)]"), "Screenshots carry numbered marks matching element IDs", shot.text)
        guard let size = shot.text.range(of: "Image (\\d+)×(\\d+)", options: .regularExpression).map({ shot.text[$0] }),
              let width = Double(size.split(separator: " ")[1].split(separator: "×")[0]) else { check(false, "Screenshot size", shot.text); finish(1) }
        // The canvas sits 20–280 pt across and 152–312 pt down the 420 pt wide window.
        let scale = width / 420
        let canvas = (x: 210 * scale, y: 232 * scale)
        let click = session.call("click_coordinates", ["x": canvas.x, "y": canvas.y])
        if let shots { snap(near: fixture.processIdentifier, to: "\(shots)/agent-cursor.png") }
        expect("click_coordinates clicks a custom-drawn view in the background", click, "c=1 ")
        check(click.images == 1, "A pixel action returns a fresh screenshot", "\(click.images) images")
        expect("A double click arrives as one", session.call("click_coordinates", ["x": canvas.x, "y": canvas.y, "count": 2]), "d=1 ")
        expect("A right click arrives as a right click", session.call("click_coordinates", ["x": canvas.x, "y": canvas.y, "button": "right"]), "r=1 ")
        let drag = session.call("drag_coordinates", ["from_x": 30 * scale, "from_y": 120 * scale, "to_x": 410 * scale, "to_y": 120 * scale])
        let dragged = state().range(of: "s=(\\d+)", options: .regularExpression).flatMap { Int(state()[$0].dropFirst(2)) } ?? 0
        check(!drag.error && dragged > 90, "drag_coordinates drags a slider", "state \(state()), \(drag.text)")
        session.assertUntouched("drag_coordinates")

        let found = session.call("search_manual", ["query": "how do I reset the counters"])
        check(!found.error && found.text.contains("p. 1") && found.text.contains("«Reset»"), "search_manual finds the passage", found.text)
        let page = session.call("read_manual", ["page": 1])
        check(page.text.contains("choose Fixture › Reset Counters"), "read_manual reads the page", page.text)
        let listing = session.call("select_menu", ["path": ["Fixture"]])
        check(listing.text.contains("Reset Counters (command+r)"), "select_menu lists a menu with its shortcuts", listing.text)
        expect("select_menu chooses a command in the background", session.call("select_menu", ["path": ["Fixture", "Reset Counters…"]]), "x=1 ")
        check(memory().contains("- Fixture › Reset Counters (command+r) ×1"), "A menu command that worked is remembered", memory())
        expect("press_key sends a menu shortcut in the background", session.call("press_key", ["key": "command+r"]), "x=2 ")
        check(memory().contains("- command+r ×1"), "A shortcut that changed something is remembered", memory())
        let wrong = session.call("remember", ["note": "Counters reset from the Edit menu"])
        let saved = session.call("remember", ["note": "Reset everything: Fixture menu → Reset Counters, or command+r"])
        check(wrong.text.hasPrefix("Saved as n1.") && saved.text.hasPrefix("Saved as n2.") && memory().contains("[n2] Reset everything"), "remember writes numbered notes", "\(wrong.text) | \(saved.text) | \(memory())")
        let forgot = session.call("forget", ["note_id": 1])
        check(!forgot.error && !memory().contains("Edit menu") && memory().contains("[n2]"), "forget removes a wrong note", memory())
        let hover = session.call("hover", ["element_id": button])
        check(!hover.error, "hover", hover.text)
        let waited = session.call("wait", ["seconds": 0.3])
        check(!waited.error && waited.text.contains("No accessibility changes"), "wait reports an unchanged tree", waited.text)
        let missing = session.call("click_element", ["element_id": 99999])
        check(missing.error, "Unknown element IDs are refused")

        let foreground = session.call("click_element", ["element_id": button, "foreground": true])
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(!foreground.error && state().contains("p=1 ") && foreground.text.contains("foreground"), "foreground: true clicks with the app brought forward", "state \(state()), \(foreground.text)")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == user.processIdentifier, "…and gives the front back to the user's app")

        if let chrome = option("--chrome").flatMap(Int32.init) { try driveChrome(executable: executable, pid: chrome, user: user) }

        // A later request: the memory and manual are still there.
        let later = try Session(executable: executable, target: fixture.processIdentifier, user: user)
        let again = later.call("search_manual", ["query": "zero every counter"])
        later.stop()
        check(again.text.contains("p. 1") && memory().contains("[n2] Reset everything"), "Knowledge carries into the next request", again.text)
        try? FileManager.default.removeItem(at: knowledge)

        session.revoke()
        let revoked = session.call("inspect_ui")
        check(revoked.error && revoked.text.contains("stopped or expired"), "Revoking the lease stops control")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        finish(failures == 0 ? 0 : 1)
    }

    /// The Chromium route: AX presses, focused typing with authenticated keys, and pixel clicks.
    static func driveChrome(executable: String, pid: Int32, user: NSRunningApplication) throws {
        let session = try Session(executable: executable, target: pid, user: user)
        defer { session.stop() }
        func title() -> String {
            let list = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
            return list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowName as String] as? String)?.isEmpty == false) }?[kCGWindowName as String] as? String ?? ""
        }
        var tree = session.call("inspect_ui")
        if !tree.text.contains("Click me") {
            // A window covered since launch has no page tree yet: the result says so, and one
            // foreground inspection builds it.
            check(tree.text.contains("Page content isn't in the tree"), "Chrome: a covered window's missing page content is explained", String(tree.text.prefix(600)))
            tree = session.call("inspect_ui", ["foreground": true])
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier == user.processIdentifier, "Chrome: …and the front goes back to the user's app")
            let covered = session.call("inspect_ui")
            check(covered.text.contains("Click me"), "Chrome: the page tree stays once the window is covered again", String(covered.text.prefix(600)))
        }
        func id(_ pattern: String) -> Int? {
            guard let match = tree.text.range(of: "\\[(\\d+)\\] \(pattern)", options: .regularExpression) else { return nil }
            return Int(tree.text[match].dropFirst().prefix { $0.isNumber })
        }
        guard let button = id("AXButton · “Click me”"), let field = id("AXTextField[^\\n]*placeholder: Type here") else {
            check(false, "Chrome: inspect finds the page's controls", String(tree.text.prefix(3000))); return
        }
        let typed = session.call("type_text", ["element_id": field, "text": "abc"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(!typed.error && title().contains("typed abc"), "Chrome: type_text reaches a web field in the background", "title “\(title())”, \(typed.text.prefix(300))")
        session.assertUntouched("Chrome type_text")
        let pressed = session.call("click_element", ["element_id": button])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(!pressed.error && title().contains("clicked 1"), "Chrome: click_element presses a web button", "title “\(title())”")
        let shot = session.call("take_screenshot")
        guard let mark = shot.text.range(of: "Image (\\d+)×", options: .regularExpression), !shot.error else { check(false, "Chrome: screenshot", shot.text); return }
        _ = mark
        // The button's center from its AX bounds, in screenshot pixels.
        guard let line = tree.text.components(separatedBy: "\n").first(where: { $0.contains("[\(button)] ") }),
              let bounds = line.range(of: "bounds=[-0-9,]+", options: .regularExpression).map({ line[$0].dropFirst(7).split(separator: ",").compactMap { Double($0) } }),
              bounds.count == 4, let window = shot.text.range(of: "Window (\\d+)", options: .regularExpression).flatMap({ UInt32(shot.text[$0].dropFirst(7)) }),
              let frame = windowFrame(window) else { check(false, "Chrome: locate the button for a pixel click", shot.text); return }
        let width = Double(shot.text.range(of: "Image (\\d+)", options: .regularExpression).map { shot.text[$0].dropFirst(6) }.flatMap { Double($0) } ?? frame.width)
        let scale = width / frame.width
        let click = session.call("click_coordinates", ["x": (bounds[0] + bounds[2] / 2 - frame.minX) * scale, "y": (bounds[1] + bounds[3] / 2 - frame.minY) * scale])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(!click.error && title().contains("clicked 2"), "Chrome: a pixel click lands in the background", "title “\(title())”, \(click.text.prefix(200))")
        session.assertUntouched("Chrome click_coordinates")
    }

    static func windowFrame(_ id: UInt32) -> CGRect? {
        let list = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]) ?? []
        return (list.first?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    /// A picture of the screen around the target window, agent cursor included.
    static func snap(near pid: Int32, to path: String) {
        let list = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let frame = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 })
            .flatMap({ ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }) else { return }
        let region = frame.insetBy(dx: -40, dy: -40)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path]
        try? capture.run(); capture.waitUntilExit()
    }

    static func readLine(from handle: FileHandle) -> String? {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return data.isEmpty ? nil : String(decoding: data, as: UTF8.self) }
            if byte == Data([10]) { return String(decoding: data, as: UTF8.self) }
            data += byte
        }
    }
}

/// One `QuickAsk --mcp` process with its lease, spoken to over stdio.
final class Session {
    struct Result { let text: String; let images: Int; let error: Bool }
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lease: URL
    private let user: NSRunningApplication
    private let mouse: CGPoint
    private let started = Date()
    private var nextID = 1
    private(set) var toolCount = 0

    init(executable: String, target: Int32, user: NSRunningApplication) throws {
        self.user = user
        mouse = CGEvent(source: nil)?.location ?? .zero
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lease = directory.appendingPathComponent("control-enabled")
        try Data().write(to: lease)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--mcp", "--target-pid", String(target), "--owner-pid", String(ProcessInfo.processInfo.processIdentifier), "--lease", lease.path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        _ = request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "e2e", "version": "1"]])
        toolCount = ((request("tools/list", [:])["result"] as? [String: Any])?["tools"] as? [Any])?.count ?? 0
    }

    func call(_ name: String, _ arguments: [String: Any] = [:]) -> Result {
        let result = request("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        return Result(text: content.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                      images: content.filter { $0["type"] as? String == "image" }.count, error: result["isError"] as? Bool ?? true)
    }

    /// The user's front app and cursor are where they were. A cursor the user moved themselves
    /// (the hardware reports it) doesn't count against the test.
    func assertUntouched(_ step: String) {
        DesktopControlE2E.check(NSWorkspace.shared.frontmostApplication?.processIdentifier == user.processIdentifier, "  \(step): front app unchanged",
                                NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
        let userMoved = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < Date().timeIntervalSince(started)
        let now = CGEvent(source: nil)?.location ?? .zero
        DesktopControlE2E.check(userMoved || now == mouse, "  \(step): cursor unmoved", "\(mouse) → \(now)")
    }

    func revoke() { try? FileManager.default.removeItem(at: lease) }
    func stop() { try? input.fileHandleForWriting.close(); process.waitUntilExit(); try? FileManager.default.removeItem(at: lease.deletingLastPathComponent()) }

    private func request(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let id = nextID; nextID += 1
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        input.fileHandleForWriting.write(body + Data([10]))
        while let line = DesktopControlE2E.readLine(from: output.fileHandleForReading) {
            if let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], message["id"] as? Int == id { return message }
        }
        return [:]
    }
}
