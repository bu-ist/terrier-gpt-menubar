import Foundation

/// Past runs, read back from each run folder's `run.json`. The folders are the record; this
/// only reads them, so deleting a folder in Finder removes it from the history too.
nonisolated struct RunRecord: Identifiable, Hashable {
    let id: String
    let directory: URL
    let recipe: String
    let title: String
    let status: String
    let origin: String
    let startedAt: Date?
    let seconds: TimeInterval?
    let costUSD: Double
    let error: String?
    let output: URL?
    let steps: [String]

    var input: URL { directory.appendingPathComponent("00-input.json") }
    var succeeded: Bool { status == "succeeded" }

    /// The result to copy: the last step's JSON payload if it made one, else its text.
    func resultText() -> String? {
        guard let output,
              let data = try? Data(contentsOf: output),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let payload = envelope["payload"], !(payload is NSNull) {
            return try? HandoffStore.encode(payload)
        }
        return envelope["text"] as? String
    }
}

nonisolated enum RunHistory {

    static func load(limit: Int = 40) -> [RunRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: ChainRunner.runsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let iso = ISO8601DateFormatter()

        let records: [RunRecord] = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("run.json")),
                  let summary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let started = (summary["started_at"] as? String).flatMap(iso.date(from:))
            let finished = (summary["finished_at"] as? String).flatMap(iso.date(from:))
            let steps = (summary["steps"] as? [[String: Any]] ?? []).map { step in
                "\(step["agent"] as? String ?? "?"):\(step["status"] as? String ?? "?")"
            }
            let recipe = summary["recipe"] as? String ?? folder.lastPathComponent
            return RunRecord(
                id: folder.lastPathComponent,
                directory: folder,
                recipe: recipe,
                title: summary["title"] as? String ?? recipe,
                status: summary["status"] as? String ?? "unknown",
                origin: summary["origin"] as? String ?? "panel",
                startedAt: started,
                seconds: both(started, finished).map { $1.timeIntervalSince($0) },
                costUSD: summary["total_cost_usd"] as? Double ?? 0,
                error: summary["error"] as? String,
                output: (summary["output"] as? String).map { URL(fileURLWithPath: $0) },
                steps: steps
            )
        }
        return Array(records.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }.prefix(limit))
    }
}

private nonisolated func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
