import Foundation
import SwiftUI

/// One piece of context the user pulled in from somewhere else on the Mac.
///
/// A capture is inert data: it carries the text that will go into the prompt plus enough
/// provenance to render an honest chip ("Safari · BU Libraries") and to build a citation
/// line when the user files it into Notes.
nonisolated struct CapturedContext: Identifiable, Equatable, Hashable {

    nonisolated enum Source: Equatable, Hashable {
        case browser(app: String)
        case finder
        case clipboard
        case answer

        var symbol: String {
            switch self {
            case .browser: return "safari"
            case .finder: return "folder"
            case .clipboard: return "doc.on.clipboard"
            case .answer: return "text.quote"
            }
        }

        var label: String {
            switch self {
            case .browser(let app): return app
            case .finder: return "Finder"
            case .clipboard: return "Clipboard"
            case .answer: return "TerrierGPT"
            }
        }

        var tint: Color {
            switch self {
            case .browser: return .blue
            case .finder: return .cyan
            case .clipboard: return .purple
            case .answer: return TG.scarlet
            }
        }
    }

    let id: UUID
    let source: Source
    /// Human label for the chip, e.g. a page title or "3 items".
    var title: String
    /// Secondary label, e.g. a host name or a folder name.
    var detail: String?
    /// The page or file this came from, when there is one.
    var url: URL?
    /// The text handed to the model.
    var body: String
    /// Whether this capture is currently folded into the prompt.
    var isEnabled: Bool
    /// Set when we could read the page but not its selection, so the UI can explain why.
    var partial: String?

    let capturedAt: Date

    init(
        id: UUID = UUID(),
        source: Source,
        title: String,
        detail: String? = nil,
        url: URL? = nil,
        body: String,
        isEnabled: Bool = true,
        partial: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.detail = detail
        self.url = url
        self.body = body
        self.isEnabled = isEnabled
        self.partial = partial
        self.capturedAt = capturedAt
    }

    /// Rough size indicator shown on the chip so the user can see what they're about to send.
    var characterCount: Int { body.count }

    /// The block this capture contributes to the composed prompt.
    var promptBlock: String {
        var header = "--- \(source.label)"
        if !title.isEmpty { header += ": \(title)" }
        header += " ---"

        var lines = [header]
        if let url { lines.append("Source: \(url.absoluteString)") }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Prompt composition

nonisolated enum PromptComposer {

    /// The instruction placed above captured context.
    ///
    /// Kept in English to match the rest of the UI. `ClipboardPrompt` used to hard-code a
    /// Spanish instruction, which produced Spanish answers for an English-language app.
    static let defaultInstruction = "Help me with the following content."

    /// Builds the final prompt from an instruction plus whichever captures are switched on.
    static func compose(instruction: String, contexts: [CapturedContext]) -> String {
        let enabled = contexts.filter(\.isEnabled).filter { !$0.body.isEmpty }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = trimmedInstruction.isEmpty ? defaultInstruction : trimmedInstruction

        guard !enabled.isEmpty else { return lead }

        return ([lead, ""] + enabled.map(\.promptBlock)).joined(separator: "\n")
    }
}
