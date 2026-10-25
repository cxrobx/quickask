# QuickAsk

A native macOS menu bar assistant. Press **Option–Space**, ask a question, and
choose **Codex** or **Claude**, using your existing CLI logins.

## Run

Open `dist/QuickAsk.app` (or the supplied release app). It lives in the menu bar and opens the popup on
launch. You can move the app to your Applications folder later if desired.
Requires macOS 14 or later; the supplied binary is built for Apple Silicon.

The app detects the Codex CLI bundled with ChatGPT, then looks for CLIs in
`~/.local/bin`, Homebrew, `/usr/local/bin`, nvm installations, and `PATH`. Set an
absolute executable path in Settings if yours is installed elsewhere. Blank
model fields use each CLI's built-in default.

If you need to sign in, do so in Terminal first:

```sh
codex login
claude auth login
```

The adapters leave credentials to their CLIs. Requests count against the selected
provider's applicable usage limits.

The direct ChatGPT experiment has been removed from the app. OpenAI's
Sign in with ChatGPT integration uses ChatGPT Work/Codex usage, rather than the
ordinary Chat allowance, so it did not provide the intended additional usage pool.
Its source is not part of this repository. Existing encrypted connection
records are left untouched; revoke the old QuickAsk connection in ChatGPT's
Settings → Security and login → Login connections if desired.

## Controls

**Studio Coach in FL Studio.** With FL Studio on screen, ask about the song or mix ("how's the low end?",
"what should the bridge do?"). Quick Ask attaches Studio Coach's tools, the coach measures what FL just played,
and its answer appears as a card under the reply, with Helped / Didn't / On purpose buttons that record
straight to the coach. Needs Studio Coach.app running. See the routing doc's Studio Coach section.

**Onyx pages.** With Onyx in front, ask about the page ("what is this arguing?") or highlight a
passage first, just as in Onyx's ask box. The answer starts from the highlight or the page excerpt
and reads further into the page, or the files beside it, only when it needs to.

**Meeting Copilot.** While a meeting is live, ask about it ("what did Sam say about the deadline?",
"research their company", "ask the copilot what to push on"); its tools attach whether or not its panel
is on screen. "How am I doing?", "did I miss anything" and "wrap up" go straight to the copilot's own
check-in, with no model in front.

QuickAsk now supports screen context for CXMail and CXTasks. The context menu
selects Auto, General chat, or a visible window on the popup's display. Auto uses
Luna Decisions (or Jev in Settings) to decide whether the question needs that
app's MCP tools. General chat skips screen capture and routing.

Quick Ask can also turn your question and an Onyx document into a tracked
CXTasks task. Review its title, feedback, exact document and working folder, then
choose **File only**, **Open Claude in Herdr**, or **Background Claude** and
confirm. Nothing is filed or launched before confirmation. The updated companion
apps are in `dist`; run those versions to enable current-item tracking and task
handoff. Background edits use CXTasks' existing checkpoint and runner checks.

See [context routing implementation](docs/context-routing-implementation.md) for
setup, rebuilt companion apps, supported actions, validation and deferred work.

To continue without a tracked task, choose **Continue this chat in Herdr…** or
say “let's transfer this session to Herdr and have it do X.” Quick Ask infers the
action, provider, and folder and shows a small confirmation inside the chat.
Use **Change…** for overrides; it asks one question if the target is unclear. It carries
the completed chat and recent images into a fresh Claude or Codex tab through
the existing Herdr helper. This path works without CXTasks.

| Action | Control |
| --- | --- |
| Show / hide | Option–Space or click the menu bar sparkle |
| Send | Return |
| Insert a newline | Shift–Return |
| Stop the answer in the tab showing | Escape (while it answers) |
| Hide and return to previous app | Escape (otherwise) |
| Queue a message for when the answer finishes | Return while it answers (Stop or Escape puts the queue back in the box) |
| New chat | Command–N or the new chat button |
| Settings | Command–comma |
| Copy latest response | Command–Shift–C or a response's copy button |
| Keep popup visible after clicking elsewhere | Pin button |
| Paste clipboard into draft | Clipboard button or Command–V |
| Stop generation | Stop button |
| Stop app control globally | Option–Escape |
| Quit | Right-click menu bar icon → Quit QuickAsk |
| Resize | Drag an edge or the bottom-right corner handle |

