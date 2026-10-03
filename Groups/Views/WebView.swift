import SwiftUI
import WebKit
import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

/// Observable state for the embedded web view, and the app's handle on it.
///
/// The panel chrome needs to read (progress, history) and act on (reload, run JavaScript) the
/// web view, but `NSViewRepresentable` hands the view out only inside `makeNSView`. This model
/// is the seam: the representable registers the view here, everything else talks to the model.
@MainActor
final class WebViewModel: ObservableObject {

    @Published fileprivate(set) var estimatedProgress: Double = 0
    @Published fileprivate(set) var isLoading: Bool = false
    @Published fileprivate(set) var canGoBack: Bool = false
    @Published fileprivate(set) var canGoForward: Bool = false
    @Published fileprivate(set) var pageTitle: String = ""
    /// Set when a download finishes, so the panel can offer "Show in Finder".
    @Published var lastDownload: URL?

    fileprivate weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    /// Mirrors `WKWebView`'s KVO-observable chrome state onto this model.
    ///
    /// Every observer defers its write to the next main-actor turn rather than assigning
    /// straight through. `WKWebView` fires KVO *synchronously* inside whatever caused the
    /// change, and the things that cause it here — `load(_:)` from `makeNSView`, `reload()`
    /// from `updateNSView` — run in the middle of a SwiftUI view update. Assigning to an
    /// `@Published` at that point is precisely "Publishing changes from within view updates is
    /// not allowed, this will cause undefined behavior": the view graph has already read those
    /// values for the frame it is building. Hopping to the next turn gives each change an
    /// update cycle of its own.
    ///
    /// The hop also removes a latent trap. The previous code used `MainActor.assumeIsolated`,
    /// which asserts rather than checks — a KVO notification delivered off the main thread
    /// would have crashed instead of being handled.
    fileprivate func attach(_ webView: WKWebView) {
        detach()
        self.webView = webView
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                guard let self else { return }
                Task { @MainActor in
                    // Progress arrives in fractions of a percent. Republishing each one
                    // re-renders the whole panel for a change nobody can see, so only
                    // visible steps are forwarded — and always the last one.
                    guard value >= 1 || abs(value - self.estimatedProgress) > 0.02 else { return }
                    self.estimatedProgress = value
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                let value = view.isLoading
                guard let self else { return }
                Task { @MainActor in
                    guard self.isLoading != value else { return }
                    self.isLoading = value
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                let value = view.canGoBack
                guard let self else { return }
                Task { @MainActor in
                    guard self.canGoBack != value else { return }
                    self.canGoBack = value
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                let value = view.canGoForward
                guard let self else { return }
                Task { @MainActor in
                    guard self.canGoForward != value else { return }
                    self.canGoForward = value
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let value = view.title ?? ""
                guard let self else { return }
                Task { @MainActor in
                    guard self.pageTitle != value else { return }
                    self.pageTitle = value
                }
            },
        ]
    }

    /// Stops observing a web view that is going away.
    ///
    /// Without this the observations outlive the panel: `NSKeyValueObservation` only
    /// unregisters when it is deallocated, and this model (a `@StateObject`) can outlive the
    /// web view it was watching.
    fileprivate func detach() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView = nil

        // Same deferral rule as above — `dismantleNSView` also runs inside a view update.
        Task { @MainActor [self] in
            self.estimatedProgress = 0
            self.isLoading = false
            self.canGoBack = false
            self.canGoForward = false
        }
    }

    // MARK: - Navigation

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func stop() { webView?.stopLoading() }

    /// Puts keyboard focus in the web view so the user can type immediately.
    func focusContent() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
    }

    // MARK: - Reading the page

    /// The text the user has selected inside the TerrierGPT page.
    ///
    /// This is deliberately selection-based rather than scraping the DOM for "the last
    /// assistant message": TerrierGPT's markup is not ours and would break on any redesign,
    /// whereas `getSelection()` is a web standard and shows the user exactly what they're
    /// about to file into Notes.
    func selectedText() async -> String {
        let js = "(function(){try{return String(window.getSelection()||'').trim();}catch(e){return '';}})()"
        return (try? await evaluate(js)) ?? ""
    }

    /// Selection if there is one, otherwise the whole readable body text, capped.
    func selectionOrPageText(limit: Int = 20_000) async -> String {
        let selection = await selectedText()
        if !selection.isEmpty { return selection }

        let js = """
        (function(){
          try {
            var el = document.querySelector('main') || document.body;
            return (el.innerText || '').trim().slice(0, \(limit));
          } catch (e) { return ''; }
        })()
        """
        return (try? await evaluate(js)) ?? ""
    }

