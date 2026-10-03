import SwiftUI

/// The session indicator: a glass capsule whose dot reflects the auth phase.
///
/// The old UI was a bare 8pt circle with a tooltip, so the state was invisible unless you
/// hovered. This says it out loud, and the dot's motion carries the meaning even before the
/// label is read: settled when signed in, breathing while connecting.
struct SessionPill: View {

    let phase: SessionPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: TG.Space.tight) {
            dot
            // Signed in is the normal state and doesn't need words; the green dot says it.
            // Anything else is worth a label.
            if phase != .signedIn {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.blurReplace)
                    .id(label)
            }
        }
        .padding(.horizontal, phase == .signedIn ? 0 : TG.Space.snug + 1)
        .padding(.vertical, phase == .signedIn ? 0 : 5)
        .background {
            if phase != .signedIn {
                Color.clear.tgGlass(.capsule, tint: tint)
            }
        }
        .tgAnimation(TG.Motion.morph, value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session status")
        .accessibilityValue(label)
        .help(helpText)
    }

    @ViewBuilder
    private var dot: some View {
        switch phase {
        case .authenticating, .loading:
            // A determinate-looking spinner would lie about progress we don't have; a
            // breathing dot just says "something is happening".
            Circle()
                .fill(tint.gradient)
                .frame(width: 7, height: 7)
                .shadow(color: tint.opacity(0.9), radius: 4)
                .modifier(BreathingDot(active: !reduceMotion))
        case .signedIn, .signedOut:
            Circle()
                .fill(tint.gradient)
                .frame(width: 7, height: 7)
                .shadow(color: tint.opacity(phase == .signedIn ? 0.9 : 0.3), radius: 4)
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.35), lineWidth: 3)
                        .scaleEffect(phase == .signedIn ? 1.9 : 1.0)
                        .opacity(phase == .signedIn ? 0.55 : 0)
                }
        }
    }

    private var tint: Color {
        switch phase {
        case .loading, .signedOut: return TG.idle
        case .authenticating: return TG.working
        case .signedIn: return TG.online
        }
    }

    private var label: String {
        switch phase {
        case .loading: return "Connecting"
        case .signedOut: return "Signed out"
        case .authenticating: return "Signing in"
        case .signedIn: return "Signed in"
        }
    }

    private var helpText: String {
        switch phase {
        case .loading: return "Loading TerrierGPT…"
        case .signedOut: return "Signed out — sign in inside the window if prompted"
        case .authenticating: return "Signing in via BU / Microsoft SSO…"
        case .signedIn: return "Signed in to TerrierGPT"
        }
    }
}

/// A slow scale-and-fade cycle, used only while we're genuinely waiting on the network.
private struct BreathingDot: ViewModifier {
    let active: Bool
    @State private var expanded = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && expanded ? 1.35 : 1.0)
            .opacity(active && expanded ? 0.55 : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(TG.Motion.ambient) { expanded = true }
            }
            .onDisappear { expanded = false }
    }
}

#Preview {
    VStack(spacing: 12) {
        SessionPill(phase: .loading)
        SessionPill(phase: .authenticating)
        SessionPill(phase: .signedIn)
        SessionPill(phase: .signedOut)
    }
    .padding(40)
}