If another app has registered Option–Space, QuickAsk reports the conflict. Free
the shortcut in that app, or select Option–Shift–Space in QuickAsk Settings.
The hotkey uses Carbon registration and doesn't need Accessibility or Input
Monitoring permission. It appears on the current desktop, including full-screen
Spaces, and initially positions itself on the screen containing the pointer.

## Glass appearance and size

**Automatic** uses Apple's native Liquid Glass on macOS 26 and later, laid out
like Control Center: a frosted regular-glass pane, interactive glass provider
pills, round glass buttons, and a subtle rim. The pane uses regular rather than
clear glass because clear glass goes nearly transparent while its app is active,
which QuickAsk always is while you type. **Darker prompt box** (on by default)
gives the prompt box its own darker glass for legibility; off, the box is the
pane's glass, outlined. **Clear glass, frosted prompt box** (off by default)
switches the pane to clear glass with full edge lensing and frosts only the
prompt box, with a behind-window blur. On
macOS 14–25 it uses a glass treatment based on CXTasks/CXMail: native desktop blur,
translucent dark panes, lighter chrome, and an opaque composer for readability.
You can also choose **CX glass** in Settings on newer systems.

The **Transparency** slider in Settings runs from opaque to more glass and saves
your choice. It starts at CXTasks' 38% default. In CX glass it changes the
pane/chrome opacity over AppKit's native blur. In Liquid Glass it adds a dark
wash over the glass, none at 100%. At 0%, either style uses solid surfaces.

The CX backdrop is a masked `NSVisualEffectView` installed as the window's
content view. Its blur, shadow, content clip, and rim share a 24-point rounded
outline, including during resizing. This avoids the square outer edge that
whole-window WindowServer blur can leave around a borderless popup. The CX
colors and opacity curves are retained; macOS controls the blur strength.

macOS Reduce Transparency switches either style to solid surfaces immediately
while preserving your slider setting; turning it off restores your choice. Increased Contrast
strengthens the rim. Codex controls are white and Claude controls are warm
orange.

The popup resizes from its edges or the visible corner handle. Width and the
compact and conversation heights are remembered across launches. Opening and
closing Settings keeps the current chat window's size and position; resizing
Settings updates the underlying chat's saved size. The prompt field grows with
the compact popup. Settings scroll inside the available space, with the header
and Done button always visible. The app still requires macOS 14 or later.

## Conversation behavior

The transcript stays in memory while QuickAsk is running. Hiding the popup keeps
your chat; New chat or quitting clears it, and summoning QuickAsk after it has been
hidden for 10 minutes starts a fresh chat. **My setup (Claude)** in the context menu
runs Claude as your normal session from your home folder (CLAUDE.md, memory, hooks,
MCP servers, tools, your own permission mode), and Auto picks it for questions about
your own work; it can make changes, so treat it like any Claude Code session (an unsent draft and an answer still
running are kept). Settings are saved in macOS preferences.
Each request supplies the completed conversation to the selected provider as
escaped JSON. That allows you to switch providers mid-conversation. An unfinished
assistant response is excluded from subsequent prompts. Long chats eventually
require starting a new chat; this version does not silently truncate history.

An emergency text export can be restored explicitly when launching a fresh app:
`open dist/QuickAsk.app --args --restore-chat /absolute/path/to/chats.json`.
This restores the selected chat, other exported tabs, and drafts, with all requests
stopped. It does not resume inference, pending actions, or desktop control. It is
a manual recovery path; chats are still held in memory during normal use.

The popup includes **text chat and experimental app control**. File/image attachments, voice,
saved chat history, and general agent tool approvals are not
implemented. Markdown emphasis, inline code, links, and line breaks are rendered;
full Markdown tables and fenced code highlighting are not yet implemented.

## Control an app or plugin

1. Bring the app you want help with to the foreground. For an audio plugin, open
   its editor inside your DAW first.
