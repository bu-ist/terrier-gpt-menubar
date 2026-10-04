import SwiftUI
import AppKit

/// The Recipes gallery: the working group's skill chains as cards you can start, schedule,
/// or hand off.
///
/// Each card answers three questions in order — what is it (the skill chain), where should
/// it run (the advice line), and how do I start it (one primary button; the rest in the
/// expanded card). Recipes are JSON files, so the gallery is whatever is in the folder.
struct RecipesView: View {

    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var isPresented: Bool

    @State private var loaded = RecipeStore.Loaded(recipes: [], errors: [:])
    @State private var shelf = "All"
    @State private var expanded: String?
    @State private var shortcuts: Set<String> = []

    private static let shelfOrder = ["Daily", "Weekly", "Tickets", "Knowledge", "Career", "Hosts", "Answer"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, TG.Space.loose)
                .padding(.top, TG.Space.loose)
                .padding(.bottom, TG.Space.snug)

            shelves
                .padding(.bottom, TG.Space.snug)

            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(spacing: TG.Space.snug) {
                    ForEach(visible) { recipe in
                        RecipeCard(
                            recipe: recipe,
                            coordinator: coordinator,
                            isExpanded: expanded == recipe.name,
                            shortcutExists: recipe.shortcut.map(shortcuts.contains) ?? false,
                            onToggle: {
                                withAnimation(TG.Motion.morph) {
                                    expanded = expanded == recipe.name ? nil : recipe.name
                                }
                            },
                            dismiss: { isPresented = false }
                        )
                    }
                    ForEach(loaded.errors.keys.sorted(), id: \.self) { file in
                        Label("\(file): \(loaded.errors[file] ?? "")", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(TG.scarletSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(TG.Space.regular)
            }
        }
        .frame(width: 480, height: 620)
        .task {
            loaded = RecipeStore.load()
            shortcuts = await Self.installedShortcuts()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recipes")
                    .font(.system(size: 17, weight: .bold))
                Text("Working-group skills, already chained.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(RecipeStore.directory)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open the recipes folder — each recipe is a JSON file")
        }
    }

    private var shelves: some View {
        ScrollView(.horizontal) {
            HStack(spacing: TG.Space.tight) {
                ForEach(["All"] + presentShelves, id: \.self) { name in
                    Button {
                        withAnimation(TG.Motion.snap) { shelf = name }
                    } label: {
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, TG.Space.snug)
                            .padding(.vertical, 5)
                            .foregroundStyle(shelf == name ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(
                                shelf == name ? AnyShapeStyle(TG.violet.gradient) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, TG.Space.loose)
        }
        .scrollIndicators(.never)
    }

    private var presentShelves: [String] {
        let names = Set(loaded.recipes.map(Self.shelf(of:)))
        return Self.shelfOrder.filter(names.contains) + names.subtracting(Self.shelfOrder).sorted()
    }

    private var visible: [Recipe] {
        let filtered = shelf == "All" ? loaded.recipes : loaded.recipes.filter { Self.shelf(of: $0) == shelf }
        return filtered.sorted {
            let a = Self.shelfOrder.firstIndex(of: Self.shelf(of: $0)) ?? .max
            let b = Self.shelfOrder.firstIndex(of: Self.shelf(of: $1)) ?? .max
            return a == b ? $0.displayTitle < $1.displayTitle : a < b
        }
    }

    nonisolated static func shelf(of recipe: Recipe) -> String { recipe.category ?? "Answer" }

    /// Names from `shortcuts list`, so a card can offer its Shortcut only when it exists.
    private static func installedShortcuts() async -> Set<String> {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        }.value
    }
}

// MARK: - Card

private struct RecipeCard: View {

    let recipe: Recipe
    @ObservedObject var coordinator: CaptureCoordinator
    let isExpanded: Bool
    let shortcutExists: Bool
    let onToggle: () -> Void
    let dismiss: () -> Void

    @ObservedObject private var scheduler = RecipeScheduler.shared
    @ObservedObject private var runner = ChainRunner.shared
    @State private var hovering = false

    private var place: Recipe.Advice.Place { recipe.advice?.place ?? (recipe.isRunnable ? .mac : .terriergpt) }

    var body: some View {
        VStack(alignment: .leading, spacing: TG.Space.snug) {
            HStack(alignment: .top, spacing: TG.Space.snug) {
                Image(systemName: recipe.icon ?? "square.stack.3d.up.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(place.tint.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                    .shadow(color: place.tint.opacity(0.4), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: TG.Space.tight) {
                        Text(recipe.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if scheduler.isEnabled(recipe), let schedule = recipe.schedule {
                            Label(schedule.label, systemImage: "clock.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(TG.jade)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    if let description = recipe.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                primaryButton
            }

            if let skills = recipe.skills, !skills.isEmpty {
                SkillChain(skills: skills, tint: place.tint)
            }

            adviceLine

            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(TG.Space.regular)
        .tgGlassTray(.rect(cornerRadius: TG.Radius.card, style: .continuous), tint: hovering || isExpanded ? place.tint : nil)
        .contentShape(.rect(cornerRadius: TG.Radius.card, style: .continuous))
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .tgAnimation(TG.Motion.snap, value: hovering)
    }

    // MARK: Primary action

    @ViewBuilder
    private var primaryButton: some View {
        switch place {
        case .terriergpt:
            Button("Ask") { askTerrierGPT() }
                .buttonStyle(.glassPill(tint: TG.scarlet, prominent: true))
                .help("Copy the prompt and switch to the right TerrierGPT")
        case .claude, .grok, .gemini:
            let target = place.aiTarget ?? .claude
            Button("Open") { handOff(to: target) }
                .buttonStyle(.glassPill(tint: target.tint, prominent: true))
                .help("Hand this recipe to \(target.name)")
        case .mac, .copilot:
            if recipe.isRunnable {
                Button {
                    run()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.glassPill(tint: TG.jade, prominent: true))
                .disabled(runner.isRunning)
                .help(recipe.input?.from == .page ? "Runs on the TerrierGPT answer in front of you" : "Runs on this Mac")
            }
        }
    }

    // MARK: Advice

    private var adviceLine: some View {
        HStack(spacing: 5) {
            Image(systemName: place.symbol)
                .foregroundStyle(place.tint)
            Text(adviceText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let then = recipe.advice?.then, then != place {
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(then.title)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .help(recipe.advice?.why ?? "")
    }

    private var adviceText: String {
        var bits = ["Best in \(place.title)"]
        if let agent = recipe.advice?.agent { bits.append(agent) }
        if let model = recipe.advice?.model { bits.append(model) }
        if let effort = recipe.advice?.effort { bits.append("\(effort) effort") }
        return bits.joined(separator: " · ")
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: TG.Space.snug) {
            if let why = recipe.advice?.why {
                Label {
                    Text(why).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(TG.gold)
                }
            }
            if let stop = recipe.stopsBefore {
                Label {
                    Text("Stops before \(stop).").fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(TG.ember)
                }
            }

            Divider().opacity(0.4)

            Text("Start it")
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.tertiary)

            if place == .terriergpt && recipe.isRunnable {
                StartRow(icon: "2.circle.fill", title: "Then run the chain", detail: "On the answer TerrierGPT gives you") {
                    Button("Run") { run() }.disabled(runner.isRunning)
                }
            }

            if let schedule = recipe.schedule, recipe.isSchedulable {
                StartRow(icon: "clock.fill", title: "On a schedule", detail: scheduleDetail(schedule)) {
                    Toggle("", isOn: Binding(
                        get: { scheduler.isEnabled(recipe) },
                        set: { scheduler.setEnabled($0, for: recipe) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
            }

            if let shortcut = recipe.shortcut {
                StartRow(icon: "square.stack.3d.forward.dottedline.fill", title: "Shortcut", detail: shortcutExists ? "\u{201C}\(shortcut)\u{201D}" : "\u{201C}\(shortcut)\u{201D} isn't in your library") {
                    if shortcutExists {
                        Button("Run") { Self.runShortcut(shortcut) }
                    }
                }
            }

            if recipe.isRunnable {
                StartRow(icon: "terminal.fill", title: "Script or AppleScript", detail: "open \"terriergpt://run?recipe=\(recipe.name)\"") {
                    Button("Copy") {
                        ClipboardPrompt.write("open \"terriergpt://run?recipe=\(recipe.name)\"")
                        coordinator.show(Toast(kind: .success, title: "Command copied", detail: "The app asks before a link starts a chain."))
                    }
                }
            }

            StartRow(icon: "cloud.fill", title: "Cloud schedulers", detail: cloudTip) { EmptyView() }

            HStack(spacing: TG.Space.tight) {
                Text("Hand off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(AITarget.allCases) { target in
                    Button {
                        handOff(to: target)
                    } label: {
                        Image(systemName: target.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(target.tint.gradient, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Hand this recipe\(hasResult ? " and its last result" : "") to \(target.name)")
                }
                Spacer()
                if recipe.prompt != nil, place != .terriergpt {
                    Button("Ask TerrierGPT instead") { askTerrierGPT() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
        }
        .font(.system(size: 11))
        .labelStyle(.titleAndIcon)
    }

    private var hasResult: Bool {
        guard let run = runner.current else { return false }
        return run.recipe.name == recipe.name && run.status == .succeeded
    }

    private func scheduleDetail(_ schedule: Recipe.Schedule) -> String {
        if let next = scheduler.nextRun(of: recipe) {
            return "\(schedule.label) · next \(next.formatted(.relative(presentation: .named)))"
        }
        return "Suggested: \(schedule.label). Runs in the app, not launchd."
    }

    private var cloudTip: String {
        switch place {
        case .mac:
            return "Not for this one — Claude routines and Grok Tasks can't see your Mac's Mail or files."
        case .terriergpt:
            return "Needs you in the chat. Pair it with a Reminder instead."
        case .claude:
            return "Claude Desktop scheduled tasks can repeat the prompt if it needs no local files."
        case .grok:
            return "Grok Tasks can repeat the prompt on a schedule if it needs no local files."
        case .gemini, .copilot:
            return "Use that app's own scheduled prompts if it needs no local files."
        }
    }

    // MARK: Actions

    private func run() {
        dismiss()
        runner.start(recipe, origin: .panel)
    }

    private func askTerrierGPT() {
        dismiss()
        coordinator.startInTerrierGPT(recipe)
    }

    private func handOff(to target: AITarget) {
        dismiss()
        Task { await coordinator.handOff(recipe, to: target) }
    }

    private static func runShortcut(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try? process.run()
        CaptureCoordinator.shared.show(Toast(kind: .info, title: "Running \u{201C}\(name)\u{201D}", detail: "Shortcuts reports its own result."))
    }
}

// MARK: - Small pieces

private struct StartRow<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: TG.Space.snug) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: TG.Space.tight)
            accessory()
                .controlSize(.small)
        }
    }
}

/// The skills a recipe strings together, as chips joined by arrows, wrapping as needed.
private struct SkillChain: View {
    let skills: [String]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(skills.enumerated()), id: \.offset) { index, skill in
                HStack(spacing: 4) {
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(skill)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.16), in: .capsule)
                        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Place presentation

extension Recipe.Advice.Place {
    var title: String {
        switch self {
        case .terriergpt: return "TerrierGPT"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        case .mac: return "your Mac"
        }
    }

    var symbol: String {
        switch self {
        case .terriergpt: return "sparkles"
        case .mac: return "desktopcomputer"
        case .copilot: return "envelope.fill"
        case .claude, .grok, .gemini: return aiTarget?.symbol ?? "sparkle"
        }
    }

    var tint: Color {
        switch self {
        case .terriergpt: return TG.scarlet
        case .mac: return TG.jade
        case .copilot: return TG.surf
        case .claude, .grok, .gemini: return aiTarget?.tint ?? TG.violet
        }
    }

    var aiTarget: AITarget? {
        switch self {
        case .claude: return .claude
        case .grok: return .grok
        case .gemini: return .gemini
        default: return nil
        }
    }
}
