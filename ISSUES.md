# Known issues

Scored Likelihood (1–10) × Impact (1–10). Items under 10 are logged here and left alone;
the rest are fixed on their branch or waiting on a decision.

## Logged (L×I < 10)

### Ask link before the panel has ever opened loads home, not `/c/new` — L3 × I3 = 9
- **Repro:** quit the app, relaunch, run `terriergpt://ask?prompt=hi&instance=nonprod` before
  clicking the menu bar icon. The panel opens on home; the stale `/c/new` loads on the next sign-out.
- **Fix:** in `WebView.makeNSView`, load `AuthManager.pendingHomeURL ?? url` and clear it.

### Chrome bridge needs `/usr/bin/python3` — L3 × I3 = 9
- **Repro:** on a Mac without Command Line Tools, capture from Chrome with the companion installed.
  The native host is the install stub, so capture silently falls back to AppleScript.
- **Fix:** detect the stub (`xcode-select -p` fails) and say so in the capture toast, or ship a compiled host.

## Needs a decision

### Personal Team ID is committed in the project — rule 7 in CLAUDE.md
- `DEVELOPMENT_TEAM = Q9HBRD8A3Z` sits in `project.pbxproj` (two targets). Teammates who clone
  the repo can't sign until they change it.
- **Fix:** move it into an untracked `.xcconfig` (e.g. `Local.xcconfig`, gitignored). This
  touches signing, so it waits for Brian.

## Deferred UI ideas (not bugs)

- **Dock stays live while signed out.** Left on purpose: with the page guard in
  `materialToFile`, Notes / Reminders / Mail then file the composed prompt, which is still useful.
- **"Copy prompt" as the tray's one primary pill.** Today it is one of three equal 10 pt text actions.
- **9–10 pt tertiary text on glass** (ContextTray counts, chip details) is low contrast. Raise to
  `.secondary` or 11 pt after a visual pass in both modes.
- **ActionDock popovers:** three `Bool`s → one `@State var popover: DockPopover?`. Cheap, low value.
- **Two loading signals:** `WebViewModel.isLoading` (progress line) and `AuthManager.isLoading`
  (pill). Pick one owner.
