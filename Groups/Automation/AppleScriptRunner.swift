import Foundation
import AppKit
import Carbon.OpenScripting
import OSLog

/// Everything that can go wrong when we talk to another app.
///
/// These are surfaced to the user verbatim in the toast, so each case carries a
/// recovery suggestion rather than a raw OSStatus.
nonisolated enum AutomationError: LocalizedError {
    case notRunning(app: String)
    case permissionDenied(app: String)
    case permissionNotGranted(app: String)
    case javaScriptFromAppleEventsDisabled(app: String)
    case scriptFailed(app: String, message: String, code: Int)
    case noResult(app: String)
    case unsupported(app: String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let app):
            return "\(app) isn't running."
        case .permissionDenied(let app):
            return "TerrierGPT isn't allowed to control \(app)."
        case .permissionNotGranted(let app):
            return "Waiting for permission to control \(app)."
        case .javaScriptFromAppleEventsDisabled(let app):
            return "\(app) won't run JavaScript from Apple Events."
        case .scriptFailed(let app, let message, _):
            return "\(app): \(message)"
        case .noResult(let app):
            return "\(app) returned nothing to capture."
        case .unsupported(let app):
            return "\(app) doesn't expose its page to automation."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied(let app):
            return "Turn on \(app) under System Settings → Privacy & Security → Automation → TerrierGPTMenu."
        case .permissionNotGranted:
            return "Approve the permission prompt, then try again."
        case .javaScriptFromAppleEventsDisabled(let app):
            return app.hasPrefix("Safari")
                ? "Enable Develop → Developer Settings → \"Allow JavaScript from Apple Events\" in Safari."
                : "Enable View → Developer → \"Allow JavaScript from Apple Events\" in \(app)."
        case .notRunning(let app):
            return "Open \(app) and try again."
        default:
            return nil
        }
    }

    /// Whether the panel should offer a "Open Privacy Settings" affordance for this failure.
    var isPermissionProblem: Bool {
        switch self {
        case .permissionDenied, .permissionNotGranted: return true
        default: return false
        }
    }
}

// MARK: - Automation permission

nonisolated enum AutomationPermission {
    case granted
    case denied
    case needsPrompt
    case targetNotRunning
    case unknown(OSStatus)

    /// Asks the system whether we may send Apple Events to `bundleIdentifier`.
    ///
    /// Passing `prompt: false` is a *silent* check — it never shows the consent dialog, so the
    /// UI can grey out actions without nagging. Pass `prompt: true` immediately before an
    /// action the user just asked for.
    static func status(bundleIdentifier: String, prompt: Bool) -> AutomationPermission {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier).aeDesc else {
            return .unknown(OSStatus(errAEDescNotFound))
        }
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, prompt)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .needsPrompt
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .unknown(status)
        }
    }

    /// Opens the exact Privacy pane the user needs, rather than the top of System Settings.
    @MainActor
    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Script execution

/// Runs AppleScript off the main thread.
///
/// `NSAppleScript` blocks its caller for the whole round trip to the target app, and a target
/// that is busy (spinning beachball, modal sheet) can hold it for many seconds. Running it on
/// the main thread would freeze the panel, so every script goes through one serial queue and
/// every script carries its own `with timeout` so a wedged app can't pin the queue forever.
nonisolated enum AppleScriptRunner {

    private static let queue = DispatchQueue(label: "com.brianmatute.TerrierGPTMenu.applescript", qos: .userInitiated)
    private static let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "automation")

    /// Default ceiling for a single Apple Event round trip, in seconds.
    static let defaultTimeout = 10

    /// Wraps `body` in a timeout so a hung target app surfaces as an error instead of a hang.
    static func timed(_ body: String, seconds: Int = defaultTimeout) -> String {
        """
        with timeout of \(seconds) seconds
        \(body)
        end timeout
        """
    }

    static func run(_ source: String, appName: String) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: AutomationError.scriptFailed(
                        app: appName, message: "Could not compile the script.", code: -1))
                    return
                }
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    continuation.resume(throwing: mapError(errorInfo, appName: appName))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Runs a script whose last statement evaluates to text.
    static func runForString(_ source: String, appName: String) async throws -> String {
        let descriptor = try await run(source, appName: appName)
        guard let value = descriptor.stringValue else {
            throw AutomationError.noResult(app: appName)
        }
        return value
    }

    /// Runs a script for its side effect only.
    static func runIgnoringResult(_ source: String, appName: String) async throws {
        _ = try await run(source, appName: appName)
    }

    private static func mapError(_ info: NSDictionary, appName: String) -> AutomationError {
        let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error."
        log.error("AppleScript failed for \(appName, privacy: .public): \(code) \(message, privacy: .public)")

        switch code {
        case Int(errAEEventNotPermitted):
            return .permissionDenied(app: appName)
        case Int(errAEEventWouldRequireUserConsent):
            return .permissionNotGranted(app: appName)
        case Int(procNotFound), -600, -609:
            return .notRunning(app: appName)
        case -2700 where message.lowercased().contains("javascript"),
             -1728 where message.lowercased().contains("javascript"):
            return .javaScriptFromAppleEventsDisabled(app: appName)
        default:
            // Safari and the Chromium browsers both report the "Allow JavaScript from Apple
            // Events" opt-out as a generic script error, so match on the text as a fallback.
            let lowered = message.lowercased()
            if lowered.contains("javascript") && (lowered.contains("not allowed") || lowered.contains("apple events")) {
                return .javaScriptFromAppleEventsDisabled(app: appName)
            }
            return .scriptFailed(app: appName, message: message, code: code)
        }
    }
}

// MARK: - AppleScript string escaping

nonisolated extension String {
    /// Escapes the receiver for interpolation inside an AppleScript string literal.
    ///
    /// Without this, a captured page title containing a quote or backslash silently turns a
    /// captured selection into a syntax error — or, worse, into script the user never wrote.
    var appleScriptLiteral: String {
        var escaped = ""
        escaped.reserveCapacity(count + 2)
        for character in self {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Escapes the receiver for embedding inside an HTML body (Notes takes HTML).
    var htmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for character in self {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
