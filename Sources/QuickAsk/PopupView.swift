import SwiftUI
import AppKit

private let muted = Color.white.opacity(0.56)
private let accent = Color(red: 0.76, green: 0.89, blue: 0.79)

private extension Provider {
    var tint: Color { self == .claude ? Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255) : .white }
    var labelColor: Color { self == .claude ? Color(red: 238 / 255, green: 154 / 255, blue: 113 / 255) : .white }
}

private struct GlassPill: ViewModifier {
    let appearance: GlassAppearance
    let tint: Color
    let selected: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
            content.background(selected ? tint.opacity(0.10) : .clear, in: Capsule())
                .glassEffect(.clear.tint(selected ? tint.opacity(0.28) : tint.opacity(0.03)).interactive(), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.35) : .white.opacity(0.08), lineWidth: 0.75))
        } else {
            content.background(selected ? tint.opacity(0.12) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.30) : .clear))
        }
    }
}

/// Control Center-style glass behind the prompt box: its own lensing surface on
/// the pane, optionally tinted darker so typed text stays legible.
private struct ComposerSurface: ViewModifier {
    @ObservedObject var appearance: GlassAppearance
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17)
        if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
            if appearance.clearPane {
                content.background {
                    PromptFrost().allowsHitTesting(false).clipShape(shape)
                        .overlay(shape.fill(Color.black.opacity(appearance.darkComposer ? 0.32 : 0)))
                }
                .overlay(shape.strokeBorder(appearance.rim, lineWidth: 1))
            } else if appearance.darkComposer {
                content.glassEffect(.clear.tint(.black.opacity(0.32)), in: shape)
                    .overlay(shape.strokeBorder(appearance.rim, lineWidth: 1))
            } else {
                // No surface of its own: the box is the pane's glass, outlined.
                // Any nested glass renders a second tone (darker or lighter).
                content.overlay(shape.strokeBorder(appearance.rim, lineWidth: 1))
            }
        } else {
            content.background(appearance.composerFill, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.05)))
        }
    }
}

/// Round glass button, like Control Center's module buttons.
private struct GlassCircle: ViewModifier {
    let appearance: GlassAppearance
    var tint: Color? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
            content.glassEffect(.clear.tint(tint).interactive(), in: Circle())
        } else if let tint {
            content.background(tint, in: Circle())
        } else {
            content
        }
    }
}

/// iMessage-style bubble: you on the right in clear glass, the assistant on the
/// left in glass tinted by provider (Claude orange, Codex smoke). The bubble only
/// tints the pane's glass, so the popup stays as see-through as before.
private struct MessageBubble: ViewModifier {
    let appearance: GlassAppearance
    let user: Bool
    let tint: Color?
    @ViewBuilder func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: user ? 17 : 5,
                                           bottomTrailingRadius: user ? 5 : 17, topTrailingRadius: 17, style: .continuous)
        let padded = content.padding(.horizontal, 13).padding(.vertical, 9)
        let rim = (tint ?? .white).opacity(tint == nil ? 0.16 : 0.32)
        if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
            padded.glassEffect(.clear.tint(tint?.opacity(0.22)), in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
        } else {
            padded.background((tint ?? .white).opacity(tint == nil ? 0.08 : 0.16), in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
        }
    }
}

