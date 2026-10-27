import AppKit
import SwiftUI

/// Exercises AppKit/SwiftUI layout without external app interaction or user
/// preferences. QUICKASK_LAYOUT_VISIBLE=1 also exercises on-screen scrolling.
@MainActor
func verifyPopupLayout(check: (Bool, String) -> Void) {
    _ = NSApplication.shared
    let watchdog = DispatchWorkItem {
        fputs("FAIL: popup layout blocked the main thread for 30 seconds\n", stderr)
        _exit(1)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
    defer { watchdog.cancel() }
    let suite = "QuickAsk-layout-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences)
    let appearance = GlassAppearance(preferences: preferences)
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 559, height: 432),
                         styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var host: GlassPanelHost!
    var fixtureSize = NSSize(width: 559, height: 432)
    var resizeRequests = 0
    let content = NSHostingView(rootView:
        PopupView(model: model, appearance: appearance, dismiss: {}, resize: {
            resizeRequests += 1
            DispatchQueue.main.async {
                window.setContentSize(fixtureSize)
                host.layoutContent()
            }
        }, changeHotkey: {}))
    content.sizingOptions = []
    content.safeAreaRegions = []
    host = GlassPanelHost(hostingView: content, appearance: appearance)
    host.attach(to: window)
    if ProcessInfo.processInfo.environment["QUICKASK_LAYOUT_VISIBLE"] == "1" {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        window.title = "QuickAsk layout tests"
        window.setFrameOrigin(NSPoint(x: 20, y: 20))
        window.orderFrontRegardless()
    }
    defer { window.orderOut(nil) }

    func settle() {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    func verify(_ name: String, size: NSSize) {
        settle()
        check(window.contentView?.bounds.size == size, "\(name): native window retains the requested size")
        check(content.frame.size == size && content.frame.origin == .zero,
              "\(name): hosted content fills the glass without an offset")
    }

    check(appearance.darkComposer, "darker prompt box defaults on")
    appearance.darkComposer = false
    check(GlassAppearance(preferences: preferences).darkComposer == false, "darker prompt box setting persists")
    appearance.darkComposer = true
    check(!appearance.clearPane, "clear glass pane defaults off")
    appearance.clearPane = true
    check(GlassAppearance(preferences: preferences).clearPane, "clear glass pane setting persists")
    verify("clear pane prompt", size: NSSize(width: 559, height: 432))
    if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
        check((window.contentView as? NSGlassEffectView)?.style == .clear, "clear pane setting uses clear glass")
    }
    appearance.clearPane = false
    verify("frosted pane prompt", size: NSSize(width: 559, height: 432))
    if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
        check((window.contentView as? NSGlassEffectView)?.style == .regular, "default pane uses frosted regular glass")
    }

    settle()
    for preference in GlassPreference.allCases {
        appearance.preference = preference
        fixtureSize = NSSize(width: 559, height: 432)
        window.setContentSize(fixtureSize)
        settle()
        for cycle in 1...3 {
            let requestsBeforeSettings = resizeRequests
            let chatFrame = window.frame
            model.showingSettings = true
            verify("\(preference.rawValue) settings cycle \(cycle)", size: fixtureSize)
            check(window.frame == chatFrame, "Settings retains the chat frame and position")
            model.showingSettings = false
            verify("\(preference.rawValue) prompt cycle \(cycle)", size: fixtureSize)
            check(resizeRequests == requestsBeforeSettings, "Opening and closing settings requests no window resize")
        }
        model.showingSettings = true
        settle()
        fixtureSize = NSSize(width: 500, height: 360)
        window.setContentSize(fixtureSize)
        verify("\(preference.rawValue) small settings", size: fixtureSize)
        model.showingSettings = false
        verify("\(preference.rawValue) manually resized prompt", size: fixtureSize)
    }
    appearance.setTransparency(0)
    model.showingSettings = true
    verify("solid settings", size: fixtureSize)
    model.showingSettings = false
    verify("solid prompt", size: fixtureSize)

    fixtureSize = NSSize(width: 700, height: 222)
    window.setContentSize(fixtureSize)
    model.showingSettings = true
    verify("compact-height settings", size: fixtureSize)
    model.showingSettings = false
    verify("compact-height prompt", size: fixtureSize)

    // The original fixture covered only empty chats and settings. Exercise long,
    // variable-height rows, the pending reply, rapid streaming, and tab changes.
    appearance.preference = .automatic
    appearance.clearPane = true
    appearance.setTransparency(0.38)
    fixtureSize = NSSize(width: 835, height: 586)
    window.setContentSize(fixtureSize)
    let answer = """
    ## A multi-part answer

    \(String(repeating: "A wrapping paragraph keeps each message taller than the viewport. ", count: 12))

    - **First item** with a longer explanation that wraps across several lines in a narrow popup.
    - Second item
      - A nested item

    > A quoted passage.

    ```swift
    let response = "test"
    ```

    | Item | Value |
    |---|---|
    | First | A wrapping cell |
    | Second | Another cell |
    """
    for _ in 0..<6 {
        model.messages.append(.init(role: "user", text: "A follow-up question"))
        model.messages.append(.init(role: "assistant", text: answer, provider: .claude))
        settle()
    }
    model.busy = true; model.status = "Connecting…"
    model.messages.append(.init(role: "user", text: "One more question"))
    model.messages.append(.init(role: "assistant", text: "", provider: .claude, complete: false))
    settle()
    for chunk in 0..<24 {
        model.messages[model.messages.count - 1].text += "\n- Streamed item \(chunk) with wrapping text."
        if chunk.isMultiple(of: 4) { settle() }
    }
    settle()
    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    if ProcessInfo.processInfo.environment["QUICKASK_LAYOUT_VISIBLE"] == "1" {
        let scroll = scrollViews(in: content).first {
            !($0.documentView is NSTextView) && $0.contentSize.height > 100
                && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 100
        }
        check(scroll != nil, "Visible transcript exposes a native scroll viewport")
        if let scroll, let document = scroll.documentView {
            let clip = scroll.contentView
            func distanceFromBottom() -> CGFloat {
                document.isFlipped ? document.bounds.maxY - clip.documentVisibleRect.maxY
                    : clip.documentVisibleRect.minY - document.bounds.minY
            }
            check(distanceFromBottom() < 2, "Streaming follows the transcript bottom")
            let origin = clip.bounds.origin
            clip.scroll(to: NSPoint(x: origin.x, y: origin.y + (document.isFlipped ? -180 : 180)))
            scroll.reflectScrolledClipView(clip)
            settle()
            let readingOrigin = clip.bounds.origin.y
            model.messages[model.messages.count - 1].text += "\n\nAnother streamed paragraph below the reader."
            settle()
            check(abs(clip.bounds.origin.y - readingOrigin) < 1, "Streaming preserves the reader's manual scroll position")
            clip.scroll(to: NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY - clip.bounds.height : document.bounds.minY))
            scroll.reflectScrolledClipView(clip)
            settle()
            model.messages[model.messages.count - 1].text += "\n\nFollowing resumes at the bottom."
            settle()
            check(distanceFromBottom() < 2, "Streaming follows again after returning to the bottom")
        }
    }
    model.stop()
    check(model.messages.count == 14 && !model.messages.last!.text.isEmpty && !model.messages.last!.complete,
          "Multi-turn chat remains usable through insertion, streaming, auto-scroll, and stop")
    model.fork(title: "Layout regression")
    settle()
    let forkID = model.activeSessionID
    model.newTab()
    settle()
    model.selectSession(forkID)
    settle()
    check(model.messages.count == 13, "A fork of the long chat restores completed messages")
    for width: CGFloat in [500, 835] {
        window.setContentSize(NSSize(width: width, height: 586))
        verify("long transcript resize", size: NSSize(width: width, height: 586))
    }
    model.showingSettings = true
    verify("long chat settings", size: fixtureSize)
    model.showingSettings = false
    verify("long chat restored", size: fixtureSize)
    var heartbeat = false
    DispatchQueue.main.async { heartbeat = true }
    settle()
    check(heartbeat, "Chat layout returns control to the main queue")
    window.contentView = nil
}

