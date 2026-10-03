import Foundation

/// Where handoffs land on disk, and the contract schemas they're checked against.
///
/// A handoff is a file, not a clipboard entry: the clipboard is size-limited, gets overwritten
/// by whatever the user copies next, and leaves no trail. A file can be read by `claude -p`,
/// `grok -p`, a Shortcut, a `launchd` WatchPaths job, or the next step of a chain — and it is
/// still there when a step fails and you want to see what it was given.
///
///     ~/Library/Application Support/TerrierGPTMenu/handoffs/
///         2026-09-28T14-03-11Z-kb-gap-verdict.json
///         latest.json          ← always the most recent one
nonisolated enum HandoffStore {

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerrierGPTMenu", isDirectory: true)
            .appendingPathComponent("handoffs", isDirectory: true)
    }

    static var latestURL: URL { directory.appendingPathComponent("latest.json") }

    /// The contracts folder of the CTS working-group clone.
    ///
    /// Override with `defaults write com.brianmatute.TerrierGPTMenu ContractsDirectory <path>`
    /// when the clone lives somewhere else.
    static var contractsDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: "ContractsDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub/cts-ai-working-group/docs/contracts", isDirectory: true)
    }

    /// Contract names with a schema on disk, e.g. `kb-gap-verdict`, sorted — the working-group
    /// folder plus the app's built-in ones.
    static func availableContracts() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: contractsDirectory.path)) ?? []
        let names = files
            .filter { $0.hasSuffix(".schema.json") }
            .map { String($0.dropLast(".schema.json".count)) }
        return Array(Set(names + BuiltInContracts.names)).sorted()
    }

    /// The working-group schema if there is one, else the app's built-in copy.
    static func schemaURL(for contract: String) -> URL {
        let shared = contractsDirectory.appendingPathComponent("\(contract).schema.json")
        guard !FileManager.default.fileExists(atPath: shared.path), BuiltInContracts.names.contains(contract) else {
            return shared
        }
        return BuiltInContracts.directory.appendingPathComponent("\(contract).schema.json")
    }

    static func schema(for contract: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: schemaURL(for: contract)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Writing

    struct Saved {
        let url: URL
        /// The envelope as written, pretty-printed.
        let json: String
        /// Just what TerrierGPT produced, for a consumer that doesn't want the envelope.
        let payloadJSON: String
        let validation: ContractCheck.Result
        /// True when the answer had no JSON block and the app wrapped its text instead.
        var isTextFallback = false
    }

    /// Wraps `match` in an envelope and writes it, plus `latest.json`.
    ///
    /// `text` is the answer's prose, when it could be read, so the next agent gets both the
    /// structure (payload) and what TerrierGPT actually said (text).
    static func save(
        _ match: HandoffExtractor.Match,
        requestedContract: String?,
        text: String? = nil,
        pageURL: URL?,
        pageTitle: String
    ) throws -> Saved {
        let contract = match.contract ?? requestedContract
        return try save(
            payload: match.payload,
            text: text,
            contract: contract,
            source: pageSource(origin: match.origin.rawValue, pageURL: pageURL, pageTitle: pageTitle),
            validation: ContractCheck.check(match.payload, against: contract)
        )
    }

    /// Saves an answer that carries no JSON block, as a `terriergpt-answer` written by the app.
    /// The text is in both `payload.answer` and the envelope's `text`, so a consumer reading
    /// either one gets it.
    static func saveAnswerText(_ text: String, origin: String, pageURL: URL?, pageTitle: String) throws -> Saved {
        let payload = BuiltInContracts.fallbackPayload(text: text, title: pageTitle)
        var saved = try save(
            payload: payload,
            text: text,
            contract: BuiltInContracts.answer,
            source: pageSource(origin: origin, pageURL: pageURL, pageTitle: pageTitle),
            validation: ContractCheck.check(payload, against: BuiltInContracts.answer)
        )
        saved.isTextFallback = true
        return saved
    }

    private static func save(
        payload: Any?,
        text: String?,
        contract: String?,
        source: [String: Any],
        validation: ContractCheck.Result
    ) throws -> Saved {
        let now = Date()
        let envelope = makeEnvelope(contract: contract, source: source, validation: validation, payload: payload, text: text, at: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(fileStamp(now))-\(contract ?? (text == nil ? "untyped" : "text")).json")
        let json = try write(envelope, to: url)
        try Data(json.utf8).write(to: latestURL, options: .atomic)
        return Saved(url: url, json: json, payloadJSON: try encode(payload ?? NSNull()), validation: validation)
    }

    private static func pageSource(origin: String, pageURL: URL?, pageTitle: String) -> [String: Any] {
        var source: [String: Any] = ["agent": "terriergpt", "extracted_from": origin]
        if let pageURL { source["url"] = pageURL.absoluteString }
        if !pageTitle.isEmpty { source["title"] = pageTitle }
        return source
    }

    // MARK: - Envelope plumbing, shared with the chain runner

    /// The handoff envelope. Every step of a chain reads and writes this same shape, so a
    /// step never needs to know whether its input came from TerrierGPT, Claude, or Grok.
    static func makeEnvelope(
        contract: String?,
        source: [String: Any],
        validation: ContractCheck.Result,
        payload: Any?,
        text: String?,
        at date: Date = Date()
    ) -> [String: Any] {
        var envelope: [String: Any] = [
            "handoff": 1,
            "id": UUID().uuidString.lowercased(),
            "created_at": ISO8601DateFormatter().string(from: date),
            "contract": contract ?? NSNull(),
            "source": source,
            "validation": validation.json,
            "payload": payload ?? NSNull(),
        ]
        if let text { envelope["text"] = text }
        return envelope
    }

    /// Writes `object` as pretty JSON and returns what was written.
    @discardableResult
    static func write(_ object: Any, to url: URL) throws -> String {
        let json = try encode(object)
        try Data(json.utf8).write(to: url, options: .atomic)
        return json
    }

    static func encode(_ object: Any) throws -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
    }

    /// `2026-09-28T14-03-11Z` — sortable, and no colons for Finder to turn into slashes.
    static func fileStamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

/// A shallow check of a payload against its contract schema.
///
/// Deliberately not a full JSON Schema validator: it checks what breaks a downstream skill
/// outright — right contract name and version, required top-level keys present, no unknown
/// top-level keys where the schema forbids them, top-level enums respected. The receiving
/// agent (`claude -p --json-schema`, `grok --json-schema`) is where deep validation belongs.
///
/// A failed check doesn't stop the handoff from being written — the envelope records the
/// issues, so it's visible what TerrierGPT got wrong, and a chain runner can refuse it.
nonisolated enum ContractCheck {

    struct Result {
        enum Status: String { case valid, invalid, unchecked }
        let status: Status
        let schemaPath: String?
        let issues: [String]

        var json: [String: Any] {
            ["status": status.rawValue, "schema": schemaPath ?? NSNull(), "issues": issues]
        }
    }

    static func check(_ payload: Any, against contract: String?) -> Result {
        guard let contract else {
            return Result(status: .unchecked, schemaPath: nil, issues: ["No contract named; nothing to check against."])
        }
        return check(payload, schemaAt: HandoffStore.schemaURL(for: contract))
    }

    /// Resolves a recipe's `output_schema`: a path (anything with a `/` or ending in `.json`)
    /// or a contract name from the contracts folder.
    static func schemaURL(forReference reference: String) -> URL {
        if reference.contains("/") || reference.hasSuffix(".json") {
            return URL(fileURLWithPath: (reference as NSString).expandingTildeInPath)
        }
        return HandoffStore.schemaURL(for: reference)
    }

    static func check(_ payload: Any, schemaAt url: URL) -> Result {
        guard let data = try? Data(contentsOf: url),
              let schema = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Result(status: .unchecked, schemaPath: nil, issues: ["No schema found at \(url.path)."])
        }
        let path = url.path
        guard let object = payload as? [String: Any] else {
            return Result(status: .invalid, schemaPath: path, issues: ["Payload is not a JSON object."])
        }

        var issues: [String] = []
        let properties = schema["properties"] as? [String: Any] ?? [:]

        for key in schema["required"] as? [String] ?? [] where object[key] == nil {
            issues.append("Missing required key \"\(key)\".")
        }
        if schema["additionalProperties"] as? Bool == false {
            for key in object.keys.sorted() where properties[key] == nil {
                issues.append("Unexpected key \"\(key)\".")
            }
        }
        for (key, rule) in properties {
            guard let rule = rule as? [String: Any], let value = object[key] else { continue }
            if let constant = rule["const"], !isEqual(constant, value) {
                issues.append("\"\(key)\" must be \(describe(constant)), got \(describe(value)).")
            }
            if let options = rule["enum"] as? [Any], !options.contains(where: { isEqual($0, value) }) {
                issues.append("\"\(key)\" is \(describe(value)), not one of the allowed values.")
            }
        }
        return Result(status: issues.isEmpty ? .valid : .invalid, schemaPath: path, issues: issues)
    }

    private static func isEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs) ?? false
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        if value is NSNull { return "null" }
        return "\(value)"
    }
}

/// The instruction that asks TerrierGPT to end its answer with a machine-readable block.
nonisolated enum HandoffPrompt {

    static func request(for contract: String) -> String {
        var text = """
        At the end of your answer, add exactly one fenced ```json code block containing a \
        single JSON object with "contract": "\(contract)". Output valid JSON only inside the \
        block — no comments, no trailing commas, no placeholder text. Keep the prose answer \
        above it as usual.
        """
        if let data = try? Data(contentsOf: HandoffStore.schemaURL(for: contract)),
           let schema = String(data: data, encoding: .utf8) {
            text += "\n\nThe object must conform to this JSON Schema:\n\n```json\n\(schema.trimmingCharacters(in: .whitespacesAndNewlines))\n```"
        }
        return text
    }
}