struct PopupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var appearance: GlassAppearance
    let dismiss: () -> Void
    let resize: () -> Void
    let changeHotkey: () -> Void
    /// Internal, not private, so a render can start with a pill hovered; the app never passes it.
    @State var hoveredTab: UUID? = nil
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var lastTabPoint: CGPoint?
    /// Internal, like `hoveredTab`, so a render can start with the model pill opened out.
    @State var pillHovered = false
    @State private var pillMenuOpen = false
    @State private var historyOpen = false
    @State private var contextOpen = false
    @State private var pillFrame: CGRect = .zero
    /// Whether transcript text sits below the visible area. A streaming answer never drags
    /// the transcript down (the reader starts at its first line); a pill offers the jump.
    @State private var transcriptMoreBelow = false
    @State private var transcriptScrollWork: DispatchWorkItem?
    /// Replies whose work log is unfolded.
    @State private var logFolds: [UUID: WorkLogView.Fold] = [:]

    var body: some View {
        GeometryReader { geometry in
            content(viewportHeight: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .preferredColorScheme(.dark)
        // The window owner coalesces these requests after SwiftUI's update pass.
        .onChange(of: model.chatExpanded) { _, _ in resize() }
        .onChange(of: model.delegation?.id) { _, _ in resize() }
        .onChange(of: model.herdrProposal?.id) { _, _ in resize() }
        .onChange(of: model.attachments.isEmpty) { _, _ in resize() }
        .onChange(of: model.showsTabs) { _, _ in resize() }
        .onChange(of: model.alternativeHotkey) { _, _ in changeHotkey() }

    }

    private func content(viewportHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Full width: the fill must run edge to edge, or a clear pane shows the desktop beside the strip.
            if model.showsTabs { tabBar.frame(maxWidth: .infinity).frame(height: PopupMetrics.tabBarHeight).background(WindowDragArea()).background(appearance.chromeFill) }
            header.fixedSize(horizontal: false, vertical: true).background(appearance.chromeFill)
            VStack(spacing: 0) {
                if model.showingSettings {
                    settingsPanel
                } else if model.delegation != nil {
                    delegationPanel
                } else if !model.messages.isEmpty || model.herdrProposal != nil {
                    transcript
                } else {
                    Spacer(minLength: 0)
                }
                if let error = model.error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(appFont(size: 12)).textSelection(.enabled).lineLimit(8)
                        Spacer(minLength: 0)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 18).padding(.bottom, 10)
                }
                if model.needsContextChoice && !model.showingSettings {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.status).font(appFont(size: 12)).foregroundStyle(muted)
                        HStack {
                            Button("General chat") { model.selectContext(.general); model.send() }
                            ForEach(Array(model.contextWindows.prefix(4))) { window in
                                Button(window.appName) { model.selectContext(.window(window.id)); model.send() }
                            }
                        }.controlSize(.small)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 10)
                }
                if !model.showingSettings && model.delegation == nil { composer(viewportHeight: viewportHeight).disabled(model.herdrProposal != nil) }
                footer.fixedSize(horizontal: false, vertical: true)
            }
            // Any empty space in the pane moves the popup; text, bubbles and controls sit on top and keep their clicks.
            .background(WindowDragArea()).background(appearance.paneFill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: PopupShape.cornerRadius, style: .circular))
        .overlay(RoundedRectangle(cornerRadius: PopupShape.cornerRadius, style: .circular).strokeBorder(appearance.rim, lineWidth: 1))
        .overlay { ResizeEdges() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            historyMenu
            contextMenu
            Spacer()
            Button(action: model.toggleControl) {
                Label(model.controlEnabled ? "Control \(model.targetApp?.name ?? "app")" : "Control app", systemImage: "cursorarrow")
                    .font(appFont(size: 11, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .foregroundStyle(model.controlEnabled ? model.provider.labelColor : muted)
                    .modifier(GlassPill(appearance: appearance, tint: model.provider.tint, selected: model.controlEnabled))
            }.buttonStyle(.plain).disabled(model.busy)
                .help("Let the selected provider inspect and control the app you were using before opening QuickAsk")
            if !model.messages.isEmpty {
                tool("New chat", symbol: "square.and.pencil", action: model.newChat)
            }
            tool(model.pinned ? "Unpin popup" : "Keep popup open", symbol: model.pinned ? "pin.fill" : "pin") { model.pinned.toggle() }
        }.padding(.horizontal, 22).padding(.top, model.showsTabs ? 18 - PopupMetrics.headerInsetUnderTabs : 18).padding(.bottom, 13)
            .background(WindowDragArea())
    }

    /// Where the next message goes, plus the chat actions. A popover rather than a `Menu`, so
    /// rows highlight as the same soft gray pill as Recent chats instead of system blue.
    private var contextMenu: some View {
        Button { contextOpen.toggle() } label: {
            Text(model.contextLabel).font(appFont(size: 11)).lineLimit(1).truncationMode(.middle).foregroundStyle(muted)
        }
        .buttonStyle(.plain).disabled(model.busy)
        .popover(isPresented: $contextOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                menuRow("Auto") { model.selectContext(.auto) }
                menuRow("General chat") { model.selectContext(.general) }
                menuRow("My setup (Claude)", enabled: model.provider == .claude) { model.selectContext(.personal) }
                if !model.contextWindows.isEmpty {
                    menuDivider
                    ForEach(model.contextWindows) { window in
                        menuRow(window.label) { model.selectContext(.window(window.id)) }
                    }
                }
                menuDivider
                menuRow("Move to focused app") { model.moveToFocusedApp?() }
                menuRow("Create task from this question…", enabled: model.canSend, action: model.prepareTask)
                menuRow("Continue this chat in Herdr", enabled: model.canTransferToHerdr, action: model.prepareHerdr)
                menuRow("Project folder tools · later release", enabled: false) {}
            }
            .padding(6).frame(minWidth: 260, maxWidth: 440).fixedSize(horizontal: true, vertical: false)
            .environment(\.colorScheme, .dark)
        }
    }

    private func menuRow(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        MenuRow(title: title, enabled: enabled) { contextOpen = false; action() }
    }

    private var menuDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
    }

    /// About ten rows; the rest of the 30 scroll.
    private static let historyListHeight: CGFloat = 470

    /// The last 30 chats, newest first, scrolling past about ten so the popover keeps its
    /// height. Picking one opens it in a tab to carry on. A popover
    /// rather than a `Menu`, so the selected row is a soft gray pill instead of system blue.
    private var historyMenu: some View {
        Button { historyOpen.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath").font(appFont(size: 13, weight: .semibold)).foregroundStyle(accent)
        }
        .buttonStyle(.plain).fixedSize()
        .disabled(!model.canSwitchChats).help("Recent chats").accessibilityLabel("Recent chats")
        .popover(isPresented: $historyOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if model.historySummaries.isEmpty {
                    Text("No chats yet").font(appFont(size: 12)).foregroundStyle(muted).padding(12)
                } else {
                    Text("Recent chats").font(appFont(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.historySummaries) { chat in
                                HistoryRow(chat: chat, mark: model.historyMark(of: chat.id),
                                           action: { historyOpen = false; model.reopenChat(chat.id) },
                                           toggleStillOnMe: { model.toggleStillOnMe(chat.id) })
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: Self.historyListHeight)
                }
            }
            .padding(6).frame(width: 300).environment(\.colorScheme, .dark)
        }
    }

    /// One pill per chat along the top edge, as in Onyx. It appears once there are two chats
    /// (a `/fork`, or + after that), so a single chat keeps the plain popup. Pills share the
    /// strip; the one under the pointer widens toward its full title (TabStripLayout), and the
    /// ⌄ list holds every tab, including any the strip has no room for.
    private var tabBar: some View {
        HStack(spacing: 2) {
            let active = model.sessions.firstIndex { $0.id == model.activeSessionID } ?? 0
            TabStripLayout(active: active, hovered: model.sessions.firstIndex { $0.id == hoveredTab }) {
                ForEach(model.sessions) { session in
                    tabPill(session).background(GeometryReader { geometry in
                        Color.clear.preference(key: TabFrames.self, value: [session.id: geometry.frame(in: .named("tabs"))])
                    })
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .coordinateSpace(name: "tabs")
            .onPreferenceChange(TabFrames.self) { tabFrames = $0 }
            // Only real pointer movement picks a pill: one that slides under a still pointer as
            // the widths change is not chosen. The widened pill stays until another is picked.
            .onContinuousHover(coordinateSpace: .named("tabs")) { phase in
                switch phase {
                case .active(let point):
                    guard point != lastTabPoint else { return }
                    lastTabPoint = point
                    if let id = tabFrames.first(where: { $0.value.contains(point) })?.key, id != hoveredTab {
                        withAnimation(TabStripLayout.grow) { hoveredTab = id }
                    }
                case .ended:
                    lastTabPoint = nil
                    withAnimation(TabStripLayout.fall) { hoveredTab = nil }
                }
            }
            tabButton("New chat tab", symbol: "plus", action: model.newTab).disabled(!model.canSwitchChats)
            Menu {
                ForEach(model.sessions) { session in
                    Button { model.selectSession(session.id) } label: {
                        if session.id == model.activeSessionID { Label(model.title(of: session), systemImage: "checkmark") }
                        else { Text(model.title(of: session)) }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(appFont(size: 11, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(muted)
            .disabled(!model.canSwitchChats).help("All tabs").accessibilityLabel("All tabs")
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private func tabButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(appFont(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(muted).help(title).accessibilityLabel(title)
    }

    private func tabPill(_ session: ChatSession) -> some View {
        let active = session.id == model.activeSessionID
        let hovered = hoveredTab == session.id
        let title = model.title(of: session)
        return HStack(spacing: 4) {
            if session.forkedFrom != nil {
                Image(systemName: "arrow.triangle.branch").font(appFont(size: 9, weight: .semibold)).foregroundStyle(muted)
            }
            // A fork's title ends in "· fork 2"; at rest its middle is cut so that end stays readable.
            TabTitle(text: title, font: appFont(size: 12, weight: active ? .semibold : .medium),
                     truncation: session.forkedFrom != nil ? .middle : .tail, rolling: hovered)
                .foregroundStyle(.white.opacity(active || hovered ? 0.92 : 0.58))
            // The × always keeps its room, so a pill's width doesn't change as it shows.
            Button { model.closeSession(session.id) } label: {
                Image(systemName: "xmark").font(appFont(size: 8, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(muted)
                .opacity(active || hovered ? 1 : 0).allowsHitTesting(active || hovered)
                .disabled(active && !model.canSwitchChats)
                .help("Close tab").accessibilityLabel("Close \(title)")
        }
        .padding(.leading, 10).padding(.trailing, 3)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(active ? 0.12 : hovered ? 0.05 : 0))
                .shadow(color: .black.opacity(active ? 0.2 : 0), radius: 1, y: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { model.selectSession(session.id) }
        .opacity(active || model.canSwitchChats ? 1 : 0.5)
        .help(title)
        .accessibilityElement(children: .contain).accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
    }

    private func tool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(appFont(size: 12))
                .frame(width: appearance.mode == .liquidGlass ? 28 : 26, height: appearance.mode == .liquidGlass ? 28 : 24)
                .modifier(GlassCircle(appearance: appearance))
        }
            .buttonStyle(.plain).foregroundStyle(muted).help(title).accessibilityLabel(title)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Chat rows have variable heights (Markdown, cards, and the pending
                // reply). Lazy height estimates can oscillate while scrollTo pins
                // the bottom. Measure the chat directly instead.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        let user = message.role == "user"
                        let provider = Provider(rawValue: message.provider ?? "")
                        VStack(alignment: user ? .trailing : .leading, spacing: 6) {
                            if !user {
                            HStack {
                                Text( (Provider(rawValue: message.provider ?? "")?.title.uppercased() ?? AppConnector(rawValue: message.provider ?? "")?.title.uppercased() ?? "ASSISTANT"))
                                    .font(appFont(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(1.3).foregroundStyle(provider?.labelColor.opacity(provider == .claude ? 1 : 0.56) ?? muted)
                                Spacer()
                                if !message.text.isEmpty {
                                    tool("Copy response", symbol: "doc.on.doc") { model.copy(message.text) }
                                }
                            }.padding(.leading, 13)
                            }
                            if !message.images.isEmpty {
                                HStack(spacing: 8) { ForEach(message.images) { thumbnail($0, size: 72) } }
                            }
                            let steps = user ? [] : message.activity ?? []
                            if !steps.isEmpty {
                                WorkLogView(steps: steps, live: !message.complete && model.busy && message.id == model.messages.last?.id,
                                            fold: Binding(get: { logFolds[message.id] }, set: { logFolds[message.id] = $0 }))
                                    .padding(.trailing, 28)
                            }
                            if message.text.isEmpty && (user || !steps.isEmpty) {
                                EmptyView()
                            } else if message.text.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(model.status).font(appFont(size: 13)).foregroundStyle(muted)
                                }.modifier(MessageBubble(appearance: appearance, user: false, tint: bubbleTint(provider)))
                            } else if user {
                                Text(markdown(message.text)).font(appFont(size: 14)).lineSpacing(5)
                                    .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .modifier(MessageBubble(appearance: appearance, user: true, tint: nil))
                                    .padding(.leading, 64)
                            } else {
                                MarkdownView(text: message.text, accent: accent, vaultFont: appearance.vaultFont).equatable()
                                    .modifier(MessageBubble(appearance: appearance, user: false, tint: bubbleTint(provider)))
                                    .padding(.trailing, 28)
                            }
                            ForEach(message.cards) { card in
                                CoachCardView(card: card, recording: model.recordingOutcomes) { finding, outcome in
                                    model.recordOutcome(message: message.id, card: card.id, finding: finding.id, outcome: outcome)
                                }
                            }
                            if !user, message.complete, let blocked = message.blocked, !blocked.isEmpty {
                                BlockedActionsCard(actions: blocked, disabled: model.busy || model.delegation != nil || model.herdrProposal != nil) {
                                    model.approveBlocked(message.id)
                                }.padding(.trailing, 28)
                            }
                            if !message.complete && (!message.text.isEmpty || !steps.isEmpty) && !model.busy {
                                Text(message.text.isEmpty ? "Stopped" : "Stopped · partial response").font(appFont(size: 10)).foregroundStyle(muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: user ? .trailing : .leading).id(message.id)
                    }
                    if let proposal = model.herdrProposal, !proposal.direct { herdrCard.id("herdr-card") }
                    // The scroll target includes the trailing space, so following
                    // reaches the actual document bottom rather than 20 pt above it.
                    Color.clear.frame(height: 1).padding(.bottom, 20).id("end")
                }.padding(.horizontal, 24).padding(.top, 12)
                .environment(\.trustedArtifacts, MediaLinks.artifacts(in: model.messages.filter { $0.role == "user" }.map(\.text)))
                .background(TranscriptFollow { transcriptMoreBelow = $0 })
                .background(WindowDragArea())
            }
            .overlay(alignment: .bottom) {
                if transcriptMoreBelow {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down").font(appFont(size: 10, weight: .semibold))
                            if model.busy { Text("More below").font(appFont(size: 11, weight: .medium)) }
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, model.busy ? 11 : 8).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain).help("Scroll to the newest text").accessibilityLabel("Scroll to the newest text")
                    .padding(.bottom, 8).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: transcriptMoreBelow)
            .onChange(of: TranscriptScrollUpdate(session: model.activeSessionID, messages: model.messages,
                                                 proposal: model.herdrProposal?.id, details: model.herdrDetailsExpanded), initial: true) { old, new in
                // A sent message, another chat or a new Herdr card brings the bottom back.
                // Streamed text alone never scrolls: the answer grows below where the reader
                // is, and the "More below" pill offers the jump.
                let jump = new.session != old.session || new.count != old.count || (new.proposal != old.proposal && new.proposal != nil)
                let herdr = new.details != old.details && model.herdrDetailsExpanded && model.herdrProposal != nil
                guard jump || herdr || old == new, transcriptScrollWork == nil else { return }
                // Coalesce into one scroll, issued after SwiftUI's current layout transaction.
                let work = DispatchWorkItem {
                    transcriptScrollWork = nil
                    if model.herdrDetailsExpanded && model.herdrProposal != nil {
                        proxy.scrollTo("herdr-card", anchor: .top)
                    } else { proxy.scrollTo("end", anchor: .bottom) }
                }
                transcriptScrollWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35), execute: work)
            }
            .onDisappear {
                transcriptScrollWork?.cancel(); transcriptScrollWork = nil
            }
        }
    }

    /// Claude's own orange; Codex and app connectors read as smoked glass.
    private func bubbleTint(_ provider: Provider?) -> Color {
        provider == .claude ? Provider.claude.tint : .black
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func composer(viewportHeight: CGFloat) -> some View {
        VStack(spacing: 7) {
            if !model.queuedMessages.isEmpty { queueStrip }
            if !model.attachments.isEmpty { attachmentStrip }
            PromptEditor(text: $model.draft, session: model.activeSessionID, focusToken: model.focusToken, onSend: model.send, onEscape: dismiss,
                         onImages: { model.addImages($0) })
                .frame(height: model.expanded ? 65 : max(65, viewportHeight - 157 - attachmentStripHeight - (model.showsTabs ? PopupMetrics.tabBar : 0)))
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text(model.messages.isEmpty ? "Ask anything…" : model.busy ? "Queue a follow-up… · Esc stops" : "Ask a follow-up…")
                            .font(appFont(size: PopupMetrics.composerFont)).foregroundStyle(.white.opacity(0.45))
                            .padding(.leading, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 5) {
                providerPicker
                Spacer()
                if let path = AppModel.cdTarget(in: model.draft) {
                    // A harness command, not a message: say what Return will do.
                    Label(path.isEmpty ? "Return goes back to your home folder" : "Return runs this chat from “\(path)”", systemImage: "folder")
                        .font(appFont(size: 11, weight: .medium)).foregroundStyle(accent).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(accent.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(accent.opacity(0.3)))
                        .transition(.opacity)
                } else if let directory = model.directory {
                    Label(directory.lastPathComponent, systemImage: "folder")
                        .font(appFont(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .help("This chat runs from \(directory.path). Send !cd to go back to your home folder.")
                }
                if let title = AppModel.forkTitle(in: model.draft) {
                    // A harness command, not a message: say what Return will do.
                    Label(title.isEmpty ? "Return forks this chat into a new tab" : "Return forks into “\(title)”", systemImage: "arrow.triangle.branch")
                        .font(appFont(size: 11, weight: .medium)).foregroundStyle(accent).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(accent.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(accent.opacity(0.3)))
                        .transition(.opacity)
                }
                VoiceButton(voice: model.voice, tint: model.provider.tint)
                if model.busy {
                    Button(action: model.stop) {
                        Image(systemName: "stop.fill").font(appFont(size: 11)).frame(width: 30, height: 30)
                            .modifier(GlassCircle(appearance: appearance, tint: Color.white.opacity(0.12)))
                    }.buttonStyle(.plain).help("Stop response · Esc").accessibilityLabel("Stop response")
                } else {
                    Button(action: model.send) {
                        Image(systemName: "arrow.up").font(appFont(size: 14, weight: .semibold))
                            .foregroundStyle(model.canSend ? Color.black.opacity(0.8) : muted)
                            .frame(width: 30, height: 30)
                            .modifier(GlassCircle(appearance: appearance, tint: model.canSend ? model.provider.tint : Color.white.opacity(0.09)))
                    }.buttonStyle(.plain).disabled(!model.canSend).help("Send · Return").accessibilityLabel("Send")
                }
            }
        }.padding(12)
            .modifier(ComposerSurface(appearance: appearance))
            .padding(.horizontal, 16)
    }

    private var attachmentStripHeight: CGFloat { model.attachments.isEmpty ? 0 : PopupMetrics.attachmentStrip }

    /// Messages sent while the answer runs, in order; each goes when it finishes, or can be taken back.
    private var queueStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.queuedMessages) { item in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(appFont(size: 10, weight: .semibold)).foregroundStyle(accent)
                    Text(item.text.isEmpty ? "Image" : item.text.split(whereSeparator: \.isNewline).joined(separator: " "))
                        .font(appFont(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.tail)
                    if !item.attachments.isEmpty {
                        Label("\(item.attachments.count)", systemImage: "photo").font(appFont(size: 10)).foregroundStyle(muted)
                    }
                    Spacer(minLength: 4)
                    Button { model.removeQueued(item.id) } label: {
                        Image(systemName: "xmark").font(appFont(size: 8, weight: .bold)).foregroundStyle(muted).frame(width: 16, height: 16)
                    }.buttonStyle(.plain).help("Remove from queue").accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(accent.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(0.25)))
                .help("Queued · sends when this answer finishes")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    thumbnail(attachment, size: 48)
                        .overlay(alignment: .topTrailing) {
                            Button { model.removeAttachment(attachment.id) } label: {
                                Image(systemName: "xmark").font(appFont(size: 8, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 16, height: 16).background(Color.black.opacity(0.7), in: Circle())
                            }.buttonStyle(.plain).offset(x: 5, y: -5)
                                .help("Remove image").accessibilityLabel("Remove image")
                        }
                }
            }.padding(.top, 6).padding(.horizontal, 4)
        }.frame(height: PopupMetrics.attachmentStrip)
    }

    private func thumbnail(_ attachment: ImageAttachment, size: CGFloat) -> some View {
        Group {
            // Fit, not fill: a wide screenshot shows whole rather than cropped to a square.
            if let image = attachment.image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
        }
        .background(Color.white.opacity(0.08))
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.15)))
        .accessibilityLabel("Attached image, \(attachment.pixelWidth) by \(attachment.pixelHeight)")
    }

    @ViewBuilder private var providerPicker: some View {
        if #available(macOS 26.0, *), appearance.mode == .liquidGlass {
            GlassEffectContainer(spacing: 4) { providerButtons }
        } else { providerButtons }
    }

    /// The model picker: one pill for the provider in use, `✳ Claude · Opus` at rest. Under the
    /// pointer it opens out to `Claude | Opus | ▮▮▮ high`, each part a menu, on the tab strip's
    /// curves, and it stays open while one of its menus is.
    private var providerButtons: some View {
        let provider = model.provider, open = pillHovered || pillMenuOpen
        let current = model.model(for: provider), effort = model.effort(for: provider)
        let slide = AnyTransition.opacity.combined(with: .move(edge: .leading))
        return HStack(spacing: 0) {
            pillSegment("Provider", menu: providerMenu) {
                HStack(spacing: 5) {
                    Image(systemName: provider.symbol).font(appFont(size: 11))
                    Text(provider.title).font(appFont(size: 12, weight: .medium))
                    if !open && !current.isEmpty {
                        Text("· \(Self.modelName(current))").font(appFont(size: 12)).opacity(0.75).transition(slide)
                    }
                }
            }
            if open {
                Group {
                    pillDivider(provider)
                    pillSegment("Model", menu: modelMenu) {
                        Text(current.isEmpty ? "Default" : Self.modelName(current)).font(appFont(size: 12))
                    }
                    pillDivider(provider)
                    pillSegment("Effort", menu: effortMenu) {
                        HStack(spacing: 5) {
                            EffortBars(level: (provider.efforts.firstIndex(of: effort) ?? -1) + 1)
                            Text(effort.isEmpty ? "auto" : effort).font(appFont(size: 12))
                        }
                    }
                }.transition(slide)
            }
        }
        .padding(.horizontal, 2)
        .foregroundStyle(provider.labelColor)
        .modifier(GlassPill(appearance: appearance, tint: provider.tint, selected: true))
        .fixedSize()
        .background(GeometryReader { geometry in
            Color.clear.onAppear { pillFrame = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in pillFrame = frame }
        })
        // Hover reports nothing while a menu tracks, so an open menu holds the pill open.
        .onContinuousHover { phase in
            switch phase {
            case .active: if !pillHovered { withAnimation(TabStripLayout.grow) { pillHovered = true } }
            case .ended: if pillHovered && !pillMenuOpen { withAnimation(TabStripLayout.fall) { pillHovered = false } }
            }
        }
        .disabled(model.busy)
    }

    private func pillDivider(_ provider: Provider) -> some View {
        Rectangle().fill(provider.labelColor.opacity(0.25)).frame(width: 1, height: 12)
    }

    private func pillSegment<Label: View>(_ name: String, menu: @escaping () -> NSMenu, @ViewBuilder label: () -> Label) -> some View {
        Button { showPillMenu(menu()) } label: {
            label().padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).help(name).accessibilityLabel(name)
    }

    /// `popUp` returns once the menu closes, with the pick already made.
    private func showPillMenu(_ menu: NSMenu) {
        pillMenuOpen = true
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
        pillMenuOpen = false
        if !pointerOnPill { withAnimation(TabStripLayout.fall) { pillHovered = false } }
    }

    private var pointerOnPill: Bool {
        let mouse = NSEvent.mouseLocation
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(mouse) }), let content = window.contentView else { return false }
        let point = window.convertPoint(fromScreen: mouse)
        return pillFrame.contains(CGPoint(x: point.x, y: content.bounds.height - point.y))
    }

    private func providerMenu() -> NSMenu {
        PillMenu.make(Provider.allCases.map { provider in
            PillMenu.Item(provider.title, on: provider == model.provider) { model.choose(provider: provider) }
        })
    }

    private func modelMenu() -> NSMenu {
        let provider = model.provider, current = model.model(for: provider)
        return PillMenu.make([PillMenu.Item("CLI default", on: current.isEmpty) { model.choose(provider: provider, model: "") }]
            + model.models(for: provider).map { name in
                PillMenu.Item(Self.modelName(name), on: name == current) { model.choose(provider: provider, model: name) }
            })
    }

    private func effortMenu() -> NSMenu {
        let provider = model.provider, current = model.effort(for: provider)
        return PillMenu.make([PillMenu.Item("CLI default", on: current.isEmpty) { model.choose(provider: provider, effort: "") }]
            + provider.efforts.map { level in
                PillMenu.Item(level, on: level == current) { model.choose(provider: provider, effort: level) }
            })
    }

    /// `opus` reads as Opus; a full id such as `gpt-6.1-sol` stays as typed.
    static func modelName(_ model: String) -> String {
        model.contains(where: { "-.:/".contains($0) }) ? model : model.capitalized
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill((model.path(for: model.provider) == nil) ? Color.orange.opacity(0.7) : model.provider.labelColor.opacity(0.7)).frame(width: 4, height: 4)
            // The context lives in the header's menu; this line only reports what's happening.
            Text(model.status == "Ready when you are" ? "" : model.status)
                .lineLimit(1)
            Spacer(minLength: 10)
            if let link = model.lastTaskLink, let url = URL(string: link) {
                Button("Open task") { NSWorkspace.shared.open(url) }.buttonStyle(.plain).foregroundStyle(accent)
            }
            // Settings sits in the bottom-right corner; the footer shows in Settings too, so it closes it.
            Button { model.showingSettings.toggle() } label: {
                Image(systemName: "gearshape").font(appFont(size: 12)).foregroundStyle(model.showingSettings ? accent : muted)
            }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
        }.font(appFont(size: 10)).foregroundStyle(muted).padding(.leading, 23).padding(.trailing, 23).padding(.vertical, 12)
            .background(WindowDragArea())
    }

    private func proposalBinding<T>(_ key: WritableKeyPath<DelegationProposal, T>, default value: T) -> Binding<T> {
        Binding(get: { model.delegation?[keyPath: key] ?? value }, set: { model.delegation?[keyPath: key] = $0 })
    }
    private func herdrBinding<T>(_ key: WritableKeyPath<HerdrProposal, T>, default value: T) -> Binding<T> {
        Binding(get: { model.herdrProposal?[keyPath: key] ?? value }, set: { model.herdrProposal?[keyPath: key] = $0 })
    }
    private var herdrCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Continue in Herdr", systemImage: "arrow.up.forward.app").font(appFont(size: 13, weight: .semibold))
                Spacer()
                Button(model.herdrDetailsExpanded ? "Done" : "Change…") { model.herdrDetailsExpanded.toggle() }
                    .buttonStyle(.plain).font(appFont(size: 11)).foregroundStyle(muted)
                    .disabled(model.busy || model.herdrProposal?.submissionAttempted == true)
            }
            if let proposal = model.herdrProposal {
                Text(proposal.instruction).font(appFont(size: 14)).lineLimit(3).textSelection(.enabled)
                Text("\(proposal.provider.title) · \(proposal.locationLabel) · chat included")
                    .font(appFont(size: 11)).foregroundStyle(muted)
                    .help(proposal.workspace.isEmpty ? "~/Projects (no single repo named)" : proposal.workspace)
                if proposal.needsDocument {
                    Text("Which document should it update?").font(appFont(size: 12))
                    Button("Choose document…", action: model.chooseHerdrDocument).controlSize(.small)
                } else if proposal.needsTargetChoice {
                    Text("Which document or folder?").font(appFont(size: 12))
                    ForEach(Array(proposal.targetChoices.prefix(3))) { target in
                        Button((target.path as NSString).abbreviatingWithTildeInPath) { model.selectHerdrTarget(target) }
                            .font(appFont(size: 11)).lineLimit(1).truncationMode(.middle).controlSize(.small)
                    }
                    if proposal.targetChoices.count > 3 {
                        Button("Choose another…") {
                            if proposal.targetChoices.contains(where: { $0.document != nil }) { model.chooseHerdrDocument() }
                            else { model.chooseHerdrFolder() }
                        }.controlSize(.small)
                    }
                }
                if model.herdrDetailsExpanded {
                    Picker("Provider", selection: herdrBinding(\.provider, default: model.provider)) {
                        ForEach(Provider.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).font(appFont(size: 12)).accessibilityLabel("Herdr provider")
                    TextEditor(text: herdrBinding(\.instruction, default: "")).font(appFont(size: 12)).frame(height: 70)
                        .accessibilityLabel("Herdr next instruction")
                    HStack {
                        TextField("~/Projects", text: herdrBinding(\.workspace, default: ""))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Herdr working folder")
                        Button("Choose…", action: model.chooseHerdrFolder).controlSize(.small)
                    }
                    Text("\(proposal.history.count) completed messages · \(proposal.images.count) recent images. Uses your normal terminal setup and approvals. Context is saved privately on this Mac.")
                        .font(appFont(size: 11)).foregroundStyle(muted)
                }
                if proposal.submissionAttempted {
                    Text("Check Herdr before starting another transfer.").font(appFont(size: 11)).foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel", action: model.cancelHerdr).disabled(model.busy)
                    Spacer()
                    Button("Open in Herdr", action: model.confirmHerdr)
                        .disabled(model.busy || proposal.submissionAttempted || proposal.needsTargetChoice)
                }.controlSize(.small)
            }
        }.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
    }
    private var delegationPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Create a tracked task").font(appFont(size: 19, weight: .medium))
                    TextField("Task title", text: proposalBinding(\.title, default: "")).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Task title")
                    Text("Instructions and feedback").font(appFont(size: 12, weight: .medium))
                    TextEditor(text: proposalBinding(\.instructions, default: "")).font(appFont(size: 12)).frame(minHeight: 100)
                        .accessibilityLabel("Task instructions")
                    if let proposal = model.delegation {
                        Text("Source: \(proposal.snapshot?.appName ?? "General chat") · \(proposal.snapshot?.selection?.label ?? proposal.snapshot?.windowTitle ?? "Your request")")
                            .font(appFont(size: 11)).foregroundStyle(muted).textSelection(.enabled)
                        if !proposal.documentPath.isEmpty {
                            Text(proposal.documentPath).font(appFont(size: 11, design: .monospaced)).textSelection(.enabled)
                        } else {
                            Button("Choose source document…", action: model.chooseTaskDocument).controlSize(.small)
                        }
                        HStack {
                            TextField("Working folder · optional for filing", text: proposalBinding(\.workspace, default: "")).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Task working folder")
                            Button("Choose…", action: model.chooseTaskFolder).controlSize(.small)
                        }
                        Picker("After filing", selection: proposalBinding(\.mode, default: .file)) {
                            ForEach(DelegationMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).font(appFont(size: 12))
                        if proposal.mode == .background {
                            Toggle("Allow file edits and commands", isOn: proposalBinding(\.writesAllowed, default: false)).font(appFont(size: 12))
                            Text("File edits and commands require a Git workspace and CXTasks’ checkpoint checks. Its runner, pause switch, and budgets still apply. No remote writes or additional app tools are granted.")
                                .font(appFont(size: 11)).foregroundStyle(muted)
                            Toggle("Start a queue pass if the runner is off", isOn: proposalBinding(\.startQueueOnce, default: false)).font(appFont(size: 12))
                            Text("A queue pass also picks up other eligible tasks already queued in CXTasks. It does not install a recurring runner.")
                                .font(appFont(size: 11)).foregroundStyle(muted)
                        } else if proposal.mode == .herdr {
                            Text("Starts a separate Claude session using CXTasks’ existing Herdr launcher. You can track the task in CXTasks; the session is managed in Herdr.")
                                .font(appFont(size: 11)).foregroundStyle(muted)
                        }
                        if proposal.submissionAttempted {
                            Text("A handoff was attempted. Retry checks the same task and does not start a second session.").font(appFont(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }.padding(.horizontal, 22).padding(.vertical, 15)
            }.scrollIndicators(.visible)
                .disabled(model.busy || model.delegation?.submissionAttempted == true)
            HStack {
                Button("Cancel", action: model.cancelDelegation).disabled(model.busy)
                Spacer()
                Button(model.delegation?.submissionAttempted == true ? "Check same handoff" : model.delegation?.mode.action ?? "Create task", action: model.confirmDelegation).disabled(model.busy)
            }.controlSize(.small).padding(.horizontal, 22).padding(.vertical, 12)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Make yourself at home").font(appFont(size: 19, weight: .medium))
            Text("Use your existing Codex or Claude Code login.").font(appFont(size: 12)).foregroundStyle(muted)
            HStack {
                Picker("Glass style", selection: $appearance.preference) {
                    ForEach(GlassPreference.allCases) { preference in Text(preference.title).tag(preference) }
                }.pickerStyle(.menu).font(appFont(size: 12))
                Spacer()
                Text(appearance.modeTitle).font(appFont(size: 10)).foregroundStyle(muted)
            }
            VStack(spacing: 6) {
                HStack {
                    Text("Transparency").font(appFont(size: 12))
                    Spacer()
                    Text("\(Int((appearance.transparency * 100).rounded()))%")
                        .font(appFont(size: 11, design: .monospaced)).foregroundStyle(muted)
                }
                Slider(value: Binding(get: { appearance.transparency }, set: appearance.setTransparency), in: 0...1)
                    .tint(.white).disabled(appearance.reduceTransparency).accessibilityLabel("Window transparency")
                HStack { Text("Opaque"); Spacer(); Text("More glass") }.font(appFont(size: 10)).foregroundStyle(muted)
            }
            Toggle("Vault font (JetBrains Mono)", isOn: $appearance.vaultFont)
                .toggleStyle(.switch).controlSize(.small).font(appFont(size: 12))
                .help("Show the whole popup in JetBrains Mono, the Obsidian vault's font, instead of the system font")
            if appearance.mode == .liquidGlass {
                Toggle("Darker prompt box", isOn: $appearance.darkComposer)
                    .toggleStyle(.switch).controlSize(.small).font(appFont(size: 12))
                    .help("Tint the prompt box darker than the pane so typed text stays easy to read")
                Toggle("Clear glass, frosted prompt box", isOn: $appearance.clearPane)
                    .toggleStyle(.switch).controlSize(.small).font(appFont(size: 12))
                    .help("Keep clear glass with full edge lensing and frost only the prompt box, instead of frosting the whole pane")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Screen context").font(appFont(size: 13, weight: .semibold))
                Picker("Routing service", selection: $model.routingEngine) {
                    Text("Luna Decisions").tag("decisions")
                    Text("Jev").tag("jev")
                    Text("Off").tag(RoutingEngine.offTag)
                }.pickerStyle(.menu).font(appFont(size: 12))
                Text(model.routingEngine == RoutingEngine.offTag
                     ? "Routing is off: Auto sends nothing to a routing service and includes the front window’s content read-only for the model to use or ignore. Pick General chat or My setup from the menu when you don’t want it."
                     : "Auto sends your question and the selected app’s labels to the routing service. General chat skips screen context. Keys use OPENAI_API_KEY or TYPESAFE_API_KEY from the environment or login Keychain (cx-secret).")
                    .font(appFont(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                Text("Routing \"yes\" bar: \(Int(model.routingThreshold * 100))% · provisional until evaluated")
                    .font(appFont(size: 11)).foregroundStyle(muted)
                Slider(value: $model.routingThreshold, in: 0.70...0.99, step: 0.01)
                    .accessibilityLabel("Minimum routing confidence")
                TextField("CXMail MCP path · bundled app default", text: $model.cxmailMCPPath)
                    .textFieldStyle(.roundedBorder).font(appFont(size: 12))
                TextField("CXTasks MCP path · bundled app default", text: $model.cxtasksMCPPath)
                    .textFieldStyle(.roundedBorder).font(appFont(size: 12))
                TextField("Meeting Copilot MCP path · ~/Projects/meeting-copilot default", text: $model.meetingcopilotMCPPath)
                    .textFieldStyle(.roundedBorder).font(appFont(size: 12))
                if let milliseconds = model.routingMilliseconds, model.routingEngine != RoutingEngine.offTag {
                    Text("Last routing check: \(milliseconds) ms").font(appFont(size: 11)).foregroundStyle(muted)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Flag chats still on me (Jev)", isOn: $model.followUpCheck)
                    .toggleStyle(.switch).controlSize(.small).font(appFont(size: 12))
                Text("After each answer, sends the text of your last question and the answer, never images or screen context, to Jev with TYPESAFE_API_KEY. If you still owe a next step, the chat gets a blue ring in Recent chats. Right-click a chat to change it.")
                    .font(appFont(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach([Provider.codex, .claude]) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(provider.title).font(appFont(size: 13, weight: .semibold))
                        Spacer()
                        Text(model.path(for: provider) == nil ? "CLI not found" : "CLI found")
                            .font(appFont(size: 10)).foregroundStyle(model.path(for: provider) == nil ? Color.orange : accent)
                    }
                    TextField("Executable path · auto-detect", text: provider == .codex ? $model.codexPath : $model.claudePath)
                        .textFieldStyle(.roundedBorder).font(appFont(size: 12))
                        .accessibilityLabel("\(provider.title) executable path")
                    TextField("Model · CLI default", text: provider == .codex ? $model.codexModel : $model.claudeModel)
                        .textFieldStyle(.roundedBorder).font(appFont(size: 12))
                        .accessibilityLabel("\(provider.title) model")
                    TextField("Pill models · comma-separated · \(provider.defaultModels.joined(separator: ", "))",
                              text: provider == .codex ? $model.codexModelList : $model.claudeModelList)
                        .textFieldStyle(.roundedBorder).font(appFont(size: 12))
                        .accessibilityLabel("\(provider.title) models in the picker")
                }
            }
            Toggle("Use ⌥ ⇧ Space instead", isOn: $model.alternativeHotkey).font(appFont(size: 12))
            Toggle("Open at login", isOn: $model.openAtLogin).font(appFont(size: 12))
            HStack {
                Button("Enable Accessibility", action: model.requestAccessibility)
                Button("Enable Screen Recording", action: model.requestScreenRecording)
            }.controlSize(.small).font(appFont(size: 11))
            Text("Control app sends the selected app’s interface and requested screenshots to your chosen provider. It can click, type, press keys, and scroll. Use ⌥ Esc to stop.")
                .font(appFont(size: 11)).foregroundStyle(muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Text("Chats stay in memory until you quit or start a new chat, and a new chat starts when you summon QuickAsk after 10 minutes away. Switching providers sends this chat’s completed messages to the selected provider.")
                .font(appFont(size: 11)).foregroundStyle(muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                settings.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)
            HStack {
                Spacer()
                Button("Done") { model.showingSettings = false; model.focusToken += 1 }
                    .buttonStyle(.bordered).controlSize(.small)
            }.padding(.horizontal, 22).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptScrollUpdate: Equatable {
    let session: UUID
    let count: Int
    let lastMessage: UUID?
    let text: String?
    let cards: Int
    let proposal: UUID?
    let details: Bool

    init(session: UUID, messages: [ChatMessage], proposal: UUID?, details: Bool) {
        self.session = session; count = messages.count
        lastMessage = messages.last?.id; text = messages.last?.text
        cards = messages.last?.cards.count ?? 0
        self.proposal = proposal; self.details = details
    }
}

/// Watches the transcript's scroll view and reports whether any of it lies below the visible
/// area, on scrolling (the clip view's origin moves) and on text arriving (the document grows).
struct TranscriptFollow: NSViewRepresentable {
    /// Distance from the bottom, in points, that still counts as "at the bottom".
    static let slack: CGFloat = 24
    let report: (Bool) -> Void

    static func moreBelow(distanceFromBottom distance: CGFloat) -> Bool { distance > slack }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.report = report }

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        private weak var clip: NSClipView?
        private var moreBelow = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            self.clip = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(measure), name: NSView.boundsDidChangeNotification, object: clip)
            if let document = clip.documentView {
                document.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(measure), name: NSView.frameDidChangeNotification, object: document)
            }
            measure()
        }

        // The probe backs the transcript stack, so it grows as streamed text arrives.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            measure()
        }

        @objc private func measure() {
            guard let clip, let document = clip.documentView else { return }
            let visible = clip.documentVisibleRect
            let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            let next = TranscriptFollow.moreBelow(distanceFromBottom: distance)
            guard next != moreBelow else { return }
            moreBelow = next
            // Out of AppKit's scroll and layout handling, which can run inside a SwiftUI update.
            DispatchQueue.main.async { [weak self] in self?.report?(next) }
        }
    }
}

/// The composer's ⌘Z history, one per chat, so switching tabs neither mixes nor loses it.
@MainActor final class ComposerUndo {
    static let kept = 20
    private var managers: [UUID: UndoManager] = [:]
    /// The draft each chat had when the composer left it. A draft changed while away (a failed
    /// question put back into a background tab) would replay its steps at stale ranges.
    private var leftWith: [UUID: String] = [:]
    private var recent: [UUID] = []
    private(set) var session: UUID?

    var current: UndoManager? { session.flatMap { managers[$0] } }

    /// Puts `text` in the editor for `session`. Within a chat, a replacement the app makes
    /// (a send, a !cd, a draft put back) is one undo step, so ⌘Z after sending brings the
    /// draft back; across chats, the text is swapped without a step and each keeps its own history.
    func show(_ text: String, for session: UUID, in editor: NSTextView) {
        if session != self.session {
            if let left = self.session { leftWith[left] = editor.string }
            self.session = session
            if managers[session] == nil || leftWith[session] != text { managers[session] = UndoManager() }
            recent.removeAll { $0 == session }; recent.append(session)
            while recent.count > Self.kept { let old = recent.removeFirst(); managers[old] = nil; leftWith[old] = nil }
            if editor.string != text { editor.string = text; editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
        } else if editor.string != text {
            let whole = NSRange(location: 0, length: (editor.string as NSString).length)
            editor.breakUndoCoalescing()
            if editor.shouldChangeText(in: whole, replacementString: text) {
                editor.replaceCharacters(in: whole, with: text); editor.didChangeText()
            }
            editor.breakUndoCoalescing()
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }
}

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    let session: UUID
    let focusToken: Int
    let onSend: () -> Void
    let onEscape: () -> Void
    var onImages: ([ImageAttachment]) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = ComposerTextView()
        editor.delegate = context.coordinator
        editor.drawsBackground = false
        editor.isRichText = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.font = appNSFont(size: PopupMetrics.composerFont)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.textContainerInset = NSSize(width: 2, height: 7)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 3
        editor.onSend = onSend; editor.onEscape = onEscape; editor.onImages = onImages
        editor.registerForDraggedTypes(editor.registeredDraggedTypes + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) })
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        if editor.string != text || context.coordinator.undo.session != session {
            context.coordinator.applying = true
            context.coordinator.undo.show(text, for: session, in: editor)
            context.coordinator.applying = false
            editor.refreshCommand()
        }
        editor.onSend = onSend; editor.onEscape = onEscape; editor.onImages = onImages
        if editor.font != appNSFont(size: PopupMetrics.composerFont) { editor.font = appNSFont(size: PopupMetrics.composerFont) }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var lastFocusToken = -1
        let undo = ComposerUndo()
        /// Set while the app's own text goes in, which the binding already holds.
        var applying = false
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if !applying, let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        func undoManager(for view: NSTextView) -> UndoManager? { undo.current }
    }
}

