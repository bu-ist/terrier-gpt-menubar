import Foundation
import Combine
import OSLog

/// A folder that starts chains on its own.
///
/// Anything that can write a file — a Claude or Grok session, a script, a Shortcut's "Save
/// File", another chain — drops a handoff envelope here, and the recipe that claims it runs.
///
///     ~/Library/Application Support/TerrierGPTMenu/handoffs/inbox/
///         <new files land here>
///         processing/    being run right now
///         done/          ran, succeeded
///         failed/        ran, failed (the run folder says why)
///         unrouted/      no recipe claimed it, or it wasn't a usable handoff
///
/// **Routing**, in order:
///   1. The envelope names a recipe (`"recipe": "kb-desk-handoff"`).
///   2. Exactly one recipe whose `input.contract` equals the envelope's `contract`.
/// Either way the recipe must have `"inbox": true`. A file nothing claims goes to `unrouted/`
/// rather than being guessed at.
///
/// **Writers** should write atomically — to a dotfile or `*.tmp` then rename, as `drop(_:)`
/// and `Scripts/handoff/drop.sh` do. Dotfiles and `.tmp` / `.partial` are never picked up.
nonisolated enum Inbox {

    /// Chains of chains stop here. A recipe that outputs to the inbox and also claims its own
    /// contract would otherwise run forever.
    static let maxHops = 5

    static var directory: URL { HandoffStore.directory.appendingPathComponent("inbox", isDirectory: true) }

    enum Box: String, CaseIterable {
        case processing, done, failed, unrouted
    }

    static func url(for box: Box) -> URL { directory.appendingPathComponent(box.rawValue, isDirectory: true) }

    static func prepare() throws {
        for box in Box.allCases {
            try FileManager.default.createDirectory(at: url(for: box), withIntermediateDirectories: true)
        }
    }

    /// Files waiting to be picked up, oldest first.
    static func pending() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { url in
                let name = url.lastPathComponent
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && !name.hasSuffix(".tmp") && !name.hasSuffix(".partial")
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
            }
    }

    /// Copies an envelope into the inbox atomically, stamping how many hops it has made.
    @discardableResult
    static func drop(_ envelope: URL, from label: String, hops: Int, recipe: String? = nil) throws -> URL {
        try prepare()
        let data = try Data(contentsOf: envelope)
        var object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        object["hops"] = hops
        if let recipe { object["recipe"] = recipe }

        let name = "\(HandoffStore.fileStamp(Date()))-\(label).json"
        let temporary = directory.appendingPathComponent(".\(name)")
        try HandoffStore.write(object, to: temporary)
        let final = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }

    static func hops(in envelope: URL) -> Int {
        guard let data = try? Data(contentsOf: envelope),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return object["hops"] as? Int ?? 0
    }

    // MARK: - Routing

    enum RouteError: LocalizedError {
        case unreadable
        case tooManyHops(Int)
        case namedRecipeMissing(String)
        case namedRecipeNotOptedIn(String)
        case noContract
        case noRecipe(contract: String)
        case ambiguous(contract: String, recipes: [String])

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Not a JSON object"
            case .tooManyHops(let hops): return "Stopped after \(hops) chained runs (limit \(Inbox.maxHops))"
            case .namedRecipeMissing(let name): return "Names recipe \"\(name)\", which doesn't exist"
            case .namedRecipeNotOptedIn(let name): return "Recipe \"\(name)\" doesn't accept inbox files (add \"inbox\": true)"
            case .noContract: return "No \"recipe\" or \"contract\" to route by"
            case .noRecipe(let contract): return "No inbox recipe takes \(contract)"
            case .ambiguous(let contract, let recipes): return "\(contract) is claimed by \(recipes.joined(separator: ", ")); add \"recipe\" to the file"
            }
        }
    }

    static func route(_ file: URL, recipes: [Recipe]) -> Result<Recipe, RouteError> {
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.unreadable)
        }
        let hops = object["hops"] as? Int ?? 0
        if hops >= maxHops { return .failure(.tooManyHops(hops)) }

        if let name = object["recipe"] as? String {
            guard let recipe = recipes.first(where: { $0.name == name }) else { return .failure(.namedRecipeMissing(name)) }
            guard recipe.inbox == true else { return .failure(.namedRecipeNotOptedIn(name)) }
            return .success(recipe)
        }

        // A bare payload (no envelope) routes by its own `contract` too.
        let contract = object["contract"] as? String
            ?? (object["payload"] as? [String: Any])?["contract"] as? String
        guard let contract else { return .failure(.noContract) }

        let claimants = recipes.filter { $0.inbox == true && $0.input?.contract == contract }
        switch claimants.count {
        case 0: return .failure(.noRecipe(contract: contract))
        case 1: return .success(claimants[0])
        default: return .failure(.ambiguous(contract: contract, recipes: claimants.map(\.name)))
        }
    }

    /// Moves `file` into `box`, never overwriting an earlier file of the same name.
    @discardableResult
    static func move(_ file: URL, to box: Box) throws -> URL {
        var destination = url(for: box).appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = file.deletingPathExtension().lastPathComponent
            destination = url(for: box).appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).\(file.pathExtension)")
        }
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}

