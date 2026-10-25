# Quick Ask: screen context and MCP routing

Status: approved routing design; implementation and validation are recorded in
`context-routing-implementation.md`. The task handoff below extends the approved
scope following the request to delegate work from Onyx.

## Task handoff extension

Quick Ask can file a task from any visible context, including an Onyx document,
and optionally start Claude using CXTasks' existing dispatch implementation.
The review opens only when the user explicitly asks for a task: a message that
says to create, file, add, make or log a task, or to turn something into a task
(a fixed text rule, checked before routing, so it needs no routing credentials),
or the context menu's **Create task from this question…**. The router is never
offered a task choice, and asking to start an agent without asking for a task
does not open it. The review does not create a task or grant the answering model
launch tools.

The review contains an editable title, the user's feedback/instructions, the
exact source document if available, and the working folder. Its execution choices
are **File only**, **Open Claude in Herdr**, and **Background Claude**. The button
names the selected action. Cancellation preserves the original question. A
document edit requires a concrete local file; unknown paths and remote URLs must
be resolved by the user. Onyx supplies its active document and displayed revision
through a read-only local interface. An open editor must be saved/closed first.

On confirmation, revalidate the selected display/window/document and its version,
then pass the reviewed proposal through a local, owner-only CXTasks handoff
interface. CXTasks creates the task first, including source path and instructions,
and records the dispatch attempt. It reuses the same foreground Herdr launcher
or background queue guards as the existing CXTasks UI. Background file writes
are an explicit choice; shell and remote writes are not enabled by the handoff.
The review shows the existing background permissions and runner limitations.
If its recurring runner is off, an optional, separately labeled checkbox permits
CXTasks' existing **Run queue once** action. The review explains that this also
picks up other eligible tasks already queued; it never installs a recurring runner.

A stable proposal ID prevents duplicate tasks. Once a launch attempt is recorded,
repeated confirmation does not launch a second session. A launch failure leaves
the filed task available and reports its actual result. A queued task is described
as queued, never as running without evidence. No approval flag, queue tool, or
background permission is exposed to the answering model's ordinary MCP gateway.
The external CXTasks worker is separate from Onyx's read-only answering models.

## Direct Herdr continuation

**Continue in Herdr…** exports a completed Quick Ask conversation and an editable
next instruction into a fresh interactive Herdr tab. An explicit request such as
“let's transfer this session to Herdr and have it do X” opens the same review.
This path does not contact CXTasks, create a task, or enter its background queue.

The review is a small confirmation card inside the chat, with the conversation
still visible. It infers the answering provider from the current chat, extracts
the next action from the transfer request, and resolves an existing working folder
from document context, exact paths already discussed, or saved project mappings.
It shows the action and destination, with **Open in Herdr**, **Change…**, and
**Cancel**. Change reveals the optional provider, instruction, and folder controls.
Ambiguous targets produce one inline question with concrete choices. A document
edit with no context asks only for its document. A general continuation uses a
private Quick Ask session folder. No missing path is invented or replaced with home.
Current screen context is added only for an explicit visible-item reference or
manually selected window, then revalidated before launch. Cancellation preserves
the chat and unsent question.

On confirmation, freeze the full completed conversation and next instruction in
owner-only local files and invoke the existing `cx-open-in-herdr` router with a
launch script passed as argv. Launch the selected CLI directly with its existing login and normal
interactive settings and approvals. No request-scoped Quick Ask tool leases,
CXTasks write-back setup, or automatic permission-bypass flags are added by this
path; the CLI's normally configured tools remain available.
The handoff starts a new CLI session seeded with the conversation, rather than
claiming to resume a hidden CLI session ID. A failed or unconfirmed launch is
shown and is never automatically retried. A repeated confirmation cannot open
another tab for the same proposal.

## Intended behavior

Quick Ask uses the app content on the display containing its dialog to answer
contextual questions and perform supported actions. One routing check decides
whether the question relates to that content, an existing project, or neither.
Unrelated questions use ordinary chat.

The routing engine and the answering provider are independent. A user can use
OpenAI's Decisions API to select context and Codex or Claude to answer
and use tools.

## 1. The dialog determines the display

