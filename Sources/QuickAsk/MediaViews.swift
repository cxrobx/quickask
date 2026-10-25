import SwiftUI
import AppKit
import AVKit
import WebKit

/// Artifact links the user pasted into this chat: those load at once. One that only a reply
/// carries waits for a click, as remote images do, since an answer can be steered by the screen.
struct TrustedArtifactsKey: EnvironmentKey { static let defaultValue: Set<String> = [] }
extension EnvironmentValues {
    var trustedArtifacts: Set<String> {
        get { self[TrustedArtifactsKey.self] }
        set { self[TrustedArtifactsKey.self] = newValue }
    }
}

enum MediaLinks {
    /// The artifact id, so the two link forms and a trailing slash compare equal.
    static func artifactID(_ url: URL) -> String { url.pathComponents.last ?? url.absoluteString }

    static func artifacts(in texts: [String]) -> Set<String> {
        var ids = Set<String>()
        for text in texts {
            for match in text.matches(of: #/https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9-]+/#) {
                if let url = URL(string: String(match.output)) { ids.insert(artifactID(url)) }
            }
        }
        return ids
    }
}

private func mediaCaption(_ text: String, symbol: String) -> some View {
    Label(text, systemImage: symbol).font(appFont(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
}

// MARK: - Video

/// A local video, played in place. WebM (what Playwright records) plays in WebKit, which
/// decodes it; everything else in AVKit.
struct InlineVideo: View {
    let url: URL
    let alt: String
    @State private var ratio: CGFloat = 16 / 9

    var body: some View {
        if !FileManager.default.fileExists(atPath: url.path) {
            mediaCaption("Video not found: \(url.path)", symbol: "film")
        } else {
            Group {
                if url.pathExtension.lowercased() == "webm" { WebVideoView(url: url, ratio: $ratio) }
                else { PlayerView(url: url).task(id: url) { await measure() } }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: min(520, 360 * ratio), alignment: .leading)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
            .accessibilityLabel(alt.isEmpty ? "Video" : alt)
            .help(alt.isEmpty ? url.lastPathComponent : alt)
        }
    }

    private func measure() async {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return }
        let shown = size.applying(transform)
        if abs(shown.width) > 0, abs(shown.height) > 0 { ratio = abs(shown.width) / abs(shown.height) }
    }
}

private struct PlayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url { view.player = AVPlayer(url: url) }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}

private struct WebVideoView: NSViewRepresentable {
    let url: URL
    @Binding var ratio: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(ratio: $ratio) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let ratio: Binding<CGFloat>
        init(ratio: Binding<CGFloat>) { self.ratio = ratio }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The media document's <video> knows its size once its metadata has loaded.
            webView.evaluateJavaScript("(() => { const v = document.querySelector('video'); return v && v.videoHeight ? v.videoWidth / v.videoHeight : 0 })()") { value, _ in
                if let value = value as? Double, value > 0 { self.ratio.wrappedValue = value }
            }
        }
    }
}

// MARK: - Pages

/// What a page view needs beyond its URL: where its network may go and how it sizes.
enum PageKind {
    /// A local HTML file Claude wrote: loads from its folder and the usual CDNs only,
    /// sizes to its content, and reloads when the file changes.
    case local
    /// A claude.ai artifact: the hosted page, signed in with Quick Ask's own claude.ai session.
    case artifact

    init(_ url: URL) { self = url.isFileURL ? .local : .artifact }

