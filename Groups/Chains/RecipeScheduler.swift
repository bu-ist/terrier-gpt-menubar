import Foundation
import Combine

/// Runs scheduled recipes from inside the app.
///
/// Why not launchd: a job launchd starts as bare `/bin/bash` isn't allowed into ~/Documents,
/// where the WG clone and the overlay live, so it dies with "Operation not permitted". The
/// app asks for that access once and keeps it, and it already runs at login.
///
/// A recipe's `schedule` is only a suggestion. Nothing runs until the user switches it on in
/// the Recipes gallery; that switch is the consent an unattended run needs. Steps with a
/// `confirm` still stop and ask.
///
/// If the Mac was asleep or the app closed at the scheduled time, the run happens on the next
/// check, as long as that's within `catchUpWindow`. A brief from three days ago is noise.
@MainActor
final class RecipeScheduler: ObservableObject {

    static let shared = RecipeScheduler()

    @Published private(set) var enabled: Set<String>

    private static let enabledKey = "RecipeSchedulesEnabled"
    private static let lastRunKey = "RecipeScheduleLastRun"
    private static let catchUpWindow: TimeInterval = 2 * 60 * 60

    private var timer: Timer?
    /// A scheduled run is between "started" and "finished".
    private var launching = false
    /// When the current stretch of back-to-back scheduled runs began.
    private var queueBusySince: Date?

    private init() {
        enabled = Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in RecipeScheduler.shared.tick() }
        }
        // .common, so an open menu or popover doesn't pause the clock.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func isEnabled(_ recipe: Recipe) -> Bool { enabled.contains(recipe.name) }

    func setEnabled(_ on: Bool, for recipe: Recipe) {
        if on {
            enabled.insert(recipe.name)
            // Count from now, so switching it on at 10:00 doesn't fire this morning's 08:00.
            markRun(recipe.name, at: Date())
        } else {
            enabled.remove(recipe.name)
        }
        UserDefaults.standard.set(Array(enabled).sorted(), forKey: Self.enabledKey)
    }

    /// When the recipe will run next, if it's switched on.
    func nextRun(of recipe: Recipe, after date: Date = Date()) -> Date? {
        guard isEnabled(recipe), recipe.isSchedulable, let schedule = recipe.schedule else { return nil }
        return Self.occurrence(of: schedule, searching: .forward, from: date)
    }

    // MARK: - The check

    private func tick() {
        guard !enabled.isEmpty, !launching, !ChainRunner.shared.isRunning else { return }
        let now = Date()
        for recipe in RecipeStore.load().recipes where enabled.contains(recipe.name) && recipe.isSchedulable {
            guard let schedule = recipe.schedule,
                  let due = Self.occurrence(of: schedule, searching: .backward, from: now),
                  due > lastRun(recipe.name),
                  isFresh(due, now: now)
            else { continue }
            launch(recipe, at: now)
            // One at a time: the runner holds a single run, and the next tick picks up the rest.
            return
        }
        // Nothing left waiting, so the queue is genuinely free again.
        queueBusySince = nil
    }

    /// Within the catch-up window — or due while an earlier scheduled run held the runner, so
    /// a long Tuesday ingest doesn't cost the next recipe its turn.
    private func isFresh(_ due: Date, now: Date) -> Bool {
        if now.timeIntervalSince(due) < Self.catchUpWindow { return true }
        if let busySince = queueBusySince, due >= busySince.addingTimeInterval(-Self.catchUpWindow) { return true }
        return false
    }

    /// Marks the run up front so the next tick can't start it twice, and takes the mark back
    /// if the runner refused (another chain started in between), so the day isn't lost.
    private func launch(_ recipe: Recipe, at now: Date) {
        let previous = lastRun(recipe.name)
        markRun(recipe.name, at: now)
        launching = true
        if queueBusySince == nil { queueBusySince = now }
        Task { @MainActor in
            let run = await ChainRunner.shared.run(recipe, origin: .schedule)
            self.launching = false
            if run == nil { self.markRun(recipe.name, at: previous) }
        }
    }

    private func lastRun(_ name: String) -> Date {
        let all = UserDefaults.standard.dictionary(forKey: Self.lastRunKey) as? [String: Date] ?? [:]
        return all[name] ?? .distantPast
    }

    private func markRun(_ name: String, at date: Date) {
        var all = UserDefaults.standard.dictionary(forKey: Self.lastRunKey) as? [String: Date] ?? [:]
        all[name] = date
        UserDefaults.standard.set(all, forKey: Self.lastRunKey)
    }

    // MARK: - Calendar math

    private enum Direction { case forward, backward }

    /// The nearest scheduled moment at or before (backward) / after (forward) `date`.
    private static func occurrence(of schedule: Recipe.Schedule, searching direction: Direction, from date: Date) -> Date? {
        let calendar = Calendar.current
        let days = Set(schedule.weekdays ?? [])
        for offset in 0...8 {
            let dayOffset = direction == .forward ? offset : -offset
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date),
                  let candidate = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: day)
            else { continue }
            // Calendar weekday: Sunday = 1. Schedules use ISO: Monday = 1 … Sunday = 7.
            let iso = (calendar.component(.weekday, from: candidate) + 5) % 7 + 1
            guard days.isEmpty || days.contains(iso) else { continue }
            switch direction {
            case .forward where candidate > date: return candidate
            case .backward where candidate <= date: return candidate
            default: continue
            }
        }
        return nil
    }
}
