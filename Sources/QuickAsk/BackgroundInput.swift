import AppKit
import ApplicationServices
import Darwin

/// Input for one app's window that leaves the user's cursor, front app and window order alone.
///
/// Clicks, drags and scrolls go through SkyLight's `SLEventPostToPid`, which Chromium and
/// Electron accept as live input where the public `CGEvent.postToPid` is dropped; keys carry
/// the authentication message macOS 14+ checks on those apps. Before input, the target window
/// becomes AppKit-key with one focus record, without raising it or switching Spaces.
///
/// Every symbol is private and resolved at runtime. When one is missing the public route is
/// used, and `available` reports it so callers can say which route ran.
///
/// The recipe (event-record layout, field stamps, the off-screen primer click) follows
/// trycua/cua's cua-driver and yabai's focus-without-raise, both MIT; see THIRD_PARTY_NOTICES.md.
enum BackgroundInput {
    private typealias PostToPid = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Void
    private typealias SetAuthMessage = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
    private typealias SetWindowLocation = @convention(c) (UnsafeMutableRawPointer, CGPoint) -> Void
    private typealias SetIntegerField = @convention(c) (UnsafeMutableRawPointer, UInt32, Int64) -> Void
    private typealias PostEventRecord = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias WindowOwner = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias ConnectionPSN = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias AuthFactory = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> UnsafeMutableRawPointer?

