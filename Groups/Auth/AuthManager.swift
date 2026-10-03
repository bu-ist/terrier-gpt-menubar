import Foundation
import WebKit
import Combine
import AppKit

/// High-level session phase driven primarily by WebView navigation URLs.
enum SessionPhase: Equatable {
    /// Waiting for the first navigation result.
    case loading
    /// On TerrierGPT (or cleared) without an active app session.
    case signedOut
    /// Microsoft / BU SSO intermediate pages.
    case authenticating
    /// Settled on the TerrierGPT app host after login.
    case signedIn
}

/// Which TerrierGPT host the panel loads. Campus prod vs AIDA nonprod (Ticket Search Desk, KB Desk).
enum TerrierInstance: String, CaseIterable, Identifiable {
    case production
    case nonprod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .production: return "Prod"
        case .nonprod: return "Test"
        }
    }

    var homeURL: URL {
        switch self {
        case .production:
            return URL(string: "https://terriergpt.bu.edu/")!
        case .nonprod:
            return URL(string: "https://test.terriergpt-nonprod.bu.edu/")!
        }
    }

    /// Short badge for chrome when not on production.
    var badge: String? {
        switch self {
        case .production: return nil
        case .nonprod: return "TEST"
        }
    }
}

@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    private static let instanceDefaultsKey = "TerrierInstance"

    @Published private(set) var phase: SessionPhase = .loading
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var isLoading: Bool = true
    /// Last main-frame URL the web view reported (debug / future UI).
    @Published private(set) var lastNavigationURL: URL?

    /// Prod campus vs nonprod test host. Persisted; switching reloads home.
    @Published private(set) var instance: TerrierInstance

    var terrierURL: URL { instance.homeURL }

    /// Bumped to reload the current page.
    @Published private(set) var reloadToken = UUID()
    /// Bumped on logout / instance switch so the web view loads home (not a bare reload).
    @Published private(set) var loadHomeToken = UUID()

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.instanceDefaultsKey) ?? ""
        self.instance = TerrierInstance(rawValue: raw) ?? .production
    }

    /// Switch Prod ↔ Test and navigate to that host's home.
    func setInstance(_ newValue: TerrierInstance) {
        guard newValue != instance else { return }
        instance = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.instanceDefaultsKey)
        apply(phase: .loading)
        loadHomeToken = UUID()
    }

    // MARK: - Navigation-driven session (source of truth)

    /// Call from `WKNavigationDelegate` for main-frame URL changes.
    func updateFromNavigation(url: URL?) {
        guard let url else { return }

        // Ignore empty provisional documents.
        let raw = url.absoluteString.lowercased()
        if raw.isEmpty || raw == "about:blank" || raw.hasPrefix("about:blank") {
            return
        }

        lastNavigationURL = url
        apply(phase: Self.classify(url: url))
    }

    /// Provisional load started.
    func noteNavigationStarted(url: URL?) {
        if let url {
            let host = (url.host ?? "").lowercased()
            if Self.isIdentityHost(host) || isNonAppCampusHost(host) {
                apply(phase: .authenticating)
                return
            }
        }
        // Keep the dot green during soft reloads of the app itself; only show the loading
        // state when we don't already have a settled session.
        if phase != .signedIn {
            isLoading = true
        }
    }

    func noteNavigationFailed(error: Error) {
        let nsError = error as NSError
        // Redirects and new loads cancel the previous navigation; that is not a real failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if phase == .loading || phase == .authenticating {
            apply(phase: .signedOut)
        }
        isLoading = false
    }

    // MARK: - Actions (UI + Shortcuts)

    func requestReload() {
        reloadToken = UUID()
    }

    func logout() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date.distantPast
        )

        apply(phase: .signedOut)
        loadHomeToken = UUID()
    }

    /// Hands the current page to the default browser, falling back to the home URL.
    ///
    /// Opening the bare home URL threw away whichever conversation the user was reading,
    /// which made "Open in Browser" close to useless mid-chat.
    func openInBrowser() {
        let target: URL
        if let current = lastNavigationURL, Self.classify(url: current) == .signedIn {
            target = current
        } else {
            target = terrierURL
        }
        NSWorkspace.shared.open(target)
    }

    /// Brings the panel forward.
    ///
    /// - Returns: `false` when the status item couldn't be reached, so the caller can tell the
    ///   user to click the menu bar icon instead of claiming success.
    @discardableResult
    func showPanel() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return MenuBarPanel.show()
    }

    // MARK: - Classification

    private func apply(phase newPhase: SessionPhase) {
        phase = newPhase
        isAuthenticated = (newPhase == .signedIn)
        isLoading = (newPhase == .loading || newPhase == .authenticating)
    }

    /// Map a main-frame URL to a session phase.
    ///
    /// Order matters: classify the TerrierGPT app host before generic SSO query markers
    /// like `client_id=`, which can appear on the app itself and caused false "authenticating".
    static func classify(url: URL) -> SessionPhase {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let query = (url.query ?? "").lowercased()

        if host.isEmpty {
            return .loading
        }

        // 1) Identity providers → mid-login
        if isIdentityHost(host) {
            return .authenticating
        }

        // 2) TerrierGPT app host (before generic SSO query heuristics)
        if isTerrierAppHost(host) {
            if pathLooksSignedOut(path) {
                return .signedOut
            }
            return .signedIn
        }

        // 3) Explicit SSO / SAML style paths on other hosts
        if pathContainsSSOMarkers(path) || queryContainsSSOMarkers(query) || host.contains("shibboleth") {
            return .authenticating
        }

        // 4) Other BU hosts (campus portal steps between Entra and the app)
        if isCampusSSOHost(host) {
            return .authenticating
        }

        return .signedOut
    }

    /// Both campus prod and AIDA nonprod. Nonprod is `test.terriergpt-nonprod.bu.edu`
    /// (not a subdomain of `terriergpt.bu.edu`).
    nonisolated static func isTerrierAppHost(_ host: String) -> Bool {
        if host == "terriergpt.bu.edu" || host.hasSuffix(".terriergpt.bu.edu") {
            return true
        }
        if host == "test.terriergpt-nonprod.bu.edu"
            || host == "terriergpt-nonprod.bu.edu"
            || host.hasSuffix(".terriergpt-nonprod.bu.edu") {
            return true
        }
        return false
    }

    private static func isIdentityHost(_ host: String) -> Bool {
        let hosts = [
            "login.microsoftonline.com",
            "login.microsoft.com",
            "login.live.com",
            "sts.windows.net",
            "login.windows.net",
            "device.login.microsoftonline.com",
        ]
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func isCampusSSOHost(_ host: String) -> Bool {
        host == "bu.edu" || host.hasSuffix(".bu.edu")
    }

    private static func pathContainsSSOMarkers(_ path: String) -> Bool {
        let markers = ["/saml", "/oauth", "/oidc", "/adfs", "/sso", "/cas/"]
        return markers.contains { path.contains($0) }
    }

    private static func queryContainsSSOMarkers(_ query: String) -> Bool {
        query.contains("saml") || query.contains("sso")
        // Intentionally NOT matching bare `client_id=` (too common on SPAs).
    }

    private static func pathLooksSignedOut(_ path: String) -> Bool {
        let segments = path.split(separator: "/").map(String.init)
        let markers: Set<String> = [
            "login", "log-in", "signin", "sign-in", "sign_in",
            "logout", "log-out", "signout", "sign-out", "sign_out",
        ]
        if segments.contains(where: { markers.contains($0) }) {
            return true
        }
        // Nested routes like /auth/logout, /account/login
        let joined = "/" + segments.joined(separator: "/")
        let prefixes = ["/auth/logout", "/account/login", "/accounts/login"]
        return prefixes.contains { joined == $0 || joined.hasPrefix($0 + "/") }
    }

    /// A BU host that is *not* the TerrierGPT app itself — i.e. a campus login hop.
    ///
    /// Named apart from the static `isCampusSSOHost` it wraps; the previous name shadowed the
    /// static one, so which of the two ran at a given call site depended on context.
    private func isNonAppCampusHost(_ host: String) -> Bool {
        guard !Self.isTerrierAppHost(host) else { return false }
        return Self.isCampusSSOHost(host)
    }
}

