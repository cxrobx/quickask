# Context routing and session handoff

Implemented October 13, 2026, from context-routing-design.md.

## Onyx pages (October 16)

`AppConnector.onyx` attaches when the Onyx window is the context. It answers the way Onyx's own
ask box does, with progressive disclosure:

- **First prompt.** Onyx's bridge (`launcher/Onyx.swift`, through `window.askwQuickAskContext` in
  `static/ask.js`) now also publishes `passage` (the highlighted text) and `surrounding` (the text
  around it). With nothing selected, `passage` is empty and `surrounding` is the 4,000-character page
  excerpt. Both go to the model in the snapshot. They are content, never identity:
  `AppSelection.sameTarget` and the gateway descriptor ignore them.
- **Reading more.** `OnyxPage` gives the model three read-only tools, served inside the gateway
  (`isLocal`, so no server is started), in place of Onyx's `--add-dir`:
  - `read_page`: the page as text, in chunks of up to 20K characters. HTML is stripped to text with
    the headings marked.
  - `search_page`: matches, each with its offset.
  - `read_nearby`: files in the page's own folder. The path is resolved through symlinks and checked
    component by component. Hidden and key-like files are refused.

  Each tool refuses once the file's `mtime_ns:size` no longer matches Onyx's `askw-doc-sig`. Remote
  pages get the passage or excerpt with no tools. The label shows the page's title:
  `App · Onyx · <title>`.
- **Routing.** The Onyx hints ("this page", "the notes next to this page") and Onyx's entry in
  `connected_apps` appear only when Onyx is the candidate window. When they appeared for any visible
  Onyx window, they pulled terminal questions to My setup: 2 costly errors in the evaluation, now 0.

## Meeting Copilot (October 16)

`AppConnector.meetingcopilot` is served by the copilot's own MCP,
`~/Projects/meeting-copilot/bin/meeting-copilot-mcp` (repo commit 96b8863). That MCP is a thin client
of the running copilot server, so answers come from the copilot's warm sessions.

- **Tools.** `status`, `transcript`, `ask`, `pulse` (checkin / missed / wrapup), `suggest` and
  `research`. None of them counts as a write.
- **When the tools attach.** The copilot's `/health` (`COPILOT_PORT`, default 17890) has to report a
  live session. Its panel doesn't need to be on screen. Then Auto adds the `uses_meetingcopilot`
  question, and the router's state says a meeting is live (`live_meeting`). The tools attach in any of
  three cases:
  - The router's score clears My setup's lower bar (0.70 Decisions), since the tools are read-only and
    missing the meeting is costly. A meeting question takes precedence over My setup.
  - The message names the copilot or "this meeting".
  - Nothing is on screen.
- **Fast path.** A bare check-in ("how am I doing?", "did I miss anything", "wrap up") calls `pulse`
  directly, with no model in front (`MeetingCopilot.pulseKind`). The reply is the copilot's, labelled
  `Meeting Copilot · How am I doing?`.
- **Time.** Tool calls get 130 s and the request 7 minutes. Codex gets a 180 s tool timeout, and
  Claude gets `MCP_TOOL_TIMEOUT` set to the same.

## End-to-end harness

`scripts/e2e-surfaces.sh <onyx|any> "<question>"` sends a question through `AppModel.send()`, the path
the popup uses, against the real apps:
- Onyx's socket.
- The routing service.
- The provider CLI.
- The gateway, served by the harness binary itself in `--mcp` mode.
- The copilot's MCP.

It skips only the keystrokes and prints the label, statuses, answer and time.
- `route "<question>"` prints the router's scores as if a meeting were live.
- `E2E_PROVIDER=codex` switches the provider.
- `COPILOT_PORT` and `MEETING_COPILOT_SOCKET` point it at a test copilot.

Each run makes real requests.

Verified October 16 against a disposable copilot server with a seeded live meeting, using real models:

| Path | Question | Result | Time |
|---|---|---|---|
| Onyx, whole page | Fact past the excerpt | `search_page`, then `read_page`; correct | 18.5 s |
| Onyx, whole page (Codex) | Same | `search_page`; correct | 10.6 s |
| Onyx, file beside the page | Notes next to the page | `read_nearby`; correct, 3 of 3 runs | ~7 s |
| Onyx, highlighted paragraph | About the highlight | Answered from the passage, no tool call | 10 s |
| Meeting fast path | "how am I doing?" | Copilot's pulse | 9.8–12.3 s |
| Meeting fast path | "did I miss anything" | Copilot's pulse | 11.1 s |
| Meeting, routed | Questions about the meeting | Read the transcript | 9.2–10.1 s |
| Meeting, routed | "ask the copilot…" | Copilot's `ask` | 8.9 s |
| Meeting, routed | Research for the meeting | Copilot's `research`, with sources | 41.9 s |

