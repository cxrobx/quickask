import AppKit
import SwiftUI
import Combine

enum PopupShape {
    static let cornerRadius: CGFloat = 24

    // AppKit uses this mask for the window shadow when the effect is the
    // content view. The center stretches while the corners keep their radius.
    @MainActor static func maskImage() -> NSImage {
        let radius = cornerRadius
        let image = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Behind-window blur of the desktop, for the prompt box under clear glass.
/// It frosts regardless of whether QuickAsk is the active app.
struct PromptFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> FrostView {
        let view = FrostView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: FrostView, context: Context) {}
}

/// Purely decorative: never the target of mouse or cursor events, so SwiftUI
/// cannot hand a cursor update to it and have it forwarded back up.
final class FrostView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func cursorUpdate(with event: NSEvent) {}
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
    }
}

enum GlassPreference: String, CaseIterable, Identifiable {
    case automatic, cxGlass
    var id: String { rawValue }
    var title: String { self == .automatic ? "Automatic" : "CX glass" }
}

enum GlassRenderingMode: Equatable {
    case liquidGlass, cxGlass, solid

    static func resolve(majorVersion: Int, preference: GlassPreference, reduceTransparency: Bool) -> Self {
        if reduceTransparency { return .solid }
        return majorVersion >= 26 && preference == .automatic ? .liquidGlass : .cxGlass
    }

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .cxGlass: return "CX glass"
        case .solid: return "Solid"
        }
    }
}

