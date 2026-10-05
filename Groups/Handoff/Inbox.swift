import Foundation
import OSLog

/// A folder that starts chains on its own. Shared by TerrierGPT Menu (which drops answers
/// here) and CTS Recipes (which watches it and runs the recipe that claims each file).
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
