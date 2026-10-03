import AppIntents
import AppKit
import Foundation

/// Shortcuts / Spotlight actions for TerrierGPT Menu.
///
/// App Intents rather than a classic AppleScript `.sdef`: intents are typed, show up in
/// Shortcuts and Spotlight without extra plumbing, and don't require the user to grant
/// Automation permission to script *this* app. The AppleScript in this project runs the other
/// direction — it's how we read Safari, Finder, and Notes.

// MARK: - Clipboard

struct PrepareClipboardForTerrierGPTIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Clipboard for TerrierGPT"
    static let description = IntentDescription(
        "Wraps the current clipboard text in a ready-to-paste TerrierGPT prompt."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Instruction", default: "Help me with the following content.")
    var instruction: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await MainActor.run { ClipboardPrompt.prepareFromPasteboard(instruction: instruction) }
        switch result {
        case .success(let prompt):
            return .result(value: prompt, dialog: "Prompt is on the clipboard. Paste into TerrierGPT with ⌘V.")
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Capture from other apps

struct CaptureBrowserPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Browser Page for TerrierGPT"
    static let description = IntentDescription(
        "Reads the frontmost browser tab — title, URL, and any selected text — and builds a TerrierGPT prompt from it.",
        categoryName: "Capture"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Instruction", default: "Help me with the following content.")
    var instruction: String

    @Parameter(title: "Copy prompt to clipboard", default: true)
    var copyToClipboard: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = try await BrowserBridge.captureFromFrontmost()
        let prompt = PromptComposer.compose(instruction: instruction, contexts: [context])

        if copyToClipboard {
            await MainActor.run {
                ClipboardPrompt.write(prompt)
                CaptureCoordinator.shared.add(context)
            }
        }
        return .result(value: prompt, dialog: "Captured \(context.title) from \(context.source.label).")
    }
}

struct CaptureFinderSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Finder Selection for TerrierGPT"
    static let description = IntentDescription(
        "Reads the current Finder selection — paths, plus the contents of small text files — into a TerrierGPT prompt.",
        categoryName: "Capture"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Instruction", default: "Help me with the following content.")
    var instruction: String

    @Parameter(title: "Include file contents", default: true)
    var includeContents: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let context = try await FinderBridge.captureSelection(includeFileContents: includeContents)
        let prompt = PromptComposer.compose(instruction: instruction, contexts: [context])
        await MainActor.run {
            ClipboardPrompt.write(prompt)
            CaptureCoordinator.shared.add(context)
        }
        return .result(value: prompt, dialog: "Captured \(context.title) from Finder.")
    }
}

// MARK: - Filing results

struct SaveToNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Text to TerrierGPT Notes"
    static let description = IntentDescription(
        "Files text into a note in the TerrierGPT folder in Apple Notes.",
        categoryName: "File"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Title", default: "TerrierGPT")
    var noteTitle: String

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Append to an existing note with this title", default: false)
    var append: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let html = text
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? "<br>" : "<p>\($0.htmlEscaped)</p>" }
            .joined(separator: "\n")

        if append {
            try await NotesBridge.appendToNote(title: noteTitle, html: html)
            return .result(dialog: "Appended to \"\(noteTitle)\".")
        }
        try await NotesBridge.createNote(title: noteTitle, html: html)
        return .result(dialog: "Saved \"\(noteTitle)\" to Notes.")
    }
}

struct CreateReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Reminder from TerrierGPT"
    static let description = IntentDescription(
        "Creates a reminder, optionally with a due date and a specific list.",
        categoryName: "File"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Title")
    var reminderTitle: String

    @Parameter(title: "Notes", inputOptions: String.IntentInputOptions(multiline: true))
    var notes: String?

    @Parameter(title: "Due date")
    var due: Date?

    @Parameter(title: "List")
    var listName: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let list = try await EventKitBridge.shared.createReminder(
            title: reminderTitle, notes: notes, due: due, listName: listName
        )
        return .result(dialog: "Added \"\(reminderTitle)\" to \(list).")
    }
}

struct CreateEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Calendar Event from TerrierGPT"
    static let description = IntentDescription(
        "Creates a calendar event with the given title, start time, and length.",
        categoryName: "File"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Title")
    var eventTitle: String

    @Parameter(title: "Notes", inputOptions: String.IntentInputOptions(multiline: true))
    var notes: String?

    @Parameter(title: "Starts")
    var start: Date

    @Parameter(title: "Length in minutes", default: 30)
    var minutes: Int

    @Parameter(title: "Calendar")
    var calendarName: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let calendar = try await EventKitBridge.shared.createEvent(
            title: eventTitle,
            notes: notes,
            start: start,
            end: start.addingTimeInterval(TimeInterval(max(1, minutes) * 60)),
            calendarName: calendarName
        )
        return .result(dialog: "Created \"\(eventTitle)\" in \(calendar).")
    }
}

// MARK: - Handing off to other agents

