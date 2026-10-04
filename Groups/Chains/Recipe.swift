import Foundation

/// A chain of agent steps, defined as data so a new flow is a JSON file, not a rebuild.
///
///     ~/Library/Application Support/TerrierGPTMenu/recipes/kb-desk-handoff.json
///
/// Each step's output envelope is the next step's input. The first step's input comes from
/// `input`: the TerrierGPT page (a contract block, or plain text), the latest handoff file, or
/// whatever a Shortcut passed in.
nonisolated struct Recipe: Codable, Identifiable, Hashable {

    var id: String { name }

    /// File name without `.json`; how triggers refer to the recipe. Not read from the file,
    /// so renaming the file is all it takes to rename the recipe.
    var name: String = ""
    var title: String?
    var description: String?
    var input: Input?
    /// Empty for a recipe that is only a guided TerrierGPT prompt or a handoff.
    var steps: [Step] = []
    /// Opt-in: a file dropped into the inbox may start this recipe without anyone clicking.
    /// Off unless the recipe says so, because an unattended run is a different thing to
    /// consent to than a run you started.
    var inbox: Bool?
    /// Drop the final envelope into the inbox, so another inbox recipe can pick it up —
    /// chains of chains. Bounded by `Inbox.maxHops`.
    var outputToInbox: Bool?

    // MARK: Catalog

    /// Shelf in the Recipes gallery: Daily, Weekly, Tickets, Knowledge, Career, Hosts, Answer.
    var category: String?
    /// SF Symbol for the card.
    var icon: String?
    /// The working-group skills this recipe strings together, in order. Shown as the chain on
    /// the card; the steps are how it runs, this is what it *is*.
    var skills: [String]?
    /// Where the work is best done, and with which model. See `Advice`.
    var advice: Advice?
    /// The TerrierGPT phase: a prompt to paste into the chat before (or instead of) the
    /// steps. Also the task given to an assistant on handoff.
    var prompt: String?
    /// `nonprod` when the prompt needs the Test instance (KB Desk, Ticket Search Desk).
    var instance: String?
    /// A suggested time. Nothing runs until the user switches it on in the gallery.
    var schedule: Schedule?
    /// An existing Shortcut that starts the same job, by name.
    var shortcut: String?
    /// The human gate: what the recipe will never do on its own ("Send", "Submit", "Publish").
    var stopsBefore: String?

    private enum CodingKeys: String, CodingKey {
        case title, description, input, steps, inbox, outputToInbox
        case category, icon, skills, advice, prompt, instance, schedule, shortcut, stopsBefore
    }

    var displayTitle: String { title ?? name }

    /// Has steps the app can run itself.
    var isRunnable: Bool { !steps.isEmpty }

    nonisolated struct Advice: Codable, Hashable {
        enum Place: String, Codable, Hashable {
            /// Stay in the TerrierGPT chat.
            case terriergpt
            case claude, grok, gemini
            /// M365 Copilot: the surface that sees mail, calendar, and Teams.
            case copilot
            /// Scripts on this Mac (Mail.app, local engines), started by the app.
            case mac
        }
        var place: Place
        /// The TerrierGPT agent or skill to pick, e.g. "KB Desk".
        var agent: String?
        var model: String?
        /// low / medium / high.
        var effort: String?
        /// One or two sentences: why here and not elsewhere.
        var why: String?
        /// Where to take the result next, if anywhere.
        var then: Place?
    }

    nonisolated struct Schedule: Codable, Hashable {
        /// ISO weekdays, Monday = 1 … Sunday = 7. Empty or missing means every day.
        var weekdays: [Int]?
        /// 24-hour "HH:mm".
        var time: String

        var hour: Int { Int(time.split(separator: ":").first ?? "") ?? 9 }
        var minute: Int { Int(time.split(separator: ":").dropFirst().first ?? "") ?? 0 }

        var label: String {
            let days = (weekdays ?? []).sorted()
            let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let dayText: String
            switch days {
            case [], [1, 2, 3, 4, 5, 6, 7]: dayText = "Daily"
            case [1, 2, 3, 4, 5]: dayText = "Weekdays"
            default: dayText = days.compactMap { names.indices.contains($0) ? names[$0] : nil }.joined(separator: ", ")
            }
            return "\(dayText) \(time)"
        }
    }

    nonisolated struct Input: Codable, Hashable {
        enum Source: String, Codable, Hashable {
            /// A JSON block from the TerrierGPT page, as in a phase 1 handoff.
            case page
            /// The selection, else the page text, as plain text. For answers with no JSON.
            case pageText = "page-text"
            /// `handoffs/latest.json`, whoever wrote it.
            case latest
            /// No input; the first step's prompt is the whole job.
            case none
        }
        var from: Source?
        /// With `from: page`, only accept this contract.
        var contract: String?
    }

    nonisolated struct Step: Codable, Hashable {
        enum Agent: String, Codable, Hashable {
            case claude, grok
            /// Any executable, with the input on stdin. For the working group's scripts.
            case command
        }

        var id: String
        var agent: Agent
        /// For `claude` / `grok`. Supports `{{input_path}}`, `{{run_dir}}`, `{{recipe}}`.
        var prompt: String?
        /// For `command`: argv. Same placeholders; a leading `~` is expanded.
        var command: [String]?
        var model: String?
        /// Working directory. For Claude and Grok this decides which project skills load.
        var cwd: String?
        /// A contract name (schema from the contracts folder) or a path to a `.json` schema.
        /// Passed to the agent as `--json-schema` and checked on the way out.
        var outputSchema: String?
        /// Tools the agent may use without asking, e.g. `["Read", "Grep", "Bash(python3:*)"]`.
        /// Headless runs can't ask, so anything not listed is denied — and reported.
        var allow: [String]?
        /// `default`, `acceptEdits`, `plan`, `dontAsk`. Permission bypass modes are refused.
        var permissionMode: String?
        var maxTurns: Int?
        /// Seconds. Default 600.
        var timeout: Double?
        /// When set, the run pauses and shows this message before the step, with Run / Stop.
        var confirm: String?

        var label: String {
            switch agent {
            case .claude: return "Claude"
            case .grok: return "Grok"
            case .command: return (command?.first).map { ($0 as NSString).lastPathComponent } ?? "Command"
            }
        }
    }

    /// The synthesized decoder ignores the `= []` default and requires `steps`, which would
    /// reject every guided-prompt recipe. Decode it as optional instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        input = try container.decodeIfPresent(Input.self, forKey: .input)
        steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
        inbox = try container.decodeIfPresent(Bool.self, forKey: .inbox)
        outputToInbox = try container.decodeIfPresent(Bool.self, forKey: .outputToInbox)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        skills = try container.decodeIfPresent([String].self, forKey: .skills)
        advice = try container.decodeIfPresent(Advice.self, forKey: .advice)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        instance = try container.decodeIfPresent(String.self, forKey: .instance)
        schedule = try container.decodeIfPresent(Schedule.self, forKey: .schedule)
        shortcut = try container.decodeIfPresent(String.self, forKey: .shortcut)
        stopsBefore = try container.decodeIfPresent(String.self, forKey: .stopsBefore)
    }

    /// An unattended run can't answer a `confirm` dialog — it would sit modal until someone
    /// came back — so only recipes without one can be scheduled.
    var isSchedulable: Bool { isRunnable && schedule != nil && !steps.contains { $0.confirm != nil } }

    /// Problems that would make the recipe fail before it did anything useful.
    var problems: [String] {
        var issues: [String] = []
        if steps.isEmpty && (prompt ?? "").isEmpty { issues.append("No steps and no prompt.") }
        for step in steps {
            switch step.agent {
            case .claude, .grok:
                if (step.prompt ?? "").isEmpty { issues.append("Step \(step.id): no prompt.") }
            case .command:
                if (step.command ?? []).isEmpty { issues.append("Step \(step.id): no command.") }
            }
            if let mode = step.permissionMode, RecipeStore.refusedPermissionModes.contains(mode) {
                issues.append("Step \(step.id): permission mode \"\(mode)\" is not allowed.")
            }
        }
        if Set(steps.map(\.id)).count != steps.count { issues.append("Step ids must be unique.") }
        return issues
    }
}