/// Watches the inbox while the app is running, and drains it one file at a time.
///
/// The `launchd` agent (`InboxLaunchAgent`) covers the time the app *isn't* running: it opens
/// `terriergpt://inbox`, which launches the app and lands here. Both paths call `scan()`, and
/// a file is claimed by moving it into `processing/` before anything runs, so the two never
/// run the same file twice.
@MainActor
final class InboxWatcher: ObservableObject {

    static let shared = InboxWatcher()

    private static let enabledKey = "InboxWatchEnabled"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: InboxWatcher.enabledKey)
    @Published private(set) var agentInstalled = InboxLaunchAgent.isInstalled
    /// Files waiting, including the one running.
    @Published private(set) var queued = 0

    private var source: DispatchSourceFileSystemObject?
    private var draining = false
    private var rescanRequested = false
    private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "inbox")

    private init() {}

    /// Called once at launch.
    func start() {
        guard isEnabled else { return }
        startWatching()
        scan()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startWatching()
            scan()
        } else {
            stopWatching()
            // Watching "when the app is closed" without watching at all makes no sense.
            if agentInstalled { setAgentInstalled(false) }
        }
    }

    func setAgentInstalled(_ install: Bool) {
        do {
            if install {
                if !isEnabled { setEnabled(true) }
                try InboxLaunchAgent.install()
            } else {
                try InboxLaunchAgent.uninstall()
            }
        } catch {
            CaptureCoordinator.shared.show(Toast(
                kind: .failure,
                title: install ? "Couldn't install the inbox agent" : "Couldn't remove the inbox agent",
                detail: error.localizedDescription
            ))
        }
        agentInstalled = InboxLaunchAgent.isInstalled
    }

    // MARK: - Draining

    /// Looks for new files and runs them. Safe to call as often as events arrive.
    func scan() {
        guard isEnabled else { return }
        if draining {
            rescanRequested = true
            return
        }
        // Claimed here, synchronously, not inside the task: launch and the `inbox` URL both
        // call scan() in the same turn, and two drains would race for the same file.
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        defer {
            draining = false
            queued = 0
        }
        do { try Inbox.prepare() } catch {
            log.error("Inbox folders: \(error.localizedDescription, privacy: .public)")
            return
        }

        repeat {
            rescanRequested = false
            var files = Inbox.pending()
            while !files.isEmpty, isEnabled {
                queued = files.count
                let file = files.removeFirst()
                await process(file)
            }
        } while rescanRequested && isEnabled
    }

    private func process(_ file: URL) async {
        // A writer that didn't write atomically may still be going. Wait for the size to
        // settle before trusting the contents.
        guard await isStable(file) else { return }

        let recipes = RecipeStore.load().recipes
        switch Inbox.route(file, recipes: recipes) {
        case .failure(let error):
            let moved = try? Inbox.move(file, to: .unrouted)
            log.info("Unrouted \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            CaptureCoordinator.shared.show(Toast(
                kind: .info,
                title: "Inbox: \(file.lastPathComponent) wasn't run",
                detail: error.errorDescription,
                action: moved.map { .reveal($0) } ?? .none
            ))

        case .success(let recipe):
            guard let claimed = try? Inbox.move(file, to: .processing) else { return }
            // One chain at a time; wait for whatever is running (maybe started by hand).
            while ChainRunner.shared.isRunning {
                try? await Task.sleep(for: .seconds(1))
            }
            let run = await ChainRunner.shared.run(recipe, input: .file(claimed), origin: .inbox)
            let box: Inbox.Box = run?.status == .succeeded ? .done : .failed
            _ = try? Inbox.move(claimed, to: box)
        }
    }

    private func isStable(_ file: URL) async -> Bool {
        func size() -> Int? { (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        guard let first = size() else { return false }
        try? await Task.sleep(for: .milliseconds(400))
        return size() == first && FileManager.default.fileExists(atPath: file.path)
    }

    // MARK: - File system events

    private func startWatching() {
        guard source == nil else { return }
        try? Inbox.prepare()
        let descriptor = open(Inbox.directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("Couldn't watch the inbox folder")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }
}

/// The per-user `launchd` job that wakes the app when a file lands in the inbox and the app
/// isn't running. It runs one command — `open -g terriergpt://inbox` — and nothing else, so
/// what actually happens to the file is still decided (and logged) by the app.
nonisolated enum InboxLaunchAgent {

    static let label = "com.brianmatute.TerrierGPTMenu.inbox"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    private static var domain: String { "gui/\(getuid())" }

    static func install() throws {
        try Inbox.prepare()
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "terriergpt://inbox"],
            "WatchPaths": [Inbox.directory.path],
            // launchd's own floor is 10s; say so, rather than relying on the default.
            "ThrottleInterval": 10,
            "RunAtLoad": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        _ = try? launchctl(["bootout", "\(domain)/\(label)"])   // reinstall cleanly
        try launchctl(["bootstrap", domain, plistURL.path])
    }

    static func uninstall() throws {
        _ = try? launchctl(["bootout", "\(domain)/\(label)"])
        if isInstalled { try FileManager.default.removeItem(at: plistURL) }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "launchctl", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "launchctl \(arguments.first ?? ""): \(output.trimmingCharacters(in: .whitespacesAndNewlines))",
            ])
        }
        return output
    }
}
