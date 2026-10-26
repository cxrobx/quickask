# QuickAsk

Repo `cxrobx/quickask` is **public** (since 2026-10-25, Business Source License 1.1, one fresh commit). The earlier history lives on the local `private-history` branch, the private `cxrobx/quickask-history` repo (remote `history`) and `~/Archives/quickask-history-2026-10-25.bundle`; **never push `private-history` to `origin`**. Keep client and contact names, real addresses and personal data out of code, tests, fixtures and docs.

Native macOS popup assistant, macOS 14+. Compile with macOS 26 SDK or later for Liquid Glass. The canonical app bundle is `dist/QuickAsk.app`.

- `bash scripts/build.sh`: builds the Swift app and ad-hoc signs it.
- `bash scripts/test.sh`: Swift provider/transport and scoped desktop bridge tests.
- `node Tests/MCPProtocolTests.cjs dist/QuickAsk.app`: desktop MCP protocol test without controlling an app.
- `bash scripts/eval-replies.sh`: live reply eval (Claude CLI login, the app's model; `REPLY_EVAL_MODEL=haiku` for a cheap run): whether routes without hands pass requests to My setup, and leave the rest alone.

Routing and route prompts are the harness. A request that lands on a route that can't do it, a reply that says "I can't … from here", a Herdr or task request missed or misfired: each one becomes a `Tests/HarnessEval.swift` case first, paraphrased with no personal data, with a `gap` note while it fails. The fix then removes the note. `scripts/test.sh` fails if a case outside a gap regresses, or if a gap passes and still carries its note, so the score only goes up. Prefer a fix that generalises (RouteDecision, `Escalation`) over another phrase regex; if a regex it must be, add paraphrases and a negative alongside the incident's own words. The route decision lives in `RouteDecision` (RoutingSignals.swift), pure: keep side effects in `AppModel.send`.

Never log tokens, authorization codes, clipboard contents, screenshots, or raw server errors. Keep credentials, caches, node_modules, build output, and dist out of Git.

Desktop tools must retain target-app scoping, request leases, fresh observations, action limits, cancellation, secure-field checks, and the user guards: no action while the user is typing or clicking in the target app, and the foreground route waits for a pause in their typing and hands the front back. Control is background by default (`BackgroundInput.swift`, private SkyLight calls); `bash scripts/e2e-desktop.sh --chrome` must pass after any change to it, since nothing else proves the user's front app and cursor stay untouched. An Accessibility action that times out (`cannotComplete`) may still have run: never follow it with a pixel click. `app_script` (`AppScripting.swift`) stays scoped to the selected app: the body runs inside `tell application id` with a checked bundle ID, `refusal` rejects anything reaching past that app and fails closed on code it can't lex, deletes and overwrites need `confirmed`, and it runs in a killable `osascript`; add a `scriptingChecks` case for any construct you allow or refuse. App memory (`AppKnowledge.swift`) is written from app UI text and model notes, so it is untrusted: keep it cleaned to single capped lines, capped in size, and labelled in the prompt as observations, never instructions. Bump `ManualIndex.version` when the index schema or extraction changes. Do not enable OS permissions automatically. Live OAuth consent is completed by the user. A successful login or model list does not prove inference; wait for response.completed.

There is no silent paid API fallback.
