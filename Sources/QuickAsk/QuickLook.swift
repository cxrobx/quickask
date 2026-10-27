import AppKit
import Quartz
import SwiftUI

/// One picture Quick Look can show: a file on disk, or bytes with no file of their own (an
/// attached image, a web image the user loaded), written to a private temp file to preview.
enum PreviewImage {
    case file(URL)
    case data(Data, fileExtension: String, title: String)

    static func attachments(_ images: [ImageAttachment]) -> [PreviewImage] {
        images.enumerated().map { .data($1.data, fileExtension: $1.fileExtension, title: "Attached image \($0 + 1)") }
    }
}

/// Finder's Quick Look for the images in a chat. A click selects an image, Space or a
/// double-click opens it full size, and the arrows step through the rest of its group (the
/// reply's images, or a message's attachments). The popup's window controls the panel.
@MainActor final class QuickLook: NSObject, ObservableObject {
    static let shared = QuickLook()

    /// The selected image's view; only it draws the selection ring.
    @Published private(set) var selected: UUID?
    /// From the moment the panel is asked to show until it closes, so the popup doesn't take
    /// the panel becoming key for the user leaving.
    private(set) var isOpen = false
    private var group: [PreviewImage] = []
    private var index = 0
    private var items: [PreviewItem] = []
    private var current = 0
    private var folder: URL?

    func select(_ token: UUID, _ group: [PreviewImage], at index: Int) {
        selected = token; self.group = group; self.index = index
        // Space must reach the preview, not the composer.
        if let window = NSApp.keyWindow, !(window is QLPreviewPanel) { window.makeFirstResponder(nil) }
        if isOpen { show() } // An open preview follows the selection, as Finder's does.
    }

    /// Clears the selection, or only `token`'s when given (a view going away).
    func deselect(_ token: UUID? = nil) {
        if token == nil || selected == token { selected = nil }
    }

    /// Whether Space toggles the preview: an image is selected and nothing is being typed.
    static func spaceToggles(_ event: NSEvent, selected: Bool, firstResponder: NSResponder?) -> Bool {
        event.keyCode == 49 && plain(event) && selected && (firstResponder as? NSTextView)?.isEditable != true
    }

    /// No modifier keys, so ⌘⌥← and friends keep their own meaning.
    private static func plain(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// The popup's keys: Esc closes an open preview first, Space toggles it on a selected image, and
    /// the arrows step through its group once a click has brought the popup back to the front.
    func handleKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        if event.keyCode == 53, isOpen { close(); return true }
        let typing = (window.firstResponder as? NSTextView)?.isEditable == true
        if isOpen, !typing, Self.plain(event), let step = [123: -1, 126: -1, 124: 1, 125: 1][Int(event.keyCode)] {
            if let panel = QLPreviewPanel.shared(), items.count > 1 {
                panel.currentPreviewItemIndex = (panel.currentPreviewItemIndex + step + items.count) % items.count
            }
            return true
        }
        guard Self.spaceToggles(event, selected: selected != nil, firstResponder: window.firstResponder) else { return false }
        if !event.isARepeat { isOpen ? close() : show() }
        return true
    }

    func show() {
        let previous = folder
        folder = nil
        var built: [PreviewItem] = [], at = 0
        for (offset, image) in group.enumerated() {
            guard let item = item(for: image, at: offset) else { continue }
            if offset == index { at = built.count }
            built.append(item)
        }
        guard !built.isEmpty, let panel = QLPreviewPanel.shared() else {
            // Nothing to show: an open preview keeps what it had.
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = previous
            NSSound.beep()
            return
        }
        items = built; current = at
        if isOpen && panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = current
        } else {
            isOpen = true
            panel.makeKeyAndOrderFront(nil)
        }
        if let previous { try? FileManager.default.removeItem(at: previous) }
    }

    func close() {
        guard isOpen else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible { panel.close() }
        finish()
    }

    private func finish() {
        isOpen = false
        items = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    private func item(for image: PreviewImage, at offset: Int) -> PreviewItem? {
        switch image {
        case .file(let url):
            return FileManager.default.fileExists(atPath: url.path) ? PreviewItem(url: url, title: url.lastPathComponent) : nil
        case .data(let data, let fileExtension, let title):
            guard let folder = makeFolder() else { return nil }
            let url = folder.appendingPathComponent("\(offset + 1).\(fileExtension)")
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return PreviewItem(url: url, title: title)
        }
    }

    /// An owner-only folder for this preview's files, removed when the panel closes.
    private func makeFolder() -> URL? {
        if let folder { return folder }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk Preview \(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        folder = url
        return url
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        // Above the popup, which floats.
        if panel.level.rawValue <= NSWindow.Level.floating.rawValue { panel.level = NSWindow.Level(NSWindow.Level.floating.rawValue + 1) }
        panel.reloadData()
        panel.currentPreviewItemIndex = current
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        finish()
    }
}

extension QuickLook: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Space closes it again, as in Finder; the panel handles Esc and the arrows itself.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false }
        if !event.isARepeat { close() }
        return true
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
}

/// A panel that controls Quick Look for the images in it. Quick Look asks the key window's
/// responders for a controller; the popup's window answers.
class PreviewHostPanel: NSPanel {
    /// While the preview has the key window, a click on the popup reaches the image under it, as in
    /// Finder, instead of only taking the focus back.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, QuickLook.shared.isOpen { makeKey() }
        super.sendEvent(event)
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.end(panel)
        // Back to the popup, so Space and Esc work again without a click.
        DispatchQueue.main.async { [weak self] in
            if let self, self.isVisible, NSApp.isActive { self.makeKey() }
        }
    }
}

/// Makes an image Quick Look-able: a click selects it with Finder's ring, a double-click (or
/// Space while selected) opens the preview on its group.
struct QuickLookable: ViewModifier {
    let group: [PreviewImage]
    let index: Int
    var cornerRadius: CGFloat = 10
    @ObservedObject private var quickLook = QuickLook.shared
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .overlay {
                if quickLook.selected == token {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onTapGesture {
                quickLook.select(token, group, at: index)
                if NSApp.currentEvent?.clickCount == 2 { quickLook.show() }
            }
            .onDisappear { quickLook.deselect(token) }
            .help("Space or double-click for Quick Look")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Quick Look") { quickLook.select(token, group, at: index); quickLook.show() }
    }
}