“Screen” means a physical display, within its currently visible macOS Space.

- On opening, place Quick Ask on the display containing the pointer. Preserve a
  dragged position when it is on that same display; a previous position on
  another display must not override the current invocation.
- If the dialog straddles displays, use the display containing the greatest
  area of the dialog. Break a tie using the dialog's center.
- Prefer the previously focused app window if it is visible on that display.
  Otherwise consider the foremost ordinary app window on that display. Exclude
  Quick Ask, desktop surfaces, menus, and system overlays.
- Show the chosen app/window before sending. When multiple visible windows
  could be intended, the context menu offers those windows on this display.
- An app focused on another display does not supply context. Offer a “Move to
  focused app” action that moves the dialog before selecting that app.
- Moving the dialog to another display invalidates its previous screen context.
  Refresh the candidate locally; do not run a model check while the user drags.
- If no eligible window is visible, show “No screen context.” General chat
  remains available.

The popup's position is the boundary for automatic screen context, rather than
global app focus. A registered project selected explicitly by the user is
intentional additional context, not an automatic inference from another display.

## 2. User experience

Replace the generic “/ anywhere” label with a context menu:

- **Auto · CXMail** before sending: a candidate, not a claim that tools are active.
- **App · CXMail · Invoice thread** or **Screen · Ghostty · ~/Projects/quickask**
  after a clear route, with `read-only`, `screenshot` and a project name added
  when they apply.
- **Auto · all context · CXMail · read-only** when relevance was unclear.
- **General chat** when the question does not need screen context.
- **Choose context** when the router failed.

The menu contains Auto, General chat, eligible windows on this display, and
registered projects. Manual selection overrides automatic routing. General chat
skips screen-content capture and the routing service.

The existing “Control app” option remains a separate explicit capability for UI
clicks, typing, and scrolling. Connecting an app MCP does not automatically enable
desktop control.

Sending follows this sequence:

1. Resolve the dialog's display and candidate window.
2. Read a fresh, bounded context snapshot.
3. Run one routing call with several questions and combine the answers (section 4).
4. Show the route and expose the corresponding tools to the answering provider.
5. Answer or perform the requested supported action, then report its actual result.

An unclear result sends all the context read-only rather than asking; the label
says so. Only a router failure produces the inline picker, preserving the prompt.
Write tools are attached only on a clear route to a connected app with a clear
action.

## 3. Context collection

Collect on opening only enough local metadata to label the candidate. Collect
content when the user sends a question in Auto mode. There is no continuous
screen recording or background classification.

Use these sources in order:

1. **Structured app context:** a small local interface returns the current
   view, selected record IDs, labels, and revision. This is the preferred source
   for CXMail and CXTasks, and later Onyx.
2. **Accessibility:** the selected window's title, URL/document path where
   exposed, visible text, and selection.
3. **Local text recognition:** when necessary and permitted, capture only the
   selected app window and extract its text locally. The router receives text,
   not a screenshot, even if its backend accepts images: routing needs titles
   and labels, not pixels. The answering provider receives an image only when
   the task needs visual understanding.

The snapshot carries display ID, window ID, app bundle ID, process identity,
capture time, selected record IDs, a bounded text excerpt, and a selection
revision where available. It remains in memory for the request.

Structured context is also what makes “this email” or “this task” reliable. The
MCP server's access to app data does not by itself reveal the frontend's current
selection. When only text is available, resolve it through the app's search/read
tools and require a unique match; do not manufacture record IDs.

Missing macOS permissions do not block ordinary chat. A question that depends on
unavailable screen context retains its prompt and shows the missing capability.
Structured app context should not require screen capture when it already provides
the needed information.

## 4. One routing call, several questions

Auto mode makes one call to the routing service. It carries several bounded
questions, and Quick Ask combines their answers locally with fixed rules (the
decision matrix below). There are no chained model calls. Start with OpenAI's
Decisions API (`gpt-6-luna`) as the default backend; support TypeSafe's Jev as an
alternative behind the same interface. Both answer several questions per request.