@MainActor
final class GlassAppearance: ObservableObject {
    @Published var preference: GlassPreference {
        didSet { preferences.set(preference.rawValue, forKey: "glassPreference"); refresh() }
    }
    @Published private(set) var mode: GlassRenderingMode
    @Published private(set) var increasedContrast: Bool
    @Published private(set) var transparency: Double
    @Published private(set) var reduceTransparency: Bool
    /// Liquid Glass only: tints the prompt box darker than the pane for legibility.
    @Published var darkComposer: Bool {
        didSet { preferences.set(darkComposer, forKey: "darkComposer") }
    }
    /// Liquid Glass only: a clear pane with full edge lensing, frosting only the
    /// prompt box, instead of the default fully frosted (regular) pane.
    @Published var clearPane: Bool {
        didSet { preferences.set(clearPane, forKey: "clearPane") }
    }
    /// The whole popup in JetBrains Mono (the Obsidian vault's font) instead of the system font.
    @Published var vaultFont: Bool {
        didSet { vaultFontEnabled = vaultFont; preferences.set(vaultFont, forKey: "monoChat") }
    }
    private let preferences: UserDefaults
    private var accessibilityObserver: NSObjectProtocol?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let savedPreference = GlassPreference(rawValue: preferences.string(forKey: "glassPreference") ?? "automatic") ?? .automatic
        let saved = (preferences.object(forKey: "glassTransparency") as? NSNumber)?.doubleValue ?? 0.38
        let level = saved.isFinite ? min(1, max(0, saved)) : 0.38
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        preference = savedPreference
        darkComposer = preferences.object(forKey: "darkComposer") as? Bool ?? true
        clearPane = preferences.bool(forKey: "clearPane")
        vaultFont = preferences.bool(forKey: "monoChat")
        vaultFontEnabled = preferences.bool(forKey: "monoChat")
        transparency = level
        reduceTransparency = reduced
        mode = GlassRenderingMode.resolve(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                         preference: savedPreference, reduceTransparency: reduced || level == 0)
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    private func refresh() {
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let resolved = GlassRenderingMode.resolve(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                                 preference: preference, reduceTransparency: reduceTransparency || transparency == 0)
        if mode != resolved { mode = resolved }
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    func setTransparency(_ value: Double) {
        transparency = value.isFinite ? min(1, max(0, value)) : 0.38
        preferences.set(transparency, forKey: "glassTransparency")
        refresh()
    }

    var effectiveTransparency: Double { reduceTransparency ? 0 : transparency }
    var modeTitle: String { reduceTransparency ? "Solid · Reduce Transparency" : mode.title }

    // Liquid Glass: the glass supplies the frost (regular pane, or the prompt box
    // in clear-pane mode), so the slider only adds a dark wash, from none at
    // "More glass" to near-solid at "Opaque".
    // CX glass: CXTasks' default 0.38 transparency gives pane 0.715, chrome 0.3502.
    // Colors match its #181818 content, #2a2b2b chrome, and #2d2d2d inputs.
    var paneFill: Color {
        switch mode {
        case .liquidGlass: return Color.black.opacity(max(increasedContrast ? 0.55 : 0, (1 - effectiveTransparency) * 0.85))
        case .cxGlass: return Color(white: 24 / 255).opacity(1 - effectiveTransparency * 0.75)
        case .solid: return Color(white: 24 / 255)
        }
    }
    var chromeFill: Color {
        switch mode {
        case .liquidGlass: return paneFill
        case .cxGlass: return Color(red: 42 / 255, green: 43 / 255, blue: 43 / 255).opacity(1 - min(1, effectiveTransparency * 1.9) * 0.9)
        case .solid: return Color(red: 42 / 255, green: 43 / 255, blue: 43 / 255)
        }
    }
    var composerFill: Color {
        mode == .liquidGlass ? Color.white.opacity(0.035) : Color(white: 45 / 255)
    }
    var rim: LinearGradient {
        let boost = increasedContrast ? 1.6 : 1.0
        return LinearGradient(colors: [.white.opacity(0.22 * boost), .white.opacity(0.055 * boost), .white.opacity(0.12 * boost)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

/// Hosts the native effect and content on the same rounded window outline.
@MainActor
final class GlassPanelHost {
    private let hostingView: NSView
    private let appearanceModel: GlassAppearance
    private weak var window: NSWindow?
    private var subscription: AnyCancellable?
    private var paneSubscription: AnyCancellable?
    private weak var glassView: NSView?

    init(hostingView: NSView, appearance: GlassAppearance) {
        self.hostingView = hostingView; self.appearanceModel = appearance
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        subscription = appearance.$mode.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.configure(mode) }
        // Restyle the existing glass in place rather than rebuilding the view
        // tree under the pointer. @Published emits before the change, so use
        // the delivered value.
        paneSubscription = appearance.$clearPane.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clearPane in self?.stylePane(clearPane: clearPane) }
    }

    func attach(to window: NSWindow) {
        self.window = window
        configure(appearanceModel.mode)
    }

    private func configure(_ mode: GlassRenderingMode) {
        guard let window else { return }
        let frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        hostingView.removeFromSuperview()
        // Let glass manage its own content container. Constraining a hosting
        // view across that internal hierarchy to the effect's outer edges can
        // leave SwiftUI with stale geometry when the window changes height.
        let content = NSView(frame: frame)
        hostingView.frame = content.bounds
        content.addSubview(hostingView)
        let root: NSView
        if mode == .liquidGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = PopupShape.cornerRadius
            glass.contentView = content
            glassView = glass
            stylePane(clearPane: appearanceModel.clearPane)
            root = glass
        } else if mode == .cxGlass {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = PopupShape.maskImage()
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            root = effect
        } else {
            let surface = NSView(frame: frame)
            surface.wantsLayer = true
            surface.layer?.cornerRadius = PopupShape.cornerRadius
            surface.layer?.masksToBounds = true
            surface.layer?.backgroundColor = NSColor.clear.cgColor
            content.autoresizingMask = [.width, .height]
            surface.addSubview(content)
            root = surface
        }
        window.contentView = root
        layoutContent()
        applyWindowEffect()
    }

    private func stylePane(clearPane: Bool) {
        guard #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView else { return }
        if clearPane {
            // Clear glass keeps the full edge lensing but goes nearly transparent
            // while its app is active, which QuickAsk always is while typing, so
            // the prompt box carries its own frost.
            glass.style = .clear
            glass.tintColor = NSColor.black.withAlphaComponent(0.16)
            glass.layer?.masksToBounds = false
        } else {
            // Regular glass stays frosted while the app is active. It paints
            // faintly to its square bounds, and the window shadow traces that
            // rectangle, so clip it to the rounded outline.
            glass.style = .regular
            glass.tintColor = nil
            glass.wantsLayer = true
            glass.layer?.cornerRadius = PopupShape.cornerRadius
            glass.layer?.masksToBounds = true
        }
        window?.invalidateShadow()
    }

    func layoutContent() {
        window?.contentView?.layoutSubtreeIfNeeded()
        if let container = hostingView.superview, hostingView.frame != container.bounds {
            hostingView.frame = container.bounds
        }
        hostingView.layoutSubtreeIfNeeded()
    }

    func applyWindowEffect() {
        guard let window else { return }
        window.isOpaque = false
        // Even a nearly clear rectangular window background leaves a second
        // outline outside the masked effect on a borderless floating panel.
        window.backgroundColor = .clear
        window.hasShadow = true
        window.invalidateShadow()
    }
}
