import Foundation

/// A handoff written for a person-facing assistant rather than for a script.
///
/// The JSON envelope (`HandoffStore`) is right for `claude -p` and recipes, but pasted into
/// Claude, Gemini, or Grok it's noise: the receiving model gets structure without the story.
/// The brief is Markdown that reads like a colleague handing over a thread — what was asked,
/// what it was given, what came back, and what to do next — with the structured block kept
/// at the end for anything that wants it.
nonisolated struct HandoffBrief {

    /// What the user wants the next assistant to do. Empty means `defaultTask`.
    var task: String
    /// The newest question the user asked TerrierGPT, when the page exposed it.
    var question: String?
    /// Context the user captured and kept switched on.
    var contexts: [CapturedContext]
    /// TerrierGPT's answer: the selection if there was one, else the newest reply.
    var answer: String
    /// The answer's JSON block, when the model produced one.
    var structured: (contract: String?, json: String)?
    var conversationTitle: String
    var conversationURL: URL?
    var date = Date()

    static let defaultTask = "Pick up where TerrierGPT left off: check its answer for gaps or mistakes, then help me with the next step."

    /// Ready-made tasks for the picker, so the common cases are one click.
    static let suggestions: [(label: String, task: String)] = [
        ("Continue", defaultTask),
        ("Fact-check", "Fact-check TerrierGPT's answer. Flag anything wrong, outdated, or unsupported, and say how sure you are."),
        ("Go deeper", "Go deeper than TerrierGPT did: fill in the details, edge cases, and anything it skipped."),
        ("Draft a reply", "Turn TerrierGPT's answer into a clear, friendly message I can send to the person who asked."),
        ("Summarize", "Summarize TerrierGPT's answer in five bullets or fewer, then list the action items."),
    ]

    /// Caps per captured context, so one long page doesn't bury the answer.
    private static let contextLimit = 6_000

    var markdown: String {
        var parts: [String] = []

        parts.append("""
        I'm handing off a conversation from TerrierGPT (Boston University's AI assistant). \
        Treat everything below as context.

        **What I need from you:** \(resolvedTask)
        """)

        if let question = question?.trimmed, !question.isEmpty {
            parts.append("## What I asked TerrierGPT\n\n\(question)")
        }

        let usable = contexts.filter { $0.isEnabled && !$0.body.trimmed.isEmpty }
        if !usable.isEmpty {
            let blocks = usable.map { context -> String in
                var lines = ["### \(context.source.label)" + (context.title.isEmpty ? "" : " — \(context.title)")]
                if let url = context.url { lines.append("Source: \(url.absoluteString)") }
                lines.append("")
                lines.append(Self.clip(context.body.trimmed, to: Self.contextLimit))
                return lines.joined(separator: "\n")
            }
            parts.append("## Context I gave it\n\n" + blocks.joined(separator: "\n\n"))
        }

        parts.append("## TerrierGPT's answer\n\n\(answer.trimmed)")

        if let structured {
            let label = structured.contract.map { " (`\($0)`)" } ?? ""
            parts.append("## Structured data\(label)\n\n```json\n\(structured.json)\n```")
        }

        var footer = ["Conversation: \(conversationTitle.isEmpty ? "TerrierGPT" : conversationTitle)"]
        if let conversationURL { footer.append(conversationURL.absoluteString) }
        footer.append(date.formatted(date: .abbreviated, time: .shortened))
        parts.append("---\n" + footer.joined(separator: " · "))

        return parts.joined(separator: "\n\n")
    }

    private var resolvedTask: String {
        let trimmed = task.trimmed
        return trimmed.isEmpty ? Self.defaultTask : trimmed
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(trimmed)" : text
    }
}

nonisolated private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A recipe handed to an assistant: the chain it stands for, the task, the guardrail, your
/// captures, and the result of its last run when there is one.
nonisolated struct RecipeBrief {
    var recipe: Recipe
    var contexts: [CapturedContext]
    var result: String?

    var markdown: String {
        var parts: [String] = []
        var lead = "I'm running the **\(recipe.displayTitle)** recipe from the CTS AI Working Group"
        if let skills = recipe.skills, !skills.isEmpty {
            lead += " — skills in order: " + skills.map { "`\($0)`" }.joined(separator: " → ")
        }
        parts.append(lead + ".")
        if let description = recipe.description { parts.append(description) }
        if let prompt = recipe.prompt?.trimmed, !prompt.isEmpty {
            parts.append("**What I need from you:** \(prompt)")
        } else if result != nil {
            parts.append("**What I need from you:** Review the result below, flag anything wrong, and help me with the next step.")
        }
        if let stop = recipe.stopsBefore {
            parts.append("**Guardrail:** stop before \(stop). Drafts only; I'll do that part myself.")
        }
        if let result = result?.trimmed, !result.isEmpty {
            parts.append("## Result of the last run\n\n\(result.count > 30_000 ? String(result.prefix(30_000)) + "\n…(trimmed)" : result)")
        }
        let usable = contexts.filter { !$0.body.trimmed.isEmpty }
        if !usable.isEmpty {
            parts.append("## Context\n\n" + usable.map(\.promptBlock).joined(separator: "\n\n"))
        }
        parts.append("---\nHanded off from TerrierGPT Menu · " + Date().formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: "\n\n")
    }
}
