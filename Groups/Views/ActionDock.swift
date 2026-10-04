import SwiftUI

/// The floating glass dock along the bottom of the panel.
///
/// One primary action — hand the answer to another assistant — and three quiet "save to"
/// instruments beside it. Everything else (chains, the inbox, raw JSON exports) lives in the
/// header's ⋯ ▸ Automation menu, because it's set up once and rarely touched.
///
/// The save actions are icon-only on purpose: four labelled pills didn't fit at the panel's
/// narrower widths and their words got cut off. Each icon keeps its own tint, a tooltip, and
/// an accessibility label, so nothing is lost but the clutter.
struct ActionDock: View {

    @ObservedObject var coordinator: CaptureCoordinator
    /// Passed in rather than read off `coordinator.webModel`, which is an unobserved weak
    /// reference — the "Append to …" label never refreshed when the page title changed.
    let pageTitle: String

    @Namespace private var glass

    @State private var showReminderSheet = false
    @State private var showEventSheet = false
    @State private var showHandoff = false

    var body: some View {
        GlassEffectContainer(spacing: TG.Space.merge) {
            HStack(spacing: TG.Space.controlGap) {
                Text("Save to")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.trailing, 2)

                notesButton

                Button {
                    showReminderSheet = true
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.glassCircle(tint: TG.ember, id: "reminder", in: glass))
                .popover(isPresented: $showReminderSheet, arrowEdge: .top) {
                    ReminderComposer(coordinator: coordinator, isPresented: $showReminderSheet)
                }
                .help("Reminders — turn the answer into a reminder")
                .accessibilityLabel("Save to Reminders")

                Button {
                    showEventSheet = true
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .buttonStyle(.glassCircle(tint: TG.scarlet, id: "event", in: glass))
                .popover(isPresented: $showEventSheet, arrowEdge: .top) {
                    EventComposer(coordinator: coordinator, isPresented: $showEventSheet)
                }
                .help("Calendar — turn the answer into an event")
                .accessibilityLabel("Save to Calendar")

                Spacer(minLength: TG.Space.snug)

                Button {
                    showHandoff = true
                } label: {
                    Label("Hand off", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.glassPill(tint: TG.jade, prominent: true, id: "handoff", in: glass))
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .help("Send TerrierGPT's answer, with its context, to Claude, Gemini, or Grok (⇧⌘J)")
                .popover(isPresented: $showHandoff, arrowEdge: .top) {
                    HandoffPicker(coordinator: coordinator, isPresented: $showHandoff)
                }
            }
            .padding(.leading, TG.Space.regular + 2)
            .padding(.trailing, TG.Space.snug)
            .padding(.vertical, TG.Space.snug - 2)
        }
        .labelStyle(.titleAndIcon)
        .background {
            // The floor the controls stand on. Recessed: it catches a rim but casts nothing,
            // so the controls above it are unambiguously the raised layer.
            Color.clear.tgGlassTray(.capsule)
        }
        .disabled(coordinator.isWorking)
        .opacity(coordinator.isWorking ? 0.6 : 1)
        .tgAnimation(TG.Motion.snap, value: coordinator.isWorking)
    }

    private var notesButton: some View {
        Menu {
            Button("New note") {
                Task { await coordinator.sendToNotes(append: false) }
            }
            Button("Add to \u{201C}\(noteTitleHint)\u{201D}") {
                Task { await coordinator.sendToNotes(append: true) }
            }
        } label: {
            Image(systemName: "note.text")
        } primaryAction: {
            Task { await coordinator.sendToNotes(append: false) }
        }
        .menuStyle(.button)
        .buttonStyle(.glassCircle(tint: TG.gold, id: "notes", in: glass))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notes — click to save as a new note, hold for more")
        .accessibilityLabel("Save to Notes")
    }

    /// Notes appends by title, so show the user which note they'd be appending to.
    private var noteTitleHint: String {
        let resolved = pageTitle.isEmpty ? "TerrierGPT" : pageTitle
        return resolved.count > 28 ? String(resolved.prefix(28)) + "…" : resolved
    }
}

// MARK: - Handoff picker

/// Asks where the answer should go, then does everything in one click: writes the brief,
/// copies it, and opens the assistant.
///
/// The last choice is remembered and answers to Return, so a habitual handoff is ⇧⌘J, ↩.
private struct HandoffPicker: View {

    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var isPresented: Bool

