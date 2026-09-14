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

@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    @Published private(set) var phase: SessionPhase = .loading
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var isLoading: Bool = true
    /// Last main-frame URL the web view reported (debug / future UI).
    @Published private(set) var lastNavigationURL: URL?

    let terrierURL = URL(string: "https://terriergpt.bu.edu/")!

    /// Bumped to reload the current page.
    @Published private(set) var reloadToken = UUID()
    /// Bumped on logout so the web view loads home with a clean store (not a bare reload).
    @Published private(set) var loadHomeToken = UUID()

    private init() {}

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

    /// Provisional load started (optional spinner).
    func noteNavigationStarted(url: URL?) {
        if let url {
            let host = (url.host ?? "").lowercased()
            if Self.isIdentityHost(host) || isCampusSSOHost(host) {
                apply(phase: .authenticating)
                return
            }
        }
        // Keep signed-in green during soft reloads of the app itself.
        if phase != .signedIn {
            isLoading = true
            if phase == .loading { return }
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

    func openInBrowser() {
        NSWorkspace.shared.open(terrierURL)
    }

    /// Best-effort: activate the app and bring any menu-bar panel window forward.
    func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey || window.frame.width >= 500 {
            let name = String(describing: type(of: window))
            if name.contains("MenuBar") || name.contains("StatusBar") || window.frame.height >= 600 {
                window.makeKeyAndOrderFront(nil)
            }
        }
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

    private static func isTerrierAppHost(_ host: String) -> Bool {
        host == "terriergpt.bu.edu" || host.hasSuffix(".terriergpt.bu.edu")
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

    private func isCampusSSOHost(_ host: String) -> Bool {
        guard !Self.isTerrierAppHost(host) else { return false }
        return Self.isCampusSSOHost(host)
    }
}

/// Shared clipboard prompt used by the UI and Shortcuts.
enum ClipboardPrompt {
    static func wrap(_ text: String) -> String {
        """
        Analiza el siguiente contenido y ayúdame con él:

        \(text)
        """
    }

    @MainActor
    static func prepareFromPasteboard() -> Result<String, PrepareError> {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return .failure(.empty)
        }
        let prompt = wrap(text)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        return .success(prompt)
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