    /// Hosts an artifact page may load in the window it lives in; sign-in pages only in the full window.
    static func allows(_ host: String, signingIn: Bool) -> Bool {
        let hosts = ["claude.ai", "claudeusercontent.com", "anthropic.com"] + (signingIn ? ["accounts.google.com", "appleid.apple.com"] : [])
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Network rules for local pages: nothing leaves the machine except the CDNs artifacts may use.
/// WebKit's rule syntax has no alternation, so each host is its own rule.
enum PageRules {
    static let cdnHosts = ["cdnjs.cloudflare.com", "cdn.jsdelivr.net", "unpkg.com", "cdn.tailwindcss.com",
                           "code.jquery.com", "fonts.googleapis.com", "fonts.gstatic.com"]
    static var json: String {
        let block = #"{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}"#
        let allow = cdnHosts.map { host in
            #"{"trigger":{"url-filter":"^https://\#(host.replacingOccurrences(of: ".", with: "\\\\."))/"},"action":{"type":"ignore-previous-rules"}}"#
        }
        return "[" + ([block] + allow).joined(separator: ",") + "]"
    }

    @MainActor private static var compiled: WKContentRuleList?
    @MainActor private static var waiting: [(WKContentRuleList?) -> Void] = []

    @MainActor static func list(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { done(compiled); return }
        waiting.append(done)
        guard waiting.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "quickask-pages", encodedContentRuleList: json) { list, error in
            DispatchQueue.main.async {
                if let error { NSLog("QuickAsk page rules failed to compile: %@", error.localizedDescription) }
                compiled = list
                let callbacks = waiting; waiting = []
                callbacks.forEach { $0(list) }
            }
        }
    }
}

/// Live page views by file, so a follow-up can send Claude a picture of the page as it looks.
@MainActor final class PageRegistry {
    static let shared = PageRegistry()
    private final class Box { weak var view: WKWebView?; init(_ view: WKWebView) { self.view = view } }
    private var views: [URL: Box] = [:]

    func register(_ url: URL, _ view: WKWebView) { views[url.standardizedFileURL] = Box(view) }

    /// The page as it shows in the reply, or nil when it isn't on screen.
    func snapshot(of url: URL) async -> ImageAttachment? {
        guard let view = views[url.standardizedFileURL]?.view, view.window != nil else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            view.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        return image.flatMap(ImageAttachment.make(from:))
    }
}

extension Notification.Name {
    /// The claude.ai session may have changed (a sign-in window closed): artifact cards reload.
    static let quickAskSessionChanged = Notification.Name("QuickAskClaudeSessionChanged")
}

/// What a page card shows about its web view: the page's title, its content height, and whether
/// claude.ai sent it to sign in.
final class PageState: ObservableObject {
    @Published var title = ""
    @Published var contentHeight: CGFloat = 0
    @Published var needsSignIn = false
    @Published var blocked = false
    weak var view: WKWebView?
    func reload() { view?.reload() }
}

/// A web page in a reply: a local HTML file or a claude.ai artifact, live and interactive.
struct InlinePage: View {
    let url: URL
    let alt: String
    @Environment(\.trustedArtifacts) private var trusted
    @StateObject private var state = PageState()
    @State private var load = false

    static let maxHeight: CGFloat = 460
    private var kind: PageKind { PageKind(url) }
    private var height: CGFloat {
        kind == .artifact ? Self.maxHeight : min(Self.maxHeight, max(120, state.contentHeight))
    }
    private var name: String {
        if !state.title.isEmpty && !state.needsSignIn { return state.title }
        if !alt.isEmpty && alt != url.lastPathComponent { return alt }
        return kind == .local ? url.deletingPathExtension().lastPathComponent : "Claude artifact"
    }