Decisions is the default on CXTasks' own measurement (`cxtasks/docs/jev.md`, 270
labeled tasks, 2026-10-06): on project choice it matched or beat Jev (49.3% vs
44.8% top pick; 81% vs 74% precision at each engine's tuned bar), answered at
~130 ms p50, and runs under OpenAI's API terms (30-day abuse logs, no stored
application state) where TypeSafe states no deletion window. Cost is ~$0.50 per
1,000 calls against Jev's ~$0.10, which is negligible at Quick Ask's volume.

The router's state contains:

- The latest question, and whether images are attached (their count, not their
  pixels).
- The last four messages, for follow-ups.
- Every eligible window on the dialog's display (app, title), marking the
  candidate.
- The candidate window's metadata: app, title, document path, URL, and the
  selected record's labels. Bounded body text only when there are no labels.
- The connected apps that are visible, with their tools.
- The user's CXTasks projects and their repository folder names.

It answers these questions:

| Question | Kind | Asked when |
| --- | --- | --- |
| `self_contained`: answerable without the screen | yes/no | always |
| `needs_screen`: needs a visible window's content | yes/no | always |
| `needs_visual`: needs to see the screen, not just its text | yes/no | always |
| `about_attached_image`: about the attached image | yes/no | images attached |
| `wants_app_action`: asks to change something in a connected app | yes/no | a connected app is visible |
| `follow_up`: depends on the previous exchange | yes/no | there is a previous answer |
| `target`: which visible window, or none | choice | always |
| `project`: which CXTasks project, or none | choice | projects exist |

Each answer stands alone. A refused, missing, malformed or duplicated answer is
no judgment for that question only. Only a call with no usable answers at all,
a timeout, or missing credentials counts as a router failure.

**Decision matrix.** Bars are per engine and provisional: a "yes" is at or above
the high bar (Decisions 0.90, the Settings value; Jev 0.80), a "no" at or below
the low bar (0.25 / 0.30), and a window or project pick needs 0.80 / 0.70.

| Result | When | What is sent |
| --- | --- | --- |
| General | `needs_screen` is a no, the question isn't a follow-up to a screen answer, no screenshot is needed, and it is self-contained, about the attached image, or targets no window | The conversation only |
| Screen | `needs_screen` is a yes and `target` picks a window | That window's content; its connected app's read tools; write tools only if `wants_app_action` is a yes |
| All context | Anything else | The target (or candidate) window's content and the other windows' titles; read tools only |

**Tools on demand.** The router is also asked, per tool, whether the request
needs the vault, CXTasks or CXMail; a yes attaches that tool to whatever the
route is, General chat included, read-only unless `wants_app_action` is a yes.
Margin is never judged by the router: it attaches only when the message names
it, with writes allowed.

**My setup.** While Claude is selected the router is also asked `about_my_work`.
It has its own bar (Decisions 0.70, Jev 0.60) because the costs are lopsided: a
false positive costs a few seconds in the user's own session, a miss answers a
question about their work with no access to it. The question is judged from the
question and conversation alone, so unrelated screen text can't talk it down.
When it clears that bar and the screen is not clearly needed, the question runs as the user's
normal Claude session from the home folder (their CLAUDE.md, memory, hooks, MCP
servers, tools and permission mode), with no screen content. The context menu
offers it directly as **My setup (Claude)**.

A screenshot of the dialog's display, with Quick Ask excluded, is added when
`needs_visual` is a yes. Without Screen Recording permission the text is sent
and the status says so. A confident `project` is passed to the answer as a hint
and shown in the label. Uncertainty never adds write tools: a request that
wanted a change but was routed uncertainly is answered read-only, and the model
says the change wasn't made.

The picker appears only on a router failure. It offers General chat and the
visible windows. Choosing a window uses exactly that window: its content, and
all of its connected app's tools.

The routing service has no tools and cannot perform actions. Its answers are
probabilities over offered questions and window/project keys; application code
maps keys back to windows and projects. The model never supplies executable
commands, MCP endpoints, filesystem paths, or permissions.

Relevance is about the user's request, not product keywords. “Draft a reply about
lasagna” can be a CXMail request; “How do I cook lasagna?” remains general even
with an email open.

