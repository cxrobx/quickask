# Validation

## Faster computer use: scripts, popups, batches (October 24, 2026)

- Four new desktop tools: `app_dictionary`, `app_script`, `choose_option`, `batch_actions`.
  The control instructions now rank routes: the app's AppleScript, then menus and shortcuts,
  then element actions with typed values, then screenshots and pixels. Prompted by the
  passport-photo session, where a dragged crop box and the Export dialog's Format popup
  took most of the run.
- `app_dictionary` reads the dictionary with `OSACopyScriptingDefinitionFromURL` (the
  `sdef` command needs Xcode). Pixelmator Pro: every name in 15 ms, the `export` entry with
  its formats, options and Pixelmator's own example script in 2 ms. TextEdit, which has no
  .sdef file, is covered by the unit tests.
- `app_script` live against TextEdit: about 0.5 s per script. A `tell application "Finder"`
  script and a bare `save` were refused before running. Against Pixelmator Pro 3.x, document
  queries (even `count of documents`) timed out with -1712 in plain `osascript` too, while
  app-level `get name` answered at once; the tool reported the timeout after 25 s.
  Relaunching Pixelmator cured it. Then, through the MCP server: `inspect_ui`, then one
  `app_script` that ran `resize image` to 600×600 at 300 ppi and `export … as JPEG` on a
  copy of the passport photo, 637 ms, output checked with `sips`. Running the same export
  again was held for confirmation because the file now existed.
- E2E (`scripts/e2e-desktop.sh --chrome`): all pass, including `choose_option` choosing an
  `NSPopUpButton` item in the background with the front app and cursor untouched, a three-step
  batch reporting its changes once, a batch stopping at a step that changed nothing, and
  `app_script` refusing an app without a dictionary. Unit tests: 803 checks pass, among them
  the refusal list (with quote-in-comment attempts to hide code) and the confirmation rules.

## Manuals and memory per app (October 16, 2026)

- Four new desktop tools: `search_manual`, `read_manual`, `remember`, `forget`. Menu listings
  now show each item's shortcut. Successful menu commands and shortcuts that changed
  something are recorded in the app's `memory.md`, under the app's real menu titles.
- DaVinci Resolve's bundled 4,234-page manual indexes in 9.8 s. On eight real questions
  (keyframes, retiming, render queue, transitions, color matching, Fairlight noise
  reduction, proxies, titles) the right section is in the top three every time, and first
  for seven. Table-of-contents pages used to outrank real sections; they now rank last.
- FL Studio: `scripts/fetch-fl-manual.sh` downloads Image-Line's public online manual
  (413 pages; Image-Line rate-limits fast fetching, so one page a second with back-off); it indexes
  in about a second. Sidechain, mixer routing, quantize, stem export, automation clips and
  tempo each find the right page.
- Live: given only "a manual is available", Codex searched it, read the page, used the
  menu command it described, and saved a one-line recipe with `remember` on its own:
  7 tool calls, 18 s.
- Chrome left its page out of the tree whenever its window had been fully covered since
  launch (the intermittent Chrome failure from the first round). Chrome builds page content
  only when the application element itself is queried while a window is visible; once
  built, it survives being covered. QuickAsk now primes it when Control is switched on, and
  `inspect_ui` explains a missing page and builds it with `foreground: true`. That route
  also raises the window through Accessibility, because `activate()` from a background
  process made Chrome frontmost without raising its windows.
- The end-to-end test now covers search, read, automatic recording, remember/forget,
  carry-over to a second request and the covered-Chrome path (61 checks, all passing with
  `--chrome`). It caught `remember` reporting "nOptional(1)". 508 Swift checks pass.

## Background app control (October 16, 2026)

- Control now runs in the background: QuickAsk focuses the target window without
  raising it (SkyLight focus record) and posts clicks, drags, scrolls and
  authenticated keys to its process. Verified on macOS 26.7.1 against an AppKit
  fixture and an isolated Chrome profile: `scripts/e2e-desktop.sh --chrome`, 51
  checks, all passing. After every action the user's front app (Ghostty) and
  cursor were unchanged.
- Found while building it: Chrome drops a whole background gesture when its
  click-group ID (field 58) is a full uptime value, so the ID is kept under a
  second's nanoseconds. Pixel clicks into Chrome land only after the focus
  record. An Accessibility press that timed out still ran, so the old
  "fall back to a pixel click" pressed twice; a timeout is now reported, never
  retried. Chrome builds its page tree one to four seconds after the first
  request, so the first inspection waits for the web area.
- New tools: `set_value`, `select_menu`, `hover`, `wait`; right and double
  clicks; `foreground: true` as a per-action fallback. Every action returns a
  diff of the accessibility tree, plus a marked screenshot after pixel actions.
  Element IDs survive refreshes. Inspection skips the menu bar.
- Live runs, same task (three presses, type into a field, set a slider, choose
  a menu command) against the fixture in the background: Codex 7 tool calls in
  15 s, Claude (Opus 5.5) 10 calls in 19 s, both with the correct end state.
