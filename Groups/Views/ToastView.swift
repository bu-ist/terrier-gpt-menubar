import SwiftUI

/// The floating glass status message.
///
/// Replaces the old inline status strip, which pushed the whole page down by a row every time
/// it appeared and reflowed the chat underneath it.
struct ToastView: View {

    let toast: Toast
    let onAction: (Toast.Action) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: TG.Space.snug) {
            Image(systemName: toast.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.kind.tint)
                .shadow(color: toast.kind.tint.opacity(0.6), radius: 5)
                .symbolEffect(.bounce, value: toast.id)

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            if let title = toast.action.title {
                Button(title) { onAction(toast.action) }
                    .buttonStyle(.glassPill(tint: toast.kind.tint))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, TG.Space.regular)
        .padding(.vertical, TG.Space.snug)
        .frame(maxWidth: 440, alignment: .leading)
        .tgGlass(.rect(cornerRadius: TG.Radius.card, style: .continuous), tint: toast.kind.tint)
        .contentShape(.rect(cornerRadius: TG.Radius.card, style: .continuous))
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .help("Click to dismiss")
    }
}
