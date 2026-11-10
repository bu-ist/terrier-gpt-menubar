import Foundation
import EventKit
import Combine
import OSLog

/// Watches a Reminders list named "TerrierGPT" and turns each new incomplete item into a
/// queued prompt in the panel.
///
/// Round-trip for the file-out path: capture → Reminders is already built; this closes the
/// loop the other way. Opt-in via the Automation menu so a busy Reminders database never
/// surprises the user. Processed items get a `terriergpt://` URL stamped on them so they
/// are not re-queued after a restart.
@MainActor
final class ReminderPromptWatcher: ObservableObject {

    static let shared = ReminderPromptWatcher()

    static let listName = "TerrierGPT"
    private static let processedURLScheme = "terriergpt-queued"

    @Published private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.enabled)

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "reminder-watch")

    private enum Keys {
        static let enabled = "ReminderPromptWatcherEnabled"
    }

    private init() {}

    func startIfEnabled() {
        guard isEnabled else { return }
        Task { await beginWatching() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled {
            Task { await beginWatching() }
        } else {
            stopWatching()
        }
    }

    private func beginWatching() async {
        do {
            try await requireAccess()
        } catch {
            log.error("Reminders access denied for watcher: \(error.localizedDescription, privacy: .public)")
            CaptureCoordinator.shared.show(Toast(
                kind: .failure,
                title: "Can't watch Reminders",
                detail: error.localizedDescription,
                action: .openPrivacyPane("Privacy_Reminders")
            ))
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.enabled)
            return
        }

        ensureListExists()
        stopWatching()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSweep()
        }
        scheduleSweep()
        log.info("Watching Reminders list \"\(Self.listName)\"")
    }

    private func stopWatching() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleSweep() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await sweep()
        }
    }

    private func sweep() async {
        guard let calendar = reminderList() else { return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: [calendar]
        )
        let reminders = await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder], Never>) in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items ?? [])
            }
        }

        for reminder in reminders {
            if let url = reminder.url, url.scheme == Self.processedURLScheme { continue }
            let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt: String
            if title.isEmpty && notes.isEmpty {
                continue
            } else if notes.isEmpty {
                prompt = title
            } else if title.isEmpty {
                prompt = notes
            } else {
                prompt = "\(title)\n\n\(notes)"
            }

            reminder.url = URL(string: "\(Self.processedURLScheme)://\(reminder.calendarItemIdentifier)")
            do {
                try store.save(reminder, commit: true)
            } catch {
                log.error("Could not mark reminder processed: \(error.localizedDescription, privacy: .public)")
                continue
            }

            // ask() already toasts and focuses the chat. One reminder per sweep so a flooded
            // list doesn't stack panels.
            CaptureCoordinator.shared.ask(prompt: prompt, instance: nil)
            break
        }
    }

    private func requireAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .denied, .writeOnly, .restricted:
            throw AppleAppsError.accessDenied(app: "Reminders")
        default:
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            if !granted { throw AppleAppsError.accessDenied(app: "Reminders") }
        }
    }

    @discardableResult
    private func ensureListExists() -> EKCalendar? {
        if let existing = reminderList() { return existing }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = Self.listName
        if let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .local }) {
            calendar.source = source
        }
        do {
            try store.saveCalendar(calendar, commit: true)
            return calendar
        } catch {
            log.error("Could not create \(Self.listName) list: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func reminderList() -> EKCalendar? {
        store.calendars(for: .reminder).first {
            $0.title.caseInsensitiveCompare(Self.listName) == .orderedSame
        }
    }
}
