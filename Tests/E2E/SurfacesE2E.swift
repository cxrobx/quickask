import AppKit
import SwiftUI

/// End-to-end: a question through `AppModel.send()` exactly as the popup sends it, against the real
/// apps: Onyx's context socket, the routing service, the provider CLI, the gateway (this binary in
/// `--mcp` mode, as QuickAsk's is) and Meeting Copilot's MCP. Only the keystrokes are skipped.
///
///   e2e-surfaces <onyx|any> "<question>" [--choice auto|general|personal|window] [--history chat.json] [--image file.png]
///
/// `--history` continues a chat saved by Quick Ask (its History JSON; the last route counts as General).
/// `--image` attaches an image file as the composer would.
/// `--save chat.json` writes the chat afterwards, in the shape `--history` reads.
/// `--show out.png` renders the chat in the real popup view and screenshots it (`--wait` seconds first);
/// `--show-first` puts the chat on screen while it answers, so a page in it can be pictured.
/// A question of "-" sends nothing: with `--history` and `--show` it renders a saved chat.
///
/// Prints one JSON line: the context label, status, error, answer and seconds.
@main
struct SurfacesE2E {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--screen-mcp") {
            let owner = arguments.firstIndex(of: "--owner-pid").flatMap { $0 + 1 < arguments.count ? Int32(arguments[$0 + 1]) : nil }
            ScreenLookServer(ownerPID: owner ?? 0).run()
            return
        }
        if arguments.contains("--mcp") {
            func value(_ name: String) -> String {
                guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return "" }
                return arguments[index + 1]
            }
            var configuration: GatewayConfiguration?
            if arguments.contains("--gateway-config") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: value("--gateway-config"))),
                      let parsed = try? JSONDecoder().decode(GatewayConfiguration.self, from: data) else { exit(1) }
                configuration = parsed
            }
            DesktopMCPServer(targetPID: Int32(value("--target-pid")) ?? 0, ownerPID: Int32(value("--owner-pid")) ?? 0,
                             lease: value("--lease"), gatewayConfiguration: configuration).run()
            return
        }
        guard arguments.count >= 3 else { print("usage: e2e-surfaces <onyx|any> \"question\""); exit(2) }
        _ = NSApplication.shared
        if arguments[1] == "route" {
            // The router's raw answers for a question asked during a live meeting, with no window.
            let windows = DisplayContext.windows(on: CGMainDisplayID())
            var candidate: ContextSnapshot?
            if let first = windows.first { candidate = await ScreenContextCapture.snapshot(first, displayID: CGMainDisplayID()) }
            var input = RoutingInput(question: arguments[2], history: [], imageCount: 0, windows: windows, candidate: candidate, projects: [], personalAvailable: true)
            input.toolConnectors.append(.meetingcopilot)
            if case .signals(let signals) = await ContextRouter.assess(input, engine: .decisions) {
                let plan = RoutePlan.make(signals, input: input, bars: .forEngine(.decisions, high: 0.9), previous: nil)
                print(signals.yes.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "), "→", plan.label)
            } else if case .failed(let reason) = await ContextRouter.assess(input, engine: .decisions) { print("router failed:", reason) }
            exit(0)
        }
        let preferences = UserDefaults(suiteName: "com.cx.quickask.e2e")!
        preferences.removePersistentDomain(forName: "com.cx.quickask.e2e")
        let model = AppModel(preferences: preferences)
        model.provider = ProcessInfo.processInfo.environment["E2E_PROVIDER"] == "codex" ? .codex : .claude
        var displays = [CGDirectDisplayID](repeating: 0, count: 8), count: UInt32 = 0
        CGGetActiveDisplayList(8, &displays, &count)
        let all = displays.prefix(Int(count)).flatMap { id in DisplayContext.windows(on: id).map { (id, $0) } }
        if arguments[1] == "onyx" {
            guard let (display, window) = all.first(where: { $0.1.bundleID == "com.cx.onyx" }) else { print(#"{"error":"Onyx has no visible window"}"#); exit(1) }
            model.contextDisplayID = display
            model.contextWindows = DisplayContext.windows(on: display)
            model.candidateWindow = window
            if arguments.contains("window") { model.selectContext(.window(window.id)) }
        } else if let (display, window) = all.first {
            model.contextDisplayID = display; model.contextWindows = DisplayContext.windows(on: display); model.candidateWindow = window
        }
        if arguments.contains("general") { model.selectContext(.general) }
        if arguments.contains("personal") { model.selectContext(.personal) }
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if let path = option("--history"), let data = FileManager.default.contents(atPath: path),
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let rows = try? JSONSerialization.data(withJSONObject: saved["messages"] ?? []),
           let history = try? JSONDecoder().decode([ChatMessage].self, from: rows) {
            model.messages = history
        }
        if let path = option("--image") {
            guard let image = NSImage(contentsOfFile: path), model.addImages(ImageAttachment.make(from: image).map { [$0] } ?? []) else {
                print(#"{"error":"The image couldn't be attached"}"#); exit(1)
            }
        }
        let started = Date()
        var statuses: [String] = []
        // "-" sends nothing: with --history and --show it renders a saved chat.
        if arguments[2] != "-" {
            // A page snapshot needs the page on screen, as it is in the app's popup.
            var window: NSWindow?
            if arguments.contains("--show-first") { window = await show(model, waitSeconds: 4) }
            model.draft = arguments[2]
            model.send()
            while Date().timeIntervalSince(started) < 900 {
                if window == nil { pump(0.1) } else { runApp(0.2) }
                if statuses.last != model.status { statuses.append(model.status) }
                if !model.busy && Date().timeIntervalSince(started) > 0.5 { break }
            }
            window?.close()
        }
        if let path = option("--save"), let rows = try? JSONEncoder().encode(model.messages),
           let messages = try? JSONSerialization.jsonObject(with: rows) {
            try? JSONSerialization.data(withJSONObject: ["messages": messages], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: path))
        }
        if let path = option("--show") {
            let window = await show(model, waitSeconds: Double(option("--wait") ?? "") ?? 5)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
            try? capture.run(); capture.waitUntilExit()
            // WebKit's own picture of the newest page, as a follow-up would send it.
            if let out = ProcessInfo.processInfo.environment["E2E_PAGE_SNAPSHOT"],
               let page = MarkdownBlocks.latestPage(in: model.messages.filter { $0.role == "assistant" }.map(\.text)),
               let shot = await PageRegistry.shared.snapshot(of: page) {
                try? shot.data.write(to: URL(fileURLWithPath: out))
            }
        }
        let answer = model.messages.last(where: { $0.role == "assistant" })
        let report: [String: Any] = [
            "label": model.contextLabel, "error": model.error ?? "", "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "replier": answer?.provider ?? "", "answer": answer?.text ?? "", "statuses": statuses
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }

    /// Runs the main run loop, which web views and timers need; async main alone doesn't.
    @MainActor static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Runs the app's event loop for a while. WebKit hands its frames to the window only under
    /// NSApp.run, as in the app: pumping the run loop from async code leaves pages blank.
    @MainActor static func runApp(_ seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        NSApp.run()
    }

    /// The real popup view on the model's chat, in a plain window, scrolled to the end.
    @MainActor static func show(_ model: AppModel, waitSeconds: Double) async -> NSWindow {
        NSApp.setActivationPolicy(.accessory)
        let height = Double(ProcessInfo.processInfo.environment["E2E_HEIGHT"] ?? "") ?? 1100
        let window = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 660, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PopupView(model: model, appearance: GlassAppearance(), dismiss: {}, resize: {}, changeHotkey: {}))
        window.level = .floating
        window.orderFrontRegardless() // Never key: the user may be typing elsewhere.
        runApp(waitSeconds)
        return window
    }
}