    private static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) != nil
    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard loaded, let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
    private static let postToPid = symbol("SLEventPostToPid", as: PostToPid.self)
    private static let setAuthMessage = symbol("SLEventSetAuthenticationMessage", as: SetAuthMessage.self)
    private static let setWindowLocation = symbol("CGEventSetWindowLocation", as: SetWindowLocation.self)
    private static let setIntegerField = symbol("SLEventSetIntegerValueField", as: SetIntegerField.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecord.self)
    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self) ?? symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let windowOwner = symbol("SLSGetWindowOwner", as: WindowOwner.self)
    private static let connectionPSN = symbol("SLSGetConnectionPSN", as: ConnectionPSN.self)
    private static let processForPID = symbol("GetProcessForPID", as: ProcessForPID.self)
    private static let authFactory = symbol("objc_msgSend", as: AuthFactory.self)

    private static let source = CGEventSource(stateID: .hidSystemState)

    /// True when background delivery is possible; otherwise callers fall back to the foreground.
    static var available: Bool { postToPid != nil && postEventRecord != nil }

    enum Button { case left, right
        var down: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var up: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
        var mouse: CGMouseButton { self == .left ? .left : .right }
        var number: Int64 { self == .left ? 0 : 1 }
    }

    // MARK: Focus without raise

    /// Makes `window` its app's key window without raising it or touching the user's front app.
    /// Only the focus record is sent: a defocus record to the user's app stops their typing
    /// landing until they click it again.
    @discardableResult
    static func focus(pid: pid_t, window: UInt32) -> Bool {
        guard let postEventRecord, var psn = processSerialNumber(pid: pid, window: window) else { return false }
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x08] = 0x0D
        withUnsafeBytes(of: window.littleEndian) { record.replaceSubrange(0x3C..<0x40, with: $0) }
        record[0x8A] = 0x01
        let status = withUnsafeBytes(of: &psn) { psnBytes in record.withUnsafeBufferPointer { postEventRecord(psnBytes.baseAddress!, $0.baseAddress!) } }
        // AppKit updates its key-window routing before the input arrives.
        usleep(50_000)
        return status == 0
    }

    private static func processSerialNumber(pid: pid_t, window: UInt32) -> (UInt32, UInt32)? {
        var psn: (UInt32, UInt32) = (0, 0)
        if let mainConnection, let windowOwner, let connectionPSN {
            var owner: UInt32 = 0
            if windowOwner(mainConnection(), window, &owner) == 0, owner != 0,
               withUnsafeMutableBytes(of: &psn, { connectionPSN(owner, $0.baseAddress!) }) == 0 { return psn }
        }
        if let processForPID, withUnsafeMutableBytes(of: &psn, { processForPID(pid, $0.baseAddress!) }) == 0 { return psn }
        return nil
    }

    // MARK: Mouse

    /// A click (or double click) at a screen point in points, in `window` of `pid`.
    static func click(pid: pid_t, window: UInt32, at point: CGPoint, button: Button = .left, count: Int = 1) {
        focus(pid: pid, window: window)
        let group = clickGroup()
        // A move primes AppKit's cursor tracking; a background NSView ignores a down without it.
        post(mouse(.mouseMoved, at: point, button: .left), pid: pid, window: window, phase: 2, clickState: 0, button: 0, group: group)
        usleep(15_000)
        if button == .left {
            // An off-screen click satisfies Chromium's user-activation gate without hitting anything.
            let away = CGPoint(x: -1, y: -1)
            post(mouse(.leftMouseDown, at: away, button: .left), pid: pid, window: window, phase: 1, clickState: 1, button: 0, group: group)
            usleep(1_000)
            post(mouse(.leftMouseUp, at: away, button: .left), pid: pid, window: window, phase: 2, clickState: 1, button: 0, group: group)
            usleep(100_000)
        }
        for state in 1...min(max(count, 1), 2) {
            post(mouse(button.down, at: point, button: button.mouse), pid: pid, window: window, phase: 3, clickState: Int64(state), button: button.number, group: group)
            usleep(button == .left ? 1_000 : 28_000)
            post(mouse(button.up, at: point, button: button.mouse), pid: pid, window: window, phase: 3, clickState: Int64(state), button: button.number, group: group)
            if state < count { usleep(80_000) }
        }
    }

    /// One id for every event of a gesture, so WindowServer and Chromium coalesce it; kept under
    /// a second's worth of nanoseconds, the range real gestures use.
    private static func clickGroup() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000) }

    static func hover(pid: pid_t, window: UInt32, at point: CGPoint) {
        post(mouse(.mouseMoved, at: point, button: .left), pid: pid, window: window, phase: 2, clickState: 0, button: 0, group: 0)
    }

    /// Press at `from`, move in steps, release at `to`. `stillValid` is checked between steps.
    static func drag(pid: pid_t, window: UInt32, from: CGPoint, to: CGPoint, stillValid: () throws -> Void) rethrows {
        focus(pid: pid, window: window)
        let group = clickGroup()
        post(mouse(.mouseMoved, at: from, button: .left), pid: pid, window: window, phase: 2, clickState: 0, button: 0, group: group, subtype: 0)
        usleep(15_000)
        post(mouse(.leftMouseDown, at: from, button: .left), pid: pid, window: window, phase: 3, clickState: 1, button: 0, group: group, subtype: 0)
        var current = from
        defer { post(mouse(.leftMouseUp, at: current, button: .left), pid: pid, window: window, phase: 3, clickState: 1, button: 0, group: group, subtype: 0) }
        for step in 1...20 {
            try stillValid()
            let t = Double(step) / 20
            current = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(mouse(.leftMouseDragged, at: current, button: .left), pid: pid, window: window, phase: 3, clickState: 1, button: 0, group: group, subtype: 0)
            usleep(12_000)
        }
    }

    /// A pixel scroll at a screen point; positive `dy` scrolls content down (the wheel turns toward you).
    static func scroll(pid: pid_t, window: UInt32, at point: CGPoint, dx: Int32, dy: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { return }
        event.location = point
        stamp(event, pid: pid, window: window)
        deliver(event, pid: pid, authenticated: false)
    }

    private static func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.flags = []
        return event
    }

    private static func post(_ event: CGEvent?, pid: pid_t, window: UInt32, phase: Int64, clickState: Int64, button: Int64, group: Int64, subtype: Int64 = 3) {
        guard let event else { return }
        let raw = Unmanaged.passUnretained(event).toOpaque()
        set(event, raw, 0, phase)
        set(event, raw, 1, clickState)
        set(event, raw, 3, button)
        set(event, raw, 7, subtype)
        if group != 0 { set(event, raw, 58, group) }
        stamp(event, pid: pid, window: window)
        deliver(event, pid: pid, authenticated: false)
    }

    /// Routing fields: the target pid (Chromium's synthetic-event filter) and the window.
    private static func stamp(_ event: CGEvent, pid: pid_t, window: UInt32) {
        let raw = Unmanaged.passUnretained(event).toOpaque()
        set(event, raw, 40, Int64(pid))
        if window != 0 { for field: UInt32 in [51, 91, 92] { set(event, raw, field, Int64(window)) } }
        setWindowLocation?(raw, event.location)
    }

    private static func set(_ event: CGEvent, _ raw: UnsafeMutableRawPointer, _ field: UInt32, _ value: Int64) {
        if let setIntegerField { setIntegerField(raw, field, value) }
        else if let known = CGEventField(rawValue: field) { event.setIntegerValueField(known, value: value) }
    }

    // MARK: Keyboard

    /// One key press. Command chords skip the authentication message so the menu shortcut fires.
    static func key(pid: pid_t, window: UInt32, code: CGKeyCode, flags: CGEventFlags) {
        if window != 0 { focus(pid: pid, window: window) }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            deliver(event, pid: pid, authenticated: !flags.contains(.maskCommand))
            usleep(8_000)
        }
    }

    /// Types `text` one character at a time; Return and Tab are sent as their keys.
    static func type(pid: pid_t, window: UInt32, text: String, stillValid: () throws -> Void) rethrows {
        if window != 0 { focus(pid: pid, window: window) }
        for (index, character) in text.enumerated() {
            if index % 32 == 0 { try stillValid() }
            if character == "\n" || character == "\r" { key(pid: pid, window: 0, code: 36, flags: []); continue }
            if character == "\t" { key(pid: pid, window: 0, code: 48, flags: []); continue }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                // Explicit empty flags: an inherited Shift would leak into the next character.
                event.flags = []
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
                deliver(event, pid: pid, authenticated: true)
                usleep(2_000)
            }
        }
    }

    // MARK: Delivery

    private static func deliver(_ event: CGEvent, pid: pid_t, authenticated: Bool) {
        guard let postToPid else { event.postToPid(pid); return }
        autoreleasepool {
            let raw = Unmanaged.passUnretained(event).toOpaque()
            if authenticated { attachAuthentication(raw, pid: pid) }
            postToPid(pid, raw)
        }
    }

    /// `[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:]` (macOS 15+), attached
    /// so Chromium-class apps accept synthetic keys. On macOS 14 the selector is absent and the
    /// key goes without it.
    private static func attachAuthentication(_ event: UnsafeMutableRawPointer, pid: pid_t) {
        let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
        guard let setAuthMessage, let authFactory, let messageClass = NSClassFromString("SLSEventAuthenticationMessage"),
              (messageClass as AnyObject).responds(to: selector) else { return }
        // `__CGEvent` is {CFRuntimeBase, uint32_t, SLSEventRecord *}: the record pointer sits at 24.
        for offset in [24, 32, 16] {
            guard let record = event.load(fromByteOffset: offset, as: UnsafeMutableRawPointer?.self) else { continue }
            // The class as an object: bit-casting the metatype would pass Swift's wrapper metadata.
            let receiver = Unmanaged.passUnretained(messageClass as AnyObject).toOpaque()
            if let message = authFactory(receiver, selector, record, pid, 0) {
                setAuthMessage(event, message)
            }
            return
        }
    }
}
