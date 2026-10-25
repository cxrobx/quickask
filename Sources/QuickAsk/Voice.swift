import AppKit
import AVFoundation
import Darwin
import SwiftUI

/// Voice mode: talk to the chat and hear the answer, round after round, until stopped.
///
/// The ears and voice are the local voice-lab server (~/Projects/voice-lab):
/// `ws://127.0.0.1:2022/v1/live` turns the mic into words while the user speaks
/// (they appear in the prompt box), and `POST :8880/v1/audio/speech` speaks the
/// reply (Kokoro, or Speechify Simba when `scripts/voice tts simba` is on).
/// The reply is spoken sentence by sentence as it streams, so a line the model
/// writes before slow tool work ("Let me check your calendar.") is heard first.
/// The floor is shared with VoiceMode sessions through its conch, so QuickAsk
/// never talks over a terminal voice conversation.
enum VoicePhase: Equatable {
    case off, waiting, listening, thinking, speaking
}

@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var phase: VoicePhase = .off
    /// Input level while listening, 0...1, for the button.
    @Published private(set) var level: Float = 0

    nonisolated static let liveURL = URL(string: "ws://127.0.0.1:2022/v1/live")!
    nonisolated static let speechURL = URL(string: "http://127.0.0.1:8880/v1/audio/speech")!
    /// Nothing said for this long ends voice mode, as walking away from the mic should.
    static let noSpeechTimeout: TimeInterval = 20
    static let maxUtterance: TimeInterval = 120

    private weak var model: AppModel?
    private let speaker = VoiceSpeaker()
    private let conch = VoiceConch()
    private var loop: Task<Void, Never>?
    /// The user pressed Return mid-utterance: their send stands, and its reply is spoken.
    private var sentByHand = false
    /// Each reply's text as the provider streams it, ahead of the paced on-screen reveal.
    private var streamed: [UUID: String] = [:]

    /// AppModel passes every streamed update of a voice-mode reply here.
    func received(_ content: String, for reply: UUID) { streamed[reply] = content }

    var isActive: Bool { phase != .off }

    init(model: AppModel) { self.model = model }

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard loop == nil, let model else { return }
        if model.busy { model.status = "Wait for this answer to finish, then start voice."; return }
        phase = .waiting
        model.voiceActive = true
        loop = Task { [weak self] in
            await self?.run()
            self?.finish()
        }
    }

    func stop() {
        loop?.cancel()
        speaker.stop()
        finish()
    }

    private func finish() {
        loop = nil
        conch.release()
        speaker.stop()
        level = 0
        if phase != .off, let model {
            model.voiceActive = false
            if ["Listening…", "Transcribing…"].contains(model.status) || model.status.hasPrefix("Voice is waiting") { model.status = "Voice off" }
        }
        phase = .off
    }

    private func say(_ status: String) { model?.status = status }

    private func run() async {
        guard await VoiceMic.permitted() else {
            say("Voice needs the microphone: allow QuickAsk in System Settings › Privacy & Security › Microphone.")
            return
        }
        while !Task.isCancelled, let model {
            guard await takeFloor() else { return }
            let before = Set(model.messages.map(\.id))
            let heard: String?
            do { heard = try await listen(into: model) } catch {
                say(error.localizedDescription); return
            }
            conch.release()
            guard !Task.isCancelled else { return }
            if sentByHand {
                sentByHand = false
            } else {
                guard let text = heard, !text.isEmpty else { say("Voice off: nothing heard."); return }
                model.draft = text
                model.send()
            }
            phase = .thinking
            await speakReply(after: before, in: model)
            guard !Task.isCancelled else { return }
        }
    }

    /// Waits until no VoiceMode session holds the conch, then takes it.
    private func takeFloor() async -> Bool {
        var told = false
        while !Task.isCancelled {
            if conch.tryAcquire() { return true }
            if !told { phase = .waiting; say("Voice is waiting for another voice session to finish…"); told = true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func listen(into model: AppModel) async throws -> String? {
        phase = .listening
        say("Listening…")
        model.draft = ""
        let socket = LiveSocket(url: Self.liveURL) { [weak self, weak model] final, draft in
            Task { @MainActor in
                guard let model, self?.phase == .listening, !model.busy else { return }
                model.draft = (final + draft).trimmingCharacters(in: .whitespaces)
            }
        }
        try await socket.connect()
        let gate = SpeechGate()
        let mic = VoiceMic()
        try mic.start { pcm, rms in
            socket.send(pcm)
            gate.update(rms: rms)
        }
        defer { mic.stop() }
        let started = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            level = min(1, gate.lastRMS * 12)
            let elapsed = Date().timeIntervalSince(started)
            if gate.heardOnlyZeros(after: 1.5) {
                socket.cancel()
                throw VoiceError("QuickAsk hears only silence: allow the microphone in System Settings › Privacy & Security › Microphone.")
            }
            if model.busy { socket.cancel(); sentByHand = true; return nil }
            if gate.ended || elapsed > Self.maxUtterance { break }
            if !gate.started && elapsed > Self.noSpeechTimeout { socket.cancel(); return nil }
        }
        level = 0
        if Task.isCancelled { socket.cancel(); return nil }
        say("Transcribing…")
        return try await socket.finish()
    }

    /// Speaks the new reply's sentences as they appear, then waits for the audio to finish.
    private func speakReply(after before: Set<UUID>, in model: AppModel) async {
        var spoken = 0, holding = false
        let begun = Date()
        defer { if holding { conch.release() }; streamed.removeAll() }
        while !Task.isCancelled {
            let reply = model.messages.last { $0.role == "assistant" && !before.contains($0.id) }
            let done = reply.map { $0.complete && !model.busy } ?? (!model.busy && Date().timeIntervalSince(begun) > 3)
            if let reply {
                // Speak from the stream, not the paced reveal, which trails it.
                let raw = streamed[reply.id] ?? ""
                let text = raw.count >= reply.text.count ? raw : reply.text
                let (chunk, end) = SpeechText.ready(text, from: spoken, final: done, opening: spoken == 0)
                if !chunk.isEmpty {
                    if !holding {
                        guard await takeFloor() else { return }
                        holding = true
                    }
                    phase = .speaking
                    do { try await speaker.say(chunk) } catch { say("Couldn't speak the reply: \(error.localizedDescription)") }
                }
                spoken = end
            }
            if done { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        await speaker.waitUntilDone()
    }
}

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - What gets spoken

extension PromptBuilder {
    /// Added to a voice-mode prompt: the reply is heard sentence by sentence as it streams.
    static let voiceNote = """


    Voice mode: the user spoke the last message and hears your reply read aloud as you write it. \
    Write for the ear: short plain sentences, no tables, headings or lists unless asked, and no \
    code unless asked (it stays on screen; say so). Before work that takes a while, such as tool \
    calls, first say in one short sentence what you are about to do. Speech-to-text can mishear; \
    if a word seems wrong, go with the likely meaning, and ask only when it matters.
    """
}

enum SpeechText {
    /// A long opening sentence may be spoken from a comma or dash once it has this many words,
    /// and the cut must leave at least `openingMinWords` before it.
    static let openingSplitWords = 12, openingMinWords = 6

    /// The next speakable piece of `text` past `offset`: whole sentences only, unless `final`.
    /// Simba shapes intonation over the whole request, so sentences sound most natural; only a
    /// long `opening` sentence is started early, at a comma or dash where a speaker pauses anyway.
    /// Returns the cleaned chunk and the offset it ends at.
    static func ready(_ text: String, from offset: Int, final: Bool, opening: Bool = false) -> (String, Int) {
        let chars = Array(text)
        guard offset < chars.count else { return ("", offset) }
        var end = chars.count
        if !final {
            // Hold back an unclosed code block, and anything after the last sentence end.
            let fences = text.components(separatedBy: "```").count - 1
            if fences % 2 == 1, let open = text.range(of: "```", options: .backwards) {
                end = min(end, text.distance(from: text.startIndex, to: open.lowerBound))
            }
            var cut = -1
            var i = offset
            while i < end {
                let c = chars[i]
                if c == "\n" || ((c == "." || c == "!" || c == "?" || c == ":") && i + 1 < end && chars[i + 1].isWhitespace) {
                    cut = i + 1
                }
                i += 1
            }
            if cut <= offset, opening { cut = openingPause(chars, from: offset, to: end) }
            guard cut > offset else { return ("", offset) }
            end = cut
        }
        return (clean(String(chars[offset..<end])), end)
    }

    /// The last comma or dash in an unfinished opening sentence of `openingSplitWords`+ words.
    private static func openingPause(_ chars: [Character], from offset: Int, to end: Int) -> Int {
        var words = 0, cut = -1, inWord = false
        var i = offset
        while i < end {
            let c = chars[i]
            if c.isWhitespace { inWord = false } else if !inWord { inWord = true; words += 1 }
            let pause = c == "," || c == "—" || c == "–" || (c == "-" && i > offset && chars[i - 1] == " ")
            if pause && words >= openingMinWords && i + 1 < end && chars[i + 1].isWhitespace { cut = i + 1 }
            i += 1
        }
        return words >= openingSplitWords ? cut : -1
    }

    /// Markdown to speech: code is shown, not read; links and paths are named, not spelled out.
    static func clean(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " The code is on screen. ", options: .regularExpression)
        s = s.replacingOccurrences(of: "```[\\s\\S]*$", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "https?://\\S+", with: "the link", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s*\\|.*\\|\\s*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s{0,3}(#{1,6}|>|[-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_~]{1,3}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Turn-taking with VoiceMode (its conch: ~/.voicemode/conch)

/// VoiceMode's floor lock, spoken in its own format so both sides honour it: an exclusive
/// flock held while talking or listening, a JSON payload naming the holder, and a `held`
/// marker a session leaves between turns to keep the floor (respected while its pid lives
/// and its `expires` has not passed). Released by unlinking, as VoiceMode does.
final class VoiceConch {
    static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".voicemode/conch")
    private var fd: Int32 = -1

    func tryAcquire() -> Bool {
        if fd >= 0 { return true }
        if Self.heldByOther() { return false }
        try? FileManager.default.createDirectory(atPath: (Self.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let f = open(Self.path, O_CREAT | O_RDWR, 0o644)
        guard f >= 0 else { return false }
        guard flock(f, LOCK_EX | LOCK_NB) == 0 else { close(f); return false }
        let payload: [String: Any] = [
            "pid": Int(getpid()), "agent": "quickask", "session_id": NSNull(), "project_path": NSNull(),
            "voice": NSNull(), "acquired": Self.isoNow(), "held": false, "expires": NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            ftruncate(f, 0)
            _ = data.withUnsafeBytes { pwrite(f, $0.baseAddress, data.count, 0) }
        }
        fd = f
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        unlink(Self.path)
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// A live, unexpired between-turns hold by another process.
    static func heldByOther() -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["held"] as? Bool == true, let pid = json["pid"] as? Int, pid != Int(getpid()) else { return false }
        guard kill(pid_t(pid), 0) == 0 || errno == EPERM else { return false }
        if let expires = (json["expires"] as? String).flatMap(parseISO) { return Date() < expires }
        if let acquired = (json["acquired"] as? String).flatMap(parseISO) { return Date().timeIntervalSince(acquired) < 15 }
        return true
    }

    /// Python's datetime.isoformat(): local time, no zone, optional microseconds.
    static func parseISO(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let date = f.date(from: text) { return date }
        }
        return nil
    }

    static func isoNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return f.string(from: Date())
    }
}

// MARK: - Ears: mic → 16 kHz PCM → the live socket

/// When the user started and stopped talking, from the input level. The floor is learned
/// from the first 0.3 s, so a quiet room and a noisy one both work.
final class SpeechGate: @unchecked Sendable {
    static let silenceToEnd: TimeInterval = 1.0
    private let lock = NSLock()
    private var floorSamples: [Float] = []
    private var floor: Float?
    private var loudRun = 0
    private var quietSince: Date?
    private var peak: Float = 0
    private let begun = Date()
    private(set) var started = false
    private(set) var ended = false
    private(set) var lastRMS: Float = 0

    func update(rms: Float) {
        lock.lock(); defer { lock.unlock() }
        lastRMS = rms
        peak = max(peak, rms)
        guard let floor else {
            floorSamples.append(rms)
            if Date().timeIntervalSince(begun) > 0.3 { self.floor = floorSamples.sorted()[floorSamples.count / 2] }
            return
        }
        let threshold = max(0.012, floor * 3)
        if rms > threshold {
            loudRun += 1; quietSince = nil
            if loudRun >= 2 { started = true }
        } else {
            loudRun = 0
            if started {
                if quietSince == nil { quietSince = Date() }
                if let quietSince, Date().timeIntervalSince(quietSince) >= Self.silenceToEnd { ended = true }
            }
        }
    }

    /// macOS gives a denied mic silent zeros rather than an error.
    func heardOnlyZeros(after seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(begun) > seconds && peak == 0
    }
}

final class VoiceMic {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static func permitted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// `onFrame` gets 16 kHz mono s16le and the frame's RMS, on the audio thread.
    func start(_ onFrame: @escaping (Data, Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw VoiceError("No microphone is available.")
        }
        self.converter = converter
        let target = self.target
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            var rms: Float = 0
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
                rms = (sum / Float(buffer.frameLength)).squareRoot()
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            onFrame(Data(bytes: samples, count: Int(out.frameLength) * 2), rms)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// WS /v1/live: binary PCM up, `partial` words down, then `final` after `end`.
final class LiveSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onPartial: (String, String) -> Void
    private let lock = NSLock()
    private var finalText: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    init(url: URL, onPartial: @escaping (String, String) -> Void) {
        task = URLSession.shared.webSocketTask(with: url)
        self.onPartial = onPartial
    }

    func connect() async throws {
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                task.sendPing { error in if let error { done.resume(throwing: error) } else { done.resume() } }
            }
        } catch {
            throw VoiceError("The voice server isn't running. Start it with `scripts/voice start` in ~/Projects/voice-lab.")
        }
        receive()
    }

    func send(_ pcm: Data) { task.send(.data(pcm)) { _ in } }

    func cancel() {
        task.send(.string("{\"type\":\"cancel\"}")) { _ in }
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Says the user is done; the full transcript comes back in ~0.2 s.
    func finish() async throws -> String {
        task.send(.string("{\"type\":\"end\"}")) { _ in }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            finalText = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.complete(.failure(VoiceError("The voice server didn't return a transcript.")))
            }
        }
    }

    private func complete(_ outcome: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = finalText; finalText = nil
        lock.unlock()
        waiting?.resume(with: outcome)
        if case .success = outcome { task.cancel(with: .normalClosure, reason: nil) }
    }

    private func receive() {
        task.receive { [weak self] message in
            guard let self else { return }
            switch message {
            case .failure(let error): self.complete(.failure(error))
            case .success(let frame):
                if case .string(let text) = frame, let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    switch json["type"] as? String {
                    case "partial": self.onPartial(json["final"] as? String ?? "", json["draft"] as? String ?? "")
                    case "final": self.complete(.success(json["text"] as? String ?? "")); return
                    case "error": self.complete(.failure(VoiceError(json["text"] as? String ?? "voice server error"))); return
                    default: break
                    }
                }
                self.receive()
            }
        }
    }
}

// MARK: - Voice: text → the TTS server → speakers

/// Plays the server's streamed 24 kHz mono s16le as it arrives, chunk after chunk in order.
final class VoiceSpeaker: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let lock = NSLock()
    private var queued = 0
    private var generation = 0
    private var started = false

    func say(_ text: String) async throws {
        try startIfNeeded()
        let mine = currentGeneration()
        var request = URLRequest(url: VoiceController.speechURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": text, "response_format": "pcm", "model": "tts-1"])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError("The voice server refused to speak.") }
        var pending = Data()
        pending.reserveCapacity(9_600)
        var first = true
        for try await byte in bytes {
            pending.append(byte)
            // The first 0.05 s plays at once; after that, 0.2 s buffers keep the scheduling light.
            if pending.count >= (first ? 2_400 : 9_600) {
                first = false
                guard currentGeneration() == mine else { return }
                schedule(pending); pending.removeAll(keepingCapacity: true)
            }
        }
        if currentGeneration() == mine { schedule(pending) }
    }

    func waitUntilDone() async {
        while queuedCount() > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func stop() {
        lock.lock(); generation += 1; queued = 0; lock.unlock()
        if started { player.stop(); player.play() }
    }

    private func queuedCount() -> Int { lock.lock(); defer { lock.unlock() }; return queued }

    private func currentGeneration() -> Int { lock.lock(); defer { lock.unlock() }; return generation }

    private func startIfNeeded() throws {
        guard !started else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
        started = true
    }

    private func schedule(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        lock.lock(); queued += 1; let mine = generation; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); if self.generation == mine { self.queued -= 1 }; self.lock.unlock()
        }
    }
}

// MARK: - The button

/// Beside Send: a mic to start; while on, what voice is doing, and a tap stops it.
struct VoiceButton: View {
    @ObservedObject var voice: VoiceController
    var tint: Color

    var body: some View {
        Button(action: voice.toggle) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: voice.phase == .speaking || voice.phase == .thinking)
                .foregroundStyle(voice.isActive ? Color.black.opacity(0.8) : Color.white.opacity(0.75))
                .scaleEffect(voice.phase == .listening ? 1 + CGFloat(voice.level) * 0.35 : 1)
                .animation(.easeOut(duration: 0.08), value: voice.level)
                .frame(width: 30, height: 30)
                .background(Circle().fill(voice.isActive ? tint : Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .help(voice.isActive ? "Stop voice · Esc" : "Talk · ⌘⇧M")
        .accessibilityLabel(voice.isActive ? "Stop voice" : "Start voice")
    }

    private var symbol: String {
        switch voice.phase {
        case .off: return "mic"
        case .waiting: return "hourglass"
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }
}
