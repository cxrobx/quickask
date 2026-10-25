import AppKit
import SwiftUI

/// Invisible resize zones on every edge and corner of the borderless popup.
struct ResizeEdges: View {
    private static let edge: CGFloat = 6
    private static let corner: CGFloat = 16

    var body: some View {
        ZStack {
            zone(.top, alignment: .top, width: nil, height: Self.edge)
            zone(.bottom, alignment: .bottom, width: nil, height: Self.edge)
            zone(.left, alignment: .leading, width: Self.edge, height: nil)
            zone(.right, alignment: .trailing, width: Self.edge, height: nil)
            zone(.topLeft, alignment: .topLeading, width: Self.corner, height: Self.corner)
            zone(.topRight, alignment: .topTrailing, width: Self.corner, height: Self.corner)
            zone(.bottomLeft, alignment: .bottomLeading, width: Self.corner, height: Self.corner)
            zone(.bottomRight, alignment: .bottomTrailing, width: Self.corner, height: Self.corner)
        }
    }

    private func zone(_ edge: ResizeEdge, alignment: Alignment, width: CGFloat?, height: CGFloat?) -> some View {
        ResizeHandle(edge: edge)
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

enum ResizeEdge {
    case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if movesTop || movesBottom { return movesLeft || movesRight ? .crosshair : .resizeUpDown }
        return .resizeLeftRight
    }
}

struct ResizeHandle: NSViewRepresentable {
    let edge: ResizeEdge
    func makeNSView(context: Context) -> EdgeResizeView { EdgeResizeView(edge: edge) }
    func updateNSView(_ view: EdgeResizeView, context: Context) {}
}

final class EdgeResizeView: NSView {
    let edge: ResizeEdge
    override var mouseDownCanMoveWindow: Bool { false }
    init(edge: ResizeEdge) {
        self.edge = edge
        super.init(frame: .zero)
        setAccessibilityLabel("Resize popup")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: edge.cursor) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = NSEvent.mouseLocation
        let original = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - origin.x, dy = pointer.y - origin.y
            var width = original.width, height = original.height
            if edge.movesRight { width += dx } else if edge.movesLeft { width -= dx }
            if edge.movesTop { height += dy } else if edge.movesBottom { height -= dy }
            width = max(window.minSize.width, min(window.maxSize.width, width))
            height = max(window.minSize.height, min(window.maxSize.height, height))
            // The opposite edge stays put.
            let x = edge.movesLeft ? original.maxX - width : original.minX
            let y = edge.movesBottom ? original.maxY - height : original.minY
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }
}

/// Empty space that moves the popup when dragged; text and controls on top keep their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    // Behind the transcript, the wheel still scrolls it.
    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