/// Onyx's tab strip. At rest the pills share it, 180 pt each at most and 88 at least; past
/// what fits at 88, the pills furthest from the active one are left out (the ⌄ list has them).
/// The pill under the pointer widens toward its full title, 360 pt at most, and the others give
/// it the room equally, down to their floor, so the strip itself never changes width.
struct TabStripLayout: Layout {
    static let rest: CGFloat = 180, floor: CGFloat = 88, widest: CGFloat = 360
    /// Widening is quick; falling back is slower, as in Onyx.
    static let grow = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)
    static let fall = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.32)
    var active: Int
    var hovered: Int?
    var spacing: CGFloat = 2

    /// Each pill's width, or nil for one left out. `natural` is the hovered pill's full width.
    static func widths(count: Int, active: Int, hovered: Int?, natural: CGFloat?, available: CGFloat, spacing: CGFloat = 2) -> [CGFloat?] {
        guard count > 0 else { return [] }
        let fits = max(1, Int((available + spacing) / (floor + spacing)))
        let shown = min(count, fits)
        let low = max(0, min(active - shown / 2, count - shown))
        let visible = low..<(low + shown)
        let room = available - spacing * CGFloat(shown - 1)
        let rest = max(floor, min(Self.rest, room / CGFloat(shown)))
        var widths = [CGFloat?](repeating: nil, count: count)
        for index in visible { widths[index] = rest }
        guard let hovered, let natural, visible.contains(hovered), shown > 1 else { return widths }
        let want = min(widest, natural, rest * CGFloat(shown) - CGFloat(shown - 1) * floor)
        guard want > rest + 1 else { return widths }
        let each = (want - rest) / CGFloat(shown - 1)
        for index in visible { widths[index] = index == hovered ? want : rest - each }
        return widths
    }

    private func widths(available: CGFloat, subviews: Subviews) -> [CGFloat?] {
        let natural = hovered.flatMap { $0 < subviews.count ? subviews[$0].sizeThatFits(.unspecified).width : nil }
        return Self.widths(count: subviews.count, active: active, hovered: hovered, natural: natural, available: available, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(subviews.count) * (Self.rest + spacing)
        let shown = widths(available: available, subviews: subviews).compactMap { $0 }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: shown.reduce(0, +) + spacing * CGFloat(max(0, shown.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(available: bounds.width, subviews: subviews)) {
            guard let width else {
                // Left out: placed well past the strip, which clips it.
                subview.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.midY), anchor: .leading, proposal: .init(width: Self.floor, height: bounds.height))
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .init(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// A pill's title: cut with an ellipsis at rest. Hovered and still cut once its pill has grown,
/// it rolls to its end and back, holding at each end, paced by how much is hidden.
private struct TabTitle: View {
    let text: String
    let font: Font
    let truncation: Text.TruncationMode
    let rolling: Bool
    @State private var natural: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var armed = false

    var body: some View {
        let over = natural - width
        ZStack(alignment: .leading) {
            if rolling && armed && over > 1 {
                let distance = over + 4, cycle = max(2.5, Double(over) / 30 + 1.5)
                Text(text).font(font).fixedSize()
                    .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { content, x in content.offset(x: x) } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(0, duration: cycle * 0.18)
                            CubicKeyframe(-distance, duration: cycle * 0.64)
                            LinearKeyframe(-distance, duration: cycle * 0.36)
                            CubicKeyframe(0, duration: cycle * 0.64)
                            LinearKeyframe(0, duration: cycle * 0.18)
                        }
                    }
            } else {
                Text(text).font(font).lineLimit(1).truncationMode(truncation)
            }
        }
        // minWidth 0: without it the frame grows to a rolling title's full width instead of the pill's.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(alignment: .leading) {
            Text(text).font(font).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 }
        }
        // Rolling starts once the pill has finished growing, so it measures the room it ends with.
        .task(id: rolling) {
            guard rolling else { armed = false; return }
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { armed = true }
        }
    }
}