2. Press Option–Space and click **Control app**. The button names the selected app.
3. Enable QuickAsk under **System Settings → Privacy & Security → Accessibility**.
   For visual control of custom interfaces, also enable **Screen Recording**.
   QuickAsk Settings has buttons to request these permissions. Restart the app
   after granting Screen Recording if macOS asks you to.
4. Choose Codex or Claude, then ask for a concrete task: “Open the preferences,”
   “Find the oversampling setting,” or “Set the plugin's mix to 30%.”
5. Go back to whatever you were doing. Control runs **in the background**: your
   cursor, front app and window order are left alone, and a small blue agent
   cursor shows where QuickAsk is acting. Use **Option–Escape** or the Stop
   button to stop the request.

The same local MCP server gives both providers twenty tools: `inspect_ui` (the
accessibility tree, with element IDs that stay stable while the element exists),
`take_screenshot` (one app window, with numbered marks matching those IDs),
`click_element`, `click_coordinates`, `drag_coordinates`, `hover`, `set_value`,
`choose_option` (a popup or dropdown item by title), `type_text`, `press_key`,
`scroll`, `select_menu` (menu-bar commands by path), `batch_actions` (up to eight
element actions with one report), `wait`, `app_dictionary` and `app_script`
(below), the manual tools `search_manual` and `read_manual`, and `remember` and
`forget` for the app's memory. Every action returns what it changed in the tree,
plus a fresh screenshot after pixel actions, so the model rarely spends a turn
re-inspecting.

The model is told to take the fastest route that fits: the app's own AppleScript
when it has a dictionary, then menu commands and shortcuts, then element actions with
typed values, and screenshots with pixel clicks only for custom-drawn interfaces.
`app_script` runs the model's lines inside `tell application id "<the selected app>"`
in `osascript`, so it is stopped with the request or after 30 s. Before it runs, the
script's code (not its strings or comments) is checked, and anything that could reach
past that app is refused: other apps, shell commands and other scripts, raw event
codes, `use` statements, the environment, the clipboard, file reads and writes, URLs,
dialogs and handlers. A script that deletes, closes, quits, saves over the open file or
writes over an existing file also needs `confirmed: true`, which the model may pass only
after you approve that change in the chat. The work log shows each script's first line.
The first script macOS sees for an app asks whether QuickAsk may control it (System
Settings → Privacy & Security → Automation). App
interface text and screenshots are sent to the selected provider. Only windows
belonging to the app captured before opening QuickAsk are exposed.

Background input goes through private SkyLight calls (`Sources/QuickAsk/BackgroundInput.swift`):
the target window becomes key without being raised, and clicks and keys are posted
to its process the way Chromium and Electron accept them. Element tools act through
Accessibility, which also works on covered windows. When an app ignores background
input, the model can retry one action with `foreground: true`: QuickAsk waits for a
pause in your typing, brings the app forward, acts, and hands the front back. If a
macOS update removes the private calls, every action takes that foreground route.