    @State private var task = ""
    @State private var includeContext = true
    @FocusState private var taskFocused: Bool

    private let last = AITarget.last

    var body: some View {
        VStack(alignment: .leading, spacing: TG.Space.regular) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hand off to…")
                    .font(.system(size: 15, weight: .semibold))
                Text("Your question, context, and TerrierGPT's answer — copied and ready.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: TG.Space.snug) {
                ForEach(AITarget.allCases) { target in
                    TargetCard(target: target, isDefault: target == last) {
                        send(to: target)
                    }
                }
            }

            VStack(alignment: .leading, spacing: TG.Space.tight) {
                Text("What should it do?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(HandoffBrief.defaultTask, text: $task, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...4)
                    .focused($taskFocused)
                    .padding(TG.Space.snug)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: TG.Radius.control, style: .continuous))

                HStack(spacing: TG.Space.tight) {
                    ForEach(HandoffBrief.suggestions.dropFirst(), id: \.label) { suggestion in
                        SuggestionChip(title: suggestion.label, isOn: task == suggestion.task) {
                            task = task == suggestion.task ? "" : suggestion.task
                        }
                    }
                }
            }

            if coordinator.hasContext {
                Toggle(isOn: $includeContext) {
                    Text("Include captured context (\(coordinator.enabledContexts.count))")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            HStack(spacing: 4) {
                Image(systemName: "return")
                Text("sends to \(last.name)")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(TG.Space.loose)
        .frame(width: 400)
        .background {
            // Return goes to the remembered assistant even while typing in the field.
            Button("") { send(to: last) }
                .keyboardShortcut(.defaultAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func send(to target: AITarget) {
        isPresented = false
        let contexts = includeContext ? coordinator.contexts : []
        let task = task
        Task { await coordinator.handOff(to: target, task: task, contexts: contexts) }
    }
}

private struct TargetCard: View {
    let target: AITarget
    let isDefault: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: TG.Space.tight) {
                Image(systemName: target.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(target.tint.gradient, in: .circle)
                    .shadow(color: target.tint.opacity(0.5), radius: hovering ? 8 : 4, y: 2)

                Text(target.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(target.destinationLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, TG.Space.regular)
            .contentShape(.rect(cornerRadius: TG.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .tgGlass(.rect(cornerRadius: TG.Radius.card, style: .continuous), tint: hovering || isDefault ? target.tint : nil)
        .overlay {
            if isDefault {
                RoundedRectangle(cornerRadius: TG.Radius.card, style: .continuous)
                    .strokeBorder(target.tint.opacity(0.8), lineWidth: 1.5)
            }
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .onHover { hovering = $0 }
        .tgAnimation(TG.Motion.snap, value: hovering)
        .help("Copy the handoff and open \(target.name)")
        .accessibilityLabel("Hand off to \(target.name)")
    }
}

private struct SuggestionChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, TG.Space.snug)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(isOn ? AnyShapeStyle(TG.jade.gradient) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Automation menu

/// Chains, the inbox, and raw handoff files: the plumbing for scripted handoffs. Lives under
/// the header's ⋯ menu so the dock can stay about the answer in front of you.
struct AutomationMenu: View {

    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject private var runner = ChainRunner.shared
    @ObservedObject private var inbox = InboxWatcher.shared
    @Binding var showHistory: Bool

    var body: some View {
        Menu {
            let recipes = RecipeStore.load()
            Section("Run a chain") {
                ForEach(recipes.recipes.filter(\.isRunnable)) { recipe in
                    Button {
                        runner.start(recipe, origin: .panel)
                    } label: {
                        Text(recipe.displayTitle)
                        Text(recipe.steps.map(\.label).joined(separator: " → "))
                    }
                }
                ForEach(recipes.errors.keys.sorted(), id: \.self) { file in
                    Button("\(file): \(recipes.errors[file] ?? "")") {}
                        .disabled(true)
                }
            }
            .disabled(runner.isRunning)
            Button("Open recipes folder") {
                NSWorkspace.shared.open(RecipeStore.directory)
            }

            Button("Run history…") { showHistory = true }

            Section("Inbox") {
                Toggle("Watch the inbox", isOn: Binding(
                    get: { inbox.isEnabled },
                    set: { inbox.setEnabled($0) }
                ))
                Toggle("Keep watching when closed", isOn: Binding(
                    get: { inbox.agentInstalled },
                    set: { inbox.setAgentInstalled($0) }
                ))
                Button("Send answer to inbox") {
                    Task { await coordinator.sendHandoffToInbox() }
                }
            }

            Section("JSON handoff") {
                Button("Save answer as JSON") {
                    Task { await coordinator.exportHandoff(contract: nil, copyToClipboard: false) }
                }
                Button("Save and copy JSON") {
                    Task { await coordinator.exportHandoff(contract: nil, copyToClipboard: true) }
                }
                Button("Copy standing instruction") {
                    coordinator.copyStandingInstruction()
                }
                let contracts = HandoffStore.availableContracts()
                if !contracts.isEmpty {
                    Menu("Save a specific contract") {
                        ForEach(contracts, id: \.self) { contract in
                            Button(contract) {
                                Task { await coordinator.exportHandoff(contract: contract, copyToClipboard: false) }
                            }
                        }
                    }
                    Menu("Copy JSON request") {
                        ForEach(contracts, id: \.self) { contract in
                            Button(contract) { coordinator.copyHandoffRequest(contract: contract) }
                        }
                    }
                }
            }

            Section("Folders") {
                Button("Handoffs") {
                    try? FileManager.default.createDirectory(at: HandoffStore.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(HandoffStore.directory)
                }
                Button("Runs") {
                    try? FileManager.default.createDirectory(at: ChainRunner.runsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ChainRunner.runsDirectory)
                }
                Button("Inbox") {
                    try? Inbox.prepare()
                    NSWorkspace.shared.open(Inbox.directory)
                }
            }
        } label: {
            Label("Automation", systemImage: "gearshape.2")
        }
    }
}

// MARK: - Reminder composer

private struct ReminderComposer: View {

    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var isPresented: Bool

    @State private var hasDueDate = true
    @State private var due = Date.nextQuarterHour
    @State private var listName: String = ""
    @State private var lists: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: TG.Space.regular) {
            Text("New reminder")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Remind me", isOn: $hasDueDate.animation(TG.Motion.snap))
                .toggleStyle(.switch)
                .controlSize(.small)

            if hasDueDate {
                DatePicker("", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .transition(.blurReplace)
            }

            if !lists.isEmpty {
                Picker("List", selection: $listName) {
                    Text("Default").tag("")
                    ForEach(lists, id: \.self) { Text($0).tag($0) }
                }
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    isPresented = false
                    Task { await coordinator.sendToReminders(due: hasDueDate ? due : nil, listName: listName.isEmpty ? nil : listName) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(TG.Space.loose)
        .frame(width: 280)
        .task { lists = EventKitBridge.shared.reminderListNames() }
    }
}

// MARK: - Event composer

private struct EventComposer: View {

    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var isPresented: Bool

    @State private var start = Date.nextQuarterHour
    @State private var duration = 30
    @State private var calendarName: String = ""
    @State private var calendars: [String] = []

    private let durations = [15, 30, 45, 60, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: TG.Space.regular) {
            Text("New event")
                .font(.system(size: 13, weight: .semibold))

            DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .controlSize(.small)

            Picker("Length", selection: $duration) {
                ForEach(durations, id: \.self) { Text("\($0) min").tag($0) }
            }
            .controlSize(.small)

            if !calendars.isEmpty {
                Picker("Calendar", selection: $calendarName) {
                    Text("Default").tag("")
                    ForEach(calendars, id: \.self) { Text($0).tag($0) }
                }
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    isPresented = false
                    Task {
                        await coordinator.sendToCalendar(
                            start: start,
                            durationMinutes: duration,
                            calendarName: calendarName.isEmpty ? nil : calendarName
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(TG.Space.loose)
        .frame(width: 300)
        .task { calendars = EventKitBridge.shared.calendarNames() }
    }
}

extension Date {
    /// Rounds forward to the next quarter hour — a saner default than "right now" for
    /// something the user is about to schedule.
    static var nextQuarterHour: Date {
        let calendar = Calendar.current
        let now = Date()
        let minute = calendar.component(.minute, from: now)
        let bump = 15 - (minute % 15)
        return calendar.date(
            bySetting: .second, value: 0,
            of: calendar.date(byAdding: .minute, value: bump, to: now) ?? now
        ) ?? now
    }
}