/// Shared clipboard prompt used by the UI, the Services menu, and Shortcuts.
enum ClipboardPrompt {

    /// Wraps arbitrary text in the app's standard instruction.
    ///
    /// This used to hard-code a Spanish instruction ("Analiza el siguiente contenido..."),
    /// which made an otherwise English app answer in Spanish. It now shares one composer with
    /// the capture pipeline so every entry point produces the same prompt shape.
    static func wrap(_ text: String, instruction: String = PromptComposer.defaultInstruction) -> String {
        PromptComposer.compose(
            instruction: instruction,
            contexts: [CapturedContext(source: .clipboard, title: "Clipboard", body: text)]
        )
    }

    /// Reads the pasteboard, wraps it, and writes the result back.
    @MainActor
    static func prepareFromPasteboard(instruction: String = PromptComposer.defaultInstruction) -> Result<String, PrepareError> {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return .failure(.empty)
        }
        let prompt = wrap(text, instruction: instruction)
        write(prompt)
        return .success(prompt)
    }

    /// Reads the pasteboard as a capture, without modifying it.
    @MainActor
    static func captureFromPasteboard() -> CapturedContext? {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        return CapturedContext(
            source: .clipboard,
            title: firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine,
            detail: "\(text.count) characters",
            body: text
        )
    }

    /// Replaces the pasteboard contents with `prompt`.
    @MainActor
    static func write(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    enum PrepareError: Error, LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Clipboard is empty"
            }
        }
    }
}