Initial deadline: two seconds, cancellable, without automatic retries against the
same backend. Routing runs before every Auto-mode answer, so target a median under
300 ms from send to route and measure it in validation.

Routing credentials are configured separately from the answering-provider login.
Decisions uses `OPENAI_API_KEY` and Jev `TYPESAFE_API_KEY` (environment, else the
login Keychain), as CXTasks does.

## 5. App adapters and project registry

Each app adapter declares its bundle IDs, MCP transport and connection details,
an explicit allowlist of tools, and a context reader. Register CXMail and CXTasks
explicitly; do not load every server from the user's global MCP configuration.
A tool not on the adapter's allowlist is not exposed, even if the app's server
offers it.

| Adapter | Context | Allowed tools (initial) |
| --- | --- | --- |
| CXMail | Account, folder, message/thread identity, selection revision | `list_accounts`, `list_folders`, `search_emails`, `read_email`, `read_thread`, `list_attachments`, `compose_draft`, `edit_draft`, `archive_email`, `flag_email`, `move_email` (not into Trash or Junk). |
| CXTasks | Task ID, project ID, current view, selection revision | `get_task`, `list_tasks`, `search_tasks`, `file_task`, `update_task`, `complete_task`, `comment_task`. |
| Projects | Registered project and exact configured folder(s) | Read/search relevant files; expose scoped edits only for an explicit edit request and enabled capability. |

Destructive or outward-facing tools are excluded from the initial allowlists:
CXMail's `delete_email`, `bulk_delete_emails`, mail-rule and group changes, and
calendar tools; CXTasks' `archive_task`. CXMail's delete tools are guarded only by
a `confirmed=true` argument (`cxmail-mcp/src/mcp/server.rs`), which the answering
model would set itself. If a destructive tool is added later, Quick Ask shows its
own confirmation naming the exact target, and the gateway, not the model, supplies
the confirmation argument after the user accepts.

Onyx answering tools are deferred to a later phase; the task handoff extension
above adds only its read-only active-document interface. It currently uses MCP servers but provides none,
so an Onyx adapter is a new server to build in that repo, not an inventory of an
existing one.

The project registry contains IDs, names, aliases, descriptions, and exact context
folder mappings. Reuse CXTasks' project/repository mappings where appropriate;
support a separately configured context folder because a project's knowledge
folder need not be its code repository. A project with several applicable folders
uses the explicit visible path or a folder picker.

The classifier chooses a project ID; Quick Ask resolves the folder from the
registry. “None” is valid. An unavailable folder is shown as unavailable, never
replaced with a parent directory or the home folder.

One primary route is selected per request. A request to turn the visible item
into a task opens the task review (above) with that item as its source, rather
than attaching a second connector.

## 6. Shared tool gateway

Add a provider-independent local gateway that exposes the selected app MCP tools
or scoped project tools. The both CLI adapters consume
the same resolved context and capability list.

Build the gateway by extending Quick Ask's existing `quickask` stdio MCP server
(the desktop-control server), not as a second component. `Provider.swift` already
injects that server into both CLIs, with `--strict-mcp-config` and a tool
allowlist for Claude and `required=true` for Codex. The gateway adds proxied app
tools and project tools to the same server and the same allowlist.

The gateway keeps connector tool names distinct, forwards app calls, checks the
request's allowed capability set, and handles cancellation. Project tools enforce
canonical folder boundaries, including symlink escapes. A working directory and
prompt instruction alone are not a filesystem boundary; provider built-in tools
must be disabled or isolated consistently with the selected capability set.

The Claude path already meets this: it runs with `--tools ""`. The Codex path
does not. It runs `codex exec --sandbox read-only`, which keeps Codex's shell, and
a read-only sandbox can still read files outside the project folder. Until a
mechanism is named that removes or confines Codex's built-in tools, Project routes
are unavailable when Codex is the answering provider; the context menu shows them
as unavailable for Codex rather than offering a boundary it cannot enforce. App
routes are unaffected, since they expose no file access.

Actual data access and actions go through the app's supported MCP tools. Existing
app authentication, live refresh, and tool-specific review requirements remain
authoritative. The user's explicit action request authorizes that supported
action; the relevance classifier does not authorize additional actions.

