# TerrierGPT Menu Bar App

A simple macOS menu-bar utility that gives quick access to [TerrierGPT](https://terriergpt.bu.edu) without keeping a browser tab open.

## What it does

- Lives in the menu bar (sparkles icon)
- Click opens a floating window with the full TerrierGPT interface (`terriergpt.bu.edu`)
- Session status dot (gray / orange / green) from WebView navigation
- **Reload**, **Quit**, clipboard prompt helper, and **Launch at Login**
- Keyboard shortcuts: **⌘R** reload, **⌘Q** quit, **⇧⌘V** prepare clipboard prompt
- External links open in your default browser; BU/SSO navigation stays in the panel
- No Dock icon: stays out of the way (`LSUIElement`)
- **Apple Shortcuts** actions via App Intents (see below)

## How it was made

- Native macOS app built in Xcode with **SwiftUI** + **WKWebView**
- Pure menu bar app
- Embeds the official TerrierGPT web UI so login, agents, and models work as usual
- Built from scratch as a learning project

## Requirements

- macOS (project deployment target is set in Xcode; use a recent macOS + Xcode)
- Xcode with a free or paid Apple Developer account for local signing

## How to build & run

1. Clone this repository.
2. Open `TerrierGPTMenu.xcodeproj` in Xcode.
3. Select the **TerrierGPTMenu** target → **Signing & Capabilities**:
   - Enable **Automatically manage signing**
   - Choose **your** Team (Apple ID)
   - If needed, change the **Bundle Identifier** to something unique (e.g. `com.yourname.TerrierGPTMenu`)
4. Choose **My Mac** as the run destination.
5. Press **Run** (⌘R).

The app appears in the menu bar (not the Dock). Click the sparkles icon to open TerrierGPT.

### Optional: install for daily use

1. Product → Archive (or build Release), then put `TerrierGPTMenu.app` in **Applications**.
2. Enable **Launch at Login** from the app’s top bar if you want it at startup.

> **Note:** Launch at Login is most reliable when the app lives in Applications (or another stable install location), not only the Xcode build folder.

## Apple Shortcuts

After you build and run the app once, open the **Shortcuts** app and search for **TerrierGPT**:

| Shortcut action | What it does |
|-----------------|--------------|
| Prepare Clipboard for TerrierGPT | Wraps clipboard text in a paste-ready prompt |
| Show TerrierGPT Panel | Activates the app / tries to bring the panel forward |
| Reload TerrierGPT | Reloads the embedded page |
| Open TerrierGPT in Browser | Opens the site in Safari (or your default browser) |
| Sign Out of TerrierGPT | Clears site data and returns home |

**AppleScript:** not required for Shortcuts. Classic AppleScript (`.sdef`) would need Automation permission and more plumbing. Prefer App Intents unless you have a specific AppleScript-only workflow.

You cannot fully automate typing into the TerrierGPT chat box without either an official API or fragile JavaScript injection. Clipboard prepare + paste (⌘V) is the reliable path today.

## Signing note

Each person who clones the repo should select their own team under **Signing & Capabilities**. That is normal for shared Xcode apps.

There are no API keys or server secrets in this project: it only loads the public TerrierGPT website.

## Project layout

```
TerrierGPTMenu/
├── Groups/
│   ├── Auth/AuthManager.swift      # Session phases + shared actions
│   ├── Views/WebView.swift         # WKWebView + navigation policy
│   └── Intents/TerrierGPTIntents.swift  # Shortcuts / App Intents
├── MyApp/
│   ├── TerrierGPTMenuApp.swift
│   ├── ContentView.swift
│   ├── LaunchAtLogin.swift
│   └── Assets.xcassets/
├── TerrierGPTMenu.xcodeproj/
├── TerrierGPTMenu-Info.plist
└── README.md
```

## License / sharing

Share freely with teammates. TerrierGPT itself is Boston University’s service; this app is only a native shell around the public web UI.
