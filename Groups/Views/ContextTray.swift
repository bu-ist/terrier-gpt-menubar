import SwiftUI

/// The row of captured-context chips between the header and the page.
///
/// Every chip is a glass capsule inside one `GlassEffectContainer`, so adding or removing a
/// capture makes the surrounding glass flow around it rather than popping. Tapping a chip
/// toggles whether it's folded into the prompt; the dimmed state is the "off" state.
struct ContextTray: View {

    @ObservedObject var coordinator: CaptureCoordinator
    @Namespace private var glass

    var body: some View {
        if !coordinator.contexts.isEmpty {
            VStack(alignment: .leading, spacing: TG.Space.tight) {
                header

                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: TG.Space.merge) {
                        HStack(spacing: TG.Space.controlGap) {
                            ForEach(coordinator.contexts) { context in
                                ContextChip(
                                    context: context,
                                    onToggle: { coordinator.toggle(context) },
                                    onRemove: { coordinator.remove(context) }
                                )
                                .glassEffectID(context.id, in: glass)
                            }
                        }
                        .padding(.horizontal, TG.Space.regular)
                        .padding(.vertical, TG.Space.tight)
                    }
                }
                .scrollIndicators(.never)
                .scrollClipDisabled()
            }
            .padding(.bottom, TG.Space.tight)
            .transition(.asymmetric(
                insertion: .push(from: .top).combined(with: .opacity),
                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
            ))
            .tgAnimation(TG.Motion.morph, value: coordinator.contexts)
        }
    }

    private var header: some View {
        HStack(spacing: TG.Space.tight) {
            Text("Context")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TG.scarletSoft)
                .textCase(.uppercase)
                .kerning(0.8)

            Text("\(coordinator.enabledContexts.count) of \(coordinator.contexts.count) in prompt")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())

            Spacer()

            // Lives with the captures it copies, not in the dock: with nothing captured it
            // would only copy the default instruction.
            Button {
                coordinator.copyPrompt()
            } label: {
                Label("Copy prompt", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TG.violet)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy your instruction plus every included capture, to paste into the chat (⇧⌘C)")

            Button("Clear") { coordinator.clearContexts() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Remove every capture")
        }
        .padding(.horizontal, TG.Space.regular + TG.Space.tight)
    }
}

/// One capture, rendered as a tinted glass capsule.
private struct ContextChip: View {

    let context: CapturedContext
    let onToggle: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: TG.Space.tight) {
            Image(systemName: context.isEnabled ? context.source.symbol : "circle.dashed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(context.isEnabled ? context.source.tint : .secondary)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(context.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let detail = context.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 160, alignment: .leading)

            // The remove button only takes up room once the pointer is over the chip, so a
            // full tray still reads as content rather than as a row of close boxes.
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Remove this capture")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, TG.Space.snug + 2)
        .padding(.vertical, TG.Space.tight + 1)
        // An excluded chip keeps its shape but loses its tint and its glow, so "in the
        // prompt" and "not in the prompt" differ in colour rather than only in opacity.
        .tgGlass(.capsule, tint: context.isEnabled ? context.source.tint : nil)
        .opacity(context.isEnabled ? 1 : 0.55)
        .saturation(context.isEnabled ? 1 : 0)
        .contentShape(.capsule)
        .onTapGesture(perform: onToggle)
        .onHover { hovering in
            withAnimation(TG.Motion.snap) { isHovering = hovering }
        }
        .tgAnimation(TG.Motion.snap, value: context.isEnabled)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(context.source.label): \(context.title)")
        .accessibilityValue(context.isEnabled ? "Included in prompt" : "Excluded from prompt")
        .accessibilityAddTraits(.isButton)
    }

    private var helpText: String {
        var lines = ["\(context.source.label) · \(context.characterCount) characters"]
        if let partial = context.partial { lines.append(partial) }
        lines.append(context.isEnabled ? "Click to exclude from the prompt" : "Click to include in the prompt")
        return lines.joined(separator: "\n")
    }
}