private struct TabFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

enum PopupMetrics {
    /// Height the composer's image strip adds; the compact popup grows by this much.
    static let attachmentStrip: CGFloat = 60
    static let tabBarHeight: CGFloat = 40
    /// The header sits this much closer to the top under the tab bar.
    static let headerInsetUnderTabs: CGFloat = 8
    /// Height the tab bar adds; the compact popup grows by this much.
    static let tabBar: CGFloat = tabBarHeight - headerInsetUnderTabs
    /// The composer types at the size replies read at, so the prompt and the answer match.
    static let composerFont: CGFloat = 14
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    var onImages: (([ImageAttachment]) -> Bool)?
    static let commandColor = NSColor(red: 0.76, green: 0.89, blue: 0.79, alpha: 1)

    /// Commands the composer completes after "/", in the order a bare "/" offers them.
    nonisolated static let commands = ["/truthcheck", "/fork", "!cd"]

    /// Where the command sits when the draft is one (the same tests send uses), so it can be
    /// drawn as a command rather than as words to the model.
    nonisolated static func commandRange(in text: String) -> NSRange? {
        guard AppModel.forkTitle(in: text) != nil || AppModel.truthTarget(in: text) != nil || AppModel.cdTarget(in: text) != nil else { return nil }
        let leading = text.prefix { $0.isWhitespace }
        let name = text.dropFirst(leading.count).prefix { !$0.isWhitespace }
        return NSRange(location: leading.utf16.count, length: name.utf16.count)
    }