    /// Everything a handoff might be extracted from, in one round trip: the selection, the text
    /// of every `<pre>` block, and the readable page text.
    ///
    /// `<pre>` is how any Markdown renderer emits a fenced code block, so this leans on HTML
    /// semantics rather than on TerrierGPT's class names — the same reason `selectedText()`
    /// uses `getSelection()`. Rendering strips the ```json fence, which is why the blocks are
    /// read as elements instead of being searched for in `innerText`.
    ///
    /// Returns `nil` when there is no web view at all (panel never opened), so callers can tell
    /// "nothing on the page" from "no page".
    func handoffSources(limit: Int = 200_000) async -> HandoffSources? {
        guard webView != nil else { return nil }
        let js = """
        (function(){
          try {
            var sel = String(window.getSelection() || '').trim();
            var blocks = Array.prototype.map.call(document.querySelectorAll('pre'), function(p){
              return (p.innerText || '').trim();
            }).filter(function(t){ return t.length > 0; });
            var el = document.querySelector('main') || document.body;
            var text = (el.innerText || '').trim().slice(-\(limit));
            // Newest assistant message, best effort. These are the containers chat UIs
            // (TerrierGPT's included) render Markdown answers into; if none match, the
            // caller falls back to the page text. Nothing here is required to work.
            var last = null, prose = null;
            var selectors = ['[data-message-author-role="assistant"]', '.agent-turn', '.markdown.prose', '.markdown'];
            for (var i = 0; i < selectors.length && last === null; i++) {
              var nodes = document.querySelectorAll(selectors[i]);
              for (var j = nodes.length - 1; j >= 0; j--) {
                var t = (nodes[j].innerText || '').trim();
                if (t.length > 0) {
                  last = t;
                  // Cut the code blocks out of the rendered text. (A detached clone would
                  // lose the paragraph breaks: innerText needs layout.)
                  prose = t;
                  nodes[j].querySelectorAll('pre').forEach(function(p){
                    var code = (p.innerText || '').trim();
                    if (code) { prose = prose.replace(code, ''); }
                  });
                  prose = prose.replace(/\\n{3,}/g, '\\n\\n').trim();
                  break;
                }
              }
            }
            // The question that produced it, for the handoff brief. Same best effort.
            var asked = null;
            var userNodes = document.querySelectorAll('[data-message-author-role="user"], .user-turn');
            for (var k = userNodes.length - 1; k >= 0 && asked === null; k--) {
              var u = (userNodes[k].innerText || '').trim();
              if (u.length > 0) { asked = u; }
            }
            return JSON.stringify({ selection: sel, blocks: blocks, text: text, lastMessage: last, lastMessageProse: prose, lastUserMessage: asked });
          } catch (e) { return ''; }
        })()
        """
        let raw = (try? await evaluate(js)) ?? ""
        let decoded = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(HandoffSources.self, from: $0) }
        return decoded ?? HandoffSources(selection: "", blocks: [], text: "")
    }

    func currentURL() -> URL? { webView?.url }

    private func evaluate(_ javaScript: String) async throws -> String {
        guard let webView else { return "" }
        let result = try await webView.evaluateJavaScript(javaScript)
        return (result as? String) ?? ""
    }
}

// MARK: - Representable

struct WebView: NSViewRepresentable {
    let url: URL
    var reloadTrigger: UUID
    /// When this changes, load `url` from scratch (used after logout).
    var loadHomeTrigger: UUID
    /// Held, not observed. The representable only ever *registers* the web view with the
    /// model; it reads none of its published state. Declaring it `@ObservedObject` subscribed
    /// the representable to every progress tick and re-ran `updateNSView` dozens of times a
    /// second during a page load.
    let model: WebViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(homeURL: url, model: model)
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
        // Matches the panel material behind the page during rubber-band scrolling, so an
        // overscroll shows the glass rather than a hard white rectangle.
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif

        context.coordinator.webView = webView
        model.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Instance toggle changes `url`; keep the coordinator's home in sync or loadHome
        // would still open the previous host.
        context.coordinator.homeURL = url
        context.coordinator.reloadIfNeeded(trigger: reloadTrigger)
        context.coordinator.loadHomeIfNeeded(trigger: loadHomeTrigger)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Without this the web view keeps loading (and keeps playing audio) after the panel
        // that owned it is gone.
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.model.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var homeURL: URL
        let model: WebViewModel
        weak var webView: WKWebView?
        private var lastReloadTrigger: UUID?
        private var lastHomeTrigger: UUID?
        private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "webview")

        init(homeURL: URL, model: WebViewModel) {
            self.homeURL = homeURL
            self.model = model
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

        /// Full navigation to home (post-logout clean slate).
        func loadHomeIfNeeded(trigger: UUID) {
            if lastHomeTrigger == nil {
                lastHomeTrigger = trigger
                return
            }
            guard lastHomeTrigger != trigger else { return }
            lastHomeTrigger = trigger
            webView?.load(URLRequest(url: homeURL))
        }

        private func reportNavigation(from webView: WKWebView, url: URL? = nil) {
            let resolved = url ?? webView.url
            Task { @MainActor in
                AuthManager.shared.updateFromNavigation(url: resolved)
            }
        }

        // MARK: - Host policy

        private func shouldHandleInternally(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return true }

            if scheme == "about" || scheme == "blob" || scheme == "data" {
                return true
            }

            guard scheme == "http" || scheme == "https" else {
                return false
            }

            guard let host = url.host?.lowercased() else { return true }

            // Always allow both TerrierGPT app hosts so Prod↔Test SSO hops stay in-panel.
            if AuthManager.isTerrierAppHost(host) {
                return true
            }

            if host == "bu.edu" || host.hasSuffix(".bu.edu") {
                return true
            }

            let authHosts = [
                "login.microsoftonline.com",
                "login.microsoft.com",
                "login.live.com",
                "sts.windows.net",
                "login.windows.net",
                "device.login.microsoftonline.com",
                "msauth.net",
                "msftauth.net",
                "aadcdn.msauth.net",
                "aadcdn.msftauth.net",
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

            if let scheme = url.scheme?.lowercased(),
               scheme != "http", scheme != "https",
               scheme != "about", scheme != "blob", scheme != "data" {
                openExternally(url)
                decisionHandler(.cancel)
                return
            }

            // A download attribute or a ⌥-click should save the file, not navigate.
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                if !shouldHandleInternally(url) {
                    openExternally(url)
                    decisionHandler(.cancel)
                    return
                }

                if navigationAction.targetFrame == nil {
                    webView.load(URLRequest(url: url))
                    decisionHandler(.cancel)
                    return
                }
            }

            // Only main-frame navigations update session (not iframes).
            // `targetFrame == nil` means a new window request; session updates when it loads in-panel.
            if let target = navigationAction.targetFrame, target.isMainFrame {
                Task { @MainActor in
                    AuthManager.shared.updateFromNavigation(url: url)
                }
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame, let url = navigationResponse.response.url {
                Task { @MainActor in
                    AuthManager.shared.updateFromNavigation(url: url)
                }
            }

            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                // Previously this handed the URL to the default browser, which then had to
                // authenticate all over again and usually just landed on a login page. Taking
                // the download here reuses the session cookies we already hold.
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                AuthManager.shared.noteNavigationStarted(url: webView.url)
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            reportNavigation(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            reportNavigation(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reportNavigation(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor in
                AuthManager.shared.noteNavigationFailed(error: error)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            Task { @MainActor in
                AuthManager.shared.noteNavigationFailed(error: error)
            }
        }

        // MARK: - WKUIDelegate

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
            return nil
        }

        /// JavaScript `alert()`.
        ///
        /// `WKUIDelegate` has no default implementation for these three: leaving them out
        /// means the page's alert/confirm/prompt calls resolve to nothing, and any flow that
        /// waits on one (a "discard this chat?" confirm, for instance) silently stalls.
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            presentAlert(message: message, style: .informational, buttons: ["OK"], window: webView.window) { _ in
                completionHandler()
            }
        }

        /// JavaScript `confirm()`.
        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            presentAlert(message: message, style: .warning, buttons: ["OK", "Cancel"], window: webView.window) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        /// JavaScript `prompt()`.
        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            runAlert(alert, window: webView.window) { response in
                completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }

        /// File `<input type="file">` pickers. Without this, attaching a file to a TerrierGPT
        /// chat does nothing at all.
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.resolvesAliases = true

            let handler: (NSApplication.ModalResponse) -> Void = { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }

            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(panel.runModal())
            }
        }

        /// Microphone / camera requests (voice input). Granting here still leaves the system
        /// TCC prompt in charge of the actual hardware.
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let host = origin.host.lowercased()
            let trusted = AuthManager.isTerrierAppHost(host) || host.hasSuffix(".bu.edu")
            decisionHandler(trusted ? .prompt : .deny)
        }

        // MARK: - Downloads

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let name = suggestedFilename.isEmpty ? "TerrierGPT-download" : suggestedFilename
            completionHandler(Self.uniqueURL(in: directory, named: name))
        }

        func downloadDidFinish(_ download: WKDownload) {
            let url = download.progress.fileURL
            Task { @MainActor in
                self.model.lastDownload = url
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        }

        /// Appends " 2", " 3", … rather than clobbering a file the user already has.
        private static func uniqueURL(in directory: URL, named name: String) -> URL {
            let candidate = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            for index in 2...999 {
                let attempt = directory
                    .appendingPathComponent("\(base) \(index)")
                    .appendingPathExtension(ext)
                if !FileManager.default.fileExists(atPath: attempt.path) { return attempt }
            }
            return directory.appendingPathComponent("\(base)-\(UUID().uuidString)").appendingPathExtension(ext)
        }

        // MARK: - Alert plumbing

        private func presentAlert(
            message: String,
            style: NSAlert.Style,
            buttons: [String],
            window: NSWindow?,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = style
            buttons.forEach { alert.addButton(withTitle: $0) }
            runAlert(alert, window: window, completion: completion)
        }

        private func runAlert(
            _ alert: NSAlert,
            window: NSWindow?,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            // The menu bar panel is a transient window; if it has already gone away, fall back
            // to an app-modal alert rather than dropping the page's callback on the floor.
            if let window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }
    }
}
