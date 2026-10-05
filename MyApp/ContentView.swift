import SwiftUI
import AppKit

/// The menu bar panel.
///
/// Layout is three bands over one continuous backdrop: floating glass header, the page, and a
/// floating glass dock. The page is inset and rounded so the glass reads as sitting *above*
/// it rather than being welded to its edges.
struct ContentView: View {

    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var coordinator = CaptureCoordinator.shared
    @StateObject private var webModel = WebViewModel()

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackdrop()

            VStack(spacing: 0) {
                PanelHeader(
                    auth: auth,
                    coordinator: coordinator,
                    webModel: webModel,
                    launchAtLogin: launchAtLoginBinding
                )

                ContextTray(coordinator: coordinator)

                page

                ActionDock(coordinator: coordinator, pageTitle: webModel.pageTitle)
                    .padding(.horizontal, TG.Space.regular)
                    .padding(.top, TG.Space.snug)
                    .padding(.bottom, TG.Space.regular)
            }

            toastLayer
        }
        .tgAnimation(TG.Motion.morph, value: coordinator.contexts.count)
        .onAppear { coordinator.webModel = webModel }
        .onChange(of: webModel.lastDownload) { _, url in
            guard let url else { return }
            coordinator.show(Toast(
                kind: .success,
                title: "Downloaded \(url.lastPathComponent)",
                detail: "Saved to your Downloads folder",
                action: .reveal(url)
            ))
        }
        .task {
            // Re-read on every open: the user may have changed the Login Items setting in
            // System Settings since the panel was last built. This assigns the @State
            // directly rather than going through `launchAtLoginBinding`, so reading the
            // system's answer never turns into a write back to it.
            launchAtLogin = LaunchAtLogin.isEnabled
            if let message = LaunchAtLogin.statusMessage, launchAtLogin {
                coordinator.show(Toast(kind: .info, title: "Launch at Login", detail: message))
            }
        }
    }

    // MARK: - Page

    private var page: some View {
        WebView(
            url: auth.terrierURL,
            reloadTrigger: auth.reloadToken,
            loadHomeTrigger: auth.loadHomeToken,
            model: webModel
        )
        .clipShape(.rect(cornerRadius: TG.Radius.card, style: .continuous))
        .overlay(alignment: .top) { progressLine }
        .overlay {
            // A lit rim, not a border: bright along the top where the panel's light falls,
            // fading to the accent underneath, so the page reads as inset into the glass
            // rather than pasted on top of it.
            RoundedRectangle(cornerRadius: TG.Radius.card, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.06),
                            TG.scarlet.opacity(0.18),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.30), radius: 20, y: 8)
        .shadow(color: TG.scarlet.opacity(0.10), radius: 28, y: 12)
        .padding(.horizontal, TG.Space.regular)
    }

    /// A scarlet thread across the top of the page while it loads.
    private var progressLine: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [TG.scarlet, TG.scarletSoft, TG.ember],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: TG.scarletSoft.opacity(0.8), radius: 4)
                .frame(width: proxy.size.width * webModel.estimatedProgress, height: 2.5)
                .opacity(webModel.isLoading ? 1 : 0)
                .tgAnimation(TG.Motion.drift, value: webModel.estimatedProgress)
                .tgAnimation(TG.Motion.drift, value: webModel.isLoading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = coordinator.toast {
            ToastView(
                toast: toast,
                onAction: { coordinator.run($0) },
                onDismiss: { coordinator.dismissToast() }
            )
            .padding(.horizontal, TG.Space.loose)
            .padding(.top, 52)
            .transition(.asymmetric(
                insertion: .push(from: .top).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
            ))
            .zIndex(1)
        }
    }

    // MARK: - Launch at Login

    /// Writes to `SMAppService` only when a *person* flips the toggle.
    ///
    /// The previous version watched `launchAtLogin` with `onChange`, which could not tell a
    /// user's tap apart from the panel syncing itself to the system on open. Opening the panel
    /// while the login item was in any state other than the one `@State` happened to hold
    /// therefore fired a real register/unregister — and when the app wasn't installed in
    /// `/Applications`, `unregister()` threw and every open produced an error toast.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                updateLaunchAtLogin(enabled: newValue)
            }
        )
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLogin = LaunchAtLogin.isEnabled
            if let message = LaunchAtLogin.statusMessage {
                coordinator.show(Toast(kind: .info, title: "Launch at Login", detail: message))
            }
        } catch {
            // Snap the toggle back to the truth rather than leaving it showing a state the
            // system rejected.
            launchAtLogin = LaunchAtLogin.isEnabled
            coordinator.show(Toast(
                kind: .failure,
                title: "Couldn't change Launch at Login",
                detail: error.localizedDescription
            ))
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 720, height: 850)
}
