import AppIntents
import AppKit

/// Shortcuts / Spotlight actions for TerrierGPT Menu.

struct PrepareClipboardForTerrierGPTIntent: AppIntent {
    static var title: LocalizedStringResource = "Prepare Clipboard for TerrierGPT"
    static var description = IntentDescription(
        "Wraps the current clipboard text in a ready-to-paste TerrierGPT prompt."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await MainActor.run { ClipboardPrompt.prepareFromPasteboard() }
        switch result {
        case .success:
            return .result(dialog: "Prompt is on the clipboard. Paste into TerrierGPT with ⌘V.")
        case .failure(let error):
            throw error
        }
    }
}

struct ReloadTerrierGPTIntent: AppIntent {
    static var title: LocalizedStringResource = "Reload TerrierGPT"
    static var description = IntentDescription("Reloads the TerrierGPT page in the menu bar window.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AuthManager.shared.requestReload()
        }
        return .result(dialog: "Reloading TerrierGPT.")
    }
}

struct SignOutTerrierGPTIntent: AppIntent {
    static var title: LocalizedStringResource = "Sign Out of TerrierGPT"
    static var description = IntentDescription(
        "Clears TerrierGPT site data (cookies) and returns to the home page."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AuthManager.shared.logout()
        return .result(dialog: "Signed out and cleared site data.")
    }
}

struct OpenTerrierGPTInBrowserIntent: AppIntent {
    static var title: LocalizedStringResource = "Open TerrierGPT in Browser"
    static var description = IntentDescription("Opens https://terriergpt.bu.edu in your default browser.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AuthManager.shared.openInBrowser()
        }
        return .result()
    }
}

struct ShowTerrierGPTPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Show TerrierGPT Panel"
    static var description = IntentDescription(
        "Activates TerrierGPT Menu and tries to bring the menu bar panel forward."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AuthManager.shared.showPanel()
        }
        return .result(
            dialog: "TerrierGPT is active. If the panel is hidden, click the sparkles icon in the menu bar."
        )
    }
}

/// Makes the intents easy to find in the Shortcuts app.
struct TerrierGPTAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrepareClipboardForTerrierGPTIntent(),
            phrases: [
                "Prepare clipboard for \(.applicationName)",
                "Wrap clipboard for \(.applicationName)",
            ],
            shortTitle: "Prepare Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: ShowTerrierGPTPanelIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Open \(.applicationName) panel",
            ],
            shortTitle: "Show Panel",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: ReloadTerrierGPTIntent(),
            phrases: [
                "Reload \(.applicationName)",
            ],
            shortTitle: "Reload",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OpenTerrierGPTInBrowserIntent(),
            phrases: [
                "Open \(.applicationName) in browser",
            ],
            shortTitle: "Open in Browser",
            systemImageName: "safari"
        )
        AppShortcut(
            intent: SignOutTerrierGPTIntent(),
            phrases: [
                "Sign out of \(.applicationName)",
            ],
            shortTitle: "Sign Out",
            systemImageName: "rectangle.portrait.and.arrow.right"
        )
    }
}
