import SwiftUI

@main
struct TerrierGPTMenuApp: App {
    @StateObject private var auth = AuthManager.shared
    var body: some Scene {
        MenuBarExtra("TerrierGPT", systemImage: "sparkles") {
            ContentView()
                .frame(minWidth: 580, idealWidth: 720, minHeight: 720, idealHeight: 900)
        }
        .menuBarExtraStyle(.window)
    }
}
