import Foundation
import AppKit

/// A browser we know how to interrogate over Apple Events.
nonisolated struct BrowserTarget: Identifiable, Equatable {
    enum Family {
        /// Safari's dictionary: `front document`, `do JavaScript … in`.
        case safari
        /// Chromium's dictionary: `active tab of front window`, `execute … javascript`.
        case chromium
    }

    let bundleID: String
    let name: String
    let family: Family

    var id: String { bundleID }

    /// Every browser we can read, in the order we prefer them when several are running.
    static let known: [BrowserTarget] = [
        BrowserTarget(bundleID: "com.apple.Safari", name: "Safari", family: .safari),
        BrowserTarget(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", family: .safari),
        BrowserTarget(bundleID: "com.kagi.kagimacOS", name: "Orion", family: .safari),
        BrowserTarget(bundleID: "com.google.Chrome", name: "Google Chrome", family: .chromium),
        BrowserTarget(bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta", family: .chromium),
        BrowserTarget(bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary", family: .chromium),
        BrowserTarget(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", family: .chromium),
        BrowserTarget(bundleID: "com.microsoft.edgemac.Beta", name: "Microsoft Edge Beta", family: .chromium),
        BrowserTarget(bundleID: "com.brave.Browser", name: "Brave Browser", family: .chromium),
        BrowserTarget(bundleID: "com.brave.Browser.beta", name: "Brave Browser Beta", family: .chromium),
        BrowserTarget(bundleID: "company.thebrowser.Browser", name: "Arc", family: .chromium),
        BrowserTarget(bundleID: "company.thebrowser.dia", name: "Dia", family: .chromium),
        BrowserTarget(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chromium),
        BrowserTarget(bundleID: "com.operasoftware.Opera", name: "Opera", family: .chromium),
    ]

    static func matching(bundleID: String?) -> BrowserTarget? {
        guard let bundleID else { return nil }
        return known.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Running browsers, most-recently-active first.
    static var running: [BrowserTarget] {
        let activeOrder = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .map { $0.lowercased() }
        return known
            .filter(\.isRunning)
            .sorted { lhs, rhs in
                let l = activeOrder.firstIndex(of: lhs.bundleID.lowercased()) ?? Int.max
                let r = activeOrder.firstIndex(of: rhs.bundleID.lowercased()) ?? Int.max
                return l < r
            }
    }
}

/// Reads the frontmost tab of a browser: title, URL, and the user's selection.
nonisolated enum BrowserBridge {

    /// Field separator for the multi-value script result. Chosen to be something no page
    /// title or selection will contain; splitting on a newline would corrupt selections.
    private static let separator = "<<|TGPT-FIELD|>>"

    /// The JavaScript we ask the page to evaluate. Kept to one expression so both Safari's
    /// `do JavaScript` and Chromium's `execute javascript` return it directly.
    private static let selectionJS =
        "(function(){try{var s=window.getSelection?String(window.getSelection()):'';return s.trim();}catch(e){return '';}})()"

    static func capture(from target: BrowserTarget) async throws -> CapturedContext {
        guard target.isRunning else { throw AutomationError.notRunning(app: target.name) }

        switch AutomationPermission.status(bundleIdentifier: target.bundleID, prompt: true) {
        case .denied:
            throw AutomationError.permissionDenied(app: target.name)
        case .needsPrompt:
            throw AutomationError.permissionNotGranted(app: target.name)
        case .targetNotRunning:
            throw AutomationError.notRunning(app: target.name)
        case .granted, .unknown:
            break
        }

        let raw = try await AppleScriptRunner.runForString(script(for: target), appName: target.name)
        return try parse(raw, target: target)
    }

    /// Captures from whichever browser the user was last actually looking at.
    @MainActor
    static func captureFromFrontmost() async throws -> CapturedContext {
        guard let target = frontmostBrowser() else {
            throw AutomationError.notRunning(app: "a supported browser")
        }
        return try await capture(from: target)
    }

    /// The browser to read when the user just says "capture the page".
    ///
    /// Opening our own panel makes *us* frontmost, so we ask `FrontmostAppTracker` which app
    /// the user came from rather than asking the workspace who is in front right now.
    @MainActor
    static func frontmostBrowser() -> BrowserTarget? {
        if let target = BrowserTarget.matching(bundleID: FrontmostAppTracker.shared.previousBundleID) {
            return target
        }
        return BrowserTarget.running.first
    }

    // MARK: - Scripts

    private static func script(for target: BrowserTarget) -> String {
        switch target.family {
        case .safari:
            return AppleScriptRunner.timed("""
            tell application id \(target.bundleID.appleScriptLiteral)
                if (count of documents) is 0 then error "No open window." number -1719
                set theDoc to front document
                set theTitle to (name of theDoc) as text
                set theURL to (URL of theDoc) as text
                set theSelection to ""
                set jsOK to "0"
                try
                    set theSelection to (do JavaScript \(selectionJS.appleScriptLiteral) in theDoc) as text
                    set jsOK to "1"
                end try
            end tell
            return theTitle & \(separator.appleScriptLiteral) & theURL & \(separator.appleScriptLiteral) & theSelection & \(separator.appleScriptLiteral) & jsOK
            """)

        case .chromium:
            return AppleScriptRunner.timed("""
            tell application id \(target.bundleID.appleScriptLiteral)
                if (count of windows) is 0 then error "No open window." number -1719
                set theTab to active tab of front window
                set theTitle to (title of theTab) as text
                set theURL to (URL of theTab) as text
                set theSelection to ""
                set jsOK to "0"
                try
                    set theSelection to (execute theTab javascript \(selectionJS.appleScriptLiteral)) as text
                    set jsOK to "1"
                end try
            end tell
            return theTitle & \(separator.appleScriptLiteral) & theURL & \(separator.appleScriptLiteral) & theSelection & \(separator.appleScriptLiteral) & jsOK
            """)
        }
    }

    // MARK: - Parsing

    private static func parse(_ raw: String, target: BrowserTarget) throws -> CapturedContext {
        let fields = raw.components(separatedBy: separator)
        guard fields.count >= 4 else { throw AutomationError.noResult(app: target.name) }

        let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let javaScriptRan = fields[3].trimmingCharacters(in: .whitespacesAndNewlines) == "1"

        let url = URL(string: urlString)

        var body = ""
        var partial: String?

        if !selection.isEmpty {
            body = selection
        } else if javaScriptRan {
            // The page loaded and we could read it, there just wasn't a selection.
            body = "(No text selected on this page.)"
            partial = "No selection — only the link was captured."
        } else {
            body = "(Selected text unavailable.)"
            partial = target.family == .safari
                ? "Enable Safari → Develop → \"Allow JavaScript from Apple Events\" to capture selected text."
                : "Enable \(target.name) → View → Developer → \"Allow JavaScript from Apple Events\" to capture selected text."
        }

        return CapturedContext(
            source: .browser(app: target.name),
            title: title.isEmpty ? (url?.host ?? "Untitled page") : title,
            detail: url?.host,
            url: url,
            body: body,
            partial: partial
        )
    }
}
