import Foundation
import AppKit
import EventKit
import OSLog

/// Failures filing content into Notes, Reminders, or Calendar.
nonisolated enum AppleAppsError: LocalizedError {
    case accessDenied(app: String)
    case accessRestricted(app: String)
    case noDefaultList(app: String)
    case saveFailed(app: String, underlying: String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .accessDenied(let app):
            return "TerrierGPT doesn't have access to \(app)."
        case .accessRestricted(let app):
            return "Access to \(app) is restricted on this Mac."
        case .noDefaultList(let app):
            return "\(app) has no default list to write to."
        case .saveFailed(let app, let underlying):
            return "Couldn't save to \(app): \(underlying)"
        case .emptyContent:
            return "There's nothing to file yet."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accessDenied(let app):
            return "Turn on TerrierGPTMenu under System Settings → Privacy & Security → \(app)."
        case .noDefaultList(let app):
            return "Create at least one \(app.lowercased()) list first."
        default:
            return nil
        }
    }
}

// MARK: - Notes

/// Creates and appends notes in Apple Notes.
///
/// Notes has no public framework API, so this is the one Apple app here that genuinely needs
/// AppleScript. Bodies are HTML — Notes renders the body as rich text.
nonisolated enum NotesBridge {

    nonisolated static let appName = "Notes"
    nonisolated static let bundleID = "com.apple.Notes"
    /// Folder we file everything into, so captures don't scatter through the user's notes.
    /// `nonisolated` so it can be used as a default argument, which is evaluated at the call
    /// site and therefore outside this module's default MainActor isolation.
    nonisolated static let defaultFolder = "TerrierGPT"

    struct Result {
        let noteID: String
        let folder: String
    }

    @discardableResult
    static func createNote(
        title: String,
        html: String,
        folder: String = defaultFolder,
        reveal: Bool = false
    ) async throws -> Result {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleAppsError.emptyContent
        }
        try await ensurePermission()

        // Notes uses the first line of the body as the on-screen title, so we lead the body
        // with an <h1> as well as setting `name`. Setting only `name` leaves a note whose
        // body starts mid-sentence.
        let body = "<h1>\(title.htmlEscaped)</h1>\n\(html)"

        let source = AppleScriptRunner.timed("""
        tell application id "com.apple.Notes"
            set theAccount to default account
            tell theAccount
                if not (exists folder \(folder.appleScriptLiteral)) then
                    make new folder with properties {name:\(folder.appleScriptLiteral)}
                end if
                set theNote to make new note at folder \(folder.appleScriptLiteral) ¬
                    with properties {name:\(title.appleScriptLiteral), body:\(body.appleScriptLiteral)}
            end tell
            \(reveal ? "activate\n            show theNote" : "")
            return (id of theNote) as text
        end tell
        """, seconds: 20)

        let id = try await AppleScriptRunner.runForString(source, appName: appName)
        return Result(noteID: id, folder: folder)
    }

    /// Appends to the most recent note with this title, creating it if there isn't one.
    ///
    /// This is what makes a "running log" note work: ask the same question five times and you
    /// get one note with five entries, not five notes.
    @discardableResult
    static func appendToNote(
        title: String,
        html: String,
        folder: String = defaultFolder
    ) async throws -> Result {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleAppsError.emptyContent
        }
        try await ensurePermission()

        let source = AppleScriptRunner.timed("""
        tell application id "com.apple.Notes"
            set theAccount to default account
            tell theAccount
                if not (exists folder \(folder.appleScriptLiteral)) then
                    make new folder with properties {name:\(folder.appleScriptLiteral)}
                end if
                set theFolder to folder \(folder.appleScriptLiteral)
                set matches to (every note of theFolder whose name is \(title.appleScriptLiteral))
                if (count of matches) is 0 then
                    set theNote to make new note at theFolder ¬
                        with properties {name:\(title.appleScriptLiteral), body:\(("<h1>" + title.htmlEscaped + "</h1>\n" + html).appleScriptLiteral)}
                else
                    set theNote to item 1 of matches
                    set body of theNote to ((body of theNote) & \(html.appleScriptLiteral))
                end if
            end tell
            return (id of theNote) as text
        end tell
        """, seconds: 20)

        let id = try await AppleScriptRunner.runForString(source, appName: appName)
        return Result(noteID: id, folder: folder)
    }

    private static func ensurePermission() async throws {
        switch AutomationPermission.status(bundleIdentifier: bundleID, prompt: true) {
        case .denied: throw AutomationError.permissionDenied(app: appName)
        case .needsPrompt: throw AutomationError.permissionNotGranted(app: appName)
        case .granted, .targetNotRunning, .unknown: return
        }
    }
}