struct ExportTerrierGPTHandoffIntent: AppIntent {
    static let title: LocalizedStringResource = "Export TerrierGPT Answer as Handoff"
    static let description = IntentDescription(
        "Saves the current TerrierGPT answer as a handoff file (latest.json): its JSON block, or its text if it has none. Returns the envelope JSON, ready to pipe into Claude or Grok.",
        categoryName: "Handoff"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Contract",
        description: "Only accept a block with this contract, e.g. kb-gap-verdict. Leave empty for the newest block."
    )
    var contract: String?

    @Parameter(title: "Also copy to clipboard", default: false)
    var copyToClipboard: Bool

    @Parameter(
        title: "Use the answer text if there's no JSON block",
        description: "On: an answer without a block is saved as a terriergpt-answer with its text. Off: no block is an error.",
        default: true
    )
    var textFallback: Bool

    @Parameter(
        title: "Return",
        description: "Envelope: the full handoff with provenance and validation. Payload: just the JSON TerrierGPT produced. Path: where the file was saved."
    )
    var output: HandoffOutput?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let saved = try await HandoffService.export(
            contract: contract,
            copyToClipboard: copyToClipboard,
            mode: textFallback ? .smart : .jsonOnly
        )
        await MainActor.run {
            CaptureCoordinator.shared.show(Toast(
                kind: saved.validation.status == .invalid ? .failure : .success,
                title: "Handoff exported",
                detail: saved.url.lastPathComponent,
                action: .reveal(saved.url)
            ))
        }

        let value: String
        switch output ?? .envelope {
        case .envelope: value = saved.json
        case .payload: value = saved.payloadJSON
        case .path: value = saved.url.path
        }

        let dialog: IntentDialog = saved.validation.status == .invalid
            ? "Saved \(saved.url.lastPathComponent), but it doesn't match the contract: \(saved.validation.issues.first ?? "")"
            : "Saved \(saved.url.lastPathComponent)."
        return .result(value: value, dialog: dialog)
    }
}

enum HandoffOutput: String, AppEnum {
    case envelope, payload, path

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Handoff Output"
    static let caseDisplayRepresentations: [HandoffOutput: DisplayRepresentation] = [
        .envelope: "Envelope",
        .payload: "Payload only",
        .path: "File path",
    ]
}

struct CopyHandoffRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy TerrierGPT JSON Request"
    static let description = IntentDescription(
        "Returns (and copies) the instruction that makes TerrierGPT end its answer with a JSON block for a contract, schema included.",
        categoryName: "Handoff"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Contract", default: "kb-gap-verdict")
    var contract: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let request = HandoffPrompt.request(for: contract)
        await MainActor.run { ClipboardPrompt.write(request) }
        return .result(value: request, dialog: "JSON request for \(contract) is on the clipboard.")
    }
}

// MARK: - Chains

struct RecipeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "TerrierGPT Chain"
    static let defaultQuery = RecipeQuery()

    let id: String
    let title: String
    let steps: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(steps)")
    }

    init(_ recipe: Recipe) {
        id = recipe.name
        title = recipe.displayTitle
        steps = recipe.steps.map(\.label).joined(separator: " → ")
    }
}

/// Recipes are read from disk on every query, so a file dropped into the folder shows up in
/// the Shortcuts picker without relaunching anything.
struct RecipeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RecipeEntity] {
        RecipeStore.load().recipes.filter { identifiers.contains($0.name) }.map(RecipeEntity.init)
    }

    func suggestedEntities() async throws -> [RecipeEntity] {
        RecipeStore.load().recipes.map(RecipeEntity.init)
    }
}

enum ChainOutput: String, AppEnum {
    case text, payload, envelope, path

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chain Output"
    static let caseDisplayRepresentations: [ChainOutput: DisplayRepresentation] = [
        .text: "Text",
        .payload: "JSON payload",
        .envelope: "Envelope",
        .path: "File path",
    ]
}

