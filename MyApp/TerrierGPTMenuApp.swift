import SwiftUI
import AppKit

@main
struct TerrierGPTMenuApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("TerrierGPT", systemImage: "sparkles") {
            ContentView()
                .frame(minWidth: 600, idealWidth: 760, minHeight: 720, idealHeight: 900)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Wires up the things that have to exist before any window does.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let servicesProvider = TerrierServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start watching app switches immediately. If we waited until the panel opened, the
        // tracker would have missed the switch *into* the app the user wants to capture from.
        _ = FrontmostAppTracker.shared

        NSApp.servicesProvider = servicesProvider
        // Without this, a freshly built copy can take minutes to show up in other apps'
        // Services menus while the system gets around to rescanning.
        NSUpdateDynamicServices()

        // The app's own contract schemas (terriergpt-answer), before anything validates.
        BuiltInContracts.install()

    }

    /// `terriergpt://handoff|ask` (and `run|inbox`, forwarded to CTS Recipes) — AppleScript, `open`, Raycast.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(HandoffService.handle)
    }
}