Control starts off, is never saved as a preference, and ends with the request.
The helper uses a request-scoped revocable lease, a ten-minute deadline, and a
100-action limit. It requires an observation from the last minute before each
action (an action's own report counts), rejects vanished elements and
out-of-window coordinates, detects app restarts, pauses when you start typing or
clicking in the controlled app yourself, and refuses to type into or set secure
password fields. Stopping removes the control lease before terminating the CLI.
There is no network listening port.

### Manuals and memory per app

Each controlled app has a folder at `~/Library/Application Support/QuickAsk/Apps/<bundle id>/`:

- **`manual/`**: PDFs, HTML or Markdown. A manual shipped beside or inside the app is used
  where it is, without copying: DaVinci Resolve's 4,234-page PDF is found automatically.
  `bash scripts/fetch-fl-manual.sh` downloads FL Studio's online manual here. The agent
  searches it with `search_manual` (offline SQLite full-text search, BM25, headings from
  the PDF's table of contents) and opens pages with `read_manual`. The index
  (`manual-index.sqlite`) is built when a control request starts, Resolve's in about ten
  seconds, and rebuilt whenever a manual file changes.
  `QuickAsk --manual <bundle id> "query"` indexes and searches from the terminal.
- **`memory.md`**: what worked. Menu commands and shortcuts that changed something are
  recorded automatically, with counts. The agent adds one-line recipes with `remember`
  and removes wrong ones with `forget`. The newest notes and most-used paths (up to 8 KB)
  go into the prompt of every control request for that app, labelled as observations,
  never instructions. It is plain Markdown: edit or delete anything.

Notes are cleaned to one line of at most 300 characters, and there are at most 40.

Chrome, Edge, Brave and Electron apps build their page content into the accessibility tree
only while a window is visible. QuickAsk asks for it when you switch Control on (the app is
still visible behind the popup), and it stays available after the window is covered. If an
app has been covered since before that, `inspect_ui` says so, and `inspect_ui` with
`foreground: true` shows the app for a moment to build it.

`bash scripts/e2e-desktop.sh [QuickAsk.app] [--chrome]` drives a fixture app (and
an isolated Chrome profile) through every tool and checks after each step that
your front app and cursor never moved. It needs Accessibility and Screen Recording
for the terminal running it.

Audio plugins with custom-drawn controls may expose almost no accessibility
information. Screenshot-driven clicks and drags are available, but success on a
particular plugin must be verified; this is not an audio-plugin parameter API.
App control requires your explicit macOS permissions and has not been validated
against your DAW/plugin setup.

## Provider adapters

The UI depends on normalized text/status/error events. Provider-specific command
arguments and JSON decoding are contained in `Sources/QuickAsk/Provider.swift`.

- **Codex**: `codex exec --json --ephemeral --skip-git-repo-check
  --ignore-user-config --sandbox read-only --color never -`. Parses agent message
  snapshots and structured failures. This is Codex through ChatGPT authentication,
  not an automation wrapper around the ChatGPT website. Responses may arrive as
  complete message events rather than individual tokens. The read-only sandbox
  does not remove all Codex tool capabilities; the prompt requests direct chat.
- **Claude via Claude Code**: print mode with stream JSON, partial messages,
  no session persistence, safe mode, no built-in or MCP tools, and no automatic
  approvals. Safe mode retains subscription authentication; current `--bare`
  does not, so the adapter deliberately avoids it.

In app-control mode, Codex receives only QuickAsk's request-specific MCP config.
Claude uses restricted mode with user/project settings and hooks disabled, no
built-in tools, and an explicit allow list for QuickAsk's MCP tools. Neither
adapter modifies your saved MCP configuration.

Requests run in a temporary empty working directory. Commands launch directly
through `Process`; prompt text is written to stdin and never passed through a
shell. stdout and stderr are drained concurrently, UTF-8 is decoded after newline
framing, stale callbacks are discarded after cancellation, and requests time out
after three minutes. QuickAsk asks the CLIs not to persist session transcripts;
the CLIs may still maintain their own caches, diagnostics, and account state.

Sources: [OpenAI non-interactive mode](https://developers.openai.com/codex/noninteractive),
[Claude headless usage](https://code.claude.com/docs/en/headless), and
[Claude CLI reference](https://code.claude.com/docs/en/cli-reference).

## Build and test

Build with Apple's macOS 26 SDK or later to include
the Liquid Glass APIs; the resulting app can still run on macOS 14 and later.
Install the matching Command Line Tools, then:

```sh
bash scripts/test.sh
bash scripts/build.sh
open dist/QuickAsk.app
```

The build script selects the standalone Command Line Tools when available,
compiles against their SDK, creates an app icon, and ad-hoc signs the bundle.
It does not change your Xcode license or install anything system-wide. To choose
another matching SDK, set `QUICKASK_SDK`. Pass a destination app path as the first
argument to `build.sh` to change its output location.

The transport tests use fake executable fixtures; they do not send data to a
provider. They exercise both event formats, split Unicode, trailing JSON events,
error handling, prompt escaping, large stderr output, and cancellation.
Additional checks exercise scoped MCP configuration and keyboard chord parsing.

The source also has a Swift package manifest for use in an IDE. The build script
is the simplest way to produce the menu bar app bundle.


## License

QuickAsk is source-available under the [Business Source License 1.1](LICENSE): free for your own personal use and your organisation's internal use. It converts to the Apache License 2.0 on 2030-09-30. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the MIT-licensed techniques it reimplements.
