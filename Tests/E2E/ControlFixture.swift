import AppKit

/// A small AppKit app for the desktop-control end-to-end test: one control of each kind the
/// tools drive, and its state published as the window title so the test can read it back.
///
///   control-fixture   (prints its window number once it is on screen)
@main
struct ControlFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Counts pixel clicks: a custom view with nothing in the accessibility tree to press.
final class Canvas: NSView {
    var onClick: (Bool, Int) -> Void = { _, _ in }
    override func draw(_ dirtyRect: NSRect) { NSColor.systemTeal.setFill(); bounds.fill() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick(false, event.clickCount) }
    override func rightMouseDown(with event: NSEvent) { onClick(true, 1) }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var presses = 0, canvasClicks = 0, doubleClicks = 0, rightClicks = 0, resets = 0, quits = 0
    var longList: NSWindow?
    let field = NSTextField(string: "")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let format = NSPopUpButton(frame: .zero, pullsDown: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(); appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        fixtureItem.submenu = NSMenu(title: "Fixture")
        fixtureItem.submenu?.addItem(withTitle: "Reset Counters", action: #selector(reset), keyEquivalent: "r").target = self
        // A stand-in for Quit: its shortcut is refused like Quit's, but running it only counts.
        let quit = fixtureItem.submenu?.addItem(withTitle: "Quit Softly", action: #selector(softQuit), keyEquivalent: "q")
        quit?.target = self; quit?.keyEquivalentModifierMask = [.command, .option]
        fixtureItem.submenu?.addItem(withTitle: "Open Long List", action: #selector(openLongList), keyEquivalent: "l").target = self
        menu.addItem(appItem); menu.addItem(fixtureItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentLayoutRect)
        let button = NSButton(title: "Increment", target: self, action: #selector(increment))
        button.frame = NSRect(x: 20, y: 240, width: 120, height: 32)
        field.frame = NSRect(x: 160, y: 244, width: 240, height: 24)
        field.placeholderString = "Type here"
        field.delegate = self
        slider.frame = NSRect(x: 20, y: 200, width: 380, height: 24)
        slider.target = self; slider.action = #selector(changed)
        format.addItems(withTitles: ["PNG", "JPEG", "HEIF"])
        format.frame = NSRect(x: 290, y: 140, width: 110, height: 26)
        format.target = self; format.action = #selector(changed)
        let canvas = Canvas(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
        canvas.setAccessibilityElement(false)
        canvas.onClick = { [weak self] right, count in
            guard let self else { return }
            if right { self.rightClicks += 1 } else if count >= 2 { self.doubleClicks += 1 } else { self.canvasClicks += 1 }
            self.publish()
        }
        [button, field, slider, format, canvas].forEach(content.addSubview)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        publish()
        print(window.windowNumber); fflush(stdout)
    }

    func controlTextDidChange(_ obj: Notification) { publish() }
    @objc func increment() { presses += 1; publish() }
    @objc func changed() { publish() }
    @objc func softQuit() { quits += 1; publish() }

    /// Three unlabelled groups of 200 checkboxes: too much for one tree, and the last is out of reach.
    @objc func openLongList() {
        let list = NSWindow(contentRect: NSRect(x: 660, y: 200, width: 360, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        list.title = "Long list"
        list.isReleasedWhenClosed = false
        for (column, name) in ["A", "B", "C"].enumerated() {
            let box = NSBox(frame: NSRect(x: 10 + column * 115, y: 10, width: 110, height: 280))
            box.title = "Section \(name)"
            for row in 1...200 {
                let check = NSButton(checkboxWithTitle: "\(name)-\(row)", target: nil, action: nil)
                check.frame = NSRect(x: 4, y: 240 - row, width: 90, height: 18)
                box.contentView?.addSubview(check)
            }
            list.contentView?.addSubview(box)
        }
        list.orderFront(nil)
        longList = list
    }

    @objc func reset() { presses = 0; canvasClicks = 0; doubleClicks = 0; rightClicks = 0; resets += 1; publish() }

    /// `p=presses c=canvas d=double r=right s=slider x=resets q=soft quits f=format t=text`
    func publish() {
        window.title = "p=\(presses) c=\(canvasClicks) d=\(doubleClicks) r=\(rightClicks) s=\(Int(slider.doubleValue)) x=\(resets) q=\(quits) f=\(format.titleOfSelectedItem ?? "") t=\(field.stringValue)"
    }
}
