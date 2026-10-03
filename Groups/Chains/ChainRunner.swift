import Foundation
import AppKit
import Combine
import OSLog

/// Runs a recipe: gets its input, then each step in turn, each step's output envelope
/// becoming the next step's input.
///
/// Every run gets its own folder, so a chain that went wrong can be read back step by step:
///
///     ~/Library/Application Support/TerrierGPTMenu/runs/2026-09-29T10-12-00Z-kb-desk-handoff/
///         00-input.json
///         01-draft.json            ← envelope handed to step 2
///         01-draft.stdout.json     ← the CLI's raw report
///         01-draft.stderr.log
///         02-review.prompt.md      ← Grok only: the prompt file, input included
///         …
///         run.json                 ← status, timings, cost per step
///     runs/latest.json             ← final output of the most recent successful run
///
/// One run at a time. Two chains driving the same CLIs at once is a way to get two half-
/// finished results, not two finished ones.
@MainActor
final class ChainRunner: ObservableObject {

    static let shared = ChainRunner()

    // MARK: - State

    nonisolated enum StepStatus: Equatable {
        case pending
        case awaitingConfirmation
        case running(since: Date)
        case done(seconds: TimeInterval, costUSD: Double?)
        case failed(String)
        case skipped
    }

    nonisolated enum RunStatus: Equatable {
        case preparing
        case running
        case succeeded
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .preparing, .running: return false
            case .succeeded, .failed, .cancelled: return true
            }
        }
    }

    nonisolated struct Run: Identifiable {
        let id: String
        let recipe: Recipe
        let directory: URL
        let startedAt: Date
        let origin: Origin
        var status: RunStatus = .preparing
        var steps: [StepStatus]
        /// The envelope handed out at the end (or the last one written, on failure).
        var outputURL: URL?
        var outputText: String?
        var outputPayloadJSON: String?
        /// Non-fatal things worth surfacing, e.g. tools an agent was refused.
        var notes: [String] = []
        /// How many chains fed into this one through the inbox (see `Inbox.maxHops`).
        var inputHops = 0

        var totalCost: Double {
            steps.reduce(0) { total, step in
                if case .done(_, let cost?) = step { return total + cost }
                return total
            }
        }
    }

    /// Where the run was started from. A link is the only trigger that asks first: anything
    /// on a web page can open a `terriergpt://` URL. The inbox doesn't ask, because a file only
    /// gets there if something on this Mac put it there, and only recipes that opted in run.
    nonisolated enum Origin: String { case panel, intent, url, inbox, history }

    /// What a Shortcut hands in, overriding the recipe's own `input`.
    nonisolated enum InputOverride {
        case text(String)
        case file(URL)
    }

    @Published private(set) var current: Run?

    var isRunning: Bool { current.map { !$0.status.isFinished } ?? false }

    private var task: Task<Run?, Never>?
    private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "chain")

    private init() {}

    nonisolated static var runsDirectory: URL {
        HandoffStore.directory.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
    }

    nonisolated static var latestOutputURL: URL { runsDirectory.appendingPathComponent("latest.json") }

    // MARK: - Starting and stopping

    /// Starts `recipe` and waits for it to finish. Returns `nil` if it never started (a run
    /// was already going, or the user declined the link prompt).
    @discardableResult
    func run(_ recipe: Recipe, input: InputOverride? = nil, origin: Origin) async -> Run? {
        guard !isRunning else {
            CaptureCoordinator.shared.show(Toast(
                kind: .info,
                title: "A chain is already running",
                detail: current.map { "\($0.recipe.displayTitle) — cancel it first" }
            ))
            return nil
        }
        if origin == .url, !confirmLink(recipe, input: input) { return nil }

        let task = Task { await self.execute(recipe, input: input, origin: origin) }
        self.task = task
        return await task.value
    }

    /// Starts `recipe` without waiting, for triggers that can't hold on for minutes.
    func start(_ recipe: Recipe, input: InputOverride? = nil, origin: Origin) {
        Task { await run(recipe, input: input, origin: origin) }
    }

    func cancel() {
        task?.cancel()
    }

    /// Clears a finished run from the panel.
    func dismiss() {
        guard let current, current.status.isFinished else { return }
        self.current = nil
    }

    // MARK: - The run

    private func execute(_ recipe: Recipe, input: InputOverride?, origin: Origin) async -> Run? {
        let now = Date()
        let id = "\(HandoffStore.fileStamp(now))-\(recipe.name)"
        let directory = Self.runsDirectory.appendingPathComponent(id, isDirectory: true)
        current = Run(id: id, recipe: recipe, directory: directory, startedAt: now, origin: origin, steps: recipe.steps.map { _ in .pending })

        var inputReady = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var inputURL = try await prepareInput(recipe, override: input, into: directory)
            inputReady = true
            let hops = Inbox.hops(in: inputURL)
            update {
                $0.status = .running
                $0.inputHops = hops
            }

            for (index, step) in recipe.steps.enumerated() {
                try Task.checkCancellation()

                if let message = step.confirm {
                    update { $0.steps[index] = .awaitingConfirmation }
                    guard confirmStep(step, message: message, index: index, of: recipe) else {
                        update { run in
                            for later in index..<run.steps.count { run.steps[later] = .skipped }
                        }
                        throw CancellationError()
                    }
                }

                let started = Date()
                update { $0.steps[index] = .running(since: started) }
                let result = try await runStep(step, index: index, recipe: recipe, input: inputURL, directory: directory)
                update { run in
                    run.steps[index] = .done(seconds: Date().timeIntervalSince(started), costUSD: result.costUSD)
                    run.outputURL = result.envelopeURL
                    run.outputText = result.text
                    run.outputPayloadJSON = result.payloadJSON
                    run.notes += result.notes
                }
                inputURL = result.envelopeURL
            }

            if let output = current?.outputURL {
                try? FileManager.default.removeItem(at: Self.latestOutputURL)
                try? FileManager.default.copyItem(at: output, to: Self.latestOutputURL)
            }
            update { $0.status = .succeeded }

            if recipe.outputToInbox == true, let output = current?.outputURL {
                do {
                    let dropped = try Inbox.drop(output, from: recipe.name, hops: (current?.inputHops ?? 0) + 1)
                    update { $0.notes.append("Result sent to the inbox as \(dropped.lastPathComponent).") }
                } catch {
                    update { $0.notes.append("Couldn't send the result to the inbox: \(error.localizedDescription)") }
                }
            }
        } catch is CancellationError {
            markUnfinished(.failed("Cancelled"), inputReady: inputReady)
            update { $0.status = .cancelled }
        } catch {
            let message = [(error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                           (error as? LocalizedError)?.recoverySuggestion]
                .compactMap { $0 }.joined(separator: " — ")
            markUnfinished(.failed(message), inputReady: inputReady)
            update { $0.status = .failed(message) }
            log.error("Chain \(recipe.name, privacy: .public) failed: \(message, privacy: .public)")
        }

        writeSummary()
        announce()
        return current
    }

    /// Input envelope for step 1, written to `00-input.json`.
    private func prepareInput(_ recipe: Recipe, override: InputOverride?, into directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("00-input.json")

        switch override {
        case .file(let file):
            try FileManager.default.copyItem(at: file, to: url)
            return url
        case .text(let text):
            try HandoffStore.write(Self.envelope(fromShortcutInput: text), to: url)
            return url
        case nil:
            break
        }

        let from = recipe.input?.from ?? .page
        switch from {
        case .page:
            let saved = try await HandoffService.export(contract: recipe.input?.contract, copyToClipboard: false)
            if saved.validation.status == .invalid {
                throw ChainError.invalidInput(saved.validation.issues)
            }
            try FileManager.default.copyItem(at: saved.url, to: url)
        case .pageText:
            let saved = try await HandoffService.exportText()
            try FileManager.default.copyItem(at: saved.url, to: url)
        case .latest:
            guard FileManager.default.fileExists(atPath: HandoffStore.latestURL.path) else { throw ChainError.noLatest }
            try FileManager.default.copyItem(at: HandoffStore.latestURL, to: url)
        case .none:
            let empty = HandoffStore.makeEnvelope(
                contract: nil,
                source: ["agent": "none"],
                validation: .init(status: .unchecked, schemaPath: nil, issues: []),
                payload: nil,
                text: nil
            )
            try HandoffStore.write(empty, to: url)
        }
        return url
    }

    private struct StepResult {
        let envelopeURL: URL
        let text: String?
        let payloadJSON: String?
        let costUSD: Double?
        let notes: [String]
    }

    private func runStep(_ step: Recipe.Step, index: Int, recipe: Recipe, input: URL, directory: URL) async throws -> StepResult {
        let prefix = String(format: "%02d-%@", index + 1, step.id)
        let file = { (suffix: String) in directory.appendingPathComponent("\(prefix).\(suffix)") }

        let invocation = try AgentAdapter.invocation(for: step, recipe: recipe, input: input, stepFile: file)
        let stdout = file("stdout.json")
        let stderr = file("stderr.log")
        let finished = try await ProcessRunner.run(invocation, stdout: stdout, stderr: stderr, timeout: step.timeout ?? 600)

        let output = AgentAdapter.parse(stdout: (try? Data(contentsOf: stdout)) ?? Data(), agent: step.agent)
        if finished.timedOut {
            throw ChainError.stepFailed(step: step.id, message: "timed out after \(Int(step.timeout ?? 600))s")
        }
        if finished.status != 0 || output.isError {
            let detail = output.errorMessage ?? Self.tail(of: stderr) ?? "exit status \(finished.status)"
            throw ChainError.stepFailed(step: step.id, message: detail)
        }
        if output.text == nil && output.payload == nil {
            throw ChainError.stepFailed(step: step.id, message: "produced no output")
        }

        var validation = ContractCheck.Result(status: .unchecked, schemaPath: nil, issues: [])
        var contract: String? = (output.payload as? [String: Any])?["contract"] as? String
        if let reference = step.outputSchema {
            let schemaURL = ContractCheck.schemaURL(forReference: reference)
            if !reference.contains("/"), !reference.hasSuffix(".json") { contract = contract ?? reference }
            validation = output.payload.map { ContractCheck.check($0, schemaAt: schemaURL) }
                ?? .init(status: .invalid, schemaPath: schemaURL.path, issues: ["No structured output."])
        }

        var source: [String: Any] = ["agent": step.agent.rawValue, "recipe": recipe.name, "step": step.id, "run": directory.lastPathComponent]
        if let session = output.sessionID { source["session_id"] = session }
        if let cost = output.costUSD { source["cost_usd"] = cost }
        if !output.permissionDenials.isEmpty { source["permission_denials"] = output.permissionDenials }

        let envelopeURL = directory.appendingPathComponent("\(prefix).json")
        let envelope = HandoffStore.makeEnvelope(
            contract: contract, source: source, validation: validation, payload: output.payload, text: output.text
        )
        try HandoffStore.write(envelope, to: envelopeURL)

        if validation.status == .invalid {
            throw ChainError.stepFailed(step: step.id, message: "output doesn't match its schema: \(validation.issues.prefix(2).joined(separator: " "))")
        }

        var notes: [String] = []
        if !output.permissionDenials.isEmpty {
            let tools = Array(Set(output.permissionDenials)).sorted().joined(separator: ", ")
            notes.append("\(step.label) (\(step.id)) was refused: \(tools). Add them to the step's \"allow\" if it needs them.")
        }
        return StepResult(
            envelopeURL: envelopeURL,
            text: output.text,
            payloadJSON: output.payload.flatMap { try? HandoffStore.encode($0) },
            costUSD: output.costUSD,
            notes: notes
        )
    }

    // MARK: - Asking the user

    /// The only gate a link gets: it names the recipe and every agent it will start.
    /// A link can also name an input file, which would be sent to the agents — so that is
    /// spelled out too.
    private func confirmLink(_ recipe: Recipe, input: InputOverride?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run \"\(recipe.displayTitle)\"?"
        var source = "Input: the recipe's own (\((recipe.input?.from ?? .page).rawValue))."
        if case .file(let url) = input { source = "Input: the file \(url.path) — its contents will be sent to the agents." }
        alert.informativeText = """
        A terriergpt:// link asked to run this chain.

        \(recipe.steps.map { "• \($0.label): \($0.id)" }.joined(separator: "\n"))

        \(source)

        Only run it if you started this yourself.
        """
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Don't Run")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmStep(_ step: Recipe.Step, message: String, index: Int, of recipe: Recipe) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        var info = "\(recipe.displayTitle) — step \(index + 1) of \(recipe.steps.count): \(step.label)"
        if let text = current?.outputText, !text.isEmpty {
            let preview = text.count > 600 ? String(text.prefix(600)) + "…" : text
            info += "\n\nWhat it will receive:\n\(preview)"
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Run \(step.label)")
        alert.addButton(withTitle: "Stop Here")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Reporting

    private func announce() {
        guard let run = current else { return }
        let coordinator = CaptureCoordinator.shared
        switch run.status {
        case .succeeded:
            coordinator.show(Toast(
                kind: run.notes.isEmpty ? .success : .info,
                title: "\(run.recipe.displayTitle) finished",
                detail: run.notes.first ?? Self.costLine(run),
                action: run.outputURL.map { .reveal($0) } ?? .none
            ))
        case .failed(let message):
            coordinator.show(Toast(
                kind: .failure,
                title: "\(run.recipe.displayTitle) failed",
                detail: message,
                action: .reveal(run.directory)
            ))
        case .cancelled:
            coordinator.show(Toast(kind: .info, title: "\(run.recipe.displayTitle) stopped"))
        case .preparing, .running:
            break
        }
    }

    private func writeSummary() {
        guard let run = current else { return }
        let steps: [[String: Any]] = zip(run.recipe.steps, run.steps).map { step, status in
            var entry: [String: Any] = ["id": step.id, "agent": step.agent.rawValue]
            switch status {
            case .pending: entry["status"] = "pending"
            case .awaitingConfirmation: entry["status"] = "awaiting-confirmation"
            case .running: entry["status"] = "running"
            case .skipped: entry["status"] = "skipped"
            case .failed(let message): entry["status"] = "failed"; entry["error"] = message
            case .done(let seconds, let cost):
                entry["status"] = "done"
                entry["seconds"] = (seconds * 10).rounded() / 10
                if let cost { entry["cost_usd"] = cost }
            }
            return entry
        }
        let status: String
        switch run.status {
        case .succeeded: status = "succeeded"
        case .failed: status = "failed"
        case .cancelled: status = "cancelled"
        case .preparing, .running: status = "running"
        }
        var summary: [String: Any] = [
            "recipe": run.recipe.name,
            "title": run.recipe.displayTitle,
            "origin": run.origin.rawValue,
            "hops": run.inputHops,
            "started_at": ISO8601DateFormatter().string(from: run.startedAt),
            "finished_at": ISO8601DateFormatter().string(from: Date()),
            "status": status,
            "steps": steps,
            "total_cost_usd": run.totalCost,
            "notes": run.notes,
        ]
        if case .failed(let message) = run.status { summary["error"] = message }
        if let output = run.outputURL { summary["output"] = output.path }
        _ = try? HandoffStore.write(summary, to: run.directory.appendingPathComponent("run.json"))
    }

    nonisolated static func costLine(_ run: Run) -> String {
        let seconds = Int(Date().timeIntervalSince(run.startedAt))
        let cost = run.totalCost > 0 ? String(format: " · $%.3f", run.totalCost) : ""
        return "\(run.recipe.steps.count) step\(run.recipe.steps.count == 1 ? "" : "s") · \(seconds)s\(cost)"
    }

    // MARK: - Helpers

    private func update(_ change: (inout Run) -> Void) {
        guard var run = current else { return }
        change(&run)
        current = run
    }

    /// Marks the step that was running (or waiting) as failed, and everything after as skipped.
    /// If the input never got made, no step ran, so all of them are skipped.
    private func markUnfinished(_ status: StepStatus, inputReady: Bool) {
        update { run in
            guard inputReady else {
                run.steps = run.steps.map { _ in .skipped }
                return
            }
            guard let index = run.steps.firstIndex(where: {
                switch $0 {
                case .running, .awaitingConfirmation: return true
                default: return false
                }
            }) ?? run.steps.firstIndex(of: .pending) else { return }
            run.steps[index] = status
            for later in run.steps.indices where later > index && run.steps[later] == .pending {
                run.steps[later] = .skipped
            }
        }
    }

    /// A Shortcut's input: an envelope as-is, other JSON as the payload, anything else as text.
    private static func envelope(fromShortcutInput text: String) -> [String: Any] {
        let parsed = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        if let object = parsed as? [String: Any], object["handoff"] != nil { return object }
        let contract = (parsed as? [String: Any])?["contract"] as? String
        return HandoffStore.makeEnvelope(
            contract: contract,
            source: ["agent": "shortcuts"],
            validation: parsed.map { ContractCheck.check($0, against: contract) }
                ?? .init(status: .unchecked, schemaPath: nil, issues: ["Plain text; no contract."]),
            payload: parsed,
            text: parsed == nil ? text : nil
        )
    }

    private static func tail(of url: URL, lines: Int = 3) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let last = text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: " ")
        return last.isEmpty ? nil : String(last.suffix(400))
    }
}

enum ChainError: LocalizedError {
    case invalidInput([String])
    case noLatest
    case stepFailed(step: String, message: String)
    case unknownRecipe(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let issues): return "TerrierGPT's JSON doesn't match the contract: \(issues.prefix(2).joined(separator: " "))"
        case .noLatest: return "There's no handoff yet"
        case .stepFailed(let step, let message): return "Step \(step) \(message)"
        case .unknownRecipe(let name): return "No recipe named \"\(name)\""
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidInput: return "Ask TerrierGPT to fix the block, or run the chain on a corrected handoff."
        case .noLatest: return "Save one with Handoff first, or change the recipe's input."
        case .stepFailed: return nil
        case .unknownRecipe: return "Recipes live in \(RecipeStore.directory.path)."
        }
    }
}
