import Foundation

func verifyVoice(check: (Bool, String) -> Void) throws {
    // Sentences are spoken as they complete; the unfinished tail waits for more text.
    let streaming = "Let me check your calendar. You have"
    let (first, at) = SpeechText.ready(streaming, from: 0, final: false)
    check(first == "Let me check your calendar.", "Voice: a finished sentence is spoken before the reply ends")
    check(SpeechText.ready(streaming, from: at, final: false).0.isEmpty, "Voice: an unfinished sentence waits")
    check(SpeechText.ready(streaming + " two meetings", from: at, final: true).0 == "You have two meetings", "Voice: the end of the reply flushes the tail")

    // A long opening sentence starts at its last comma; later ones, and short openings, wait.
    let long = "Sure, I looked through the benchmark script and the timing code, and the part that measures"
    let (opening, openAt) = SpeechText.ready(long, from: 0, final: false, opening: true)
    check(opening == "Sure, I looked through the benchmark script and the timing code,", "Voice: a long opening sentence starts at a comma")
    check(SpeechText.ready(long, from: 0, final: false).0.isEmpty, "Voice: only the opening is split early")
    check(SpeechText.ready("Sure, I looked through the script and", from: 0, final: false, opening: true).0.isEmpty, "Voice: a short opening waits for its sentence")
    check(SpeechText.ready(long, from: openAt, final: false, opening: false).0.isEmpty, "Voice: the rest waits for the sentence end")

    // An open code block holds speech back until it closes, then is named, not read.
    let open = "Here it is:\n```swift\nlet x = 1."
    let (beforeCode, codeAt) = SpeechText.ready(open, from: 0, final: false)
    check(beforeCode == "Here it is:" && SpeechText.ready(open, from: codeAt, final: false).0.isEmpty, "Voice: an unclosed code block isn't read")
    check(SpeechText.clean("Run:\n```\nls -la\n```\nDone.") == "Run: The code is on screen. Done.", "Voice: code is named, not read")

    check(SpeechText.clean("## Plan\n- **Fix** the `server`\n- see [docs](https://x.io/a)") == "Plan Fix the server see docs",
          "Voice: markdown marks and link targets aren't spoken")
    check(SpeechText.clean("Open https://example.com/a?b=1 now") == "Open the link now", "Voice: a bare URL is named, not spelled")

    // VoiceMode's conch: a live, unexpired hold by another pid keeps the floor; ours or a dead one doesn't.
    check(VoiceConch.parseISO("2026-10-24T20:31:05.123456") != nil && VoiceConch.parseISO("2026-10-24T20:31:05") != nil,
          "Voice: the conch's Python timestamps parse")
}
