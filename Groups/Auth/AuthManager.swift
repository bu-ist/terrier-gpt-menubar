import Foundation
import WebKit
import Combine

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
            if isIdentityHost(host) || isCampusSSOHost(host) {
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

    func noteNavigationFailed() {
        if phase == .loading || phase == .authenticating {
            apply(phase: .signedOut)
        }
        isLoading = false
    }

    // MARK: - Logout

    func logout() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date.distantPast
        )

        apply(phase: .signedOut)
        // Force a fresh load of the home URL (cookies are gone).
        loadHomeToken = UUID()
    }

    // MARK: - Classification

    private func apply(phase newPhase: SessionPhase) {
        phase = newPhase
        isAuthenticated = (newPhase == .signedIn)
        isLoading = (newPhase == .loading || newPhase == .authenticating)
    }

    /// Map a main-frame URL to a session phase.
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

        // 2) Explicit SSO / SAML style paths on any host
        if pathContainsSSOMarkers(path) || queryContainsSSOMarkers(query) || host.contains("shibboleth") {
            return .authenticating
        }

        // 3) TerrierGPT app host
        if isTerrierAppHost(host) {
            if pathLooksSignedOut(path) {
                return .signedOut
            }
            // Landed on the product UI (or SPA root). SSO redirects away if not logged in.
            return .signedIn
        }

        // 4) Other BU hosts (campus portal steps between Entra and the app)
        if isCampusSSOHost(host) {
            return .authenticating
        }

        // Unknown host (should be rare with our navigation policy)
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
        query.contains("saml") || query.contains("sso") || query.contains("client_id=")
    }

    private static func pathLooksSignedOut(_ path: String) -> Bool {
        // Conservative: only treat clearly auth/logout routes as signed out.
        let markers = [
            "/login", "/log-in", "/signin", "/sign-in", "/sign_in",
            "/logout", "/log-out", "/signout", "/sign-out", "/sign_out",
            "/auth/logout", "/account/login",
        ]
        return markers.contains { path == $0 || path.hasPrefix($0 + "/") || path.contains($0) }
    }

    // Free-function style helpers used from instance methods
    private func isIdentityHost(_ host: String) -> Bool {
        Self.isIdentityHost(host)
    }

    private func isCampusSSOHost(_ host: String) -> Bool {
        // Exclude the app host itself (already handled as TerrierGPT).
        guard !Self.isTerrierAppHost(host) else { return false }
        return Self.isCampusSSOHost(host)
    }
}