    var body: some View {
        if kind == .local && !FileManager.default.fileExists(atPath: url.path) {
            mediaCaption("Page not found: \(url.path)", symbol: "doc.richtext")
        } else if kind == .artifact && !load && !trusted.contains(MediaLinks.artifactID(url)) {
            Button { load = true } label: {
                mediaCaption("\(alt.isEmpty ? "Claude artifact" : alt) · open it here", symbol: "sparkles.rectangle.stack")
            }.buttonStyle(.plain).help(url.absoluteString)
        } else {
            VStack(spacing: 0) {
                header
                PageWebView(url: url, state: state)
                    .frame(height: height)
                    .overlay { if state.needsSignIn { signIn } }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
            .onReceive(NotificationCenter.default.publisher(for: .quickAskSessionChanged)) { _ in
                if kind == .artifact { state.needsSignIn = false; state.view?.load(URLRequest(url: url)) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .local ? "doc.richtext" : "sparkles.rectangle.stack")
                .font(appFont(size: 11)).foregroundStyle(.white.opacity(0.55))
            Text(name).font(appFont(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if kind == .local {
                Text("live").font(appFont(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 5).padding(.vertical, 1.5).background(Capsule().fill(Color.white.opacity(0.08)))
                    .help("Reloads when the file changes. Ask for changes in the chat.")
            }
            Spacer(minLength: 4)
            button("arrow.clockwise", "Reload") { state.reload() }
            button("arrow.up.left.and.arrow.down.right", "Open in a larger window") { PageWindow.open(url, title: name) }
            button("arrow.up.forward.app", kind == .local ? "Open in Onyx" : "Open in your browser") { openOutside() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(appFont(size: 11)).foregroundStyle(.white.opacity(0.7)).frame(width: 20, height: 18)
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private var signIn: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
            Text("Sign in to claude.ai to see this artifact").font(appFont(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            Text("Quick Ask keeps its own claude.ai session; you sign in once.").font(appFont(size: 11)).foregroundStyle(.white.opacity(0.55))
            Button("Sign in…") { PageWindow.open(url, title: "Sign in to claude.ai", signingIn: true) }.controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func openOutside() {
        if kind == .local, let onyx = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cx.onyx") {
            NSWorkspace.shared.open([url], withApplicationAt: onyx, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A WKWebView that hands the scroll wheel to the transcript when the page fits its frame, so a
/// reply with a page in it scrolls like any other.
final class PageWebView_: WKWebView {
    var fitsContent = false
    override func scrollWheel(with event: NSEvent) {
        if fitsContent { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

struct PageWebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var state: PageState
    var signingIn = false

    func makeCoordinator() -> PageCoordinator { PageCoordinator(url: url, state: state, signingIn: signingIn) }

    func makeNSView(context: Context) -> PageWebView_ {
        let view = PageCoordinator.makeView(for: url, coordinator: context.coordinator)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: PageWebView_, context: Context) {
        view.fitsContent = PageKind(url) == .local && state.contentHeight > 0 && state.contentHeight <= InlinePage.maxHeight
    }

    static func dismantleNSView(_ view: PageWebView_, coordinator: PageCoordinator) { coordinator.detach() }
}

/// Loads, sizes, guards and live-reloads one page view.
@MainActor final class PageCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let url: URL
    let state: PageState
    let signingIn: Bool
    private weak var view: WKWebView?
    private var watch: Timer?
    private var stamp: (Date?, Int?) = (nil, nil)
    private var restoreScroll: Double?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    /// A sign-in window closes once claude.ai leaves its login page, not before it has shown it.
    private var sawLogin = false
    var onSignedIn: (() -> Void)?

    init(url: URL, state: PageState, signingIn: Bool) { self.url = url; self.state = state; self.signingIn = signingIn }

    /// Reports the document's height as it changes, so a local page's card fits it.
    private static let heightScript = """
    (() => {
      const post = () => window.webkit.messageHandlers.qaHeight.postMessage(Math.ceil(document.documentElement.scrollHeight));
      new ResizeObserver(post).observe(document.documentElement);
      addEventListener('load', post); post();
    })();
    """

    static func makeView(for url: URL, coordinator: PageCoordinator) -> PageWebView_ {
        let configuration = WKWebViewConfiguration()
        if url.isFileURL {
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.addUserScript(WKUserScript(source: heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            configuration.userContentController.add(WeakHandler(coordinator), name: "qaHeight")
        } else {
            // Quick Ask's own claude.ai session, kept between launches.
            configuration.websiteDataStore = .default()
            // Read as Safari, so claude.ai's Google sign-in doesn't refuse the embedded view.
            configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        }
        configuration.preferences.isElementFullscreenEnabled = true
        let view = PageWebView_(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func attach(_ view: WKWebView) {
        self.view = view
        state.view = view
        titleObservation = view.observe(\.title, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.state.title = view.title ?? "" }
        }
        // claude.ai is a single-page app: its login redirect and return change the URL without a new load.
        if !url.isFileURL {
            urlObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.followed(view.url) }
            }
        }
        if url.isFileURL {
            PageRegistry.shared.register(url, view)
            PageRules.list { [weak self, weak view] rules in
                guard let self, let view else { return }
                if let rules { view.configuration.userContentController.add(rules) }
                else { self.state.blocked = true; return } // Never load a local page without its network rules.
                view.loadFileURL(self.url, allowingReadAccessTo: self.url.deletingLastPathComponent())
                self.stamp = Self.stamp(self.url)
                self.startWatching()
            }
        } else {
            view.load(URLRequest(url: url))
        }
    }

    func detach() {
        watch?.invalidate(); watch = nil
        titleObservation = nil; urlObservation = nil
        view?.configuration.userContentController.removeScriptMessageHandler(forName: "qaHeight")
    }

    private static func stamp(_ url: URL) -> (Date?, Int?) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate, values?.fileSize)
    }

    /// Claude edits the file in place; the card follows, keeping its scroll position.
    private func startWatching() {
        watch = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFile() }
        }
        RunLoop.main.add(watch!, forMode: .common)
    }

    private func checkFile() {
        guard let view else { return }
        let now = Self.stamp(url)
        guard now.0 != nil, now != stamp else { return }
        stamp = now
        view.evaluateJavaScript("window.scrollY") { value, _ in
            self.restoreScroll = value as? Double
            view.loadFileURL(self.url, allowingReadAccessTo: self.url.deletingLastPathComponent())
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let height = message.body as? Double { state.contentHeight = CGFloat(height) }
        else if let height = message.body as? Int { state.contentHeight = CGFloat(height) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let y = restoreScroll { restoreScroll = nil; webView.evaluateJavaScript("window.scrollTo(0, \(y))") }
    }

    private func followed(_ current: URL?) {
        guard let current, current.host == "claude.ai" else { return }
        let onLogin = current.path.hasPrefix("/login")
        if signingIn {
            // Back on claude.ai after its login page: every artifact card can load now.
            if onLogin { sawLogin = true } else if sawLogin { onSignedIn?(); onSignedIn = nil }
        } else {
            state.needsSignIn = onLogin
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { decisionHandler(.cancel); return }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let scheme = target.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) { decisionHandler(.allow); return }
        if url.isFileURL {
            // The page and files beside it; a clicked web link opens in the browser.
            if target.isFileURL, target.standardizedFileURL.path.hasPrefix(url.deletingLastPathComponent().standardizedFileURL.path) {
                decisionHandler(.allow); return
            }
            if mainFrame, action.navigationType == .linkActivated, scheme == "https" || scheme == "http" { NSWorkspace.shared.open(target) }
            decisionHandler(mainFrame ? .cancel : .allow) // Subframes still meet the network rules.
            return
        }
        if let host = target.host?.lowercased(), PageKind.allows(host, signingIn: signingIn) || !mainFrame {
            decisionHandler(.allow); return
        }
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(target) }
        decisionHandler(.cancel)
    }

    /// target=_blank and window.open: a sign-in popup gets its own window; anything else opens in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = action.request.url else { return nil }
        if signingIn, let host = target.host?.lowercased(), PageKind.allows(host, signingIn: true) {
            return PageWindow.popup(configuration: configuration)
        }
        if let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http" { NSWorkspace.shared.open(target) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }
}

/// Breaks the retain cycle between a content controller and its handler.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A page at full size in its own window: the Expand button, and claude.ai sign-in.
@MainActor enum PageWindow {
    private static var windows: [NSWindow: (PageCoordinator, PageState)] = [:]
    private static var closing: [NSObjectProtocol] = []

    static func open(_ url: URL, title: String, signingIn: Bool = false) {
        let state = PageState()
        let coordinator = PageCoordinator(url: url, state: state, signingIn: signingIn || !url.isFileURL)
        let view = PageCoordinator.makeView(for: url, coordinator: coordinator)
        let window = makeWindow(title: title, content: view)
        coordinator.onSignedIn = signingIn ? { [weak window] in window?.close() } : nil
        coordinator.attach(view)
        windows[window] = (coordinator, state)
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                windows[window]?.0.detach(); windows[window] = nil
                if !url.isFileURL { NotificationCenter.default.post(name: .quickAskSessionChanged, object: nil) }
            }
        }
        closing.append(token)
    }

    /// A sign-in popup (Google's chooser) in a window of its own, on the opener's configuration.
    static func popup(configuration: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: configuration)
        let window = makeWindow(title: "Sign in", content: view, size: NSSize(width: 520, height: 680))
        let state = PageState()
        let coordinator = PageCoordinator(url: URL(string: "https://claude.ai/login")!, state: state, signingIn: true)
        view.navigationDelegate = coordinator; view.uiDelegate = coordinator
        windows[window] = (coordinator, state)
        return view
    }

    private static func makeWindow(title: String, content: NSView, size: NSSize = NSSize(width: 1100, height: 780)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating // Above the Quick Ask panel, which floats.
        window.contentView = content
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
