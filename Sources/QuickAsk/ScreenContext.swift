import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import Darwin

struct DisplayRegion { let id: UInt32; let frame: CGRect }
struct ContextWindow: Identifiable, Equatable {
    let id: UInt32
    let pid: Int32
    let bundleID: String
    let appName: String
    let title: String
    let bounds: CGRect
    var label: String { title.isEmpty ? appName : "\(appName) · \(title)" }
    var target: AppTarget { .init(pid: pid, name: appName) }
}

enum DisplayContext {
    static func display(for rect: CGRect, regions: [DisplayRegion]) -> DisplayRegion? {
        guard regions.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return regions.max { a, b in
            let aa = a.frame.intersection(rect), bb = b.frame.intersection(rect)
            let areaA = aa.isNull ? 0 : aa.width * aa.height, areaB = bb.isNull ? 0 : bb.width * bb.height
            if areaA != areaB { return areaA < areaB }
            return !a.frame.contains(center) && b.frame.contains(center)
        }
    }
    @MainActor static var regions: [DisplayRegion] { NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return DisplayRegion(id: number.uint32Value, frame: screen.frame)
    } }
    static func windows(on displayID: UInt32, ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> [ContextWindow] {
        let frame = CGDisplayBounds(displayID)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownerPID,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundle = app.bundleIdentifier, let id = info[kCGWindowNumber as String] as? UInt32,
                  let raw = info[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  rect.width > 100, rect.height > 80, rect.intersects(frame),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return ContextWindow(id: id, pid: pid, bundleID: bundle, appName: app.localizedName ?? "App", title: info[kCGWindowName as String] as? String ?? "", bounds: rect)
        }
    }
    static func candidate(_ windows: [ContextWindow], preferredPID: Int32?, preferredWindow: UInt32? = nil) -> ContextWindow? {
        if let preferredWindow, let window = windows.first(where: { $0.id == preferredWindow }) { return window }
        if let preferredPID, let window = windows.first(where: { $0.pid == preferredPID }) { return window }
        return windows.first
    }
    static func focusedWindow(pid: Int32) -> UInt32? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0 })?[kCGWindowNumber as String] as? UInt32
    }
}

enum SelectionReader {
    static func socketPath(_ connector: AppConnector) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuickAsk/Context/\(connector.rawValue).sock").path
    }
    static func read(_ connector: AppConnector, pid: Int32) -> AppSelection? {
        read(source: connector.rawValue, bundleID: connector.bundleID, pid: pid)
    }
    static func read(bundleID: String, pid: Int32) -> AppSelection? {
        guard let connector = AppConnector.matching(bundleID), connector.publishesSelection else { return nil }
        return read(connector, pid: pid)
    }
    private static func read(source: String, bundleID: String, pid: Int32) -> AppSelection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let socketName = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuickAsk/Context/\(source).sock").path
        let path = Array(socketName.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: path) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) } }
        guard connected == 0 else { return nil }
        var peerPID: Int32 = 0, peerSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerSize) == 0, peerPID == pid else { return nil }
        let query = Array("{\"op\":\"context\"}\n".utf8)
        guard query.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, query.count) }) == query.count else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64_000 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }; data.append(contentsOf: buffer.prefix(count))
            if data.contains(10) { break }
        }
        guard let line = data.split(separator: 10).first,
              let selection = try? JSONDecoder().decode(AppSelection.self, from: Data(line)),
              selection.pid == pid, selection.bundleID == bundleID, selection.windowLabel == "main" else { return nil }
        return selection
    }
}

enum ScreenContextCapture {
    static func snapshot(_ window: ContextWindow, displayID: UInt32) async -> ContextSnapshot {
        let published = SelectionReader.read(bundleID: window.bundleID, pid: window.pid)
        let selection = published?.windowID == window.id ? published : nil
        var text = "", document = selection?.records["document_path"] ?? "", url = ""
        if selection == nil {
            let accessible = accessibility(window)
            text = accessible.text; document = accessible.document; url = accessible.url
            if text.isEmpty, CGPreflightScreenCaptureAccess() { text = await recognize(window) }
        }
        return .init(displayID: displayID, windowID: window.id, pid: window.pid, bundleID: window.bundleID,
                     appName: window.appName, windowTitle: window.title, capturedAt: Date().timeIntervalSince1970,
                     launchTime: NSRunningApplication(processIdentifier: window.pid)?.launchDate?.timeIntervalSince1970 ?? 0,
                     selection: selection, text: String(text.prefix(8000)), document: document, url: url)
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func accessibility(_ window: ContextWindow) -> (text: String, document: String, url: String) {
        guard AXIsProcessTrusted() else { return ("", "", "") }
        let root = AXUIElementCreateApplication(window.pid); AXUIElementSetMessagingTimeout(root, 0.15)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let selected = windows.first { element in
            guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return false }
            var point = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point); AXValueGetValue(size as! AXValue, .cgSize, &extent)
            return abs(point.x - window.bounds.minX) < 3 && abs(point.y - window.bounds.minY) < 3 && abs(extent.width - window.bounds.width) < 3
        }
        guard let selected else { return ("", "", "") }
        var lines: [String] = [], visited = 0, url = ""
        let deadline = Date().addingTimeInterval(0.5)
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard depth < 14, visited < 200, Date() < deadline, lines.joined().count < 8000 else { return }
            visited += 1
            if attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return }
            // Browsers expose the page address on their web area.
            if url.isEmpty, let address = attribute(node, kAXURLAttribute) as? URL, address.scheme?.hasPrefix("http") == true { url = address.absoluteString }
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXSelectedTextAttribute] {
                if let value = attribute(node, key) as? String, !value.isEmpty { lines.append(String(value.prefix(1000))) }
            }
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
        }
        walk(selected, 0)
        return (lines.joined(separator: "\n"), attribute(selected, kAXDocumentAttribute) as? String ?? "", String(url.prefix(2000)))
    }
    /// The whole display the dialog is on, with Quick Ask itself excluded. Nil without
    /// Screen Recording permission; the caller says so rather than failing the request.
    static func displayScreenshot(_ displayID: UInt32) async -> ImageAttachment? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let config = SCStreamConfiguration(); config.width = display.width; config.height = display.height; config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), configuration: config)
            return ImageAttachment.make(from: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        } catch { return nil }
    }
    private static func recognize(_ window: ContextWindow) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == window.id && $0.owningApplication?.processID == window.pid }) else { return "" }
            let config = SCStreamConfiguration(); config.width = min(1600, Int(target.frame.width)); config.height = min(1200, Int(target.frame.height)); config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast
            try VNImageRequestHandler(cgImage: image).perform([request])
            return String((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(8000))
        } catch { return "" }
    }
}
