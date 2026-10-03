import Foundation
import AppKit
import OSLog

/// The one entry point every handoff trigger goes through — the dock button, the App Intent
/// (Shortcuts, `shortcuts run`, JXA), and the `terriergpt://` URL (AppleScript, `open`,
/// Raycast). Same extraction, same file, same errors, whichever one the user settles on.
@MainActor
enum HandoffService {

    private static let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "handoff")

    /// How strict an export is about finding JSON.
    enum Mode {
        /// The newest block that names a contract; if there's none, the answer text wrapped
        /// as `terriergpt-answer`. What the Handoff button does, and the default everywhere a
        /// contract isn't required.
        case smart
        /// JSON or nothing. Bare JSON blocks count; text never does.
        case jsonOnly
    }

    /// Reads the TerrierGPT page, extracts the payload, and writes the handoff file.
    ///
    /// - Parameters:
    ///   - contract: Only accept a payload with this `contract`. In `.smart` mode, asking for
    ///     `terriergpt-answer` still falls back to text, because that contract is the fallback.
    ///   - copyToClipboard: Also put the envelope JSON on the clipboard, for pasting by hand.
    static func export(contract: String?, copyToClipboard: Bool, mode: Mode = .smart) async throws -> HandoffStore.Saved {
        let contract = contract?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let webModel = CaptureCoordinator.shared.webModel,
              let sources = await webModel.handoffSources() else {
            throw HandoffError.noPage
        }
        let canFallBack = mode == .smart && (contract == nil || contract == BuiltInContracts.answer)

        let saved: HandoffStore.Saved
        if let match = HandoffExtractor.extract(from: sources, contract: contract, untypedBlocks: !canFallBack) {
            // The prose goes along with the block, unless the block *was* the selection.
            let prose = match.origin == .selection ? nil : sources.lastMessageProse?.nilIfEmpty
            saved = try HandoffStore.save(
                match,
                requestedContract: contract,
                text: prose,
                pageURL: webModel.currentURL(),
                pageTitle: webModel.pageTitle
            )
            log.info("Handoff \(saved.url.lastPathComponent, privacy: .public) from \(match.origin.rawValue, privacy: .public), \(saved.validation.status.rawValue, privacy: .public)")
        } else if canFallBack {
            saved = try saveAnswerText(from: sources, webModel: webModel)
        } else {
            throw HandoffError.nothingFound(contract: contract, hadSelection: !sources.selection.isEmpty)
        }

        if copyToClipboard { ClipboardPrompt.write(saved.json) }
        return saved
    }

    /// Saves the answer as text, for answers with no JSON block: the selection if there is
    /// one, else the newest assistant message, else the page text.
    static func exportText() async throws -> HandoffStore.Saved {
        guard let webModel = CaptureCoordinator.shared.webModel,
              let sources = await webModel.handoffSources() else {
            throw HandoffError.noPage
        }
        return try saveAnswerText(from: sources, webModel: webModel)
    }

    /// A brief ready to paste into an assistant, plus the files it was saved as.
    struct Prepared {
        let brief: String
        let briefURL: URL
        let saved: HandoffStore.Saved
    }

    /// Reads the page once and writes both forms of the handoff: the JSON envelope (for
    /// recipes, the inbox, and `latest.json`) and the Markdown brief (for a person-facing
    /// assistant, saved as `latest.md`).
    static func prepareBrief(task: String, contexts: [CapturedContext]) async throws -> Prepared {
        guard let webModel = CaptureCoordinator.shared.webModel,
              let sources = await webModel.handoffSources() else {
            throw HandoffError.noPage
        }

        let match = HandoffExtractor.extract(from: sources, contract: nil, untypedBlocks: false)
        let saved: HandoffStore.Saved
        if let match {
            let prose = match.origin == .selection ? nil : sources.lastMessageProse?.nilIfEmpty
            saved = try HandoffStore.save(match, requestedContract: nil, text: prose, pageURL: webModel.currentURL(), pageTitle: webModel.pageTitle)
        } else {
            saved = try saveAnswerText(from: sources, webModel: webModel)
        }

        let selection = sources.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = [selection, sources.lastMessageProse, sources.lastMessage, String(sources.text.suffix(20_000))]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let answer else { throw HandoffError.emptyPage }

        // A selected block is already the answer; repeating it as "structured data" is noise.
        let structured = match.flatMap { match -> (String?, String)? in
            guard match.origin != .selection, let json = try? HandoffStore.encode(match.payload) else { return nil }
            return (match.contract, json)
        }

        let brief = HandoffBrief(
            task: task,
            question: sources.lastUserMessage,
            contexts: contexts,
            answer: answer,
            structured: structured.map { (contract: $0.0, json: $0.1) },
            conversationTitle: webModel.pageTitle,
            conversationURL: webModel.currentURL()
        ).markdown

        let briefURL = saved.url.deletingPathExtension().appendingPathExtension("md")
        try Data(brief.utf8).write(to: briefURL, options: .atomic)
        try Data(brief.utf8).write(to: HandoffStore.directory.appendingPathComponent("latest.md"), options: .atomic)
        log.info("Handoff brief \(briefURL.lastPathComponent, privacy: .public), \(brief.count) chars")
        return Prepared(brief: brief, briefURL: briefURL, saved: saved)
    }

    private static func saveAnswerText(from sources: HandoffSources, webModel: WebViewModel) throws -> HandoffStore.Saved {
        let selection = sources.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [(String?, HandoffExtractor.Origin)] = [
            (selection, .selection),
            (sources.lastMessage, .lastMessage),
            // The whole conversation is a poor stand-in for one answer; cap it.
            (String(sources.text.suffix(20_000)), .pageText),
        ]
        guard let (text, origin) = candidates.first(where: { ($0.0 ?? "").isEmpty == false }),
              let text else {
            throw HandoffError.emptyPage
        }
        let saved = try HandoffStore.saveAnswerText(
            text,
            origin: origin.rawValue,
            pageURL: webModel.currentURL(),
            pageTitle: webModel.pageTitle
        )
        log.info("Handoff \(saved.url.lastPathComponent, privacy: .public): answer text from \(origin.rawValue, privacy: .public)")
        return saved
    }

    /// Handles `terriergpt://handoff?contract=kb-gap-verdict&copy=1`.
    ///
    /// The URL route can't return a value, so the result goes where every trigger's does —
    /// `latest.json` — and the panel toast says what happened. A caller that needs the output
    /// reads the file.
    ///
    /// Also `terriergpt://run?recipe=kb-desk-handoff[&input=/path/to/handoff.json]`, which
    /// always asks before running (see `ChainRunner.confirmLink`).
    static func handle(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.scheme?.lowercased() == "terriergpt" else { return }

        // From the launchd agent (or anything else): look at the inbox now. Only files
        // already there, only recipes that opted in — nothing for a link to choose.
        if url.host?.lowercased() == "inbox" {
            InboxWatcher.shared.scan()
            return
        }

        if url.host?.lowercased() == "run" {
            let name = query.first { $0.name == "recipe" }?.value ?? ""
            guard let recipe = RecipeStore.recipe(named: name) else {
                CaptureCoordinator.shared.show(Toast(
                    kind: .failure,
                    title: ChainError.unknownRecipe(name).errorDescription ?? "Unknown recipe",
                    detail: ChainError.unknownRecipe(name).recoverySuggestion
                ))
                return
            }
            let input = query.first { $0.name == "input" }?.value
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                .map(ChainRunner.InputOverride.file)
            ChainRunner.shared.start(recipe, input: input, origin: .url)
            return
        }

        guard url.host?.lowercased() == "handoff" else {
            CaptureCoordinator.shared.show(Toast(kind: .failure, title: "Unknown link", detail: url.absoluteString))
            return
        }
        let contract = query.first { $0.name == "contract" }?.value
        let flag = { (name: String) in
            query.first { $0.name == name }?.value.map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
        }

        Task {
            await CaptureCoordinator.shared.exportHandoff(
                contract: contract,
                copyToClipboard: flag("copy"),
                mode: flag("strict") ? .jsonOnly : .smart
            )
        }
    }
}

enum HandoffError: LocalizedError {
    case noPage
    case emptyPage
    case nothingFound(contract: String?, hadSelection: Bool)

    var errorDescription: String? {
        switch self {
        case .noPage:
            return "TerrierGPT isn't open"
        case .emptyPage:
            return "The TerrierGPT page has no text yet"
        case .nothingFound(let contract, let hadSelection):
            if hadSelection { return "The selection isn't \(contract.map { "a \($0) " } ?? "")JSON" }
            return contract.map { "No \($0) block on the page" } ?? "No JSON block on the page"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noPage, .emptyPage:
            return "Open the panel on the conversation you want to hand off."
        case .nothingFound(_, true):
            return "Select just the JSON block, or clear the selection to search the page."
        case .nothingFound(let contract, false):
            return "Ask TerrierGPT to end its answer with a ```json block"
                + (contract.map { " for \($0) — ⋯ ▸ Automation ▸ Copy JSON request puts the instruction on the clipboard." } ?? ".")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
