import Foundation
import AppKit

/// Reads the selected Microsoft Outlook message, and opens draft replies / new messages.
///
/// Targets classic Outlook for Mac (`com.microsoft.Outlook`), which still exposes a scripting
/// dictionary. The "New Outlook" toggle can weaken or remove that dictionary — failures surface
/// as a clear toast rather than a silent no-op. Drafts only; never Send.
nonisolated enum OutlookBridge {

    static let appName = "Outlook"
    static let bundleID = "com.microsoft.Outlook"

    private static let separator = "<<|TGPT-FIELD|>>"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Capture

    static func captureSelection() async throws -> CapturedContext {
        try await ensurePermission()
        let raw = try await AppleScriptRunner.runForString(captureScript, appName: appName)
        let fields = raw.components(separatedBy: separator)
        guard fields.count >= 4 else { throw AutomationError.noResult(app: appName) }

        let subject = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let date = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty || !subject.isEmpty else {
            throw AutomationError.noResult(app: appName)
        }

        var lines: [String] = []
        if !sender.isEmpty { lines.append("From: \(sender)") }
        if !date.isEmpty { lines.append("Date: \(date)") }
        if !subject.isEmpty { lines.append("Subject: \(subject)") }
        lines.append("")
        lines.append(body.isEmpty ? "(No message body.)" : body)

        return CapturedContext(
            source: .outlook,
            title: subject.isEmpty ? "Outlook message" : subject,
            detail: sender.isEmpty ? nil : sender,
            body: lines.joined(separator: "\n")
        )
    }

    private static var captureScript: String {
        AppleScriptRunner.timed("""
        tell application id "com.microsoft.Outlook"
            set sel to selection
            if sel is missing value then error "No message selected." number -1719
            if (count of sel) is 0 then error "No message selected." number -1719
            set msg to item 1 of sel
            set theSubject to subject of msg
            set theSender to ""
            try
                set theSender to address of (sender of msg)
            end try
            set theDate to ""
            try
                set theDate to (time received of msg) as text
            end try
            set theBody to plain text content of msg
            return theSubject & \(separator.appleScriptLiteral) & theSender & \(separator.appleScriptLiteral) & theDate & \(separator.appleScriptLiteral) & theBody
        end tell
        """, seconds: 20)
    }

    // MARK: - Drafts (never send)

    static func draftReply(body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleAppsError.emptyContent }
        try await ensurePermission()

        let source = AppleScriptRunner.timed("""
        tell application id "com.microsoft.Outlook"
            set sel to selection
            if sel is missing value then error "Select the message to reply to first." number -1719
            if (count of sel) is 0 then error "Select the message to reply to first." number -1719
            set msg to item 1 of sel
            set theReply to reply to msg with opening window
            set content of theReply to \(trimmed.appleScriptLiteral)
            activate
        end tell
        """, seconds: 20)
        try await AppleScriptRunner.runIgnoringResult(source, appName: appName)
    }

    static func draftNewMessage(subject: String, body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleAppsError.emptyContent }
        try await ensurePermission()

        let source = AppleScriptRunner.timed("""
        tell application id "com.microsoft.Outlook"
            set newMsg to make new outgoing message with properties {subject:\(subject.appleScriptLiteral), content:\(trimmed.appleScriptLiteral)}
            open newMsg
            activate
        end tell
        """, seconds: 20)
        try await AppleScriptRunner.runIgnoringResult(source, appName: appName)
    }

    private static func ensurePermission() async throws {
        guard isRunning else { throw AutomationError.notRunning(app: appName) }
        switch AutomationPermission.status(bundleIdentifier: bundleID, prompt: true) {
        case .denied: throw AutomationError.permissionDenied(app: appName)
        case .needsPrompt: throw AutomationError.permissionNotGranted(app: appName)
        case .granted, .targetNotRunning, .unknown: return
        }
    }
}
