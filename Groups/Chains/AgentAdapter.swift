import Foundation

/// Turns a recipe step into a command line, and the command's output back into an envelope.
///
/// Both CLIs are driven headless and asked for JSON, and the two differ in small ways that
/// all live here:
///
/// | | Claude (`claude -p`) | Grok (`grok --prompt-file`) |
/// |---|---|---|
/// | Input | stdin (Claude reads it as context) | Appended to the prompt file (Grok ignores stdin) |
/// | Structured output | `structured_output` | `structuredOutput` |
/// | Text | `result` | `text` |
/// | Tool allow-list | `--allowedTools a,b` | `--allow a --allow b` |
nonisolated enum AgentAdapter {

    struct Invocation {
        let executable: URL
        let arguments: [String]
        /// Fed to the process's stdin; `nil` means /dev/null.
        let stdin: URL?
        let cwd: URL?
        let environment: [String: String]
    }

    struct Output {
        var text: String?
        var payload: Any?
        var isError: Bool
        var errorMessage: String?
        var sessionID: String?
        var costUSD: Double?
        /// Tools the agent tried to use and was refused because the recipe didn't allow them.
        var permissionDenials: [String]
    }

    enum AdapterError: LocalizedError {
        case notFound(String)
        case refusedMode(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "Couldn't find `\(name)`"
            case .refusedMode(let mode):
                return "Permission mode \"\(mode)\" is not allowed in recipes"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notFound(let name):
                return "Install it, or point the app at it: defaults write com.brianmatute.TerrierGPTMenu \(name.capitalized)Path /full/path/to/\(name)"
            case .refusedMode:
                return "Headless steps get an allow-list instead; see the recipe's \"allow\"."
            }
        }
    }

    // MARK: - Building the command

    static func invocation(
        for step: Recipe.Step,
        recipe: Recipe,
        input: URL,
        stepFile: (String) -> URL
    ) throws -> Invocation {
        if let mode = step.permissionMode, RecipeStore.refusedPermissionModes.contains(mode) {
            throw AdapterError.refusedMode(mode)
        }
        let substitute = { (text: String) in
            text.replacingOccurrences(of: "{{input_path}}", with: input.path)
                .replacingOccurrences(of: "{{run_dir}}", with: input.deletingLastPathComponent().path)
                .replacingOccurrences(of: "{{recipe}}", with: recipe.name)
        }
        let cwd = step.cwd.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let schema = try step.outputSchema.map { reference -> String in
            let url = ContractCheck.schemaURL(forReference: reference)
            return try String(contentsOf: url, encoding: .utf8)
        }

        switch step.agent {
        case .claude:
            var arguments = ["-p", substitute(step.prompt ?? ""), "--output-format", "json"]
            if let model = step.model { arguments += ["--model", model] }
            if let schema { arguments += ["--json-schema", schema] }
            if let allow = step.allow, !allow.isEmpty { arguments += ["--allowedTools", allow.joined(separator: ",")] }
            if let mode = step.permissionMode { arguments += ["--permission-mode", mode] }
            if let turns = step.maxTurns { arguments += ["--max-turns", String(turns)] }
            return Invocation(
                executable: try resolve("claude"),
                arguments: arguments,
                stdin: input,
                cwd: cwd,
                environment: environment
            )

        case .grok:
            // Grok doesn't read stdin in headless mode, so the input rides in the prompt file.
            let envelope = (try? String(contentsOf: input, encoding: .utf8)) ?? "{}"
            let prompt = substitute(step.prompt ?? "")
                + "\n\nInput — a handoff envelope from the previous step (also at \(input.path)):\n\n```json\n\(envelope)\n```\n"
            let promptURL = stepFile("prompt.md")
            try Data(prompt.utf8).write(to: promptURL, options: .atomic)

            var arguments = ["--prompt-file", promptURL.path, "--output-format", "json"]
            if let model = step.model { arguments += ["--model", model] }
            if let schema { arguments += ["--json-schema", schema] }
            for rule in step.allow ?? [] { arguments += ["--allow", rule] }
            if let mode = step.permissionMode { arguments += ["--permission-mode", mode] }
            if let turns = step.maxTurns { arguments += ["--max-turns", String(turns)] }
            if let cwd { arguments += ["--cwd", cwd.path] }
            return Invocation(
                executable: try resolve("grok"),
                arguments: arguments,
                stdin: nil,
                cwd: cwd,
                environment: environment
            )

        case .command:
            let argv = (step.command ?? []).map { substitute(($0 as NSString).expandingTildeInPath) }
            guard let first = argv.first else { throw AdapterError.notFound("command") }
            return Invocation(
                executable: try resolve(first),
                arguments: Array(argv.dropFirst()),
                stdin: input,
                cwd: cwd,
                environment: environment
            )
        }
    }

    // MARK: - Reading the result

    static func parse(stdout: Data, agent: Recipe.Step.Agent) -> Output {
        let raw = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]

        switch agent {
        case .claude where object != nil:
            let object = object!
            let text = object["result"] as? String
            let isError = object["is_error"] as? Bool ?? false
            let denials = (object["permission_denials"] as? [[String: Any]] ?? [])
                .compactMap { $0["tool_name"] as? String }
            return Output(
                text: text,
                payload: object["structured_output"] ?? jsonObject(in: text),
                isError: isError,
                errorMessage: isError ? (text ?? object["subtype"] as? String) : nil,
                sessionID: object["session_id"] as? String,
                costUSD: object["total_cost_usd"] as? Double,
                permissionDenials: denials
            )

        case .grok where object != nil:
            let object = object!
            let text = object["text"] as? String
            let error = object["error"] as? String
            return Output(
                text: text,
                payload: object["structuredOutput"] ?? jsonObject(in: text),
                isError: error != nil,
                errorMessage: error,
                sessionID: object["sessionId"] as? String,
                costUSD: object["total_cost_usd"] as? Double,
                permissionDenials: []
            )

        default:
            // A command, or an agent that printed something other than its JSON report.
            return Output(
                text: raw.isEmpty ? nil : raw,
                payload: jsonObject(in: raw),
                isError: false,
                errorMessage: nil,
                sessionID: nil,
                costUSD: nil,
                permissionDenials: []
            )
        }
    }

    /// The text as JSON, but only when the whole text *is* JSON (bare or fenced) — a stray
    /// `{…}` inside an agent's prose is not a payload.
    private static func jsonObject(in text: String?) -> Any? {
        guard let text else { return nil }
        let values = HandoffExtractor.jsonValues(in: text)
        guard values.count == 1, let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first,
              first == "{" || first == "[" || first == "`" else { return nil }
        return values[0]
    }

    // MARK: - Finding executables

    /// Menu bar apps don't inherit the shell's PATH — Grok's is only set in `.zshrc` — so
    /// look where the installers actually put things.
    static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixed = ["\(home)/.local/bin", "\(home)/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (fixed + inherited).filter { seen.insert($0).inserted }
    }()

    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        // Headless runs have no terminal; keep CLIs from trying to draw one.
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        return environment
    }()

    static func resolve(_ name: String) throws -> URL {
        if name.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else { throw AdapterError.notFound(name) }
            return URL(fileURLWithPath: name)
        }
        if let custom = UserDefaults.standard.string(forKey: "\(name.capitalized)Path"),
           FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        for directory in searchPath {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        throw AdapterError.notFound(name)
    }
}

