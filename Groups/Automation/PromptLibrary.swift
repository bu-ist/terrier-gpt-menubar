import Foundation
import Combine

/// Named instructions the user can drop onto a capture before pasting into chat.
///
/// Seeded CTS-flavoured prompts ship with the app; custom ones live in Application Support
/// so they survive rebuilds. The dock stays one Menu — no extra chrome.
@MainActor
final class PromptLibrary: ObservableObject {

    static let shared = PromptLibrary()

    struct Prompt: Identifiable, Codable, Equatable, Hashable {
        var id: UUID
        var title: String
        var body: String
        /// Built-in rows the user can reset but not delete.
        var isBuiltIn: Bool

        init(id: UUID = UUID(), title: String, body: String, isBuiltIn: Bool = false) {
            self.id = id
            self.title = title
            self.body = body
            self.isBuiltIn = isBuiltIn
        }
    }

    @Published private(set) var prompts: [Prompt] = []

    private let customURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TerrierGPTMenu", isDirectory: true)
        return root.appendingPathComponent("prompt-library.json")
    }()

    private init() {
        reload()
    }

    func reload() {
        let custom = loadCustom()
        // Built-ins first, then custom — menu order stays predictable.
        prompts = Self.builtIns + custom
    }

    func add(title: String, body: String) {
        var custom = loadCustom()
        custom.append(Prompt(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                             body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
        saveCustom(custom)
        reload()
    }

    func remove(_ prompt: Prompt) {
        guard !prompt.isBuiltIn else { return }
        var custom = loadCustom()
        custom.removeAll { $0.id == prompt.id }
        saveCustom(custom)
        reload()
    }

    // MARK: - Persistence

    private func loadCustom() -> [Prompt] {
        guard let data = try? Data(contentsOf: customURL),
              let decoded = try? JSONDecoder().decode([Prompt].self, from: data) else {
            return []
        }
        return decoded.map {
            var copy = $0
            copy.isBuiltIn = false
            return copy
        }
    }

    private func saveCustom(_ prompts: [Prompt]) {
        let root = customURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writable = prompts.map {
            Prompt(id: $0.id, title: $0.title, body: $0.body, isBuiltIn: false)
        }
        guard let data = try? JSONEncoder().encode(writable) else { return }
        try? data.write(to: customURL, options: .atomic)
    }

    /// CTS day-to-day instructions. Kept short so the menu stays scannable.
    private static let builtIns: [Prompt] = [
        Prompt(
            id: UUID(uuidString: "A1111111-1111-1111-1111-111111111101")!,
            title: "Draft a KB article",
            body: "Draft a short, warm BU Knowledge Base article from this. Lead with the problem the client hits, then the fix in numbered steps. Friendly and clear — not a long SOP.",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "A1111111-1111-1111-1111-111111111102")!,
            title: "Ticket update",
            body: "Write a concise ServiceNow work note from this. Past tense, what was tried, what changed, and what's left. No fluff.",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "A1111111-1111-1111-1111-111111111103")!,
            title: "Client reply",
            body: "Draft a plain-language reply the client can act on. Lead with the answer, then one or two next steps. Warm, not corporate.",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "A1111111-1111-1111-1111-111111111104")!,
            title: "Escalate note",
            body: "Draft a tech-to-tech escalation for another assignment group. Include symptom, what's already ruled out, access or logs they'll need, and the ask. Flag any group name that needs verifying in ServiceNow.",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "A1111111-1111-1111-1111-111111111105")!,
            title: "Triage this INC",
            body: "Triage this ServiceNow ticket. What is it, whose move is it, and the single next action? Keep it short enough to paste into a huddle.",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "A1111111-1111-1111-1111-111111111106")!,
            title: "Summarize for a manager",
            body: "Summarize this for a manager check-in. One headline, three bullets max, and any decision still open.",
            isBuiltIn: true
        ),
    ]
}
