import SwiftUI
import WebKit
import AppKit

struct WebView: NSViewRepresentable {
    let url: URL
    var reloadTrigger: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(homeURL: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(trigger: reloadTrigger)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let homeURL: URL
        weak var webView: WKWebView?
        private var lastReloadTrigger: UUID?

        init(homeURL: URL) {
            self.homeURL = homeURL
        }

        /// Only reloads when the trigger changes; skips the first `updateNSView` after creation.
        func reloadIfNeeded(trigger: UUID) {
            if lastReloadTrigger == nil {
                lastReloadTrigger = trigger
                return
            }
            guard lastReloadTrigger != trigger else { return }
            lastReloadTrigger = trigger
            webView?.reload()
        }

        // MARK: - Host policy

        /// Pages that should stay inside the menu panel (app host, BU SSO, common auth).
        private func shouldHandleInternally(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return true }

            // about:/blob: stay in-panel (some SPAs use them).
            if scheme == "about" || scheme == "blob" || scheme == "data" {
                return true
            }

            guard scheme == "http" || scheme == "https" else {
                return false
            }

            guard let host = url.host?.lowercased() else { return true }

            if let homeHost = homeURL.host?.lowercased() {
                if host == homeHost || host.hasSuffix("." + homeHost) {
                    return true
                }
            }

            // Keep campus + common SSO hosts so login redirects still work in-panel.
            if host == "bu.edu" || host.hasSuffix(".bu.edu") {
                return true
            }

            let authHosts = [
                "login.microsoftonline.com",
                "login.microsoft.com",
                "login.live.com",
                "sts.windows.net",
                "login.windows.net",
            ]
            return authHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        private func openExternally(_ url: URL) {
            NSWorkspace.shared.open(url)
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // mailto:, tel:, custom schemes → system handler
            if let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https",
               scheme != "about", scheme != "blob", scheme != "data" {
                openExternally(url)
                decisionHandler(.cancel)
                return
            }

            // User-clicked link to an external site → default browser
            if navigationAction.navigationType == .linkActivated {
                if !shouldHandleInternally(url) {
                    openExternally(url)
                    decisionHandler(.cancel)
                    return
                }

                // target="_blank" (no target frame): load in this panel when allowed
                if navigationAction.targetFrame == nil {
                    webView.load(URLRequest(url: url))
                    decisionHandler(.cancel)
                    return
                }
            }

            // Redirects / form posts (including SSO) stay in-panel
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // Downloads / unrenderable MIME types → hand off to the browser
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else if let url = navigationResponse.response.url {
                openExternally(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }

        // MARK: - WKUIDelegate (new windows / popups)

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }

            if shouldHandleInternally(url) {
                webView.load(URLRequest(url: url))
            } else {
                openExternally(url)
            }
            // No second window; we handled the navigation ourselves.
            return nil
        }
    }
}
