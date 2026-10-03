import SwiftUI
import AppKit

/// The running (or last) chain, just above the dock: one chip per step, then what to do with
/// the result. Stays after the run finishes — unlike the toast — because the result is the
/// thing the user started the chain for.
struct RunStrip: View {

    @ObservedObject var runner: ChainRunner
    let run: ChainRunner.Run

    var body: some View {
        HStack(spacing: TG.Space.snug) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: TG.Space.tight) {
                    statusIcon
                    Text(run.recipe.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    ForEach(Array(zip(run.recipe.steps, run.steps).enumerated()), id: \.offset) { index, pair in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        StepChip(step: pair.0, status: pair.1)
                    }
                }
                if let line = detailLine {
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: TG.Space.snug)

            actions
        }
        .padding(.horizontal, TG.Space.regular)
        .padding(.vertical, TG.Space.snug)
        .tgGlassTray(.rect(cornerRadius: TG.Radius.card, style: .continuous), tint: tint)
        .tgAnimation(TG.Motion.snap, value: run.steps)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusIcon: some View {
        switch run.status {
        case .preparing, .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(TG.online)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TG.scarletSoft)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if run.status.isFinished {
            HStack(spacing: TG.Space.tight) {
                if run.status == .succeeded, let text = run.outputPayloadJSON ?? run.outputText {
                    Button("Copy result") {
                        ClipboardPrompt.write(text)
                        CaptureCoordinator.shared.show(Toast(kind: .success, title: "Result copied"))
                    }
                    .help("Copy the last step's output (JSON if it produced any, else its text)")
                }
                Button("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([run.outputURL ?? run.directory])
                }
                .help("Show this run's files in Finder")
                Button {
                    runner.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss")
            }
            .controlSize(.small)
        } else {
            Button("Cancel", role: .cancel) { runner.cancel() }
                .controlSize(.small)
                .help("Stop the chain; the step that's running is terminated")
        }
    }

    private var detailLine: String? {
        switch run.status {
        case .failed(let message): return message
        case .succeeded: return run.notes.first ?? ChainRunner.costLine(run)
        case .preparing: return "Reading TerrierGPT…"
        case .running, .cancelled: return nil
        }
    }

    private var tint: Color? {
        switch run.status {
        case .failed: return TG.scarlet
        case .succeeded: return TG.jade
        default: return TG.violet
        }
    }
}

private struct StepChip: View {
    let step: Recipe.Step
    let status: ChainRunner.StepStatus

    var body: some View {
        HStack(spacing: 3) {
            symbol
            Text(step.label)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(isActive ? 1 : 0.5), in: .capsule)
        .help(help)
    }

    private var isActive: Bool {
        switch status {
        case .running, .awaitingConfirmation: return true
        default: return false
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .awaitingConfirmation: Image(systemName: "hand.raised.fill").foregroundStyle(TG.gold)
        case .running: ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .done: Image(systemName: "checkmark").foregroundStyle(TG.online)
        case .failed: Image(systemName: "xmark").foregroundStyle(TG.scarletSoft)
        case .skipped: Image(systemName: "minus").foregroundStyle(.tertiary)
        }
    }

    private var help: String {
        switch status {
        case .pending: return "\(step.id): waiting"
        case .awaitingConfirmation: return "\(step.id): waiting for your OK"
        case .running(let since): return "\(step.id): running since \(since.formatted(date: .omitted, time: .standard))"
        case .done(let seconds, let cost):
            return "\(step.id): \(Int(seconds))s" + (cost.map { String(format: " · $%.3f", $0) } ?? "")
        case .failed(let message): return "\(step.id): \(message)"
        case .skipped: return "\(step.id): skipped"
        }
    }
}