/// Runs one process to completion, with stdout and stderr going straight to files.
///
/// Files rather than pipes: nothing can deadlock on a full pipe buffer, and the raw output of
/// every step is on disk afterwards for when a chain does something unexpected.
nonisolated enum ProcessRunner {

    struct Finished {
        let status: Int32
        let timedOut: Bool
    }

    static func run(
        _ invocation: AgentAdapter.Invocation,
        stdout: URL,
        stderr: URL,
        timeout: TimeInterval
    ) async throws -> Finished {
        let manager = FileManager.default
        manager.createFile(atPath: stdout.path, contents: nil)
        manager.createFile(atPath: stderr.path, contents: nil)

        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        if let cwd = invocation.cwd { process.currentDirectoryURL = cwd }
        process.standardInput = try invocation.stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        process.standardOutput = out
        process.standardError = err
        defer {
            try? out.close()
            try? err.close()
        }

        let box = ProcessBox(process)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            box.terminate(timedOut: true)
        }
        defer { watchdog.cancel() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate(timedOut: false)
        }

        if Task.isCancelled { throw CancellationError() }
        return Finished(status: status, timedOut: box.timedOut)
    }
}

/// Lets the watchdog and the cancellation handler, which run on other threads, stop the
/// process safely. `Process.terminate()` raises if the process was never launched.
private nonisolated final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _timedOut = false

    init(_ process: Process) { self.process = process }

    var timedOut: Bool { lock.withLock { _timedOut } }

    func terminate(timedOut: Bool) {
        lock.withLock {
            guard process.isRunning else { return }
            if timedOut { _timedOut = true }
            process.terminate()
        }
    }
}
