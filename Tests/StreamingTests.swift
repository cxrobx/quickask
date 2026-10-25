import AppKit
import SwiftUI

/// Streaming pace (T295) and transcript follow (T294): the pacer on its own, the model
/// against a fake Claude CLI that streams in bursts and stalls, and the real transcript.
@MainActor
func verifyStreaming(check: (Bool, String) -> Void) throws {
    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // The pacer: bursts spread over ticks, revisions cut back, graphemes kept whole.
    var reveal = StreamReveal()
    reveal.receive(String(repeating: "word ", count: 20))
    var steps: [Int] = []
    var last = 0
    while let shown = reveal.step() { steps.append(shown.count - last); last = shown.count }
    check(reveal.shown == String(repeating: "word ", count: 20), "Pacer reveals the whole burst exactly")
    check(steps.count >= 8 && steps.max()! <= 20, "A 100-character burst is spread over several ticks")
    reveal = StreamReveal()
    reveal.receive("Hello wor")
    while reveal.step() != nil {}
    reveal.receive("Hello world, again")
    _ = reveal.step()
    check(reveal.shown.hasPrefix("Hello wor") && reveal.shown.count > 9, "Appended text continues from what is showing")
    reveal.receive("Final answer")
    check(reveal.shownCount == 0 || "Final answer".hasPrefix(reveal.shown), "A revised answer cuts back to what still matches")
    reveal.finish()
    while reveal.step() != nil {}
    check(reveal.shown == "Final answer", "A revised answer ends exactly on the final text")
    reveal = StreamReveal()
    reveal.receive("Family 👨")
    while reveal.step() != nil {}
    reveal.receive("Family 👨\u{200D}👩\u{200D}👧 café")
    while reveal.step() != nil {}
    check(reveal.shown == "Family 👨\u{200D}👩\u{200D}👧 café" && reveal.shown.unicodeScalars.elementsEqual("Family 👨\u{200D}👩\u{200D}👧 café".unicodeScalars),
          "A grapheme that grows across deltas ends byte-exact")

    check(!TranscriptFollow.moreBelow(distanceFromBottom: 0), "At the bottom, nothing is below")
    check(!TranscriptFollow.moreBelow(distanceFromBottom: 20), "Within the slack still counts as the bottom")
    check(TranscriptFollow.moreBelow(distanceFromBottom: 300), "Text off the bottom is below")

    // A fake Claude CLI: 4 bursts of 6 deltas, 0.4 s apart, with Unicode split across deltas.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-stream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var deltas: [String] = []
    for burst in 0..<4 {
        for item in 0..<6 { deltas.append("Burst \(burst) part \(item) has words. ") }
        deltas.append(burst == 1 ? "**bold** 👨" : "")
        deltas.append(burst == 1 ? "\u{200D}👩\u{200D}👧 café\n\n" : "")
    }
    deltas.removeAll(where: \.isEmpty)
    let full = deltas.joined()
    func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func script(name: String, gap: Double, perBurst: Int) throws -> String {
        var body = "#!/bin/sh\ncat >/dev/null\n"
        body += "printf '%s\\n' '\(line(["type": "system", "subtype": "init"]))'\n"
        for (index, delta) in deltas.enumerated() {
            let event = line(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": delta]]])
            body += "printf '%s\\n' '\(event.replacingOccurrences(of: "'", with: "'\\''"))'\n"
            if (index + 1) % perBurst == 0 { body += "sleep \(gap)\n" }
        }
        body += "printf '%s\\n' '\(line(["type": "result", "is_error": false, "result": full]).replacingOccurrences(of: "'", with: "'\\''"))'\n"
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    let suite = "QuickAsk-streaming-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences)
    model.provider = .claude
    model.selectContext(.general)
    model.claudePath = try script(name: "bursty", gap: 0.4, perBurst: 7)
    model.draft = "Stream something"
    let started = Date()
    model.send()
    var samples: [(TimeInterval, Int)] = []
    var lastCount = 0
    while model.busy && Date().timeIntervalSince(started) < 10 {
        pump(0.005)
        let count = model.messages.last?.role == "assistant" ? model.messages.last!.text.count : 0
        if count != lastCount { samples.append((Date().timeIntervalSince(started), count - lastCount)); lastCount = count }
    }
    let answer = model.messages.last
    check(answer?.text == full && answer?.complete == true && !model.busy, "Paced answer completes with the exact streamed text")
    check(answer.map { $0.text.unicodeScalars.elementsEqual(full.unicodeScalars) } == true, "Paced answer keeps Markdown and Unicode byte-exact")
    let biggest = samples.map(\.1).max() ?? 0
    check(biggest < 60, "No burst lands at once (largest visible step \(biggest) of \(full.count) characters)")
    check(samples.count > 40, "Text arrives in many small steps (\(samples.count) updates for 4 bursts)")
    // Each 0.4 s stall should be eased into rather than landing as one jump and a dead stop.
    let intervals = zip(samples.dropFirst(), samples).map { $0.0 - $1.0 }
    check((intervals.max() ?? 1) < 0.35, "Reveal keeps moving through most of each upstream stall (longest still \(String(format: "%.2f", intervals.max() ?? 1)) s)")
    check(Date().timeIntervalSince(started) < 1.2 + 1.0, "Pacing adds at most a fraction of a second to completion")

    // Stop mid-reveal: the queued text is dropped and what shows stays as it is.
    model.claudePath = try script(name: "slow", gap: 0.3, perBurst: 7)
    model.draft = "Stream again"
    let firstReplyID = model.messages.last?.id
    model.send()
    let second = Date()
    while (model.messages.last?.id == firstReplyID || model.messages.last?.role != "assistant" || (model.messages.last?.text.count ?? 0) < 40)
        && Date().timeIntervalSince(second) < 5 { pump(0.005) }
    check(model.messages.last?.id != firstReplyID && model.messages.last?.role == "assistant" && model.busy,
          "Stop test reaches its own streaming reply")
    model.stop()
    let stoppedText = model.messages.last?.text ?? ""
    pump(0.6)
    check(!stoppedText.isEmpty && model.messages.last?.text == stoppedText && full.hasPrefix(stoppedText),
          "Stop freezes the partial answer at what was showing")
    check(model.messages.last?.complete == false && !model.busy, "A stopped answer stays marked partial")

    // Return mid-answer queues; both queued messages go as one turn once the answer finishes.
    func waitForStreaming(after replyID: UUID?, _ label: String) {
        let start = Date()
        while (model.messages.last?.id == replyID || model.messages.last?.role != "assistant" || (model.messages.last?.text.count ?? 0) < 20)
            && Date().timeIntervalSince(start) < 5 { pump(0.005) }
        check(model.busy && model.canQueue == false && model.messages.last?.role == "assistant", label)
    }
    model.draft = "Answer slowly"
    var replyID = model.messages.last?.id
    model.send()
    waitForStreaming(after: replyID, "Queue test reaches its own streaming reply")
    model.draft = "First follow-up"
    check(model.canQueue, "A draft typed mid-answer can be queued")
    model.send()
    model.draft = "Second follow-up"; model.send()
    check(model.draft.isEmpty && model.queuedMessages.map(\.text) == ["First follow-up", "Second follow-up"] && model.busy,
          "Return mid-answer queues the draft and leaves the answer running")
    let queuedStart = Date()
    while model.messages.filter({ $0.role == "user" }).last?.text != "First follow-up\n\nSecond follow-up" && Date().timeIntervalSince(queuedStart) < 10 { pump(0.01) }
    check(model.queuedMessages.isEmpty && model.messages.filter { $0.role == "user" }.last?.text == "First follow-up\n\nSecond follow-up",
          "Queued messages go as one message when the answer finishes")
    while model.busy && Date().timeIntervalSince(queuedStart) < 10 { pump(0.01) }
    check(model.messages.last?.text == full && model.messages.last?.complete == true, "The queued message gets its own complete answer")

    // Stop (what Esc does mid-answer) hands the queue back to the draft instead of sending it.
    model.draft = "Answer slowly again"
    replyID = model.messages.last?.id
    model.send()
    waitForStreaming(after: replyID, "Stop-queue test reaches its own streaming reply")
    model.draft = "Never mind this"; model.send()
    model.draft = "and this"
    model.stop()
    pump(0.3)
    check(!model.busy && model.queuedMessages.isEmpty && model.draft == "Never mind this\n\nand this",
          "Stop puts queued messages back in the draft, ahead of what was being typed")
    model.draft = ""

    // A new chat mid-stream drops the reveal; nothing lands in the new chat.
    model.draft = "Stream a third time"
    let secondReplyID = model.messages.last?.id
    model.send()
    let third = Date()
    while (model.messages.last?.id == secondReplyID || model.messages.last?.role != "assistant" || (model.messages.last?.text.count ?? 0) < 20)
        && Date().timeIntervalSince(third) < 5 { pump(0.005) }
    check(model.messages.last?.id != secondReplyID && model.messages.last?.role == "assistant" && model.busy,
          "New-chat test reaches its own streaming reply")
    model.newChat()
    pump(0.6)
    check(model.messages.isEmpty && !model.busy, "A chat change stops the queued reveal")

    // Another tab mid-stream: the answer finishes in its own tab and nothing lands in the new one.
    model.draft = "Stream in the background"
    model.send()
    let answering = model.activeSessionID, fourth = Date()
    while (model.messages.last?.role != "assistant" || (model.messages.last?.text.count ?? 0) < 20) && Date().timeIntervalSince(fourth) < 5 { pump(0.005) }
    model.draft = "typed meanwhile"; model.newTab()
    check(model.activeSessionID != answering && !model.busy && model.anyBusy && model.messages.isEmpty, "A new tab comes forward while the answer runs, free to send")
    // Both tabs answer at once, each into its own chat.
    model.draft = "A second chat at once"
    model.send()
    let parallel = model.activeSessionID
    while model.messages.isEmpty && Date().timeIntervalSince(fourth) < 5 { pump(0.005) }
    check(model.busy && model.messages.first?.text == "A second chat at once", "A new tab sends while another tab is still answering")
    while model.anyBusy && Date().timeIntervalSince(fourth) < 10 { pump(0.01) }
    check(model.messages.count == 2 && model.messages.last?.text == full && model.messages.last?.complete == true && !model.anyBusy,
          "The second tab's answer completes in its own tab")
    model.selectSession(answering)
    check(model.messages.last?.text == full && model.messages.last?.complete == true && model.draft == "typed meanwhile"
          && model.messages.filter { $0.role == "user" }.map(\.text) == ["Stream in the background"], "The first tab holds only its own complete answer and its draft")

    // Stopping one tab leaves the other answering.
    model.draft = "Slow one"; model.send()
    let slowStart = Date()
    while model.messages.last?.role != "assistant" || model.messages.last?.complete == true, Date().timeIntervalSince(slowStart) < 5 { pump(0.005) }
    model.selectSession(parallel)
    model.draft = "Slow two"; model.send()
    let fifth = Date()
    while (model.messages.count < 4 || (model.messages.last?.text.count ?? 0) < 20) && Date().timeIntervalSince(fifth) < 5 { pump(0.005) }
    model.stop()
    check(!model.busy && model.anyBusy && model.messages.last?.complete == false, "Stop ends only the tab showing")
    while model.anyBusy && Date().timeIntervalSince(fifth) < 10 { pump(0.01) }
    model.selectSession(answering)
    check(model.messages.last?.text == full && model.messages.last?.complete == true, "The other tab's answer finishes after the stop")

    // A tab brought forward before routing finishes: the question still routes and answers in the tab it was sent from.
    model.draft = "Routed in the background"; model.send()
    model.newTab()
    check(!model.busy && model.anyBusy && model.messages.isEmpty && model.draft.isEmpty, "A new tab comes forward before the question has routed")
    let sixth = Date()
    while model.anyBusy && Date().timeIntervalSince(sixth) < 10 { pump(0.01) }
    check(model.messages.isEmpty, "Routing in another tab writes nothing into the tab showing")
    model.selectSession(answering)
    check(model.messages.filter { $0.role == "user" }.last?.text == "Routed in the background" && model.messages.last?.text == full
          && model.messages.last?.complete == true && model.draft.isEmpty, "The question routes from its own tab's saved draft and answers there")

    // Only one tab drives an app at a time.
    let control = AppModel(preferences: preferences)
    control.messages = [.init(role: "user", text: "Drive the app")]
    control.controlEnabled = true; control.busy = true
    control.newTab()
    control.draft = "Drive it from here too"
    control.send()
    check(!control.busy && control.messages.isEmpty && control.status.contains("Another tab is controlling"), "A second app-control request waits for the first")
    control.stopAll()
    check(!control.anyBusy, "Quitting stops every tab's request")

    try verifyTranscriptFollow(check: check, pump: pump, deltas: deltas)
}

/// The real transcript in a hidden window: streamed text never moves the reader, whether
/// they sit at the bottom or have scrolled up; sending a message brings the bottom back.
@MainActor
private func verifyTranscriptFollow(check: (Bool, String) -> Void, pump: (TimeInterval) -> Void, deltas: [String]) throws {
    let suite = "QuickAsk-follow-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let model = AppModel(preferences: preferences)
    let appearance = GlassAppearance(preferences: preferences)
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 559, height: 586), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSHostingView(rootView: PopupView(model: model, appearance: appearance, dismiss: {}, resize: {}, changeHotkey: {}))
    content.sizingOptions = []
    window.contentView = content
    defer { window.orderOut(nil) }
    func settle() { for _ in 0..<4 { content.layoutSubtreeIfNeeded(); pump(0.03) } }

    for _ in 0..<4 {
        model.messages.append(.init(role: "user", text: "A question"))
        model.messages.append(.init(role: "assistant", text: String(repeating: "A long earlier answer line that wraps. ", count: 30), provider: .claude))
    }
    model.messages.append(.init(role: "user", text: "Stream please"))
    model.messages.append(.init(role: "assistant", text: "Start. ", provider: .claude, complete: false))
    settle(); pump(0.1); settle()

    func scrollViews(_ view: NSView) -> [NSScrollView] {
        let own: [NSScrollView] = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews)
    }
    guard let scroll = scrollViews(content).filter({ !($0.documentView is NSTextView) })
        .max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
          let document = scroll.documentView else { check(false, "Transcript scroll view exists"); return }
    let clip = scroll.contentView
    func distance() -> CGFloat {
        let visible = clip.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }
    func append(_ text: String) {
        model.messages[model.messages.count - 1].text += text
        settle()
    }
    func scrollTo(fromBottom offset: CGFloat) {
        let height = document.bounds.height - clip.bounds.height
        let y = document.isFlipped ? height - offset : offset
        clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(clip)
        pump(0.05)
    }
    check(document.bounds.height > clip.bounds.height * 2, "Transcript fixture is taller than the viewport")
    check(distance() <= 2, "Opening the chat starts at the newest text")
    scrollTo(fromBottom: 0)
    let atBottom = clip.bounds.origin.y
    for delta in deltas.prefix(12) { append(delta + String(repeating: " more words that wrap", count: 6)) }
    pump(0.1); settle()
    check(abs(clip.bounds.origin.y - atBottom) < 1, "From the bottom, streamed text doesn't drag the reader down (moved \(Int(abs(clip.bounds.origin.y - atBottom))) pt)")
    check(distance() > TranscriptFollow.slack, "The answer grows below the reader, so the pill has something to offer")

    scrollTo(fromBottom: 400)
    let held = clip.bounds.origin.y
    for delta in deltas.dropFirst(12) { append(delta) }
    pump(0.1); settle()
    check(abs(clip.bounds.origin.y - held) < 1, "After scrolling up, streamed text doesn't move the reader (moved \(Int(abs(clip.bounds.origin.y - held))) pt)")
    check(distance() > 400, "New text keeps arriving below the reader")

    scrollTo(fromBottom: 400)
    model.messages.append(.init(role: "user", text: "Another question"))
    settle(); pump(0.1); settle()
    check(distance() <= 2, "Sending a message brings the newest text back into view")

    // Spares: the popup opening launches them, and the question goes to the waiting one.
    let warmDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk-warm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: warmDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: warmDirectory) }
    let launches = warmDirectory.appendingPathComponent("warm-launches")
    let warmCLI = warmDirectory.appendingPathComponent("warm-claude")
    try """
    #!/bin/sh
    echo $$ >> '\(launches.path)'
    cat >/dev/null
    printf '{"type":"result","is_error":false,"result":"answered by %s"}\\n' "$$"
    """.write(to: warmCLI, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: warmCLI.path)
    func pids() -> [String] { ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    let pool = WarmPool()
    defer { pool.drain() }
    let warmModel = AppModel(preferences: preferences, warmPool: pool)
    warmModel.provider = .codex
    warmModel.claudePath = warmCLI.path
    warmModel.prewarm()
    pump(0.5)
    check(pids().isEmpty, "With Codex selected, nothing is launched ahead")
    warmModel.provider = .claude
    var waited = Date()
    while pids().count < 2 && Date().timeIntervalSince(waited) < 5 { pump(0.05) }
    check(pids().count == 2 && pool.count == 2, "Choosing Claude launches a plain chat and a My setup spare")
    let spares = Set(pids())
    warmModel.selectContext(.general)
    warmModel.draft = "Warm question"
    warmModel.send()
    waited = Date()
    while warmModel.busy && Date().timeIntervalSince(waited) < 10 { pump(0.02) }
    let warmAnswer = warmModel.messages.last?.text ?? ""
    check(spares.contains(String(warmAnswer.dropFirst("answered by ".count))), "The popup's question is answered by a spare (\(warmAnswer))")
    waited = Date()
    while pool.count < 2 && Date().timeIntervalSince(waited) < 5 { pump(0.05) }
    check(pids().count == 3 && pool.count == 2, "The used spare is replaced")
    warmModel.stopAll()
    check(pool.count == 0, "Quitting ends the spares")
}
