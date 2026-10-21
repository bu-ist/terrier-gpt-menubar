# Agent conventions — terrier-gpt-menubar

TerrierGPT Menu: a macOS menu-bar app (SwiftUI, Liquid Glass, macOS 27 SDK, deployment target
macOS 26.6) around TerrierGPT. It captures context from other apps, files answers into Notes,
Reminders, and Calendar, hands off JSON to CTS Recipes, and carries the Safari build of
TerrierGPT Companion.

## Layout

| Path | What lives there |
|------|------------------|
| `MyApp/` | App entry, root view, launch at login, Chrome native-messaging host |
| `Groups/` | Feature code: Auth, Automation, Design, Handoff, Intents, MenuBar, Services, Views |
| `SafariExtension/` | Native side of the Safari extension only |
| `Scripts/build-safari-extension.sh` | Builds `../terrier-gpt-companion` for Safari on every Xcode build |
| `Scripts/handoff/` | Trigger scripts for handoffs (URL scheme, JXA, AppleScript, folder watch) |
| `Scripts/tests/` | Safari handler tests that run without Safari |
| `TerrierGPTMenu-Info.plist` | `NSServices`, `terriergpt://` URL scheme |

## Build and checks

```bash
xcodebuild -project TerrierGPTMenu.xcodeproj -scheme TerrierGPTMenu -configuration Debug build
Scripts/tests/test-safari-handler.sh
```

The Safari phase needs Node and the companion cloned next to this repo
(`TERRIERGPT_COMPANION_DIR` overrides the path).

## Rules

1. **Web half lives in the companion.** Fix extension web bugs in `../terrier-gpt-companion`.
   Work here only on `SafariExtension/Sources`, signing, and entitlements.
2. **Siblings are found under `~/Developer/GitHub`** (`terrier-gpt-companion`, `cts-recipes`).
   Do not hardcode another user's home path.
3. **Handoff envelopes are a contract** shared with CTS Recipes and the Chrome companion.
   Change all sides together.
4. **Motion goes through `TG.Motion` and `.tgAnimation`**, which honors Reduce Motion. No ad hoc
   `withAnimation` on new surfaces.
5. **Never type into the chat box over AppleScript.** Context goes to the clipboard or a handoff.
6. **Signing:** do not commit a personal Team ID, provisioning profiles, or `xcuserdata/`.
   The Safari extension's sandbox exception is only `~/Library/Application Support/TerrierGPTMenu/`;
   do not widen it.
7. Recipe chains belong in `cts-recipes`, not in this app.

## Workflow

Team repo (`bu-ist`): work on a branch and open a PR. Keep the README's panel and integration
tables in sync with behavior changes.
