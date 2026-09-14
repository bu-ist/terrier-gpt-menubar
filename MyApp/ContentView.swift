import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject private var auth = AuthManager.shared

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var statusMessage: String?
    @State private var statusMessageToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("TerrierGPT")
                    .font(.headline)

                Circle()
                    .fill(sessionDotColor)
                    .frame(width: 8, height: 8)
                    .help(sessionHelpText)
                    .accessibilityLabel(sessionHelpText)

                Spacer()

                Button {
                    useClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Prepare clipboard prompt")
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button {
                    auth.requestReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Reload")
                .keyboardShortcut("r", modifiers: .command)

                if auth.isAuthenticated {
                    Button {
                        Task { await auth.logout() }
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Logout (clear site data and return home)")
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .help("Quit")
                .keyboardShortcut("q", modifiers: .command)

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .help("Start TerrierGPT automatically when you log in to your Mac")
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar.opacity(0.6))
            } else if auth.isLoading {
                Text(sessionHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar.opacity(0.6))
            } else if let launchAtLoginMessage {
                Text(launchAtLoginMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar.opacity(0.6))
            }

            WebView(
                url: auth.terrierURL,
                reloadTrigger: auth.reloadToken,
                loadHomeTrigger: auth.loadHomeToken
            )
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginMessage = LaunchAtLogin.statusMessage
        }
    }

    // MARK: - Session UI

    private var sessionDotColor: Color {
        switch auth.phase {
        case .loading, .signedOut:
            return .gray
        case .authenticating:
            return .orange
        case .signedIn:
            return .green
        }
    }

    private var sessionHelpText: String {
        switch auth.phase {
        case .loading:
            return "Loading TerrierGPT..."
        case .signedOut:
            return "Signed out - sign in inside the window if prompted"
        case .authenticating:
            return "Signing in (BU / Microsoft SSO)..."
        case .signedIn:
            return "Signed in"
        }
    }

    // MARK: - Clipboard

    private func useClipboard() {
        switch ClipboardPrompt.prepareFromPasteboard() {
        case .success:
            showStatus("✅ Prompt ready on the clipboard - paste into chat (⌘V)")
        case .failure:
            showStatus("Clipboard is empty")
        }
    }

    private func showStatus(_ message: String) {
        let token = UUID()
        statusMessageToken = token
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if statusMessageToken == token {
                statusMessage = nil
            }
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