With no meeting live, the same question gets no meeting tools.

Checks:
- 479 Swift checks.
- The routing evaluation grows to 40 samples, with six new: the Onyx notes question and five
  meeting-live questions. Result: 37 exact, 0 costly, the same three misses as before. Two Onyx samples
  now expect `app`, since Onyx is a connected app.
- `evaluate-routing.sh` was missing `CoachCard.swift` since the Studio Coach commit, and compiles
  again.

## Studio Coach in FL Studio (October 15)

`AppConnector.studiocoach` is FL Studio's connector (`com.image-line.flstudio`), served by
`/Applications/Studio Coach.app/Contents/MacOS/StudioCoach --mcp` (the engine's `coach mcp`). It
attaches like CXMail's and CXTasks': Screen when the router picks FL, read-only under All context. With FL
visible, the router is told that a question about the song, mix or arrangement points at it.

- **Tools:** `status`, `assess`, `compare`, `diff`, `lyrics`, `journal`; writes `set_card` and
  `record_outcome`, which pass only their own fields (`GatewayPolicy.coachFields`). `assess` journals an
  answer and writes a clip, as the app's quick actions do, so it counts as asking for advice and stays
  available read-only. FL publishes no selection, so coach writes skip the selection identity check
  (`hasSelection`).
- **Live audio:** `assess` defaults to `source: live`. The app hands over the last ~90 s through
  `~/.studio-coach/live.sock` (owner-only, peer uid checked). If the app is down or FL is quiet, it uses the
  newest bounce and says why on the card.
- **Cards:** a coach result's `structuredContent.card` is appended by the gateway to an owner-only
  `coach-cards.jsonl` in the request workspace (`GatewayConfiguration.cardsPath`). `CLIRunner` follows it
  (`CardTail`) and emits `.card` while the model is still writing. `CoachCardView` draws it under the reply.
  Outcome buttons call the coach's `record_outcome` directly (`StudioCoachOutcome`): the click is the
  approval, and no model is involved. Each card goes into later prompts as a short note naming its finding
  ids, without its numbers, so "the second one helped" can resolve.
- **Time:** coach tool calls get 300 s (`toolDeadline`), the lease 420 s, the request 7 minutes. Codex gets
  `tool_timeout_sec=400` and Claude `MCP_TOOL_TIMEOUT`. A cached answer takes ~30 s end to end.

Verified October 15: 284 Swift checks, including a fake-coach gateway run (read-only listing, refused
writes, card hand-off, owner-only file); 6 engine MCP tests; the signed app's `--mcp` server; and a live
Claude request through QuickAsk's gateway to the real coach. That request returned a checked mix answer
on *blessings* (newest bounce, since FL was quiet), with the card and a two-sentence reply in 31 s. Not yet
exercised: a live clip while FL is playing, and the popup's own routing with FL open.

## Links open in My setup (October 15)

A message that is a link (a bare URL, or a short “is this legit? <url>” / “read
this <url>”) goes straight to My setup when Claude is selected in Auto, with no
router call or screen capture. Only that session can open links: the sandboxed
routes run with no tools, Claude's WebFetch refuses some sites outright
(reddit.com), and Reddit's public `.json` returns 403 without a login, so its
prompt points refused sites at the user's Zen browser (zen-ext). A link inside a
longer pasted email or note doesn't count, and an explicitly chosen General chat
or window keeps its choice; those prompts now say where links open instead of
only refusing. Verified live: the My setup prompt read a Reddit share link.

## Direct Herdr continuation (October 14)

Use **Continue this chat in Herdr…** in the context menu, or say “lets transfer
this session to herdr and have it do X” or “start a Herdr session to …”. The fixed intent rule opens a separate
review without contacting the router or CXTasks. A request explicitly asking to
create a tracked task still uses the task flow; the direct menu action always
chooses a direct continuation. The menu also works with an empty composer when
there is already a chat.

The review is a compact card within the transcript; it keeps the conversation
visible and does not replace the chat with a form. It infers the current provider,
extracts the next instruction (e.g. “shorten the introduction”), and resolves exact
existing paths from the document, recent conversation, or saved project mappings.
The folder inference reads the registry locally; no classifier supplies paths.
One **Change…** control reveals optional edits to the instruction, provider, and
folder. Ambiguous documents/folders produce one targeted inline question.
With no relevant folder needed for a general continuation, it
uses a new private Quick Ask session folder, grouped in Herdr's Quick Ask space.
An explicit working folder uses the shared router's canonical checkout matching.
The entire completed conversation is carried over, plus the five most recent
images. Unfinished replies and older images are labeled as excluded. A generic
transfer does not capture the current screen; an explicit visible-item reference
or manually selected window can attach fresh source metadata and is revalidated.

Confirmation writes owner-only prompt/image/launch files under
`~/Library/Application Support/QuickAsk/Sessions/<proposal-id>` and invokes
`~/.local/bin/cx-open-in-herdr` directly with its existing argv interface.
Both CLIs start interactively, with their normal settings, tools, and approvals.
No Quick Ask leases, task write-back configuration, or permission-bypass flags
are added. API-key environment variables are removed from the handoff child.
Codex's interactive entry point follows the
[official CLI reference](https://developers.openai.com/codex/cli/reference).

This creates a fresh Herdr tab seeded with the chat, rather than resuming an
ephemeral CLI session ID. No CXTasks app, task, or runner is invoked; its saved
project-folder mappings can be read locally for inference. Cancellation
preserves the chat and draft. A stable launch reservation prevents duplicate tabs,
including after an unconfirmed result; no alternate terminal or automatic retry
is attempted. A successful receipt confirms the Herdr tab, not the agent's final
work. The user manages that session in Herdr. The prompt has a 128 KB transfer
limit; an oversized chat is rejected intact rather than silently truncated.

Verification covers full conversation continuity, images, exact Unicode/quoted
argument delivery to a fake CLI, protected files, duplicate confirmation, missing
folders/helpers, failed launches, menu/typed intent, cancellation, and routing
independence. No real agent was started for these checks.
The complete current suite passes 223 provider/transport/UI-state checks,
including action extraction, remembered document context, exact project-folder
resolution, and ambiguous-target selection.

## Available now

Quick Ask selects app windows on the display containing its dialog, using
greatest overlap with a center tie-break. Opening on another pointer display
overrides a dragged position on the previous one.

The context menu supports Auto, General chat, visible windows and moving to the
previously focused app. General chat bypasses capture/routing, including after a
display change. Auto makes one routing call to Luna Decisions (Jev is an
alternative in Settings) carrying several questions: self-contained, needs the
screen, needs to see it, about the attached image, wants an app action,
follow-up, which window, and which CXTasks project. `RoutePlan.make` combines the
answers: General chat, Screen (one window's content, with its app's read tools,
plus write tools only for a clear action), or All context when unclear
(read-only). A screenshot of the display is added for visual questions. The
label shows what was sent, for example `Screen · Ghostty · ~/Projects/quickask`
or `Auto · all context · CXMail · read-only`. Design: section 4 of the spec.

Only a router failure (missing credentials, timeout, no usable answers) shows the
inline picker; it offers General chat and the visible windows.

CXMail and CXTasks tools are proxied through the existing quickask MCP server,
with the design's named allowlists. Active answering providers are Codex and
Claude. The direct ChatGPT experiment is archived.

Writes validate the frozen process, window, selection identity and revision.
Task fields cannot enable background execution or tripwires. Email moves check
the actual folder role. Trash/Junk, deletion, direct sending and task archiving
are excluded. Screen changes and Stop revoke further contextual tool calls;
already completed app actions are not represented as rolled back.

## Confirmed task and agent handoff

The review opens only on an explicit request: a message that says to create,
file, add, make or log a task, or to turn something into a task
(`AppModel.requestsTaskCreation`, checked before routing), or the context menu's
**Create task from this question…**. The router is never offered a task choice,
and the Choose picker has no task button. This opens a review containing an editable task title/instructions,
source item, exact local document, working folder, and these execution choices:

- **File only** creates the task without starting an agent.
- **Open Claude in Herdr** files the task first, then calls the existing CXTasks
  `dispatch_foreground` implementation. The installed `cx-open-in-herdr` helper
  is required; a missing helper leaves a tracked task and a visible failure.
- **Background Claude** files and queues through the existing `queue_background`
  guards. File edits and commands require the same Git workspace/checkpoint
  rules as the CXTasks UI. Explicit edit requests propose that permission in
  the review; the user can change it before confirming. A queued task is never
  described as running without evidence. Paused/uninstalled runners are named.
  An optional checkbox authorizes the existing **Run queue once** action if the
  recurring runner is off. It explains that this also picks up other eligible
  queued tasks and does not install a recurring runner.

No task exists before confirmation. Cancel preserves the question. A stable
proposal UUID makes task creation idempotent, and a persisted reservation prevents
another launch after a duplicate or uncertain response. Launch failures leave
the task and its handoff comment available. The chat shows a link to that task.
After an interrupted submission, **Check same handoff** resends the frozen
proposal rather than creating or launching another one.

Onyx's native launcher now offers read-only active-document metadata, including
its canonical path, displayed file revision, and whether its editor is open.
Its existing read-only answering models are unchanged. Quick Ask revalidates the
source window/selection and document version before confirmation; CXTasks checks
the file version and canonical working folder again before filing. Save and close
an open Onyx editor first. Remote pages need an explicitly chosen local source
before an agent can edit them. The worker's seed includes the exact document,
feedback, version and instructions to report a conflict rather than overwrite
changes it did not see.

The reviewed handoff is a separate owner-only local socket operation. It verifies
the caller PID and QuickAsk host executable/bundle identity. It is absent from
the model MCP catalog: models cannot supply approval, agent permissions, queue
operations, arbitrary commands, or additional MCP endpoints.

## Tools on demand

Any answer, General chat included, can gain tools mid-conversation through the
gateway, with either provider:

- **Vault** (`search_vault`, `related_notes`; read-only), **CXTasks** and **CXMail**:
  attached when the router answers yes to `uses_vault` / `uses_cxtasks` /
  `uses_cxmail`. They write only when `wants_app_action` is also a yes.
- **Margin** (`list_folders`, `list_notes`, `read_note`, `create_note`,
  `append_note`): attached only when the message names Margin
  (`AppModel.mentionsMargin`: "add this to Margin", "a Margin note"), never by
  the router. Writes are allowed, since it was named.

Vault and Margin start exactly as `~/.claude.json` registers them, by name; an
unregistered server is reported, not guessed. Without a window, the gateway's
snapshot is a placeholder for Quick Ask itself (`screenless`), and its lease
check requires only a fresh lease and a running Quick Ask. "File a task for this"
still opens the task review. The label lists attached tools, e.g.
`General chat · Vault`.

Verified: 188 checks; a live Claude answer with only the vault attached searched
the real vault through the gateway in about 10 s; the router sent "Check our Onyx
vault…" to the vault (Codex) or My setup (Claude), and "Add this as a note in
Margin" attached Margin with either provider.

## My setup (Claude as a normal session)

**Fix (October 14):** "are we all ready for the acme call on friday?" with a terminal
full of another agent session's text scored `about_my_work` 0.48–0.81 and missed
My setup. The question now tells the router to judge from the question and
conversation alone, and My setup has its own bar (0.70 Decisions / 0.60 Jev).
Evaluation with seven new busy-terminal samples, before → after: exact 30 → 31 of
34, costly misses 1 → 0 (a missed My setup now counts as costly), no new My
setup false positives; the reproduction scored 0.99 on three of three runs.


**My setup (Claude)** in the context menu, or Auto when the router judges a question
to be about the user's own work (`about_my_work`, asked only while Claude is
selected) and not about the screen, runs Claude as a normal session from the home
folder: no `--safe-mode`, so CLAUDE.md files, memory, skills, hooks and user-scope
MCP servers load; all tools; and the user's own permission mode and deny rules
(no `--permission-mode` is passed). It can make changes when asked. No screen
content is sent in this mode; attached images are. A follow-up to a My setup
answer stays there. Requests time out after 15 minutes instead of 3, and the
status line names the tool in use. Codex has no equivalent yet.

Verified: 163 checks; a live run of "What do you think we should focus on today?"
read `Current Focus.md` and answered from it in about 10 s; in the routing
evaluation, three questions about the user's own work went to My setup and no
other question did (24 of 27 exact, 0 costly errors).

## Images in the composer

Paste (⌘V or the clipboard button) or drop images into the composer; up to five
per message, shown as removable thumbnails, and an image alone can be sent. Images
are downscaled to 2,000 px on the long edge (PNG, JPEG above 3.5 MB). Claude
receives them as base64 content over stdin (`--input-format stream-json`); Codex
receives owner-only files in the request workspace via `--image=<path>`. Each
request resends the five most recent images so follow-ups can refer back; the
history marks older ones as no longer attached. The router stays text-only and is
told only that an image was attached. Task handoffs don't carry images.

## Companion interfaces and privacy

Both companion repositories now include a serialized, deduplicated selection
publisher in src/hooks/useQuickAskSelection.ts and a read-only context interface
in src-tauri/src/quickask.rs. Rust resolves labels/revisions from its database.
Only the main window can publish. The context operation provides no app actions;
CXTasks separately accepts the host-reviewed handoff described above.

Each app has an owner-only Unix socket in the QuickAsk/Context application
support directory. Quick Ask verifies the socket peer PID, published app identity
and native window ID.

Structured labels are preferred, followed by accessibility and local OCR.
Routing omits body text when labels exist. Screen text, titles, labels and URLs
stay in host memory during ordinary questions. Confirming task creation persists
the reviewed source identity and instructions in CXTasks. The temporary
owner-only gateway descriptor contains
record/process identities and capabilities; it is removed with the workspace.

Routing keys use OPENAI_API_KEY or TYPESAFE_API_KEY from the environment or
login Keychain's cx-secret service. Keychain lookup is isolated in a child
process with a 300 ms limit. HTTP routing has a two-second deadline and rejects
redirects. The API shape follows the
[official Decisions documentation](https://developers.openai.com/api/docs/guides/decisions).

## Local builds

The ignored dist directory contains QuickAsk.app, CXMail.app, CXTasks.app and Onyx.app.
The companion bundles are frozen local build copies with their selection
interfaces. CXMail/CXTasks retain the existing developer identity, with CXTasks
using its required non-hardened foreground-launch signature. Onyx is an ad hoc
signed local build. Signatures were verified.

The companion builds are installed in /Applications (CXMail Oct 13 22:36,
Onyx Oct 14 01:28, CXTasks Oct 14 01:45). Checked October 14: each answers on its
socket in Application Support/QuickAsk/Context with its current selection (CXMail:
account, folder, thread, uid; CXTasks: task, project; Onyx: document path,
revision, editing). Nothing was notarized or published.

## Verification

- 223 Swift provider/transport/display/routing/gateway checks pass, including
  denied tools and fields, revocation, target checks, namespacing, IPC privacy
  and folder-role validation. Task review covers cancellation, exact document
  identity, stale revisions, open editors, background permissions and honest
  queued results.
- The built app passes MCP protocol tests and signature verification.
- CXMail/CXTasks pass Rust compilation and frontend type checking and produce
  local application bundles. CXTasks has 31 passing desktop tests (one existing
  live-service test ignored), including five new handoff tests; 48 core dispatch
  tests and 15 existing Herdr launcher tests pass against temporary fixtures.
- Onyx passes all 365 existing unit tests and Swift type checking with its macOS
  14 deployment target, and produces a self-contained app without installation.
  Its checked native bridge is committed in that repository as f4d0176.
- Native UI inspection confirms context choices and Codex/Claude controls.
  A live General-chat request returned QUICKASK_OK. The test chat was cleared.
- Routing evaluation (2026-10-13, Decisions, 24 invented windows/questions over
  Ghostty, Zen, Onyx, CXMail, CXTasks and image questions): at the shipped 90%
  bar, 21 exact, 22 acceptable, 0 costly errors (no General route when context
  was needed, no unrequested write tools). Misses: two image questions fell back
  to All context, and "Fix it" over Ghostty went to Screen. 157 ms median,
  210 ms p95. A live in-app image question answered correctly under
  `Auto · all context`.

The synthetic evaluation is a smoke test, not production calibration. The
90% "yes" bar stays provisional and configurable; the evaluation's suggested bar
is reported, not applied. Run scripts/evaluate-routing.sh with an accessible
routing key to repeat it (`ROUTING_ENGINE=jev` for Jev). Results, including the
invented per-sample questions and their answers, go to the ignored
build/routing-evaluation.json.

Live agent launches or mutations against real emails/tasks/documents and physical two-display/full-screen
behavior have not been exercised. Policy and geometry are covered by fixtures;
further validation requires running the rebuilt companion apps.

## Deferred as specified

Project folder tools remain a separate follow-up. Onyx pages are answered through
`OnyxPage` (see Onyx pages above) rather than an Onyx answering MCP server.
Onyx document-to-task handoff is available. Project routes are not offered to Codex, whose
built-in file/shell access is not confined by this gateway.
