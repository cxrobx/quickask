import AppKit
import SwiftUI
import Carbon
import os

private let activationLog = Logger(subsystem: "local.quickask.desktop", category: "activation")

final class QuickPanel: PreviewHostPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel(history: .standard, warmPool: .shared, followUpJudge: FollowUpCheck.judge)
    private let appearance = GlassAppearance()
    private var glassHost: GlassPanelHost!
    private var panel: QuickPanel!
    private var statusItem: NSStatusItem!
    private var hotkey: EventHotKeyRef?
    private var stopHotkey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var previousApp: NSRunningApplication?
    private var previousWindowID: UInt32?
    /// When the popup was last hidden; 10 minutes later the next summon starts a fresh chat.
    private var hiddenAt: Date?
    private var keyMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var draggedPosition = false
    private var positioning = false
    private var resizeScheduled = false
    private var preferredWidth: CGFloat = 620
    private var compactHeight: CGFloat = 222
    private var expandedHeight: CGFloat = 640
    var recoveryURL: URL?
    private var statusFeed: StatusFeed?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusFeed = StatusFeed.standardURL.map { StatusFeed(model: model, url: $0) }
        if let recoveryURL {
            do { try model.restoreChats(ChatRecovery.load(from: recoveryURL)) }
            catch { model.error = error.localizedDescription }
        }
        NSApp.setActivationPolicy(.accessory)
        model.applyOpenAtLogin()
        makeEditMenu()
        func savedDimension(_ key: String, fallback: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            let value = UserDefaults.standard.double(forKey: key)
            return value.isFinite && value > 0 ? max(minimum, min(maximum, CGFloat(value))) : fallback
        }
        preferredWidth = savedDimension("popupWidth", fallback: 620, minimum: 500, maximum: 2400)
        compactHeight = savedDimension("popupCompactHeight", fallback: 222, minimum: 222, maximum: 1600)
        expandedHeight = savedDimension("popupExpandedHeight", fallback: 640, minimum: 360, maximum: 1600)
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 222),
                           styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.contentMinSize = NSSize(width: 500, height: 222)
        panel.title = "QuickAsk"
        panel.identifier = NSUserInterfaceItemIdentifier("QuickAskPopup")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        // Only the header and footer drag the popup, so text can be selected anywhere else.
        panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        model.refreshScreenContext = { [weak self] in self?.refreshContext() }
        model.moveToFocusedApp = { [weak self] in self?.moveToFocusedApp() }
        let content = NSHostingView(rootView: PopupView(model: model, appearance: appearance,
            dismiss: { [weak self] in self?.hide(restoreFocus: true) },
            resize: { [weak self] in self?.scheduleResize() },
            changeHotkey: { [weak self] in self?.registerHotkey() }))
        // The panel owns its size. SwiftUI's generated content-size constraints
        // otherwise fight the glass container when settings replaces the prompt.
        content.sizingOptions = []
        content.safeAreaRegions = []
        glassHost = GlassPanelHost(hostingView: content, appearance: appearance)
        glassHost.attach(to: panel)
        makeStatusItem()
        installHotkeyHandler()
        registerHotkey()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.previousApp = app; self.previousWindowID = DisplayContext.focusedWindow(pid: app.processIdentifier)
                if self.panel.isVisible { self.refreshContext() }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if QuickLook.shared.handleKey(event, in: self.panel) { return nil }
            // Esc ends voice mode first, then interrupts the answer in the tab showing; the next one hides the popup.
            if event.keyCode == 53 && self.model.voice.isActive { self.model.voice.stop(); return nil }
            if event.keyCode == 53 && self.model.busy { self.model.stop(); return nil }
            if event.keyCode == 53 { self.hide(restoreFocus: true); return nil }
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "m" { self.model.voice.toggle(); return nil }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "n" { self.model.newChat(); return nil }
                if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "t" { self.model.reopenClosedTab(); return nil }
                if event.charactersIgnoringModifiers == "t" { self.model.newTab(); return nil }
                // ⌘W closes the tab showing; with one chat there is no tab, so it hides the popup as Esc does.
                if event.charactersIgnoringModifiers == "w" {
                    if self.model.showsTabs { self.model.closeSession(self.model.activeSessionID) } else { self.hide(restoreFocus: true) }
                    return nil
                }
                // ⌘⌥← / ⌘⌥→ cycle the open tabs (123 = left arrow, 124 = right arrow).
                if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
                    self.model.cycleTab(by: event.keyCode == 123 ? -1 : 1); return nil
                }
                if event.charactersIgnoringModifiers == "," { self.model.showingSettings.toggle(); return nil }
                if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "c" {
                    self.model.copyLatest(); return nil
                }
            }
            return event
        }
        show()
    }

    private func makeEditMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit QuickAsk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            menu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.insertItem(redo, at: 1)
        edit.submenu = menu; main.addItem(edit)
        NSApp.mainMenu = main
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "QuickAsk")
            button.toolTip = "QuickAsk · Option–Space"
            button.target = self; button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show QuickAsk", action: #selector(showFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: "").target = self
            if model.busy { menu.addItem(withTitle: "Stop current request", action: #selector(stopFromMenu), keyEquivalent: "").target = self }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit QuickAsk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { toggle() }
    }
    @objc private func showFromMenu() { show() }
    @objc private func settingsFromMenu() { model.showingSettings = true; show() }
    @objc private func stopFromMenu() { model.stop(); show() }

    private func installHotkeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID(signature: 0, id: 0)
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let stop = id.id == 2
            DispatchQueue.main.async { if stop { delegate.model.stop(); delegate.show() } else { delegate.toggle() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func registerHotkey() {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if let stopHotkey { UnregisterEventHotKey(stopHotkey); self.stopHotkey = nil }
        let modifiers = UInt32(optionKey) | (model.alternativeHotkey ? UInt32(shiftKey) : 0)
        let id = EventHotKeyID(signature: 0x5141534B, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), modifiers, id, GetApplicationEventTarget(), 0, &hotkey)
        let stopID = EventHotKeyID(signature: 0x5141534B, id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(optionKey), stopID, GetApplicationEventTarget(), 0, &stopHotkey)
        model.hotkeyStatus = model.alternativeHotkey ? "⌥ ⇧ Space" : "⌥ Space"
        if result != noErr {
            model.hotkeyStatus = "Shortcut unavailable"
            model.error = "This shortcut is already in use. Free it in the other app, or choose Option–Shift–Space in Settings. You can still open QuickAsk from the menu bar."
        }
    }

    func toggle() { panel.isVisible ? hide(restoreFocus: true) : show() }
    private func show() {
        if !panel.isVisible {
            if let hiddenAt { model.startFreshIfIdle(hiddenFor: Date().timeIntervalSince(hiddenAt)) }
            hiddenAt = nil
            previousApp = NSWorkspace.shared.frontmostApplication
            if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApp = nil }
            previousWindowID = previousApp.flatMap { DisplayContext.focusedWindow(pid: $0.processIdentifier) }
            resize()
            let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            let currentDisplay = DisplayContext.display(for: panel.frame, regions: DisplayContext.regions)?.id
            let pointerDisplay = (pointerScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            if !draggedPosition || currentDisplay != pointerDisplay { positionOnCurrentScreen() }
        }
        refreshContext()
        model.prewarm()
        panel.orderFrontRegardless()
        model.popupVisible = true
        glassHost.applyWindowEffect()
        panel.makeKey()
        NSApp.activate()
        model.focusToken += 1
        // macOS may decline a cooperative activation and leave the other app in front. The popup
        // then shows without a caret, and clear glass frosts until it is clicked, so insist once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel.isVisible, !NSApp.isActive else { return }
            activationLog.notice("Summon left QuickAsk inactive; forcing activation")
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    private func hide(restoreFocus: Bool) {
        QuickLook.shared.close()
        if panel.isVisible { hiddenAt = Date() }
        panel.orderOut(nil)
        model.popupVisible = false
        if restoreFocus { previousApp?.activate(options: []) }
        previousApp = nil
    }

    /// What the compact popup adds to its saved height: the image strip and the tab bar.
    private var compactExtra: CGFloat { (model.attachments.isEmpty ? 0 : PopupMetrics.attachmentStrip) + (model.showsTabs ? PopupMetrics.tabBar : 0) }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        // Never resize NSWindow while its hosting view is updating SwiftUI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resize()
        }
    }

    private func resize() {
        // Settings scrolls within the current chat frame, including after a
        // background reply or a menu action requests a layout update.
        if model.showingSettings {
            glassHost?.layoutContent()
            glassHost?.applyWindowEffect()
            return
        }
        let bottom = panel.frame.minY
        positioning = true
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let height: CGFloat = model.delegation != nil ? max(600, expandedHeight) : (!model.messages.isEmpty ? expandedHeight : (model.herdrProposal != nil ? max(440, compactHeight) : (model.error != nil || model.needsContextChoice ? max(360, compactHeight) : compactHeight + compactExtra)))
        panel.contentMinSize = NSSize(width: 500, height: model.chatExpanded ? 360 : 222)
        panel.contentMaxSize = NSSize(width: max(500, visible.width - 40), height: max(360, visible.height - 40))
        panel.setContentSize(NSSize(width: min(preferredWidth, visible.width - 40), height: min(height, visible.height - 70)))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: max(visible.minY + 20, min(bottom, visible.maxY - panel.frame.height - 20))))
        glassHost?.layoutContent()
        positioning = false
        glassHost.applyWindowEffect()
    }

    private func positionOnCurrentScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        positioning = true
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
            y: min(visible.minY + visible.height * 0.18, visible.maxY - panel.frame.height - 25)))
        positioning = false
    }

    private func refreshContext() {
        guard let display = DisplayContext.display(for: panel.frame, regions: DisplayContext.regions) else { return }
        if let old = model.contextDisplayID, old != display.id { model.displayChanged() }
        model.contextDisplayID = display.id
        let windows = DisplayContext.windows(on: display.id)
        model.contextWindows = windows
        let chosen: ContextWindow?
        if case .window(let id) = model.contextChoice { chosen = windows.first { $0.id == id } }
        else { chosen = DisplayContext.candidate(windows, preferredPID: nil, preferredWindow: previousWindowID) }
        model.candidateWindow = chosen
        if !model.busy { model.targetApp = chosen?.target }
        if !model.busy && !model.needsContextChoice {
            model.contextLabel = model.contextChoice == .general ? "General chat" : model.contextChoice == .personal ? "My setup" : (chosen.map { "\(model.contextChoice == .auto ? "Auto · " : "")\($0.appName)" } ?? "No screen context")
        }
    }

    private func moveToFocusedApp() {
        guard !model.busy, let app = previousApp,
              let pair = DisplayContext.regions.compactMap({ region in DisplayContext.windows(on: region.id).first(where: { $0.pid == app.processIdentifier }).map { (region, $0) } }).first,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == pair.0.id }) else { return }
        positioning = true
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.midY - panel.frame.height / 2))
        positioning = false; previousWindowID = pair.1.id; refreshContext()
    }

    func windowDidMove(_ notification: Notification) { if !positioning { draggedPosition = true; refreshContext() } }
    func windowDidResize(_ notification: Notification) {
        glassHost?.layoutContent()
        guard !positioning, let panel else { return }
        let size = panel.contentRect(forFrameRect: panel.frame).size
        preferredWidth = size.width
        UserDefaults.standard.set(Double(preferredWidth), forKey: "popupWidth")
        if model.chatExpanded {
            expandedHeight = size.height
            UserDefaults.standard.set(Double(expandedHeight), forKey: "popupExpandedHeight")
        } else {
            compactHeight = max(222, size.height - compactExtra)
            UserDefaults.standard.set(Double(compactHeight), forKey: "popupCompactHeight")
        }
        glassHost?.applyWindowEffect()
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look taking the key window is still the popup in use.
        if !model.pinned && !QuickLook.shared.isOpen { hide(restoreFocus: false) }
    }
    /// Quick Look held the key window, so the popup never saw the user leave: close both.
    func applicationDidResignActive(_ notification: Notification) {
        guard QuickLook.shared.isOpen else { return }
        QuickLook.shared.close()
        if !model.pinned { hide(restoreFocus: false) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.stopAll(); return .terminateNow }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    /// quickask://chat/<id> brings that chat forward (reopening it from history if its tab was
    /// closed) and shows the popup. The Stream Deck plugin sends it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "quickask" && url.host == "chat" {
            if let id = UUID(uuidString: url.lastPathComponent), id != model.activeSessionID { model.reopenChat(id) }
            hiddenAt = nil // the chat asked for, not the fresh one a long-hidden summon starts
            show()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let stopHotkey { UnregisterEventHotKey(stopHotkey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

@main
struct QuickAskMain {
    @MainActor static func main() {
        // QuickAsk --manual <bundle id> ["query"]: index an app's manual, optionally search it.
        if let flag = CommandLine.arguments.firstIndex(of: "--manual"), flag + 1 < CommandLine.arguments.count {
            let bundleID = CommandLine.arguments[flag + 1]
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let knowledge = AppKnowledge(key: bundleID, appName: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID, bundleURL: url)
            let index = ManualIndex(knowledge)
            let started = Date()
            do {
                let rows = try index.build()
                print("\(knowledge.manualSources().count) files, \(rows) rows, \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(knowledge.indexURL.path)")
                if flag + 2 < CommandLine.arguments.count {
                    for hit in try index.search(CommandLine.arguments[flag + 2]) { print("[\(hit.source) p. \(hit.page)] \(hit.heading) — \(hit.excerpt)\n") }
                }
                exit(0)
            } catch { print(error.localizedDescription); exit(1) }
        }
        // My setup's screen tool (ScreenLook.swift): one tool, launched by Claude Code.
        if CommandLine.arguments.contains("--screen-mcp") {
            let owner = CommandLine.arguments.firstIndex(of: "--owner-pid").flatMap { $0 + 1 < CommandLine.arguments.count ? Int32(CommandLine.arguments[$0 + 1]) : nil }
            ScreenLookServer(ownerPID: owner ?? 0).run()
            return
        }
        if CommandLine.arguments.contains("--mcp") {
            func value(_ name: String) -> String {
                guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return "" }
                return CommandLine.arguments[index + 1]
            }
            var configuration: GatewayConfiguration?
            if CommandLine.arguments.contains("--gateway-config") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: value("--gateway-config"))), data.count < 200_000,
                      let parsed = try? JSONDecoder().decode(GatewayConfiguration.self, from: data) else { exit(1) }
                configuration = parsed
            }
            DesktopMCPServer(targetPID: Int32(value("--target-pid")) ?? 0,
                             ownerPID: Int32(value("--owner-pid")) ?? 0, lease: value("--lease"), gatewayConfiguration: configuration).run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        if let index = CommandLine.arguments.firstIndex(of: "--restore-chat"), index + 1 < CommandLine.arguments.count {
            delegate.recoveryURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
