import Foundation
import AppKit

/// Reads the selected Apple Mail message, and opens draft replies / new messages.
///
/// Drafts only — never calls Send. The person hits Send in Mail.
nonisolated enum MailBridge {

    static let appName = "Mail"
    static let bundleID = "com.apple.mail"

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
            source: .mail,
            title: subject.isEmpty ? "Mail message" : subject,
            detail: sender.isEmpty ? nil : sender,
            body: lines.joined(separator: "\n")
        )
    }

    private static var captureScript: String {
        AppleScriptRunner.timed("""
        tell application id "com.apple.mail"
            set sel to selection
            if (count of sel) is 0 then error "No message selected." number -1719
            set msg to item 1 of sel
            set theSubject to subject of msg
            set theSender to sender of msg
            set theDate to (date received of msg) as text
            set theBody to content of msg
            return theSubject & \(separator.appleScriptLiteral) & theSender & \(separator.appleScriptLiteral) & theDate & \(separator.appleScriptLiteral) & theBody
        end tell
        """, seconds: 20)
    }

    // MARK: - Drafts (never send)

    /// Opens a reply draft to the selected message, body filled from TerrierGPT's answer.
    static func draftReply(body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleAppsError.emptyContent }
        try await ensurePermission()

        let source = AppleScriptRunner.timed("""
        tell application id "com.apple.mail"
            set sel to selection
            if (count of sel) is 0 then error "Select the message to reply to first." number -1719
            set msg to item 1 of sel
            set theReply to reply msg with opening window
            set content of theReply to \(trimmed.appleScriptLiteral)
            activate
        end tell
        """, seconds: 20)
        try await AppleScriptRunner.runIgnoringResult(source, appName: appName)
    }

    /// Opens a new outgoing message draft (not a reply).
    static func draftNewMessage(subject: String, body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleAppsError.emptyContent }
        try await ensurePermission()

        let source = AppleScriptRunner.timed("""
        tell application id "com.apple.mail"
            set newMsg to make new outgoing message with properties {subject:\(subject.appleScriptLiteral), content:\(trimmed.appleScriptLiteral), visible:true}
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
