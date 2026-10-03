import Foundation

/// Contracts the app owns, for answers that don't come from a working-group skill.
///
/// `terriergpt-answer` is the default handoff for *any* TerrierGPT answer:
///   • With the standing instruction pasted into an agent's Instructions, every answer ends in
///     a `terriergpt-answer` block — structure the next agent can use (summary, action items,
///     entities…), while the prose stays in the answer.
///   • Without a block, the Handoff button wraps the answer text in the same contract
///     (`generated_by: app-fallback`), so recipes and inbox routing treat both alike.
///
/// The schema is written to `Application Support/TerrierGPTMenu/contracts/` on launch. A
/// schema of the same name in the working-group contracts folder takes precedence, so it can
/// be contributed there later without changing the app.
nonisolated enum BuiltInContracts {

    static let answer = "terriergpt-answer"

    static var directory: URL {
        HandoffStore.directory.deletingLastPathComponent().appendingPathComponent("contracts", isDirectory: true)
    }

    static var names: [String] { [answer] }

    /// Writes the built-in schemas. Overwrites: these files are the app's, not the user's.
    static func install() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(answer).schema.json")
        if (try? String(contentsOf: url, encoding: .utf8)) != answerSchema {
            try? Data(answerSchema.utf8).write(to: url, options: .atomic)
        }
    }

    /// The payload for an answer that had no block: the same contract, marked as made by the
    /// app, carrying the text. Nothing is summarised or inferred here, because that's the
    /// model's job.
    static func fallbackPayload(text: String, title: String) -> [String: Any] {
        var payload: [String: Any] = [
            "contract": answer,
            "version": 1,
            "answer": text,
            "generated_by": "app-fallback",
        ]
        if !title.isEmpty { payload["title"] = title }
        return payload
    }

    // MARK: - Schema

    static let answerSchema = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "terriergpt-answer.schema.json",
      "title": "terriergpt-answer",
      "description": "Default handoff block at the end of any TerrierGPT answer, so the TerrierGPTMenu app can pass it to Claude, Grok, or a script. The prose answer stays above the block; the block carries structure. When an answer has no block, the app wraps its text in this contract with generated_by: app-fallback.",
      "type": "object",
      "additionalProperties": false,
      "required": ["contract", "version"],
      "properties": {
        "contract": { "const": "terriergpt-answer" },
        "version": { "type": "integer", "const": 1 },
        "title": { "type": "string" },
        "summary": { "type": "string", "description": "Two or three sentences." },
        "answer": { "type": "string", "description": "The full answer text. Set by the app on fallback; the model leaves it out." },
        "key_points": { "type": "array", "items": { "type": "string" } },
        "action_items": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["task"],
            "properties": {
              "task": { "type": "string" },
              "owner": { "type": ["string", "null"] },
              "due": { "type": ["string", "null"] }
            }
          }
        },
        "entities": {
          "type": "array",
          "description": "Things the answer names that a next step may act on.",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["type", "value"],
            "properties": {
              "type": { "type": "string", "enum": ["ticket", "kb", "person", "device", "system", "url", "other"] },
              "value": { "type": "string" }
            }
          }
        },
        "sources": { "type": "array", "items": { "type": "string" } },
        "open_questions": { "type": "array", "items": { "type": "string" } },
        "suggested_next": { "type": ["string", "null"], "description": "One line: what the next agent should do with this." },
        "generated_by": { "type": "string", "enum": ["model", "app-fallback"] }
      }
    }
    """

    // MARK: - Standing instruction

    /// Paste once into a TerrierGPT agent's Instructions (Agent Builder), and every answer from
    /// that agent ends in a handoff block — no per-prompt request needed.
    ///
    /// It defers to a skill's own contract (`kb-gap-verdict`, …), so it can sit in an agent
    /// that also runs those skills without producing two blocks.
    static let standingInstruction = """
    ## Handoff block (every answer)

    End every answer with exactly one fenced ```json code block, after the prose, so the answer can be handed to other agents on the user's Mac.

    - If a skill used in this answer defines its own JSON block (for example kb-gap-verdict or kb_retrieve_payload), emit that block and no other. Never emit two blocks.
    - Otherwise emit a terriergpt-answer block in this shape:

    ```json
    {"contract":"terriergpt-answer","version":1,"title":"…","summary":"2–3 sentences","key_points":["…"],"action_items":[{"task":"…","owner":null,"due":null}],"entities":[{"type":"ticket","value":"INC0000000"}],"sources":["…"],"open_questions":["…"],"suggested_next":"…","generated_by":"model"}
    ```

    - entities.type is one of: ticket, kb, person, device, system, url, other.
    - Valid JSON only: double quotes, no comments, no trailing commas. Use [] or null when something doesn't apply. Never invent ticket, KB, or asset numbers.
    - Don't repeat the full answer inside the block, and don't mention the block in the prose.
    """
}
