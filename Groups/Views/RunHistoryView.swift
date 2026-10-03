import SwiftUI
import AppKit

/// Past chain runs, newest first, with what you'd want to do next with each: look at it, take
/// its result, or run it again on the same input.
struct RunHistoryView: View {

    @ObservedObject private var runner = ChainRunner.shared
    @ObservedObject private var inbox = InboxWatcher.shared
    @State private var records: [RunRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: TG.Space.snug) {
            HStack {
                Text("Chain runs")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    records = RunHistory.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload")
                Button("Folder") {
                    try? FileManager.default.createDirectory(at: ChainRunner.runsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ChainRunner.runsDirectory)
                }
                .controlSize(.small)
            }

            if records.isEmpty {
                Text("No runs yet. Start one from ⋯ ▸ Automation, Shortcuts, a terriergpt:// link, or the inbox.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, TG.Space.snug)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TG.Space.tight) {
                        ForEach(records) { record in
                            RunRow(record: record, canRerun: !runner.isRunning)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()
            inboxFooter
        }
        .padding(TG.Space.regular)
        .frame(width: 400)
        .onAppear { records = RunHistory.load() }
        // A run finishing while the popover is open should show up without a manual reload.
        .onChange(of: runner.current?.status.isFinished) { _, finished in
            if finished == true { records = RunHistory.load() }
        }
    }

    private var inboxFooter: some View {
        HStack(spacing: TG.Space.tight) {
            Image(systemName: inbox.isEnabled ? "tray.and.arrow.down.fill" : "tray")
                .foregroundStyle(inbox.isEnabled ? TG.online : .secondary)
            Text(inboxStatus)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Inbox") {
                try? Inbox.prepare()
                NSWorkspace.shared.open(Inbox.directory)
            }
            .controlSize(.small)
        }
    }

    private var inboxStatus: String {
        guard inbox.isEnabled else { return "Inbox off — turn it on in ⋯ ▸ Automation." }
        let when = inbox.agentInstalled ? "even when the app is closed" : "while the app is running"
        return inbox.queued > 0 ? "Inbox: \(inbox.queued) waiting" : "Watching the inbox \(when)."
    }
}

private struct RunRow: View {
    let record: RunRecord
    let canRerun: Bool

    var body: some View {
        HStack(alignment: .top, spacing: TG.Space.snug) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = record.error, !record.succeeded {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(TG.scarletSoft)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: TG.Space.tight)

            Menu {
                if record.succeeded, record.resultText() != nil {
                    Button("Copy result") {
                        if let text = record.resultText() {
                            ClipboardPrompt.write(text)
                            CaptureCoordinator.shared.show(Toast(kind: .success, title: "Result copied"))
                        }
                    }
                }
                Button("Run again on the same input") { rerun() }
                    .disabled(!canRerun || !FileManager.default.fileExists(atPath: record.input.path))
                Button("Send result to inbox") { sendToInbox() }
                    .disabled(!record.succeeded || record.output == nil)
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([record.output ?? record.directory])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, TG.Space.tight)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: TG.Radius.control, style: .continuous))
    }

    private func rerun() {
        guard let recipe = RecipeStore.recipe(named: record.recipe) else {
            CaptureCoordinator.shared.show(Toast(
                kind: .failure,
                title: ChainError.unknownRecipe(record.recipe).errorDescription ?? "Unknown recipe"
            ))
            return
        }
        ChainRunner.shared.start(recipe, input: .file(record.input), origin: .history)
    }

    private func sendToInbox() {
        guard let output = record.output else { return }
        do {
            let dropped = try Inbox.drop(output, from: record.recipe, hops: Inbox.hops(in: record.input) + 1)
            CaptureCoordinator.shared.show(Toast(kind: .success, title: "Sent to inbox", detail: dropped.lastPathComponent))
        } catch {
            CaptureCoordinator.shared.show(Toast(kind: .failure, title: "Couldn't send to inbox", detail: error.localizedDescription))
        }
    }

    private var symbol: String {
        switch record.status {
        case "succeeded": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "cancelled": return "stop.circle"
        default: return "circle.dotted"
        }
    }

    private var tint: Color {
        switch record.status {
        case "succeeded": return TG.online
        case "failed": return TG.scarletSoft
        default: return .secondary
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let started = record.startedAt {
            parts.append(started.formatted(.relative(presentation: .named)))
        }
        parts.append(record.origin)
        if let seconds = record.seconds { parts.append("\(Int(seconds))s") }
        if record.costUSD > 0 { parts.append(String(format: "$%.3f", record.costUSD)) }
        return parts.joined(separator: " · ")
    }
}