CXMail's current MCP deliberately disables direct email sending. This initial
design supports its draft/review-in-CXMail flow. Sending from Quick Ask would be a
separate feature requiring a change to CXMail's existing send contract; desktop
control must not bypass that restriction.

Treat screen text, email content, files, and tool results as data rather than
instructions that can change the route or expand access.

## 7. Freshness, follow-ups, and failure behavior

- Freeze display, window, selected item, folders, and allowed tools for each
  request. Refresh context and rerun routing for the next Auto-mode question.
- Follow-up history may explain intent, but must not silently override the new
  display or app selection. Show a changed context clearly in the chat.
- Moving the dialog or changing its selected app item during a request must not
  retarget an action. Stop new contextual actions on a display change; revalidate
  item identity/revision before writes. Completed actions are not undone.
- A read about the originally selected item may finish without affecting a
  newly selected item. A changed write target requires a fresh request/selection.
- Stop cancels routing and blocks new gateway calls before terminating provider
  work. An operation already accepted by an app may finish; report its confirmed
  status rather than implying rollback.
- A missing/disconnected MCP is named in the dialog. Do not substitute UI clicks
  or claim an action succeeded.
- A pinned dialog refreshes from its own display on send, even though Quick Ask
  itself is now the globally focused app.

## 8. Validation criteria

| Scenario | Expected result |
| --- | --- |
| CXMail visible; “Summarize this thread” | Resolve the selected thread, connect CXMail, summarize actual data. |
| CXMail visible; “How do I cook lasagna?” | General chat; no app tools attached. |
| CXTasks visible; “Mark this complete” | Resolve and revalidate the selected task, complete it, report the result. |
| Registered project content visible; “Explain this error” | Select the matching registered folder, read relevant context. |
| Two plausible projects | No project hint; no guessed folder access. |
| Unclear relevance | All context, read-only; label `Auto · all context`. |
| Visual question | Display screenshot added (Quick Ask excluded); without permission, text only and the status says so. |
| CXMail focused on display A; Quick Ask on display B | Display A contributes no automatic context. |
| Dialog moved between displays | Candidate/badge refresh; previous display context is invalidated. |
| Pinned popup with another app behind it | Resolve the eligible window on the popup's display, excluding Quick Ask. |
| User selects another item before an action | No silent retargeting; revalidation prevents a stale write. |
| User selects General chat | No screen-content collection or routing call. |
| Router timeout, invalid choice, refusal, or missing credentials | Preserve prompt and show known choices; no accidental tool exposure. |
| Request to delete an email or archive a task | Tool not exposed; the answer says it is unavailable from Quick Ask. |
| Project route with Codex selected | Project shown as unavailable for Codex; no file access. |
| App MCP unavailable | Visible connection failure; no false success or automatic UI fallback. |
| Folder symlink points outside registered scope | Access is rejected by the gateway. |
| Stop during routing/tool use | No new calls; accurately distinguish completed and pending work. |

Use representative labeled questions to measure false contextual routing and
missed contextual requests, and tune the Decisions confidence bar on half of them
and check it on the other half, as CXTasks did. Record routing latency (median and
95th percentile) against the target in section 4. Test behavior across two
displays, full-screen Spaces, several windows from one app, and both
answering-provider paths.

## 9. Implementation order after design approval

The first routing version is steps 1–3: CXMail and CXTasks. The task handoff
extension above adds Onyx document identity. Steps 4 and 5 are
separate follow-ups.

1. Display/window selection, context badge, overrides, and request lifecycle.
2. Shared context snapshot and the single bounded routing check.
3. Gateway (extending the `quickask` MCP server) with the CXMail and CXTasks
   allowlists, plus their current-selection interfaces.
4. Registered project folders and enforced scoped file tools. Codex support for
   Project routes waits on the built-in-tool mechanism in section 6.
5. An Onyx MCP server and adapter, built in the Onyx repo, followed by end-to-end
   validation.

Application code has not been changed for this proposal. Work in CXMail and
CXTasks (current-selection interfaces) and, later, Onyx (an MCP server) is an
explicit dependency of reliable structured selection, rather than something their
existing MCP connections should be assumed to provide already.
