import SwiftUI

/// A slow, very low-contrast mesh gradient behind the panel's glass.
///
/// Liquid Glass is a *lensing* material: it has almost nothing to show unless something is
/// moving behind it. This gives the chrome something to refract in the margins around the
/// page, which is what keeps the header and dock from looking like flat grey bars.
///
/// It is deliberately faint, and it stops entirely under Reduce Motion — an animated
/// background is exactly the kind of thing that setting exists to switch off.
struct AmbientBackdrop: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceMotion {
            mesh(phase: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: false)) { context in
                // 1/20s is plenty for something this slow and this faint, and it keeps the
                // panel from spending a display-link's worth of work on decoration.
                mesh(phase: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func mesh(phase: TimeInterval) -> some View {
        // Three incommensurable periods, so the field never visibly repeats.
        let drift = Float(sin(phase / 7)) * 0.09
        let drift2 = Float(cos(phase / 11)) * 0.09
        let drift3 = Float(sin(phase / 17)) * 0.06

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5 + drift, 0), .init(1, 0),
                .init(0, 0.5 - drift2), .init(0.5 + drift2, 0.5 + drift), .init(1, 0.5 + drift2),
                .init(0, 1), .init(0.5 - drift, 1 ), .init(1, 1),
            ],
            colors: colors(shift: drift3)
        )
        .opacity(colorScheme == .dark ? 0.70 : 0.42)
        .ignoresSafeArea()
    }

    /// Scarlet leads, but a lone hue gives glass nothing to separate: the rim of a control
    /// over a flat red field refracts red and disappears. The warm/cool neighbours are what
    /// make the header and dock edges pick out a colour of their own as they drift.
    private func colors(shift: Float) -> [Color] {
        let wander = Double(shift)

        if colorScheme == .dark {
            return [
                .black,                                   TG.scarlet.opacity(0.30 + wander),  .black,
                TG.violet.opacity(0.16 + wander),         .black,                             TG.ember.opacity(0.22 - wander),
                TG.azure.opacity(0.12 - wander),          TG.scarlet.opacity(0.16),           .black,
            ]
        }
        return [
            .white,                                       TG.scarlet.opacity(0.14 + wander),  .white,
            TG.violet.opacity(0.08 + wander),             .white,                             TG.ember.opacity(0.10 - wander),
            TG.surf.opacity(0.07 - wander),               TG.scarlet.opacity(0.07),           .white,
        ]
    }
}