- `command+a` then typing replaced a TextEdit document's text in the background.
  TextEdit's autocorrect panel then waited for the next event, as it does for a
  person typing.
- 484 Swift checks and the MCP protocol test pass.

## Clear-pane toggle crash (October 15, 2026)

- The app crashed (main-thread stack overflow in `cursorUpdate` forwarding
  between SwiftUI hosting views) after the user flipped **Clear glass, frosted
  prompt box**. Not reproduced in a harness that toggled it repeatedly with
  Settings open and with real pointer movement over the popup.
- Defensive fixes for the two new pieces on that path: the toggle now restyles
  the existing glass in place instead of rebuilding the window's view tree, and
  the prompt-box frost view is inert to hit testing, tracking areas and cursor
  updates. 294 checks pass; both looks unchanged in captures.

## Optional clear glass pane, frosted prompt box (October 15, 2026)

- Regular glass stays frosted while typing but loses the clear glass's edge
  lensing. New Settings toggle **Clear glass, frosted prompt box** (default off,
  persisted; the frosted regular pane stays the default): clear glass (tint
  0.16) with only the prompt box frosted by a behind-window `.hudWindow` blur,
  which does not depend on the app's active state. **Darker prompt box** adds
  a 0.32 black tint over that frost.
- Captured the real view focused over busy text: edge lensing restored, text
  behind the prompt box fully diffused, typed text legible with the setting on
  and off. Header and footer labels sit over the clear pane, as before.

## Frosted Liquid Glass while typing (October 15, 2026)

- Found why QuickAsk's glass barely blurred: `.clear` Liquid Glass turns almost
  transparent while its app is active, and QuickAsk is active whenever the user
  types. A harness hosting the real `PopupView`/`GlassPanelHost` showed the same
  code fully frosted when the app was inactive and see-through when active.
  Neither the deployment target (14.0 vs 26.0) nor the panel flags changed it.
  `.regular` glass stays frosted while active.
- Pane is now regular glass with a lighter dark wash (none at 100%); the prompt
  box is its own glass surface; header, paste and send buttons are glass circles.
- New **Darker prompt box** setting (default on, persisted): dark-tinted clear
  glass, or off: no surface of its own, just the rim over the pane's glass, so
  the popup is one uniform tone (nested glass always renders a second tone).
- Captured the real view focused over busy light/dark text: background fully
  diffused, white text legible in both settings; Settings shows the toggle; the
  CX glass fallback is unchanged. All 263 checks passed.

## Glass experiment rollback (October 15, 2026)

- At the user's request, restored the original public clear-glass pane and
  provider/control pills, tint, shading curves, rim, and dark appearance.
- Removed the private Control Center material adapter and the additional
  backdrop blur. Those experiments did not achieve the requested visual result.
- Retained the independent Settings window sizing fix and its layout checks.
- Rebuilt, signed, verified, and relaunched the canonical app. Preserved the
  unsent draft exactly across the reload and retained the current preferences.
  All 261 provider/transport/layout checks and desktop MCP protocol checks passed.

## Settings window layout fix (October 15, 2026)

- Coalesced native window resize requests onto the next main-queue turn so
  opening or closing Settings cannot resize its host during a SwiftUI update.
- Added an autoresizing content container inside the native glass, removing
  constraints across the glass view's internal hierarchy. Window resize events
  explicitly finish content layout; appearance changes also defer reparenting.
- Rebuilt, verified the ad-hoc signature, and relaunched `dist/QuickAsk.app`.
  Inspected repeated Settings icon, Done, and Command-comma transitions, plus
  Automatic → CX glass → Automatic. The header, prompt, and Settings actions
  remained aligned without manual resizing. Saved width and all three heights
  were unchanged; native glass and the original transparency were restored.
- All 261 checks passed: the existing 225 provider/transport checks plus 36
  hidden-window native layout checks covering repeated Settings transitions,
  500 × 360 Settings, restored prompt dimensions, and all three surface modes.
  Desktop MCP protocol checks and `git diff --check` also passed.

Validated locally on macOS 26.7.1, Apple Silicon, October 12, 2026.

- Native app compiled successfully against the Command Line Tools SDK with a
  macOS 14 deployment target; local ad-hoc signature verified.
- 29 provider/transport/configuration checks passed, including prompt escaping,
  Unicode framing, message deduplication, large stderr output, cancellation,
  scoped MCP configuration, and key chord parsing.
- MCP protocol tests passed: initialization, eight-tool discovery, notifications,
  expired lease denial, and unknown-method errors.
- A live ChatGPT/Codex request and a live Claude Code request both returned the
  expected answer using the existing account logins.
- In the actual popup, ChatGPT answered “Hello from QuickAsk.” Switching to
  Claude and asking it to repeat the previous answer produced the same answer,
  verifying context transfer through the UI.
- Both real CLI backends discovered QuickAsk's desktop MCP and invoked its
  inspection tool against an intentionally invalid test target. The bridge
  rejected that target, and both clients returned the expected error. No app
  content was read or controlled by this integration test.
