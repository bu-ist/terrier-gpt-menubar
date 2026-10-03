# TerrierGPT Menu Bar App

A macOS menu-bar shell around [TerrierGPT](https://terriergpt.bu.edu) (campus) and
[TerrierGPT nonprod](https://test.terriergpt-nonprod.bu.edu/) (AIDA test) — the chat, plus the two
things a browser tab can't do: pull in what you're looking at elsewhere on the Mac, and put the
answer somewhere it still exists tomorrow.

## What it does

- Lives in the menu bar (sparkles icon); click for the full TerrierGPT interface
- **Prod | Test toggle** in the panel header (persists). Test is
  `https://test.terriergpt-nonprod.bu.edu/` — use it for CTS Ticket Search Desk / KB Desk.
  An amber **TEST** badge shows whenever you are not on campus prod.
- **Capture context** from the frontmost browser tab, the Finder selection, the clipboard, or
  your own selection inside the chat — each one shows up as a chip you can switch in or out of
  the prompt
- **File answers out** to Apple Notes, Reminders, and Calendar without leaving the panel
- **Services menu** entries (*Ask / Summarize / Explain with TerrierGPT*) in every app that can
  put text on a pasteboard
- **Shortcuts & Spotlight** actions via App Intents
- External links open in your default browser; BU/SSO navigation stays in the panel
- No Dock icon (`LSUIElement`), optional Launch at Login

## The panel

Built against the macOS 27 SDK using Liquid Glass.

| Piece | What it does |
|---|---|
| Header | Name, a status dot, and three controls: Back/Forward (only once there's history), Capture, and ⋯. Reload, Open in Browser, the Prod/Test instance, Launch at Login, and **Automation** (chains, inbox, JSON handoffs, folders) live in ⋯ |
| Session status | A green dot when signed in; a labelled pill (Connecting / Signing in / Signed out) only when something needs attention |
| Context tray | Capture chips, tinted per source, morphing in and out via `glassEffectID`. **Copy prompt** (⇧⌘C) lives here, next to the captures it copies |
| Action dock | *Save to* Notes · Reminders · Calendar (icon buttons with tooltips) and one primary **Hand off** button |
| Toast | Floating glass, replacing the old inline status strip that reflowed the page every time it appeared |
| Backdrop | A very faint animated `MeshGradient`. Glass is a lensing material — it has nothing to show unless something moves behind it |

Motion comes from one vocabulary in `TG.Motion` (`snap` / `morph` / `drift` / `ambient`) so
nothing moves differently from anything else. **Every animated surface routes through
`.tgAnimation`, which drops to no animation under Reduce Motion**, and the mesh backdrop stops
entirely.

## Integrations, and why each one works the way it does

| Target | Mechanism | Why |
|---|---|---|
| Safari, Chrome, Edge, Brave, Arc, Dia, Vivaldi, Opera, Orion, Safari TP | AppleScript | No other way to read another app's active tab |
| Finder | AppleScript | Same |
| Notes | AppleScript | Notes has no public framework API |
| Reminders | **EventKit** | Real permission model, typed errors, works whether or not Reminders is running |
| Calendar | **EventKit** | Same |
| Any app with selectable text | **Services menu** | No scripting, no Automation permission, works everywhere |
| Shortcuts / Spotlight | **App Intents** | Typed parameters, no `.sdef`, no Automation prompt to script *this* app |

Two details worth knowing:

- **Selected text in a browser needs one extra opt-in.** Reading the tab's title and URL works
  out of the box; reading the *selection* runs `getSelection()` through AppleScript, which
  Safari and the Chromium browsers both gate behind "Allow JavaScript from Apple Events"
  (Safari: Develop → Developer Settings; Chromium: View → Developer). Without it the capture
  still succeeds with the link, and the chip tells you exactly which menu item to turn on.
- **Nothing types into the chat box.** That would mean injecting JavaScript into markup we
  don't control, and one redesign upstream would break it silently. Captures compose into a
  prompt on the clipboard; you paste with ⌘V. Boring, but it keeps working.

### Permissions

On first use macOS will ask for:

- **Automation** → Safari / Chrome / Finder / Notes, per app, on first capture
- **Reminders** and **Calendars** → on first file-out

If you deny one by accident, the failure toast has an *Open Settings* button that goes to the
exact pane. `AUTOMATION_APPLE_EVENTS = YES` is set on the target, which is required for Apple
Events under the hardened runtime.

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘R | Reload |
| ⌘[ / ⌘] | Back / forward |
| ⇧⌘B | Capture the frontmost browser page |
| ⇧⌘F | Capture the Finder selection |
| ⇧⌘V | Capture the clipboard |
| ⇧⌘C | Copy the composed prompt |
| ⇧⌘J | Hand off the answer to Claude, Gemini, or Grok (then ↩ for the last one used) |
| ⌘L | Focus the chat |
| ⌘Q | Quit |

## Hand off to Claude, Gemini, or Grok

**Hand off** (or ⇧⌘J) asks where the answer should go and does the rest in one click:

1. Writes a Markdown **brief**: what you need the next assistant to do, the question you asked
   TerrierGPT, the context you captured (if included), TerrierGPT's full answer (or your
   selection), its JSON block when it has one, and the conversation title, link, and time.
2. Puts the brief on the clipboard and saves it next to the JSON envelope in the handoffs
   folder (`<stamp>-….md` and `latest.md`; `latest.json` is still written for recipes).
3. Opens the assistant — the desktop app when installed (Claude, Gemini, a Grok web app in
   `~/Applications`), else claude.ai / gemini.google.com / grok.com. Claude and Grok get the
   brief prefilled through `?q=` when it's under 6,000 characters; otherwise, and always for
   Gemini, paste with ⌘V.

The picker has a *What should it do?* field (empty means "pick up where TerrierGPT left off")
with one-click suggestions: Fact-check, Go deeper, Draft a reply, Summarize. The last
assistant you chose is remembered and answers to ↩.

## Handoffs to scripts and agents (phase 1)

A TerrierGPT answer can end in a fenced ```json block that follows a contract from
`cts-ai-working-group/docs/contracts/` (`kb-gap-verdict`, …). **Handoff** pulls that block out
and writes it to a file that Claude, Grok, or a script can pick up — no copy and paste.

1. **⋯ ▸ Automation ▸ Copy JSON request ▸ *contract*** puts the instruction (schema included) on the
   clipboard. Paste it at the end of your prompt.
2. After TerrierGPT answers, trigger a handoff (see below). The app reads the selection if
   there is one, otherwise the newest `<pre>` block, otherwise the page text, checks the
   payload against the schema, and writes:

```
~/Library/Application Support/TerrierGPTMenu/handoffs/
    2026-09-28T14-03-11Z-kb-gap-verdict.json
    latest.json
```

```json
{ "handoff": 1, "id": "…", "created_at": "…", "contract": "kb-gap-verdict",
  "source": { "agent": "terriergpt", "url": "…", "title": "…", "extracted_from": "code-block" },
  "validation": { "status": "valid | invalid | unchecked", "schema": "…", "issues": [] },
  "payload": { … } }
```

A payload that fails the check is still written, with the problems listed under `issues`, so
you can see what TerrierGPT got wrong. The downstream agent decides whether to refuse it.
The contracts folder can be moved with
`defaults write com.brianmatute.TerrierGPTMenu ContractsDirectory <path>`.

### Triggers — try each, keep the one that fits

Every trigger calls the same `HandoffService`, so they only differ in how they're launched.
Test scripts are in `Scripts/handoff/`.

| Trigger | How | Returns |
|---|---|---|
| Panel menu | **⋯ ▸ Automation ▸ Save answer as JSON** | Toast + file |
| Shortcuts | Action *Export TerrierGPT Answer as Handoff* (Contract, Return: envelope / payload / path) | The value directly |
| Shell via Shortcuts | `Scripts/handoff/shortcut.sh` (needs a shortcut named *TerrierGPT Handoff* wrapping that action) | stdout |
| JXA | `osascript -l JavaScript Scripts/handoff/handoff-jxa.js` (same shortcut) | The value directly |
| URL scheme | `open -g "terriergpt://handoff?contract=kb-gap-verdict&copy=1"`, or `Scripts/handoff/url.sh kb-gap-verdict`. Works the same from Raycast or a Shortcut's *Open URL* | `latest.json` |
| AppleScript | `osascript Scripts/handoff/handoff.applescript kb-gap-verdict` (runs `open location`) | `latest.json`, returned by the script |
| Folder watch | `Scripts/handoff/watch.sh ./pipe.sh claude`, which fires on every new handoff from any trigger | Whatever the consumer does |

End-to-end check, headless and read-only:
`Scripts/handoff/url.sh kb-gap-verdict | Scripts/handoff/pipe.sh claude` (or `grok`).

**Ticket Search Desk (CTS):** after TerrierGPT emits `ticket-search-report`, run the
`ticket-search-html` recipe (⋯ ▸ Automation ▸ Run a chain) or
`Scripts/handoff/ticket-search-html.sh` against `handoffs/latest.json`. That fills the WG
`servicenow-search-report` HTML template into `~/Downloads`. Same pattern as KB Desk, different
contract. Presentation notes live in the WG clone:
`docs/orchestration/examples/handoff-ticket-search.md`.

The panel has to have been opened on the conversation. The web view is what gets read, and a
closed-and-dismantled panel has no page, which gives the error *TerrierGPT isn't open*.

### JSON by default, and answers without it

Saving a JSON handoff doesn't need a JSON block anymore:

1. **The newest block that names a contract** is used if there is one (`kb-gap-verdict`,
   `terriergpt-answer`, …). The answer's prose goes along in the envelope's `text`.
2. **Otherwise the answer text** is saved as a `terriergpt-answer` with
   `generated_by: "app-fallback"` and the text in `payload.answer` and `text`. The text comes
   from the selection, else the newest assistant message, else the page text (last 20k
   characters). Recipes and inbox routing treat it like any other `terriergpt-answer`.

A bare JSON block with no `contract` is skipped, because it's usually an example
in the answer. `terriergpt://handoff?strict=1` (or the intent with
*Use the answer text* off) keeps the old JSON-or-nothing behaviour.

**To get JSON in every answer**, use **⋯ ▸ Automation ▸ Copy standing
instruction** and paste it into your agent's *Instructions* in the TerrierGPT Agent Builder. Each
answer then ends in a `terriergpt-answer` block (title, summary, key points, action items,
entities, sources, open questions, suggested next step). It defers to a skill's own block, so
an agent running `kb-gap-check` still emits only `kb-gap-verdict`.

The `terriergpt-answer` schema ships with the app
(`~/Library/Application Support/TerrierGPTMenu/contracts/`). A schema of the same name in the
working-group `docs/contracts/` takes precedence, so it can be contributed there unchanged.
The example recipe `answer-to-claude` takes any `terriergpt-answer` and has Claude draft the
next step.

"Newest assistant message" is a best guess from common chat markup
(`[data-message-author-role="assistant"]`, `.agent-turn`, `.markdown`). If TerrierGPT's
markup matches none of them, the fallback uses the page text instead. It still works, just
with more noise.

## Chains (phase 2)

A **recipe** is a JSON file that hands the answer from agent to agent. Each step's output
envelope becomes the next step's input, so Claude, Grok, and your scripts all read and write
the same shape. Recipes are data, so adding a flow means adding a file, not rebuilding the app.

```
~/Library/Application Support/TerrierGPTMenu/recipes/   ← one .json per chain (examples seeded on first run)
~/Library/Application Support/TerrierGPTMenu/runs/<stamp>-<recipe>/
    00-input.json  01-<step>.json  01-<step>.stdout.json  01-<step>.stderr.log  run.json
~/Library/Application Support/TerrierGPTMenu/runs/latest.json   ← last successful result
```

```json
{
  "title": "KB desk → draft-kb → Grok review",
  "input": { "from": "page", "contract": "kb-gap-verdict" },
  "steps": [
    { "id": "draft", "agent": "claude", "cwd": "~/Documents/GitHub/cts-ai-working-group",
      "prompt": "/cts-orchestrate kb-desk-handoff …", "allow": ["Read", "Grep", "Glob", "Skill"] },
    { "id": "review", "agent": "grok", "confirm": "Send the drafts to Grok?",
      "prompt": "Review these KB drafts…" }
  ]
}
```

| Field | Meaning |
|---|---|
| `input.from` | `page` (a JSON block, optionally a specific `contract`), `page-text` (selection or page text, for answers with no JSON), `latest` (`handoffs/latest.json`), `none` |
| `agent` | `claude` (`claude -p`, input on stdin), `grok` (`grok --prompt-file`, input appended to the prompt because Grok ignores stdin), `command` (any argv, input on stdin) |
| `prompt` / `command` | Placeholders: `{{input_path}}`, `{{run_dir}}`, `{{recipe}}` |
| `output_schema` | A contract name or a schema path. Passed as `--json-schema` and checked on the way out. A mismatch stops the chain |
| `allow` | Tools the agent may use. Headless runs can't ask, so anything else is denied, and the panel lists what was refused |
| `permission_mode`, `max_turns`, `model`, `cwd`, `timeout` (s, default 600) | Passed through. `bypassPermissions` is refused |
| `confirm` | Pause before the step with this message and a preview of its input |

**Starting a chain:**

| From | How |
|---|---|
| Panel | **⋯ ▸ Automation ▸ Run a chain ▸ *recipe***. Progress shows in the strip above the dock, with Cancel, Copy result, and Show |
| Shortcuts | *Run TerrierGPT Chain* (Chain, optional Input, Return: text / JSON payload / envelope / path, Wait). Its Input can be another action's output, so Shortcuts can chain chains |
| URL / AppleScript / Raycast | `terriergpt://run?recipe=kb-desk-handoff[&input=/path/handoff.json]`, or `Scripts/handoff/run.sh <recipe> [input]`. **A link always asks first** and names the steps and any input file, because any web page can open a `terriergpt://` URL |

One chain runs at a time. Nothing in a chain sends mail, publishes, or submits unless a step
is explicitly allowed the tool that does it, and the example recipes allow none.

## Inbox and history (phase 3)

**The inbox** starts chains without a click. Anything that can write a file (a Claude or Grok
session, a script, a Shortcut's *Save File*, another chain) drops a handoff envelope here:

```
~/Library/Application Support/TerrierGPTMenu/handoffs/inbox/
    <new files>   processing/   done/   failed/   unrouted/
```

- **Routing:** the file's `"recipe"` field if it has one, otherwise the single recipe whose
  `input.contract` matches the file's `contract`. The recipe must opt in with `"inbox": true`.
  A file nothing claims, or one two recipes both claim, goes to `unrouted/` with a toast
  saying why. Nothing is guessed.
- **Chains of chains:** `"output_to_inbox": true` on a recipe drops its result back into the
  inbox with `hops + 1`, so another recipe can pick it up (Claude → Grok → your script → …).
  After 5 hops the file is parked instead of run, so a recipe that feeds itself can't loop.
- **Writing safely:** write a dotfile or `*.tmp`, then rename. Those are never picked up
  half-written. `Scripts/handoff/drop.sh file.json [recipe]` (or `… | drop.sh -`) does this.
- **In the panel:** **⋯ ▸ Automation ▸ Inbox ▸ Watch the inbox** turns it on. **Send newest JSON
  block to inbox** goes from TerrierGPT to whichever recipe claims the contract, in one click.
- **When the app is closed:** **…even when the app is closed** installs a per-user `launchd`
  agent (`~/Library/LaunchAgents/com.brianmatute.TerrierGPTMenu.inbox.plist`) that watches
  the folder and runs `open -g terriergpt://inbox`, which launches the app. The agent does
  nothing else, so what happens to a file is still decided and logged by the app. launchd
  also fires the agent once when it loads, which means **with the agent on, the app opens at
  login** and picks up anything dropped in the meantime. Turning the toggle off removes the
  agent.

`terriergpt://inbox` only looks at files already in the folder and only runs recipes that
opted in, so a web page opening that link can't choose what runs.

**Run history:** **⋯ ▸ Automation ▸ Run history…** lists past runs (status, trigger, time, cost), read
from each run's `run.json`. From there you can copy a result, run a chain again on the same
input, send a result to the inbox, or open the run folder.

## Bugs fixed in this pass

**Build / project**
- `Groups/Intents/` was never referenced by the Xcode project and `Groups/Auth`, `Groups/Views`
  and `Groups/MenuBar` were declared as synchronized folders but left out of the target's
  `fileSystemSynchronizedGroups`, with per-file membership exception sets on top. All four are
  now one synchronized `Groups` folder that the target builds, so new subfolders are picked up
  without touching the project file again.

**Web view**
- JavaScript `alert()`, `confirm()` and `prompt()` did nothing — `WKUIDelegate` has no default
  implementations, so any page flow waiting on one stalled silently
- `<input type="file">` did nothing: no open-panel delegate, so attaching a file was impossible
- Downloads were handed to the default browser, which had no session and usually just landed on
  a login page. They now download in-app, to `~/Downloads`, without clobbering existing files
- The web view kept loading (and playing audio) after its panel went away
- Microphone requests from the page were never answered
- `msauth.net` / `msftauth.net` were missing from the SSO allow-list, so parts of the Microsoft
  login flow could get bounced out to the browser mid-sign-in

**Session**
- "Open in Browser" always opened the bare home page, discarding whatever conversation you were
  reading
- `showPanel()` matched *any* window ≥600pt tall and claimed success unconditionally; it now
  goes through the status item and reports honestly when it couldn't open anything
- A private `isCampusSSOHost(_:)` shadowed the static method it wrapped
- `isLoading` could stay stuck on after a navigation that never re-settled the phase

**Prompt**
- `ClipboardPrompt.wrap` hard-coded a Spanish instruction ("Analiza el siguiente contenido…")
  in an otherwise English app, so wrapped clipboard text came back answered in Spanish

**UI**
- The Launch at Login toggle was only read on `onAppear`, so it drifted out of sync with System
  Settings, and a failed toggle left the switch showing a state the system had rejected
- The status strip pushed the page down a row and reflowed the chat whenever it appeared

**Automation (new code, built to avoid the obvious traps)**
- AppleScript runs off the main thread with a per-script `with timeout`, so a wedged target app
  can't freeze the panel
- Page titles and selections are escaped before interpolation into AppleScript literals
- Finder captures cap inlined file contents at 120 KB and only read text-ish UTIs, rather than
  silently truncating a large binary into a prompt

## Proposed next steps

Ordered by value per unit of work. None of these are built yet.

1. **Global hotkey to summon the panel** (⌥Space or similar). The one thing that would make
   capture-from-anywhere feel instant. Needs `RegisterEventHotKey` or a `CGEventTap`; the
   latter wants Accessibility permission, the former doesn't.
2. **Mail and Messages capture.** Both script cleanly (`selection` in Mail, `text` of the
   selected chat in Messages) and slot straight into the existing `CapturedContext` model —
   roughly one new bridge file each.
3. **Reading the page, not just the selection.** Today a browser capture is title + URL +
   selection. Running Safari's Reader extraction (or a small Readability script through
   `do JavaScript`) would let you capture a whole article without selecting it first.
4. **A saved-prompt library.** Capture chips plus a named instruction ("draft a KB article from
   this", "summarize for a ticket update") is most of a personal prompt library already; it
   needs a store and a picker in the dock.
5. **Round-trip from Reminders.** Right now context flows outward. A "TerrierGPT" reminders list
   that the app watches, turning each new item into a queued prompt, would close the loop.
6. **Quick Look–style transient panel** for the Services entries, so *Ask TerrierGPT* on selected
   text can answer inline without opening the full panel.
7. **A `.sdef` scripting dictionary**, if you ever want to drive this app *from* AppleScript
   rather than the other way round. App Intents cover Shortcuts and Spotlight already, so this
   is only worth it for an existing AppleScript-only workflow.

## Requirements

- macOS 26.6 or later (deployment target); built and verified against the **macOS 27 SDK / Xcode 27**
- Xcode with a free or paid Apple Developer account for local signing

## How to build & run

1. Clone this repository.
2. Open `TerrierGPTMenu.xcodeproj` in Xcode.
3. Select the **TerrierGPTMenu** target → **Signing & Capabilities**:
   - Enable **Automatically manage signing**
   - Choose **your** Team (Apple ID)
   - If needed, change the **Bundle Identifier** to something unique
4. Choose **My Mac** as the run destination.
5. Press **Run** (⌘R).

The app appears in the menu bar (not the Dock). Click the sparkles icon to open TerrierGPT.

> Services menu entries can take a moment to appear in other apps the first time. The app calls
> `NSUpdateDynamicServices()` at launch to hurry that along; logging out and back in is the
> reliable fallback.

### Install for daily use

1. Product → Archive (or build Release), then put `TerrierGPTMenu.app` in **Applications**.
2. Enable **Launch at Login** from the ⋯ menu.

> Launch at Login is most reliable when the app lives in Applications, not only in the Xcode
> build folder.

## Signing note

Each person who clones the repo should select their own team under **Signing & Capabilities**.

There are no API keys or server secrets in this project: it only loads the public TerrierGPT
website and talks to apps already on your Mac.

## Project layout

```
TerrierGPTMenu/
├── Groups/
│   ├── Auth/AuthManager.swift            # Session phases, clipboard prompt, shared actions
│   ├── Automation/
│   │   ├── AppleScriptRunner.swift       # Off-main AppleScript, permissions, escaping
│   │   ├── BrowserBridge.swift           # Frontmost tab across 14 browsers
│   │   ├── FinderBridge.swift            # Finder selection + safe file inlining
│   │   ├── AppleAppsBridge.swift         # Notes (AppleScript) + Reminders/Calendar (EventKit)
│   │   ├── CapturedContext.swift         # Capture model + prompt composition
│   │   ├── CaptureCoordinator.swift      # Capture/file state machine, toasts
│   │   └── FrontmostAppTracker.swift     # "Which app was I in before this panel opened?"
│   ├── Chains/
│   │   ├── Recipe.swift                  # Recipe model, loading, seeded examples
│   │   ├── AgentAdapter.swift            # claude / grok / command lines; output parsing; process runner
│   │   ├── ChainRunner.swift             # Runs a recipe step by step, gates, run folders
│   │   ├── Inbox.swift                   # Inbox routing, folder watcher, launchd agent
│   │   └── RunHistory.swift              # Reads past runs back from run.json
│   ├── Design/TGDesign.swift             # Glass tokens, button styles, motion, Reduce Motion
│   ├── Handoff/
│   │   ├── HandoffExtractor.swift        # Find the answer's JSON block (pure, testable)
│   │   ├── HandoffStore.swift            # Envelope + files, contract check, JSON request text
│   │   └── HandoffService.swift          # The one entry point every trigger uses; URL route
│   ├── Intents/TerrierGPTIntents.swift   # Shortcuts / Spotlight
│   ├── MenuBar/MenuBarPanel.swift        # Programmatic panel open
│   ├── Services/TerrierServices.swift    # Services menu provider
│   └── Views/
│       ├── WebView.swift                 # WKWebView, navigation policy, dialogs, downloads
│       ├── PanelHeader.swift
│       ├── ContextTray.swift
│       ├── ActionDock.swift              # Dock + Handoff/chain menu
│       ├── RunStrip.swift                # Chain progress above the dock
│       ├── RunHistoryView.swift          # Run history popover
│       ├── SessionPill.swift
│       ├── ToastView.swift
│       └── AmbientBackdrop.swift
├── MyApp/
│   ├── TerrierGPTMenuApp.swift           # Scene + AppDelegate
│   ├── ContentView.swift                 # Panel layout
│   ├── LaunchAtLogin.swift
│   └── Assets.xcassets/
├── TerrierGPTMenu.xcodeproj/
├── Scripts/handoff/                      # Trigger test scripts, run.sh, drop.sh, pipe.sh
├── TerrierGPTMenu-Info.plist             # NSServices, terriergpt:// URL scheme
└── README.md
```

## License / sharing

Share freely with teammates. TerrierGPT itself is Boston University's service; this app is only
a native shell around the public web UI.
