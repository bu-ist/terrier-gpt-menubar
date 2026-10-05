import Foundation
import SwiftUI
import AppKit
import Combine
import OSLog

/// A transient message shown in the panel's glass toast.
struct Toast: Identifiable, Equatable {

    enum Kind: Equatable {
        case success, failure, info

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: return TG.online
            case .failure: return TG.scarletSoft
            case .info: return .secondary
            }
        }
    }

    /// A follow-up the toast can offer. Modelled as data rather than a closure so `Toast`
    /// stays `Equatable` and can drive SwiftUI transitions.
    enum Action: Equatable {
        case none
        case openAutomationSettings
        case openPrivacyPane(String)
        case reveal(URL)
        case openApp(URL)

        var title: String? {
            switch self {
            case .none: return nil
            case .openAutomationSettings, .openPrivacyPane: return "Open Settings"
            case .reveal: return "Show in Finder"
            case .openApp: return "Open"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    var detail: String?
    var action: Action = .none
}

/// The app's capture-and-file brain.
///
/// Holds whatever context the user has pulled in from other apps, composes it into a prompt,
/// and files results back out to Notes, Reminders, and Calendar. The views stay dumb.
@MainActor
final class CaptureCoordinator: ObservableObject {

    static let shared = CaptureCoordinator()

    @Published var contexts: [CapturedContext] = []
    @Published var instruction: String = ""
    @Published var toast: Toast?
    /// Set while an Apple Event is in flight, so the UI can show the shimmer instead of
    /// looking frozen for the second or two a cold browser takes to answer.
    @Published private(set) var isWorking = false
    @Published var isTrayExpanded = false

    /// Set by `ContentView` once the web view exists.
    weak var webModel: WebViewModel?

    private var toastToken = UUID()
    private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "capture")

    private init() {}

    // MARK: - Derived

    var enabledContexts: [CapturedContext] { contexts.filter(\.isEnabled) }

    var composedPrompt: String {
        PromptComposer.compose(instruction: instruction, contexts: contexts)
    }

    var hasContext: Bool { !contexts.isEmpty }

    /// The browser we'd capture from right now, for labelling the capture button.
    var frontmostBrowserName: String? { BrowserBridge.frontmostBrowser()?.name }

    // MARK: - Capturing

    func captureBrowser(_ target: BrowserTarget? = nil) async {
        await perform {
            let context = try await {
                if let target { return try await BrowserBridge.capture(from: target) }
                return try await BrowserBridge.captureFromFrontmost()
            }()
            self.add(context)
            return Toast(
                kind: context.partial == nil ? .success : .info,
                title: "Captured from \(context.source.label)",
                detail: context.partial ?? context.title
            )
        }
    }

    func captureFinder() async {
        await perform {
            let context = try await FinderBridge.captureSelection()
            self.add(context)
            return Toast(
                kind: .success,
                title: "Captured \(context.title)",
                detail: context.partial
            )
        }
    }

    func captureClipboard() {
        guard let context = ClipboardPrompt.captureFromPasteboard() else {
            show(Toast(kind: .info, title: "Clipboard is empty"))
            return
        }
        add(context)
        show(Toast(kind: .success, title: "Captured clipboard", detail: context.detail))
    }

    /// Captures whatever the user has selected inside the TerrierGPT page.
    func captureAnswer() async {
        guard let webModel else { return }
        let text = await webModel.selectedText()
        guard !text.isEmpty else {
            show(Toast(kind: .info, title: "Nothing selected", detail: "Select text in the chat first."))
            return
        }
        add(CapturedContext(
            source: .answer,
            title: webModel.pageTitle.isEmpty ? "TerrierGPT answer" : webModel.pageTitle,
            detail: "\(text.count) characters",
            url: webModel.currentURL(),
            body: text
        ))
        show(Toast(kind: .success, title: "Captured selection"))
    }

    // MARK: - Managing captures

    func add(_ context: CapturedContext) {
        withAnimation(TG.Motion.morph) {
            // Re-capturing the same page replaces the old chip instead of stacking duplicates.
            //
            // Keyed on the URL, and only when there is one. Matching on `source` alone meant
            // every clipboard capture (which never has a URL) collided with the previous one,
            // so pasting a second snippet silently threw the first away.
            let existing = context.url.flatMap { url in
                contexts.firstIndex { $0.source == context.source && $0.url == url }
            }
            if let existing {
                contexts[existing] = context
            } else {
                contexts.append(context)
            }
            isTrayExpanded = true
        }
    }

    func toggle(_ context: CapturedContext) {
        guard let index = contexts.firstIndex(where: { $0.id == context.id }) else { return }
        withAnimation(TG.Motion.snap) { contexts[index].isEnabled.toggle() }
    }

    func remove(_ context: CapturedContext) {
        withAnimation(TG.Motion.morph) {
            contexts.removeAll { $0.id == context.id }
            if contexts.isEmpty { isTrayExpanded = false }
        }
    }

    func clearContexts() {
        withAnimation(TG.Motion.morph) {
            contexts.removeAll()
            isTrayExpanded = false
        }
    }

    // MARK: - Using the prompt

    /// Puts the composed prompt on the clipboard so the user can paste it into the chat.
    ///
    /// Typing straight into TerrierGPT's composer would mean injecting JavaScript into markup
    /// we don't control; one redesign upstream and it breaks silently. Clipboard-and-paste is
    /// boring, but it keeps working.
    func copyPrompt() {
        let prompt = composedPrompt
        guard !prompt.isEmpty else { return }
        ClipboardPrompt.write(prompt)
        show(Toast(kind: .success, title: "Prompt copied", detail: "Paste into the chat with ⌘V"))
    }

    // MARK: - Filing results

    /// The text the "send to" actions act on: the user's selection in the page, else the page
    /// itself, else the composed prompt.
    private func materialToFile() async -> (title: String, body: String, url: URL?) {
        if let webModel {
            let text = await webModel.selectionOrPageText()
            if !text.isEmpty {
                let title = webModel.pageTitle.isEmpty ? "TerrierGPT" : webModel.pageTitle
                return (title, text, webModel.currentURL())
            }
        }
        let prompt = composedPrompt
        return ("TerrierGPT prompt", prompt, contexts.first?.url)
    }

    func sendToNotes(append: Bool = false) async {
        await perform {
            let material = await self.materialToFile()
            guard !material.body.isEmpty else { throw AppleAppsError.emptyContent }

            let stamp = Self.stampFormatter.string(from: Date())
            let html = Self.notesHTML(body: material.body, url: material.url, stamp: stamp)

            if append {
                try await NotesBridge.appendToNote(title: material.title, html: html)
            } else {
                try await NotesBridge.createNote(title: material.title, html: html)
            }
            return Toast(
                kind: .success,
                title: append ? "Appended to note" : "Saved to Notes",
                detail: "\(NotesBridge.defaultFolder) → \(material.title)",
                action: .openApp(URL(string: "notes://")!)
            )
        }
    }

    func sendToReminders(due: Date?, listName: String? = nil) async {
        await perform {
            let material = await self.materialToFile()
            guard !material.body.isEmpty else { throw AppleAppsError.emptyContent }

            let list = try await EventKitBridge.shared.createReminder(
                title: Self.shortTitle(from: material.title, fallbackBody: material.body),
                notes: material.body,
                due: due,
                url: material.url,
                listName: listName
            )
            return Toast(
                kind: .success,
                title: "Reminder added",
                detail: due.map { "\(list) · \(Self.dueFormatter.string(from: $0))" } ?? list,
                action: .openApp(URL(string: "x-apple-reminderkit://")!)
            )
        }
    }

    func sendToCalendar(start: Date, durationMinutes: Int, calendarName: String? = nil) async {
        await perform {
            let material = await self.materialToFile()
            guard !material.body.isEmpty else { throw AppleAppsError.emptyContent }

            let calendar = try await EventKitBridge.shared.createEvent(
                title: Self.shortTitle(from: material.title, fallbackBody: material.body),
                notes: material.body,
                start: start,
                end: start.addingTimeInterval(TimeInterval(durationMinutes * 60)),
                url: material.url,
                calendarName: calendarName
            )
            return Toast(
                kind: .success,
                title: "Event created",
                detail: "\(calendar) · \(Self.dueFormatter.string(from: start))",
                action: .openApp(URL(string: "ical://")!)
            )
        }
    }

    // MARK: - Handing off to other agents

    /// Extracts the answer into a handoff file (see `HandoffService`): its JSON block, or in
    /// `.smart` mode the answer text when there isn't one.
    func exportHandoff(contract: String?, copyToClipboard: Bool, mode: HandoffService.Mode = .smart) async {
        await perform {
            let saved = try await HandoffService.export(contract: contract, copyToClipboard: copyToClipboard, mode: mode)
            return Self.handoffToast(saved, copied: copyToClipboard)
        }
    }

    /// The main handoff: write a brief with the context and TerrierGPT's answer, put it on the
    /// clipboard, and open the chosen assistant with it.
    func handOff(to target: AITarget, task: String, contexts: [CapturedContext]) async {
        AITarget.last = target
        await perform {
            let prepared = try await HandoffService.prepareBrief(task: task, contexts: contexts)
            ClipboardPrompt.write(prepared.brief)
            let prefilled = target.open(with: prepared.brief)
            return Toast(
                kind: .success,
                title: "Opening \(target.name)",
                detail: prefilled
                    ? "The handoff is filled in and on your clipboard."
                    : "Handoff copied. Paste it with ⌘V.",
                action: .reveal(prepared.briefURL)
            )
        }
    }

    // MARK: - Asked from outside

    /// `terriergpt://ask` — another app (CTS Recipes, a Shortcut) wants a prompt in the chat:
    /// switch instance if asked, put the prompt (plus any captures) on the clipboard, show the
    /// panel, and focus the composer. Pasting stays with the person, as everywhere else.
    func ask(prompt: String, instance: String?) {
        let auth = AuthManager.shared
        if instance == "nonprod", auth.instance != .nonprod { auth.setInstance(.nonprod) }
        if instance == "production", auth.instance != .production { auth.setInstance(.production) }
        // compose() trims the instruction, which would eat a template's trailing "- " — only
        // go through it when there are captures to append.
        let text = enabledContexts.isEmpty ? prompt : PromptComposer.compose(instruction: prompt, contexts: contexts)
        ClipboardPrompt.write(text)
        MenuBarPanel.show()
        webModel?.focusContent()
        show(Toast(kind: .success, title: "Prompt ready — paste with ⌘V", detail: instance == "nonprod" ? "Switched to the Test instance." : nil))
    }

    /// `terriergpt://handoff?text=1` — the answer as plain text, no JSON needed.
    func exportAnswerText() async {
        await perform {
            let saved = try await HandoffService.exportText()
            return Self.handoffToast(saved, copied: false)
        }
    }

    private static func handoffToast(_ saved: HandoffStore.Saved, copied: Bool) -> Toast {
        let name = saved.url.lastPathComponent
        let verb = copied ? "saved and copied" : "saved"
        if saved.isTextFallback {
            return Toast(
                kind: .info,
                title: "Handoff \(verb) — answer text",
                detail: "No JSON block in the answer. ⋯ ▸ Automation ▸ Copy standing instruction makes TerrierGPT add one every time.",
                action: .reveal(saved.url)
            )
        }
        switch saved.validation.status {
        case .valid, .unchecked:
            return Toast(
                kind: saved.validation.status == .valid ? .success : .info,
                title: "Handoff \(verb)",
                detail: saved.validation.status == .valid ? name : "\(name) · not checked against a schema",
                action: .reveal(saved.url)
            )
        case .invalid:
            return Toast(
                kind: .failure,
                title: "Handoff saved, but it doesn't match the contract",
                detail: saved.validation.issues.prefix(2).joined(separator: " "),
                action: .reveal(saved.url)
            )
        }
    }

    /// Puts the standing instruction on the clipboard, for an agent's Instructions.
    func copyStandingInstruction() {
        ClipboardPrompt.write(BuiltInContracts.standingInstruction)
        show(Toast(
            kind: .success,
            title: "Standing instruction copied",
            detail: "Paste it into your TerrierGPT agent's Instructions (Agent Builder)"
        ))
    }

    /// Saves the answer (its JSON block, else its text) and drops it into the shared inbox, where
    /// the CTS Recipes recipe that claims its contract picks it up.
    func sendHandoffToInbox() async {
        await perform {
            let saved = try await HandoffService.export(contract: nil, copyToClipboard: false)
            let dropped = try Inbox.drop(saved.url, from: "terriergpt", hops: 0)
            // CTS Recipes watches the inbox; the link wakes it if it isn't running.
            let recipes = CTSRecipesApp.isInstalled
            if recipes, let url = URL(string: "ctsrecipes://inbox") { CTSRecipesApp.open(url) }
            return Toast(
                kind: recipes ? .success : .info,
                title: "Sent to CTS Recipes",
                detail: recipes ? dropped.lastPathComponent : "Saved to the inbox. Install CTS Recipes to have a recipe pick it up.",
                action: .reveal(dropped)
            )
        }
    }

    /// Puts the "end your answer with a JSON block" instruction on the clipboard.
    func copyHandoffRequest(contract: String) {
        ClipboardPrompt.write(HandoffPrompt.request(for: contract))
        show(Toast(kind: .success, title: "JSON request copied", detail: "Paste it at the end of your prompt (\(contract))"))
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        let token = UUID()
        toastToken = token
        withAnimation(TG.Motion.drift) { self.toast = toast }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.kind == .failure ? 7 : 4))
            guard let self, self.toastToken == token else { return }
            withAnimation(TG.Motion.drift) { self.toast = nil }
        }
    }

    func dismissToast() {
        toastToken = UUID()
        withAnimation(TG.Motion.drift) { toast = nil }
    }

    func run(_ action: Toast.Action) {
        switch action {
        case .none:
            break
        case .openAutomationSettings:
            AutomationPermission.openAutomationSettings()
        case .openPrivacyPane(let anchor):
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openApp(let url):
            NSWorkspace.shared.open(url)
        }
        dismissToast()
    }

    // MARK: - Plumbing

    /// Runs an async job, turning any thrown error into a toast the user can act on.
    private func perform(_ job: @escaping () async throws -> Toast) async {
        isWorking = true
        defer { isWorking = false }
        do {
            show(try await job())
        } catch {
            show(Self.toast(for: error))
            log.error("Capture action failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func toast(for error: Error) -> Toast {
        let detail = (error as? LocalizedError)?.recoverySuggestion
        let title = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        var action = Toast.Action.none
        if let automation = error as? AutomationError, automation.isPermissionProblem {
            action = .openAutomationSettings
        } else if let apps = error as? AppleAppsError {
            switch apps {
            case .accessDenied(let app) where app == "Reminders":
                action = .openPrivacyPane("Privacy_Reminders")
            case .accessDenied(let app) where app == "Calendar":
                action = .openPrivacyPane("Privacy_Calendars")
            default:
                break
            }
        }
        return Toast(kind: .failure, title: title, detail: detail, action: action)
    }

    // MARK: - Formatting

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// Reminders and Calendar want a one-line title, not a page of text.
    private static func shortTitle(from title: String, fallbackBody: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty
            ? (fallbackBody.split(separator: "\n").first.map(String.init) ?? "TerrierGPT")
            : trimmed
        return candidate.count > 120 ? String(candidate.prefix(120)) + "…" : candidate
    }

    /// Notes takes HTML. Paragraph-per-line keeps line breaks that a single `<p>` would eat.
    private static func notesHTML(body: String, url: URL?, stamp: String) -> String {
        var html = "<p><i>Captured from TerrierGPT — \(stamp.htmlEscaped)</i></p>\n"
        if let url {
            html += "<p><a href=\"\(url.absoluteString.htmlEscaped)\">\(url.absoluteString.htmlEscaped)</a></p>\n"
        }
        html += body
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? "<br>" : "<p>\($0.htmlEscaped)</p>" }
            .joined(separator: "\n")
        return html
    }
}
