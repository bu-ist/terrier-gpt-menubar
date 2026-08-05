import SwiftUI

@main
struct TerrierGPTMenuApp: App {
    var body: some Scene {
        MenuBarExtra("TerrierGPT", systemImage: "brain.head.profile") {
            ContentView()
                .frame(width: 420, height: 680)
        }
        .menuBarExtraStyle(.window)
    }
}
