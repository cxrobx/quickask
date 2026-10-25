import SwiftUI

/// The work behind a reply, in the T3 Code style: a "Working · 0:14" header over the latest
/// steps while it runs, folded to "6 steps · 0:34 ›" once it's done. A subagent's steps sit
/// under its Agent row.
struct WorkLogView: View {
    let steps: [ActivityStep]
    let live: Bool
    /// What the user chose with the chevron; nil follows the run (latest steps while live, folded when done).
    @Binding var fold: Fold?

    enum Fold { case all, closed }

    /// Top-level rows shown while running, before "+N earlier".
    static let liveRows = 4
    static let liveChildren = 3

    private let muted = Color.white.opacity(0.56)

    private var expanded: Bool { fold == .all }
    private var open: Bool { fold == .all || (fold == nil && live) }

    var body: some View {
        let top = steps.filter { step in step.parent == nil || !steps.contains { $0.id == step.parent } }
        let shown = expanded ? top : open ? Array(top.suffix(Self.liveRows)) : []
        VStack(alignment: .leading, spacing: 5) {
            header(count: top.count)
            if !expanded && open && top.count > shown.count {
                Button { fold = .all } label: {
                    Text("+\(top.count - shown.count) earlier").font(appFont(size: 11)).foregroundStyle(muted)
                }.buttonStyle(.plain).padding(.leading, 21)
            }
            ForEach(shown) { step in
                row(step)
                let children = steps.filter { $0.parent == step.id }
                let visible = expanded ? children : Array(children.suffix(Self.liveChildren))
                if visible.count < children.count {
                    Text("+\(children.count - visible.count) earlier").font(appFont(size: 10)).foregroundStyle(muted).padding(.leading, 42)
                }
                ForEach(visible) { row($0).padding(.leading, 21) }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        .accessibilityElement(children: .contain).accessibilityLabel("Work log")
    }

    private func header(count: Int) -> some View {
        Button { fold = open ? .closed : .all } label: {
            HStack(spacing: 7) {
                if live { ProgressView().controlSize(.mini).frame(width: 14) }
                else { Image(systemName: "checklist").font(appFont(size: 11)).frame(width: 14) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(live ? "Working · \(Self.clock(steps.elapsed))" : "\(count) \(count == 1 ? "step" : "steps") · \(Self.clock(steps.elapsed))")
                        .font(appFont(size: 11, weight: .medium)).monospacedDigit()
                }
                Image(systemName: open ? "chevron.down" : "chevron.right").font(appFont(size: 9, weight: .semibold))
                // Every look at the screen shows, folded or not: the user always sees what Claude saw.
                if !expanded {
                    let looks = steps.compactMap(\.image)
                    if !looks.isEmpty {
                        Image(systemName: "eye").font(appFont(size: 10)).foregroundStyle(muted).padding(.leading, 4)
                        ForEach(looks.suffix(4), id: \.self) { LookThumbnail(path: $0, height: 18) }
                    }
                }
                Spacer(minLength: 0)
            }.foregroundStyle(.white.opacity(0.72)).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(open ? "Fold the work log" : "Show every step")
            .accessibilityLabel(live ? "Working, \(count) steps" : "\(count) steps")
    }

    private func row(_ step: ActivityStep) -> some View {
        HStack(spacing: 7) {
            Image(systemName: Self.symbol(step.kind)).font(appFont(size: 10)).foregroundStyle(muted).frame(width: 14)
            label(step).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let image = step.image { LookThumbnail(path: image, height: 26) }
            switch step.state {
            case .running: ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
            case .done: Image(systemName: "checkmark").font(appFont(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
            case .failed: Image(systemName: "xmark").font(appFont(size: 9, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
            case .stopped: Image(systemName: "stop.fill").font(appFont(size: 8)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(appFont(size: 11.5))
        .help(step.detail.map { "\(step.name): \($0)" } ?? step.name)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state.rawValue)
    }

    private func label(_ step: ActivityStep) -> Text {
        let lead: String
        if step.kind == .thinking, step.state != .running, let ended = step.ended {
            lead = "Thought for \(max(1, Int(ended.timeIntervalSince(step.started).rounded())))s"
        } else { lead = step.verb ?? step.name }
        let head = Text(lead).foregroundColor(.white.opacity(0.82))
        guard step.kind != .thinking, let detail = step.detail else { return head }
        let code = step.kind == .command || step.kind == .search
        return Text("\(head) \(Text(detail).font(code ? .system(size: 10.5, design: .monospaced) : appFont(size: 11.5)).foregroundColor(muted))")
    }

    static func symbol(_ kind: ActivityStep.Kind) -> String {
        switch kind {
        case .command: return "terminal"
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .fetch: return "link"
        case .mcp: return "puzzlepiece.extension"
        case .control: return "cursorarrow.rays"
        case .agent: return "person.2"
        case .thinking: return "brain"
        case .retry: return "arrow.clockwise"
        case .tool: return "wrench.and.screwdriver"
        case .look: return "eye"
        }
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.down))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// What a look at the screen saw, small; a click opens it full size.
struct LookThumbnail: View {
    let path: String
    let height: CGFloat

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            }.buttonStyle(.plain).help("What Claude saw. Click to open it.").accessibilityLabel("Screen Claude looked at")
        }
    }
}