    /// The rest of the command a draft of just "/…" is heading for ("/tr" → "uthcheck"),
    /// drawn faintly after the cursor; Tab takes it.
    nonisolated static func completion(for text: String) -> String? {
        guard text.hasPrefix("/") || text.hasPrefix("!"), !text.contains(where: \.isWhitespace) else { return nil }
        let typed = text.lowercased()
        guard let match = commands.first(where: { $0.hasPrefix(typed) && $0 != typed }) else { return nil }
        return String(match.dropFirst(typed.count))
    }
    private var pendingCompletion: String? {
        selectedRange() == NSRange(location: (string as NSString).length, length: 0) && !hasMarkedText() ? Self.completion(for: string) : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let suffix = pendingCompletion, let layoutManager, let textContainer, let font else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: (string as NSString).length), actualCharacterRange: nil)
        let typed = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let origin = NSPoint(x: typed.maxX + textContainerOrigin.x, y: typed.minY + textContainerOrigin.y)
        (suffix as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    }
    private var commandRange: NSRange?

    /// Tints the command through temporary attributes, which are display-only, so the color
    /// never carries into what is typed after it.
    func refreshCommand() {
        let range = Self.commandRange(in: string)
        guard range != commandRange else { return }
        commandRange = range
        if let layoutManager {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (string as NSString).length))
            if let range { layoutManager.addTemporaryAttribute(.foregroundColor, value: Self.commandColor, forCharacterRange: range) }
        }
        needsDisplay = true
    }
    override func didChangeText() {
        super.didChangeText()
        refreshCommand()
        needsDisplay = true
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let range = commandRange, let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -3, dy: 1)
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        Self.commandColor.withAlphaComponent(0.16).setFill(); pill.fill()
        Self.commandColor.withAlphaComponent(0.45).setStroke(); pill.lineWidth = 1; pill.stroke()
    }
    // Images become attachments; everything else keeps the plain-text behavior.
    override func paste(_ sender: Any?) {
        if onImages?(ImageAttachment.read(from: .general)) == true { return }
        super.paste(sender)
    }
    // A plain-text view disables Paste (and so ⌘V) when the clipboard holds only an image.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onImages != nil, ImageAttachment.available(on: .general) { return true }
        return super.validateUserInterfaceItem(item)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageAttachment.available(on: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageAttachment.available(on: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if ImageAttachment.available(on: sender.draggingPasteboard),
           onImages?(ImageAttachment.read(from: sender.draggingPasteboard)) == true { return true }
        return super.performDragOperation(sender)
    }
    override func keyDown(with event: NSEvent) {
        // Preserve IME composition: Return confirms marked text before sending.
        if (event.keyCode == 36 || event.keyCode == 76), !event.modifierFlags.contains(.shift), !hasMarkedText() {
            onSend?(); return
        }
        if event.keyCode == 53, !hasMarkedText() { onEscape?(); return }
        if event.keyCode == 48, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty, let suffix = pendingCompletion {
            insertText(suffix + " ", replacementRange: selectedRange()); return
        }
        super.keyDown(with: event)
    }
}

