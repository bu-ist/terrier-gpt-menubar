import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var auth = AuthManager.shared
    
    @State private var reloadTrigger = UUID()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var statusMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            
            // Top bar limpia
            HStack(spacing: 10) {
                Text("TerrierGPT")
                    .font(.headline)
                
                // Solo el puntito de estado
                Circle()
                    .fill(auth.isAuthenticated ? .green : .gray)
                    .frame(width: 8, height: 8)
                    .help(auth.isAuthenticated ? "Conectado" : "Desconectado")
                
                Spacer()
                
                // Portapapeles
                Button {
                    useClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .help("Usar desde Portapapeles")
                
                // Reload
                Button {
                    reloadTrigger = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Reload")
                .keyboardShortcut("r", modifiers: .command)
                
                // Logout (solo si está autenticado)
                if auth.isAuthenticated {
                    Button {
                        Task {
                            await auth.logout()
                            reloadTrigger = UUID()
                        }
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Logout")
                }
                
                // Quit
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .help("Quit")
                .keyboardShortcut("q", modifiers: .command)
                
                // Launch at Login
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
            
            // Mensajes de estado
            if let statusMessage {
                Text(statusMessage)
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
            
            WebView(url: auth.terrierURL, reloadTrigger: reloadTrigger)
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginMessage = LaunchAtLogin.statusMessage
        }
    }
    
    // MARK: - Clipboard
    private func useClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            statusMessage = "El portapapeles está vacío"
            clearStatusMessageAfterDelay()
            return
        }
        
        let prompt = """
        Analiza el siguiente contenido y ayúdame con él:

        \(text)
        """
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        
        statusMessage = "✅ Prompt listo en el portapapeles — pégalo en el chat (⌘V)"
        clearStatusMessageAfterDelay()
    }
    
    private func clearStatusMessageAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            statusMessage = nil
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