struct RunTerrierGPTChainIntent: AppIntent {
    static let title: LocalizedStringResource = "Run TerrierGPT Chain"
    static let description = IntentDescription(
        "Runs a recipe: takes the TerrierGPT answer (or the input you pass), hands it to Claude, Grok, or a script step by step, and returns the last step's result.",
        categoryName: "Handoff"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Chain")
    var recipe: RecipeEntity

    @Parameter(
        title: "Input",
        description: "Optional. A handoff envelope, any JSON, or plain text — e.g. the output of a previous action. Empty uses the chain's own input (usually the TerrierGPT page).",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var input: String?

    @Parameter(title: "Return", default: .text)
    var output: ChainOutput

    @Parameter(
        title: "Wait for the result",
        description: "Off returns the run folder immediately and lets the chain finish in the background.",
        default: true
    )
    var wait: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$recipe) on \(\.$input)") {
            \.$output
            \.$wait
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let recipe = RecipeStore.recipe(named: recipe.id) else {
            throw ChainError.unknownRecipe(self.recipe.id)
        }
        let override = input.flatMap { $0.isEmpty ? nil : ChainRunner.InputOverride.text($0) }
        let runner = await MainActor.run { ChainRunner.shared }

        guard wait else {
            await runner.start(recipe, input: override, origin: .intent)
            return .result(value: ChainRunner.runsDirectory.path, dialog: "Started \(recipe.displayTitle).")
        }

        guard let run = await runner.run(recipe, input: override, origin: .intent) else {
            throw ChainIntentError.notStarted
        }
        switch run.status {
        case .succeeded:
            let value: String
            switch output {
            case .text: value = run.outputText ?? run.outputPayloadJSON ?? ""
            case .payload: value = run.outputPayloadJSON ?? ""
            case .envelope: value = run.outputURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            case .path: value = run.outputURL?.path ?? run.directory.path
            }
            return .result(value: value, dialog: "\(recipe.displayTitle) finished. \(ChainRunner.costLine(run))")
        case .failed(let message):
            throw ChainIntentError.failed(message)
        case .cancelled, .preparing, .running:
            throw ChainIntentError.cancelled
        }
    }
}

enum ChainIntentError: LocalizedError {
    case notStarted, cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notStarted: return "Another chain is already running."
        case .cancelled: return "The chain was stopped."
        case .failed(let message): return message
        }
    }
}

// MARK: - App control

struct ReloadTerrierGPTIntent: AppIntent {
    static let title: LocalizedStringResource = "Reload TerrierGPT"
    static let description = IntentDescription("Reloads the TerrierGPT page in the menu bar window.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            AuthManager.shared.requestReload()
        }
        return .result(dialog: "Reloading TerrierGPT.")
    }
}

struct SignOutTerrierGPTIntent: AppIntent {
    static let title: LocalizedStringResource = "Sign Out of TerrierGPT"
    static let description = IntentDescription(
        "Clears TerrierGPT site data (cookies) and returns to the home page."
    )
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AuthManager.shared.logout()
        return .result(dialog: "Signed out and cleared site data.")
    }
}

struct OpenTerrierGPTInBrowserIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TerrierGPT in Browser"
    static let description = IntentDescription("Opens the current TerrierGPT page in your default browser.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AuthManager.shared.openInBrowser()
        }
        return .result()
    }
}

struct ShowTerrierGPTPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Show TerrierGPT Panel"
    static let description = IntentDescription("Opens the TerrierGPT menu bar panel.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let opened = await MainActor.run { AuthManager.shared.showPanel() }
        // Report what actually happened. The previous version always claimed success, even
        // when it hadn't managed to open anything.
        return .result(dialog: opened
            ? "TerrierGPT is open."
            : "TerrierGPT is active — click the sparkles icon in the menu bar to open the panel.")
    }
}

// MARK: - Shortcuts gallery

struct TerrierGPTAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureBrowserPageIntent(),
            phrases: [
                "Capture this page for \(.applicationName)",
                "Ask \(.applicationName) about this page",
            ],
            shortTitle: "Capture Browser Page",
            systemImageName: "safari"
        )
        AppShortcut(
            intent: CaptureFinderSelectionIntent(),
            phrases: [
                "Capture Finder selection for \(.applicationName)",
                "Ask \(.applicationName) about these files",
            ],
            shortTitle: "Capture Finder Selection",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: PrepareClipboardForTerrierGPTIntent(),
            phrases: [
                "Prepare clipboard for \(.applicationName)",
                "Wrap clipboard for \(.applicationName)",
            ],
            shortTitle: "Prepare Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: ExportTerrierGPTHandoffIntent(),
            phrases: [
                "Export \(.applicationName) handoff",
                "Hand off \(.applicationName) answer",
            ],
            shortTitle: "Export Handoff",
            systemImageName: "arrow.triangle.branch"
        )
        AppShortcut(
            intent: SaveToNotesIntent(),
            phrases: [
                "Save this to \(.applicationName) notes",
            ],
            shortTitle: "Save to Notes",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: CreateReminderIntent(),
            phrases: [
                "Create a \(.applicationName) reminder",
            ],
            shortTitle: "Create Reminder",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: CreateEventIntent(),
            phrases: [
                "Create a \(.applicationName) event",
            ],
            shortTitle: "Create Event",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: ShowTerrierGPTPanelIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Open \(.applicationName) panel",
            ],
            shortTitle: "Show Panel",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: ReloadTerrierGPTIntent(),
            phrases: ["Reload \(.applicationName)"],
            shortTitle: "Reload",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OpenTerrierGPTInBrowserIntent(),
            phrases: ["Open \(.applicationName) in browser"],
            shortTitle: "Open in Browser",
            systemImageName: "safari"
        )
        // Sign Out has no gallery entry: macOS allows ten, and a spoken phrase is the wrong
        // way into something that clears site data. It's still an action in Shortcuts.
    }
}
