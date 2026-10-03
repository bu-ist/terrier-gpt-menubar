import Foundation

/// The raw material read off the TerrierGPT page for a handoff.
nonisolated struct HandoffSources: Decodable, Equatable {
    var selection: String
    /// Text of every `<pre>` block on the page, in document order.
    var blocks: [String]
    /// Readable page text, the tail end if the page is long.
    var text: String
    /// Best guess at the newest assistant message, and the same without its code blocks.
    /// `nil` when no known message container was on the page.
    var lastMessage: String? = nil
    var lastMessageProse: String? = nil
    /// Best guess at the newest thing the user asked. `nil` when the page doesn't mark it.
    var lastUserMessage: String? = nil
}

/// Finds the JSON a TerrierGPT answer is carrying.
///
/// The model is asked to end its answer with a fenced ```json block that follows a contract
/// (`kb-gap-verdict`, …). This picks that block out of what the page shows. Pure and
/// synchronous so it can be reasoned about without a web view.
nonisolated enum HandoffExtractor {

    /// Where the payload was found, recorded in the envelope so a bad extraction is traceable.
    enum Origin: String, Codable {
        case selection
        case codeBlock = "code-block"
        case pageText = "page-text"
        case lastMessage = "last-message"
    }

    struct Match {
        /// A JSON object or array.
        let payload: Any
        /// The payload's `contract` field, when it has one.
        let contract: String?
        let origin: Origin
    }

    /// Picks the payload to hand off.
    ///
    /// Search order:
    ///   1. The selection, if the user made one — an explicit choice beats any heuristic.
    ///   2. Code blocks, newest (lowest on the page) first.
    ///   3. The page text, newest first, for renderers that don't use `<pre>`.
    ///
    /// With `contract` set, only a payload whose `contract` field equals it counts. Without
    /// one, a payload that names *any* contract wins over a bare JSON block, and a bare block
    /// is accepted only from the selection or a code block — the page text is full of stray
    /// braces that were never meant as data.
    ///
    /// `untypedBlocks: false` skips that last resort. The Handoff button uses it: a bare JSON
    /// block with no contract is usually an example in the answer, not data meant for the
    /// next agent, and falling back to the answer text is the better guess.
    static func extract(from sources: HandoffSources, contract: String?, untypedBlocks: Bool = true) -> Match? {
        let selection = sources.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            // The user pointed at something. Don't go looking elsewhere if it isn't JSON:
            // silently handing off a different block would be worse than failing.
            return best(in: [selection], origin: .selection, contract: contract, allowUntyped: true)
        }
        if let match = best(in: sources.blocks.reversed(), origin: .codeBlock, contract: contract, allowUntyped: false) {
            return match
        }
        if let match = best(in: [sources.text], origin: .pageText, contract: contract, allowUntyped: false) {
            return match
        }
        // Last resort: an untyped JSON block, only when no contract was asked for.
        guard contract == nil, untypedBlocks else { return nil }
        return best(in: sources.blocks.reversed(), origin: .codeBlock, contract: nil, allowUntyped: true)
    }

    /// The first acceptable payload across `texts`, scanning each text from its end.
    private static func best(
        in texts: some Sequence<String>,
        origin: Origin,
        contract: String?,
        allowUntyped: Bool
    ) -> Match? {
        for text in texts {
            for value in jsonValues(in: text).reversed() {
                let object = value as? [String: Any]
                // The schema pasted into the request by `HandoffPrompt` is on the page too.
                // It's the question, not the answer.
                if object?["$schema"] != nil { continue }
                // Nor is the standing instruction's template, if someone pasted it into a chat.
                if let object, isTemplate(object) { continue }
                let named = object?["contract"] as? String
                if let contract {
                    if named == contract { return Match(payload: value, contract: named, origin: origin) }
                } else if named != nil || allowUntyped {
                    return Match(payload: value, contract: named, origin: origin)
                }
            }
        }
        return nil
    }

    /// A template has "…" where its values go.
    private static func isTemplate(_ object: [String: Any]) -> Bool {
        object.values.contains { ($0 as? String) == "…" }
    }

    /// Every top-level JSON object or array in `text`, in order of appearance.
    ///
    /// Tries the whole text first (the common case: a code block that *is* the JSON), then
    /// falls back to scanning for balanced `{…}` / `[…]` spans, tracking strings so a brace
    /// inside a quoted value doesn't end the span early.
    static func jsonValues(in text: String) -> [Any] {
        let trimmed = stripFence(text)
        if let whole = parse(trimmed), whole is [String: Any] || whole is [Any] {
            return [whole]
        }

        var values: [Any] = []
        let bytes = Array(trimmed.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "{") || byte == UInt8(ascii: "["),
                  let end = matchingClose(in: bytes, from: index) else {
                index += 1
                continue
            }
            let slice = String(decoding: bytes[index...end], as: UTF8.self)
            if let value = parse(slice) {
                values.append(value)
                index = end + 1
            } else {
                index += 1
            }
        }
        return values
    }

    /// Removes a surrounding ```json … ``` fence, for selections that include it.
    private static func stripFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        guard lines.count >= 2,
              lines.first?.hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    /// Index of the bracket that closes the one at `start`, or `nil` if it never closes.
    private static func matchingClose(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    private static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }
}