/// Reply images sit at their own shape with the border hugging them, and Space previews only
/// when an image is selected and nothing is being typed.
@MainActor
func verifyImagePreview(check: (Bool, String) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-image-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func fixture(_ name: String, _ width: Int, _ height: Int) -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = folder.appendingPathComponent(name)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        return url
    }
    func size(_ url: URL, width: CGFloat) -> NSSize {
        NSHostingController(rootView: MarkdownImage(url: url, alt: "")).sizeThatFits(in: NSSize(width: width, height: 10_000))
    }
    func near(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1 }
    let tall = size(fixture("tall.png", 1200, 1400), width: 760)
    check(near(tall, NSSize(width: 480 * 1200 / 1400, height: 480)), "A tall screenshot fills the height cap and its frame hugs it (\(tall))")
    let wide = size(fixture("wide.png", 1600, 500), width: 700)
    check(near(wide, NSSize(width: 700, height: 700 * 500 / 1600)), "A wide image takes the reply's full width (\(wide))")
    let small = size(fixture("small.png", 300, 200), width: 700)
    check(near(small, NSSize(width: 300, height: 200)), "A small image keeps its own size (\(small))")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    let editor = NSTextView(), prose = NSTextView()
    prose.isEditable = false
    func space(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }
    check(QuickLook.spaceToggles(space(), selected: true, firstResponder: window), "Space previews a selected image")
    check(QuickLook.spaceToggles(space(), selected: true, firstResponder: prose), "Space previews a selected image after selecting reply text")
    check(!QuickLook.spaceToggles(space(), selected: true, firstResponder: editor), "Space types in the composer even with an image selected")
    check(!QuickLook.spaceToggles(space(), selected: false, firstResponder: window), "Space does nothing with no image selected")
    check(!QuickLook.spaceToggles(space(.command), selected: true, firstResponder: window), "⌘Space is left alone")
}
