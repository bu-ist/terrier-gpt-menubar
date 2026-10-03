import AppKit
import SwiftUI

/// The assistants a handoff can go to.
///
/// Each one prefers its desktop app when it's installed and falls back to the website. The
/// brief always goes on the clipboard first; where the destination accepts a prefilled prompt
/// (`?q=`) and the brief is short enough to survive a URL, it's also typed in for you.
enum AITarget: String, CaseIterable, Identifiable {
    case claude, gemini, grok

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        }
    }

    var maker: String {
        switch self {
        case .claude: return "Anthropic"
        case .gemini: return "Google"
        case .grok: return "xAI"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .gemini: return "sparkle"
        case .grok: return "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .gemini: return TG.azure
        case .grok: return TG.graphite
        }
    }

    // MARK: - Where it lives

    /// The installed desktop app, if any.
    var appURL: URL? {
        switch self {
        case .claude:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
        case .gemini:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.GeminiMacOS")
        case .grok:
            // Grok has no native Mac app; people install grok.com as a Safari web app, which
            // gets a random bundle ID. Find it by name instead.
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [URL(fileURLWithPath: "/Applications/Grok.app"), home.appendingPathComponent("Applications/Grok.app")]
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    var isInstalled: Bool { appURL != nil }

    /// Where the brief ends up, for the picker's subtitle.
    var destinationLabel: String {
        isInstalled ? "Desktop app" : (self == .gemini ? "gemini.google.com" : self == .claude ? "claude.ai" : "grok.com")
    }

    /// Whether the brief can ride in the URL rather than only on the clipboard.
    func canPrefill(_ brief: String) -> Bool {
        self != .gemini && brief.count <= Self.prefillLimit
    }

    /// Long URLs get truncated by browsers and apps in ways that drop the end of the brief —
    /// which is the answer. Past this, paste instead.
    private static let prefillLimit = 6_000

    // MARK: - Opening

    /// Opens the assistant, with the brief prefilled when it fits.
    /// - Returns: `true` when the brief was prefilled, so the caller can skip "paste with ⌘V".
    @MainActor
    @discardableResult
    func open(with brief: String) -> Bool {
        let prefill = canPrefill(brief)
        let query = prefill ? brief.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) : nil

        switch self {
        case .claude:
            let path = query.map { "claude.ai/new?q=\($0)" } ?? "claude.ai/new"
            if isInstalled, let url = URL(string: "claude://\(path)") {
                NSWorkspace.shared.open(url)
            } else if let url = URL(string: "https://\(path)") {
                NSWorkspace.shared.open(url)
            }
        case .gemini:
            if let app = appURL {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } else if let url = URL(string: "https://gemini.google.com/app") {
                NSWorkspace.shared.open(url)
            }
        case .grok:
            let link = URL(string: "https://grok.com/" + (query.map { "?q=\($0)" } ?? ""))!
            if let app = appURL {
                NSWorkspace.shared.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } else {
                NSWorkspace.shared.open(link)
            }
        }
        return prefill && query != nil
    }

    /// `urlQueryAllowed` leaves `&`, `=`, `+` and `#` alone, which would cut the brief short.
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()

    // MARK: - Remembered choice

    private static let lastKey = "HandoffLastTarget"

    static var last: AITarget {
        get { UserDefaults.standard.string(forKey: lastKey).flatMap(AITarget.init(rawValue:)) ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastKey) }
    }
}
