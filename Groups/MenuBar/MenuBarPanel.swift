import AppKit
import SwiftUI

/// Best-effort programmatic control of the `MenuBarExtra` panel.
///
/// SwiftUI's `MenuBarExtra` exposes `isInserted` but nothing to open its window: as of the
/// macOS 27 SDK there is no public "isPresented". App Intents, the Services menu, and the
/// global hotkey all need to summon the panel, so we reach the status item the only way
/// available and say so plainly.
///
/// The lookup is guarded with `responds(to:)` rather than a bare `value(forKey:)`, so if a
/// future macOS renames the property this returns `false` instead of raising.
@MainActor
enum MenuBarPanel {

    /// Clicks the status item, which toggles the panel the same way the user would.
    /// - Returns: `false` when the status item could not be reached, so callers can fall back
    ///   to telling the user to click the menu bar icon themselves.
    @discardableResult
    static func toggle() -> Bool {
        guard let button = statusItemButton() else { return false }
        button.performClick(nil)
        return true
    }

    /// Opens the panel if it isn't already showing. Unlike `toggle()`, calling this twice
    /// doesn't close what it just opened.
    @discardableResult
    static func show() -> Bool {
        guard let button = statusItemButton() else { return false }
        // `NSStatusBarButton` reflects panel visibility in its highlight state.
        if button.state == .on { return true }
        button.performClick(nil)
        return true
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        let selector = NSSelectorFromString("statusItem")
        for window in NSApp.windows where window.className == "NSStatusBarWindow" {
            guard window.responds(to: selector),
                  let item = window.value(forKey: "statusItem") as? NSStatusItem,
                  let button = item.button
            else { continue }
            return button
        }
        return nil
    }
}
