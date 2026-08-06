import SwiftUI
import AppKit

struct ContentView: View {
    private let terrierURL = URL(string: "https://terriergpt.bu.edu")!

    @State private var reloadTrigger = UUID()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Text("TerrierGPT")
                    .font(.headline)

                Spacer()

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .help("Start TerrierGPT automatically when you log in to your Mac")
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }

                Button("Reload") {
                    reloadTrigger = UUID()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            if let launchAtLoginMessage {
                Text(launchAtLoginMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar.opacity(0.6))
            }

            WebView(url: terrierURL, reloadTrigger: reloadTrigger)
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginMessage = LaunchAtLogin.statusMessage
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginMessage = LaunchAtLogin.statusMessage
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 720, height: 850)
}