/// Loads recipes from disk and seeds the examples on first run.
nonisolated enum RecipeStore {

    /// Modes that would let a headless agent act without anyone approving it. A recipe is
    /// started by a click or a link; that is not consent to send mail or publish a KB.
    static let refusedPermissionModes: Set<String> = ["bypassPermissions"]

    static var directory: URL {
        HandoffStore.directory.deletingLastPathComponent()
            .appendingPathComponent("recipes", isDirectory: true)
    }

    struct Loaded {
        var recipes: [Recipe]
        /// File name → why it didn't load, so a typo shows up instead of a missing menu item.
        var errors: [String: String]
    }

    static func load() -> Loaded {
        seedIfNeeded()
        var loaded = Loaded(recipes: [], errors: [:])
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            do {
                var recipe = try decoder.decode(Recipe.self, from: Data(contentsOf: url))
                recipe.name = url.deletingPathExtension().lastPathComponent
                if let problem = recipe.problems.first {
                    loaded.errors[url.lastPathComponent] = problem
                } else {
                    loaded.recipes.append(recipe)
                }
            } catch {
                loaded.errors[url.lastPathComponent] = describe(error)
            }
        }
        loaded.recipes.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        return loaded
    }

    static func recipe(named name: String) -> Recipe? {
        load().recipes.first { $0.name == name }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "Missing \"\(key.stringValue)\"."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "Wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))."
        case DecodingError.dataCorrupted(let context): return context.debugDescription
        default: return error.localizedDescription
        }
    }

    // MARK: - Examples

    /// Writes example recipes the user hasn't been offered yet.
    ///
    /// Each example has the version it shipped in. A fresh install gets all of them; an
    /// existing folder gets only the ones newer than the last seeding, and only where no file
    /// of that name exists. An example the user deleted therefore stays deleted, and nothing
    /// they edited is overwritten.
    private static func seedIfNeeded() {
        let manager = FileManager.default
        let key = "SeededRecipeExamplesVersion"
        let folderExisted = manager.fileExists(atPath: directory.path)
        // Folders created before versioning existed got the version 1 examples.
        let seeded = UserDefaults.standard.object(forKey: key) as? Int ?? (folderExisted ? 1 : 0)
        let examples = examples + RecipeCatalog.examples
        let current = examples.map(\.since).max() ?? 0
        guard seeded < current else { return }

        try? manager.createDirectory(
            at: directory.appendingPathComponent("schemas", isDirectory: true),
            withIntermediateDirectories: true
        )
        for example in examples where example.since > seeded {
            let url = directory.appendingPathComponent("\(example.name).json")
            if manager.fileExists(atPath: url.path) {
                let onDisk = try? String(contentsOf: url, encoding: .utf8)
                guard let replaces = example.replaces, onDisk == replaces else { continue }
            }
            try? Data(example.json.utf8).write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(current, forKey: key)
    }

    struct Example {
        let name: String
        let since: Int
        /// An earlier shipped version of this file. When the file on disk still matches it
        /// exactly, the user never edited it, so it's safe to upgrade.
        var replaces: String? = nil
        let json: String
    }

    /// The shipped text of an early example, so the catalog can upgrade it only while it's untouched.
    static let legacyKBDesk = """
        {
          "title": "KB desk → draft-kb → Grok review",
          "description": "TerrierGPT kb-gap-verdict → Claude runs the kb-desk-handoff chain → Grok reviews the drafts. Drafts only; nothing is published.",
          "input": { "from": "page", "contract": "kb-gap-verdict" },
          "steps": [
            {
              "id": "draft",
              "agent": "claude",
              "cwd": "~/Documents/GitHub/cts-ai-working-group",
              "prompt": "/cts-orchestrate kb-desk-handoff\\n\\nThe kb-gap-verdict handoff envelope is on stdin (also saved at {{input_path}}). Search KB Draft/ first, then draft-kb only for Gap rows. Return the drafts. Do not publish anything.",
              "allow": ["Read", "Grep", "Glob", "Skill"],
              "timeout": 900
            },
            {
              "id": "review",
              "agent": "grok",
              "confirm": "Send Claude's drafts to Grok for a second-opinion review?",
              "prompt": "You are reviewing BU IT knowledge-base drafts produced by another agent. Check accuracy, missing steps, and tone for end users. Reply with a short list of concrete fixes per draft."
            }
          ]
        }
        """

    /// The shipped text of an early example, so the catalog can upgrade it only while it's untouched.
    static let legacyTicketSearch = """
        {
          "title": "Ticket Search Desk → HTML report",
          "description": "TerrierGPT ticket-search-report → fill servicenow-search-report HTML in Downloads. Read-only; nothing is written to ServiceNow.",
          "input": { "from": "page", "contract": "ticket-search-report" },
          "steps": [
            {
              "id": "fill-html",
              "agent": "command",
              "command": [
                "/usr/bin/python3",
                "~/Documents/GitHub/cts-ai-working-group/docs/orchestration/examples/handoff-ticket-search.py",
                "--file",
                "{{input_path}}"
              ],
              "timeout": 120
            }
          ]
        }
        """

    private static let examples: [Example] = [
        Example(name: "answer-to-claude", since: 2, json: """
        {
          "title": "Answer → Claude next step",
          "description": "Any TerrierGPT answer — its terriergpt-answer block, or its text when there's none — goes to Claude, which drafts the next step. Drafts only.",
          "input": { "from": "page", "contract": "terriergpt-answer" },
          "steps": [
            {
              "id": "next",
              "agent": "claude",
              "prompt": "The handoff envelope on stdin is a TerrierGPT answer: structure in payload (summary, action_items, entities, suggested_next), the prose in text. If payload.suggested_next is set, do that. Otherwise draft the single most useful next step — a reply, a ticket work note, a KB outline, or a checklist — and say which you chose. Drafts only: do not send, publish, or submit anything.",
              "allow": ["Read", "Grep", "Glob"]
            }
          ]
        }
        """),

        Example(name: "kb-desk-handoff", since: 1, json: legacyKBDesk),
        Example(name: "ticket-search-html", since: 2, json: legacyTicketSearch),
        Example(name: "summarize-to-grok", since: 1, json: """
        {
          "title": "Answer → Grok summary",
          "description": "The selected answer (or the page text) as plain text → Grok summarises it in Spanish.",
          "input": { "from": "page-text" },
          "steps": [
            {
              "id": "summary",
              "agent": "grok",
              "prompt": "Resume en español, en 5 viñetas, el texto de la respuesta de TerrierGPT que sigue. Termina con una línea de próximos pasos."
            }
          ]
        }
        """),
        Example(name: "claude-then-grok", since: 1, json: """
        {
          "title": "Claude analysis → Grok second opinion",
          "description": "Newest JSON block → Claude analyses it (structured) → Grok challenges the analysis.",
          "input": { "from": "page" },
          "steps": [
            {
              "id": "analyse",
              "agent": "claude",
              "prompt": "Analyse the handoff on stdin. Say what it contains, what is missing, and the next concrete step.",
              "output_schema": "~/Library/Application Support/TerrierGPTMenu/recipes/schemas/analysis.schema.json"
            },
            {
              "id": "challenge",
              "agent": "grok",
              "prompt": "Another agent produced this analysis. Find what it got wrong or missed, and say what you would do differently."
            }
          ]
        }
        """),
        Example(name: "schemas/analysis.schema", since: 1, json: """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["summary", "gaps", "next_step"],
          "properties": {
            "summary": { "type": "string" },
            "gaps": { "type": "array", "items": { "type": "string" } },
            "next_step": { "type": "string" }
          }
        }
        """),
    ]
}
