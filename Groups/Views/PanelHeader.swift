import SwiftUI

/// The panel's top chrome: identity on the left, a glass control cluster on the right.
///
/// The controls share one `GlassEffectContainer` with stable `glassEffectID`s so they animate
/// as one family when a button appears or disappears (Back/Forward only exist once there is
/// history). The container's spacing is deliberately *small*: that value is the distance at
/// which neighbouring glass shapes fuse, and at the old 14pt — against a 6pt layout gap — the
/// entire cluster melted into a single lozenge with no readable button boundaries.
struct PanelHeader: View {

    @ObservedObject var auth: AuthManager
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject var webModel: WebViewModel
    @Binding var launchAtLogin: Bool

    @Namespace private var glass

    var body: some View {
        HStack(spacing: TG.Space.snug) {
            identity

            SessionPill(phase: auth.phase)

            Spacer(minLength: TG.Space.snug)

            GlassEffectContainer(spacing: TG.Space.merge) {
                HStack(spacing: TG.Space.controlGap) {
                    historyControls
                    captureMenu
                    overflowMenu
                }
            }
        }
        .padding(.horizontal, TG.Space.regular)
        .padding(.top, TG.Space.snug)
        .padding(.bottom, TG.Space.snug)
    }

    // MARK: - Identity

    private var identity: some View {
        HStack(spacing: TG.Space.tight) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [TG.scarletSoft, TG.scarlet],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: TG.scarlet.opacity(0.55), radius: 5)
                // Marks the moment a capture lands, which is otherwise easy to miss when the
                // tray is scrolled or collapsed.
                .symbolEffect(.bounce, value: coordinator.contexts.count)

            Text("TerrierGPT")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if let badge = auth.instance.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(TG.working.gradient, in: Capsule())
                    .accessibilityLabel("Non-production test instance")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(auth.instance == .nonprod ? "TerrierGPT Test" : "TerrierGPT")
    }

    private var instanceBinding: Binding<TerrierInstance> {
        Binding(
            get: { auth.instance },
            set: { auth.setInstance($0) }
        )
    }

    // MARK: - Controls

    private var historyControls: some View {
        Group {
            if webModel.canGoBack || webModel.canGoForward {
                Button { webModel.goBack() } label: { Image(systemName: "chevron.backward") }
                    .buttonStyle(.glassCircle(tint: TG.azure, id: "back", in: glass))
                    .disabled(!webModel.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back (⌘[)")

                Button { webModel.goForward() } label: { Image(systemName: "chevron.forward") }
                    .buttonStyle(.glassCircle(tint: TG.azure, id: "forward", in: glass))
                    .disabled(!webModel.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward (⌘])")
            }
        }
        .transition(.blurReplace)
        .tgAnimation(TG.Motion.morph, value: webModel.canGoBack || webModel.canGoForward)
    }

    private var captureMenu: some View {
        Menu {
            if let browser = coordinator.frontmostBrowserName {
                Button {
                    Task { await coordinator.captureBrowser() }
                } label: {
                    Label("Page in \(browser)", systemImage: "safari")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            Button {
                Task { await coordinator.captureFinder() }
            } label: {
                Label("Finder selection", systemImage: "folder")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button {
                coordinator.captureClipboard()
            } label: {
                Label("Clipboard", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button {
                Task { await coordinator.captureAnswer() }
            } label: {
                Label("Selection in this chat", systemImage: "text.quote")
            }

            if !BrowserTarget.running.isEmpty {
                Divider()
                Menu("From another browser") {
                    ForEach(BrowserTarget.running) { target in
                        Button(target.name) {
                            Task { await coordinator.captureBrowser(target) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: coordinator.isWorking ? "ellipsis" : "plus.viewfinder")
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.button)
        .buttonStyle(.glassCircle(tint: TG.scarlet, prominent: coordinator.hasContext, id: "capture", in: glass))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Capture context from another app")
        .accessibilityLabel("Capture context")
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                auth.requestReload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)

            Button {
                auth.openInBrowser()
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }

            Button {
                webModel.focusContent()
            } label: {
                Label("Focus Chat", systemImage: "keyboard")
            }
            .keyboardShortcut("l", modifiers: .command)

            Divider()

            // Prod campus vs AIDA nonprod. Persistent; reloads home on change.
            Picker(selection: instanceBinding) {
                ForEach(TerrierInstance.allCases) { item in
                    Text(item == .nonprod ? "Test (nonprod)" : "Campus").tag(item)
                }
            } label: {
                Label("Instance", systemImage: "server.rack")
            }

            AutomationMenu(coordinator: coordinator)

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)

            Button {
                AutomationPermission.openAutomationSettings()
            } label: {
                Label("Permissions…", systemImage: "lock.shield")
            }

            if auth.isAuthenticated {
                Divider()
                Button(role: .destructive) {
                    Task { await auth.logout() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit TerrierGPT", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.glassCircle(tint: TG.graphite, id: "overflow", in: glass))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More options")

    }
}