// MARK: - EventKit (Reminders + Calendar)

/// Reminders and Calendar go through EventKit rather than AppleScript.
///
/// EventKit gives a real permission model (a TCC prompt the user can revisit), returns typed
/// errors, and doesn't need the target app to be running — all three things AppleScript gets
/// wrong here. Notes is the exception only because it has no framework.
@MainActor
final class EventKitBridge {

    static let shared = EventKitBridge()

    /// One long-lived store. Creating an `EKEventStore` per call is slow and drops change
    /// notifications.
    private let store = EKEventStore()
    private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "eventkit")

    private init() {}

    // MARK: Permission

    func remindersAccess() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    func calendarAccess() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    private func requireReminders() async throws {
        switch remindersAccess() {
        case .fullAccess:
            return
        case .denied, .writeOnly:
            throw AppleAppsError.accessDenied(app: "Reminders")
        case .restricted:
            throw AppleAppsError.accessRestricted(app: "Reminders")
        default:
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            if !granted { throw AppleAppsError.accessDenied(app: "Reminders") }
        }
    }

    private func requireCalendar() async throws {
        switch calendarAccess() {
        case .fullAccess:
            return
        case .writeOnly:
            // Write-only is all this app needs: it adds events and never reads them back.
            // Falling through to the `default` branch re-prompted for full access on every
            // single save, and refused to file the event when the user declined.
            return
        case .denied:
            throw AppleAppsError.accessDenied(app: "Calendar")
        case .restricted:
            throw AppleAppsError.accessRestricted(app: "Calendar")
        default:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if !granted { throw AppleAppsError.accessDenied(app: "Calendar") }
        }
    }

    // MARK: Reminders

    @discardableResult
    func createReminder(
        title: String,
        notes: String?,
        due: Date?,
        url: URL? = nil,
        listName: String? = nil
    ) async throws -> String {
        try await requireReminders()

        guard let calendar = reminderList(named: listName) else {
            throw AppleAppsError.noDefaultList(app: "Reminders")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.url = url
        reminder.calendar = calendar

        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            // A due date without an alarm never notifies, which reads as a bug to the user.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw AppleAppsError.saveFailed(app: "Reminders", underlying: error.localizedDescription)
        }
        return calendar.title
    }

    private func reminderList(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else { return store.defaultCalendarForNewReminders() }
        let lists = store.calendars(for: .reminder)
        return lists.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            ?? store.defaultCalendarForNewReminders()
    }

    // MARK: Calendar

    @discardableResult
    func createEvent(
        title: String,
        notes: String?,
        start: Date,
        end: Date,
        url: URL? = nil,
        calendarName: String? = nil,
        allDay: Bool = false
    ) async throws -> String {
        try await requireCalendar()

        guard let calendar = eventCalendar(named: calendarName) else {
            throw AppleAppsError.noDefaultList(app: "Calendar")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.url = url
        event.calendar = calendar
        event.isAllDay = allDay
        event.startDate = start
        // Guard against a caller handing us an end before the start; EventKit would throw a
        // less legible error.
        event.endDate = max(end, start.addingTimeInterval(allDay ? 0 : 60))

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw AppleAppsError.saveFailed(app: "Calendar", underlying: error.localizedDescription)
        }
        return calendar.title
    }

    private func eventCalendar(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else { return store.defaultCalendarForNewEvents }
        let calendars = store.calendars(for: .event)
        return calendars.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            ?? store.defaultCalendarForNewEvents
    }

    // MARK: Lists for pickers

    func reminderListNames() -> [String] {
        guard remindersAccess() == .fullAccess else { return [] }
        return store.calendars(for: .reminder).map(\.title).sorted()
    }

    func calendarNames() -> [String] {
        guard calendarAccess() == .fullAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications).map(\.title).sorted()
    }
}