- Popup layout, prompt focus, provider switching, expanded transcript, and the
  settings layout were inspected through native UI automation. Carbon hotkey
  registration succeeded; global shortcuts require a physical-key check because
  targeted app input automation does not exercise global Carbon hotkey routing.
- Native Liquid Glass and the selectable CX glass fallback were inspected in the
  running app. The transparency slider updated live from 38% to 48% and back;
  the saved value and style were confirmed in macOS preferences. ChatGPT uses
  white controls and Claude uses warm orange controls.
- A resized compact popup grew the prompt field and saved its width and height
  (563 × 245 points). Settings expanded separately without overwriting the
  compact height. Standard edge resizing and a visible corner handle are enabled.
- The binary records a macOS 14 minimum and SDK 26.5. Liquid Glass APIs are
  weak-linked and guarded by OS availability checks. The CX fallback was
  previewed on macOS 26; execution on an older macOS release was not available
  for validation.

Actual desktop inspection, screenshots, clicks, drags, and typing require the
user to grant macOS Accessibility and Screen Recording permissions to QuickAsk.
These actions have not yet been verified on the user's DAW or plugins. Custom
plugin interfaces vary and need application-specific testing.

## Rounded backdrop and settings fixes (0.3.1)

- Replaced whole-window CGS blur with a public AppKit effect installed as the
  content view, using a resizable 24-point mask that also shapes the shadow.
  The content clip and rim use the same circular corner geometry. The window
  background is fully clear so it cannot add a rectangular outer outline.
- Disabled generated SwiftUI hosting size constraints and pinned the hosting
  view to the native backdrop. The prompt now reads the actual viewport from
  an outer GeometryReader, avoiding the expanded-height feedback that was
  reproduced when closing Settings.
- In the running app, tested CX Settings at 500 × 360 points, scrolled to the
  bottom, closed to the 500 × 222 compact popup, and reopened at the top.
  Header, footer, and Done remained visible; the compact prompt was fully shown.
- Tested corner resizing to a larger Settings window and switching between CX
  glass and native Liquid Glass, then closing Settings in Liquid Glass. Settings
  height saved independently; compact dimensions and transparency were preserved.
- Build completed successfully and the updated ad-hoc signature was verified.
  macOS manages CX blur strength; the slider retains the CX opacity curves.

No launch-at-login setting or system-wide installation was performed.

## Direct ChatGPT and project migration (0.4.0, October 13, 2026)

The experiment recorded here, and the vendored DevKit, were removed from the public repository.

- Canonical source moved to `~/projects/quickask`, initialized as a Git repository,
  registered as the `quickask` Codex project, and this chat attached to it.
- Official documentation explicitly supports personal projects running locally
  and eligible Plus/Pro plan usage through OAuth and Responses. The preview
  supports namespaced local function tools, which QuickAsk uses for the existing
  guarded desktop helper. Hosted computer use and hosted MCP are not used.
- All 57 upstream OAuth/JWT/refresh/encrypted-storage/error tests passed using
  synthetic accounts and mocked network responses. The SDK revision and our two
  modifications are recorded in Vendor/siwc/PROVENANCE.md.
- Nine direct-stream/tool-loop tests passed: Unicode, completion requirements,
  truncation, usage-limit handling without paid fallback/retry, namespaced
  local tools, screenshot outputs, unexpected tools, cancellation, and incomplete
  responses. No live inference or private app content was used in these tests.
- All 29 existing Swift provider/transport checks and the MCP protocol checks
  passed. The new app compiled successfully and its ad-hoc signature was verified,
  including the bundled Node runtime.
- Inspected the running compact UI at 500 × 222 points with ChatGPT, Codex, and
  Claude. Inspected scrollable Settings with Continue with ChatGPT and Manage
  usage visible. Existing appearance and dimensions were preserved.
- The user completed the separate OAuth consent. Settings showed the connected
  ChatGPT plan and account-specific GPT-6.1-Sol model. A live direct request in
  the popup returned exactly “QuickAsk direct chat works.” and completed, using
  the bridge's response.completed success requirement. OpenAI's plan-sharing
  help article states that eligible requests count toward ChatGPT Work and Codex
  usage; this connection does not expose the ordinary Chat allowance.
- The bundled DevKit is under its Noncommercial License; the source and app retain
  its provenance, modification notices, and license, plus dependency/Node notices.

## Two-provider simplification (0.4.1, October 13, 2026)

- Removed direct ChatGPT from the provider enum, send flow, account UI, startup,
  and release bundle. Saved direct-ChatGPT selections fall back to Codex.
- Retained the experiment source and its license/provenance notices; existing
  encrypted connection records were not accessed or deleted.
- Built and signed a stable source snapshot with the concurrent context-routing
  work preserved. All 64 provider/transport checks and the desktop MCP protocol
  checks passed. The release bundle is approximately 1.7 MB without Node.
- Inspected the running popup with only Codex and Claude and Settings with only
  their CLI configuration. Liquid Glass and saved 49% transparency remained.
- Live requests completed with exactly “QuickAsk Codex works.” and
  “QuickAsk Claude works.” in General chat. Restored automatic context and
  left Codex selected with a fresh chat.