/// Five rising bars, filled to the effort level (0 is the CLI default).
private struct EffortBars: View {
    let level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...5, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1).frame(width: 2.5, height: 4 + CGFloat(bar) * 1.6).opacity(bar <= level ? 1 : 0.25)
            }
        }.frame(height: 12, alignment: .bottom)
    }
}

/// An AppKit menu for the model pill: it keeps its own look, and `popUp` reports when it closes.
enum PillMenu {
    final class Item: NSMenuItem {
        private let handler: () -> Void
        init(_ title: String, on: Bool, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self; state = on ? .on : .off
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is unused") }
        @objc private func run() { handler() }
    }
    static func make(_ items: [Item]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }
}

/// A recent-chats row: neutral text that never recolours, and a gray rounded fill on hover.
/// A dot and a word beside the time say whether the chat still needs you; a chat with
/// neither is done, and its title dims a little.
private struct HistoryRow: View {
    let chat: ChatHistory.Summary
    let mark: ChatHistory.Mark?
    let action: () -> Void
    let toggleStillOnMe: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(mark: mark).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.title).font(appFont(size: 13)).foregroundStyle(.white.opacity(mark == nil ? 0.7 : 0.92))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 0) {
                        if let mark {
                            Text(mark.label).font(appFont(size: 11, weight: .medium)).foregroundStyle(StatusDot.color(mark))
                            Text(" · ").font(appFont(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                        Text(chat.updated, format: .relative(presentation: .named)).font(appFont(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(hovered ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(mark == .stillOnMe ? "Clear Still on Me" : "Still on Me", action: toggleStillOnMe)
        }
        .accessibilityLabel(mark.map { "\(chat.title), \($0.label)" } ?? chat.title)
    }
}

/// The 7pt dot before a history title: red needs you, blue unread, a blue ring still on
/// you, a pulsing green while it works. A done chat keeps the space empty so titles align.
private struct StatusDot: View {
    let mark: ChatHistory.Mark?
    @State private var dim = false

    static func color(_ mark: ChatHistory.Mark) -> Color {
        switch mark {
        case .needsYou: Color(red: 0.90, green: 0.45, blue: 0.42)
        case .unread, .stillOnMe: Color(red: 0.48, green: 0.65, blue: 0.91)
        case .working: accent
        }
    }

    var body: some View {
        Group {
            switch mark {
            case nil: Color.clear
            case .stillOnMe: Circle().strokeBorder(Self.color(.stillOnMe), lineWidth: 1.5)
            case .working:
                Circle().fill(accent).opacity(dim ? 0.25 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: dim)
                    .onAppear { dim = true }
            case let mark?: Circle().fill(Self.color(mark))
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// A plain popover row: soft gray pill on hover, muted and inert when disabled.
private struct MenuRow: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).font(appFont(size: 13)).foregroundStyle(.white.opacity(enabled ? 0.92 : 0.35))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(hovered && enabled ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
    }
}

/// What a reply's permission check refused, verbatim, and the one click that approves it.
struct BlockedActionsCard: View {
    let actions: [String]
    let disabled: Bool
    let approve: () -> Void

    var body: some View {
        let one = actions.count == 1
        VStack(alignment: .leading, spacing: 10) {
            Label(one ? "Claude’s permission check blocked this" : "Claude’s permission check blocked these",
                  systemImage: "hand.raised").font(appFont(size: 13, weight: .semibold))
            ForEach(Array(actions.prefix(4).enumerated()), id: \.offset) { _, action in
                Text(action).font(appFont(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(6).truncationMode(.tail).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            if actions.count > 4 { Text("and \(actions.count - 4) more").font(appFont(size: 11)).foregroundStyle(muted) }
            HStack {
                Text("Approving sends a message naming \(one ? "it" : "them"), and Claude runs \(one ? "it" : "them") again.")
                    .font(appFont(size: 11)).foregroundStyle(muted)
                Spacer()
                Button("Approve & retry", action: approve).disabled(disabled)
            }.controlSize(.small)
        }.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
    }
}
