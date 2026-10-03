import SwiftUI

/// Design tokens and materials for the macOS 27 "Liquid Glass" chrome.
///
/// Everything visual in the panel pulls from here so the whole surface reads as one
/// material: same corner geometry, same spring, same tint ramp, same way of catching light.
nonisolated enum TG {

    // MARK: - Palette

    /// BU scarlet, the app's primary accent. Used as a glass *tint*, never as a flat fill.
    static let scarlet = Color(red: 0.80, green: 0.04, blue: 0.13)
    static let scarletSoft = Color(red: 0.95, green: 0.29, blue: 0.31)

    /// Secondary accents. Each "file it somewhere" action owns one, so the dock reads as a
    /// row of distinct instruments rather than four copies of the same button.
    static let ember = Color(red: 1.00, green: 0.47, blue: 0.20)
    static let gold = Color(red: 1.00, green: 0.74, blue: 0.22)
    static let jade = Color(red: 0.13, green: 0.80, blue: 0.52)
    static let azure = Color(red: 0.20, green: 0.54, blue: 1.00)
    static let surf = Color(red: 0.18, green: 0.80, blue: 0.93)
    static let violet = Color(red: 0.56, green: 0.36, blue: 0.98)
    static let graphite = Color(red: 0.55, green: 0.58, blue: 0.65)

    // Status colors, named by meaning rather than by hue.
    static let online = jade
    static let working = ember
    static let idle = graphite

    // MARK: - Geometry

    /// Concentric radii: the panel's outer shell, cards inside it, and controls inside those.
    nonisolated enum Radius {
        static let shell: CGFloat = 22
        static let card: CGFloat = 18
        static let tray: CGFloat = 20
        static let control: CGFloat = 12
    }

    nonisolated enum Space {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let regular: CGFloat = 14
        static let loose: CGFloat = 20

        /// Distance at which two glass shapes in a `GlassEffectContainer` fuse into one blob.
        ///
        /// This is the whole reason the old dock looked welded together: the containers asked
        /// for a 14–16pt merge radius while the stacks inside them sat only 6–10pt apart, so
        /// every neighbouring control was inside its neighbour's merge field. Keeping the merge
        /// distance well *below* the smallest layout gap is what makes each control read as its
        /// own piece of glass.
        static let merge: CGFloat = 2

        /// The smallest gap any two glass controls may sit at. Comfortably above `merge`.
        static let controlGap: CGFloat = 10
    }

    // MARK: - Motion

    /// One spring vocabulary, so nothing in the panel moves "differently" from anything else.
    nonisolated enum Motion {
        /// Controls reacting to a direct hit: presses, toggles, chip taps.
        static let snap = Animation.spring(response: 0.26, dampingFraction: 0.72)
        /// Layout changes: trays opening, glass shapes appearing and leaving.
        static let morph = Animation.spring(response: 0.42, dampingFraction: 0.80)
        /// Things arriving or leaving on their own: toasts, status lines.
        static let drift = Animation.spring(response: 0.55, dampingFraction: 0.86)
        /// Continuous ambient motion (breathing dots, shimmer).
        static let ambient = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    }
}

// MARK: - The glass material

/// The app's one glass surface: Liquid Glass, plus the two things the system effect leaves to
/// the app — a specular highlight and a lit rim.
///
/// `glassEffect` handles refraction and the interactive press deformation, but on its own a
/// small control over a dark panel reads as a flat grey lozenge. The sheen gives it a light
/// source (top-left, like every other surface on the system), the rim gives it an edge to
/// catch that light, and the tinted glow underneath separates it from whatever is behind it.
/// Together that's the "neo-skeuomorphic" part: it looks like a physical, lit object.
struct TGGlass<S: InsettableShape>: ViewModifier {

    let shape: S
    var tint: Color?
    /// Raised controls glow and cast; recessed surfaces (trays) only catch a rim.
    var raised: Bool = true
    var isPressed: Bool = false
    var glassID: String?
    var namespace: Namespace.ID?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .glassEffect(glass, in: shape)
            .modifier(GlassIdentity(glassID: glassID, namespace: namespace))
            .overlay { sheen }
            .overlay { rim }
            // Without this the two shadows below are drawn from the *content's* alpha, which
            // for a label with glyph holes means light leaking through the letterforms.
            .compositingGroup()
            .shadow(color: castColor, radius: castRadius, y: castOffset)
            .shadow(color: glowColor, radius: raised ? 12 : 0, y: raised ? 4 : 0)
            .scaleEffect(isPressed ? 0.965 : 1)
    }

    // MARK: Layers

    private var glass: Glass {
        // A tray is a backdrop, not a control: `.regular` renders it as a near-opaque slab
        // that flattens whatever colour is standing on it, and `interactive` would have it
        // deform under a pointer that is aiming at the buttons it holds.
        let core: Glass = raised ? .regular : .clear
        let tinted = tint.map { core.tint($0.opacity(tintStrength)) } ?? core

        // Under Reduce Transparency the system already swaps the material for something
        // opaque; asking for `interactive` on top of that just adds motion for no read.
        guard raised, !reduceTransparency else { return tinted }
        return tinted.interactive()
    }

    private var tintStrength: Double {
        guard raised else { return 0.10 }
        return scheme == .dark ? 0.40 : 0.32
    }

    /// The highlight. Strongest along the top edge, gone by the middle — a single soft light
    /// source above the panel, not a gradient for decoration's sake.
    private var sheen: some View {
        shape
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(scheme == .dark ? 0.26 : 0.50), location: 0.00),
                        .init(color: .white.opacity(scheme == .dark ? 0.07 : 0.14), location: 0.34),
                        .init(color: .clear, location: 0.58),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blendMode(.plusLighter)
            // A tray gets a hint of the same light so it still reads as glass, but nothing
            // strong enough to compete with the controls standing on it.
            .opacity(raised ? (isPressed ? 0.45 : 1) : 0.35)
            .allowsHitTesting(false)
    }

    /// The edge. Bright where it faces the light, and picking up the control's own tint where
    /// it faces away, which is what keeps a row of differently-coloured pills legible.
    private var rim: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity((scheme == .dark ? 0.55 : 0.90) * rimStrength),
                        .white.opacity((scheme == .dark ? 0.10 : 0.22) * rimStrength),
                        (tint ?? .white).opacity((scheme == .dark ? 0.40 : 0.28) * rimStrength),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: raised ? 0.8 : 0.6
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    private var rimStrength: Double { raised ? 1.0 : 0.5 }

    private var castColor: Color {
        .black.opacity(scheme == .dark ? 0.45 : 0.20)
    }

    private var castRadius: CGFloat {
        guard raised else { return 0 }
        return isPressed ? 4 : 9
    }

    private var castOffset: CGFloat {
        guard raised else { return 0 }
        return isPressed ? 1 : 3
    }

    /// A coloured bloom under a tinted control. This is what makes the dock read as colourful
    /// without painting the glass itself opaque.
    private var glowColor: Color {
        guard let tint else { return .clear }
        return tint.opacity(isPressed ? 0.14 : (scheme == .dark ? 0.34 : 0.24))
    }
}

/// Applies `glassEffectID` only when the call site supplied both halves of one.
///
/// The identity has to sit on the same view as the `glassEffect` it names, so it is applied
/// here, immediately after, rather than being left to the call site.
private struct GlassIdentity: ViewModifier {
    let glassID: String?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let glassID, let namespace {
            content.glassEffectID(glassID, in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Raised glass: a control the user can press.
    func tgGlass<S: InsettableShape>(
        _ shape: S,
        tint: Color? = nil,
        isPressed: Bool = false,
        id: String? = nil,
        in namespace: Namespace.ID? = nil
    ) -> some View {
        modifier(TGGlass(shape: shape, tint: tint, raised: true, isPressed: isPressed, glassID: id, namespace: namespace))
    }

    /// Recessed glass: a surface that *holds* controls. No glow, no cast — it is the floor.
    func tgGlassTray<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(TGGlass(shape: shape, tint: tint, raised: false))
    }
}

// MARK: - Button styles

/// A circular glass control sized for the header cluster.
struct GlassCircleButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent: Bool = false
    var glassID: String?
    var namespace: Namespace.ID?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 30, height: 30)
            .contentShape(.circle)
            .tgGlass(
                .circle,
                tint: prominent ? tint : tint?.opacity(0.7),
                isPressed: configuration.isPressed,
                id: glassID,
                in: namespace
            )
            .tgAnimation(TG.Motion.snap, value: configuration.isPressed)
    }

    private var foreground: some ShapeStyle {
        // A prominent control earns a white glyph; everything else stays in the text colour so
        // the header doesn't turn into a row of competing signals.
        prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
    }
}

/// A capsule glass control with an icon and a label, used in the action dock.
struct GlassPillButtonStyle: ButtonStyle {
    var tint: Color?
    /// The one primary action in a row: a saturated fill under the glass and a white label.
    var prominent: Bool = false
    var glassID: String?
    var namespace: Namespace.ID?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 13 : 12, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, prominent ? TG.Space.loose : TG.Space.regular)
            .padding(.vertical, prominent ? TG.Space.snug - 1 : TG.Space.tight + 2)
            .background {
                if prominent, let tint {
                    Capsule().fill(tint.gradient).opacity(configuration.isPressed ? 0.75 : 0.9)
                }
            }
            .contentShape(.capsule)
            .tgGlass(
                .capsule,
                tint: tint,
                isPressed: configuration.isPressed,
                id: glassID,
                in: namespace
            )
            .tgAnimation(TG.Motion.snap, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassCircleButtonStyle {
    static var glassCircle: GlassCircleButtonStyle { GlassCircleButtonStyle() }

    static func glassCircle(
        tint: Color? = nil,
        prominent: Bool = false,
        id: String? = nil,
        in namespace: Namespace.ID? = nil
    ) -> GlassCircleButtonStyle {
        GlassCircleButtonStyle(tint: tint, prominent: prominent, glassID: id, namespace: namespace)
    }
}

extension ButtonStyle where Self == GlassPillButtonStyle {
    static var glassPill: GlassPillButtonStyle { GlassPillButtonStyle() }

    static func glassPill(
        tint: Color? = nil,
        prominent: Bool = false,
        id: String? = nil,
        in namespace: Namespace.ID? = nil
    ) -> GlassPillButtonStyle {
        GlassPillButtonStyle(tint: tint, prominent: prominent, glassID: id, namespace: namespace)
    }
}

// MARK: - Reduce Motion

/// Swaps an animation for `nil` when the user has asked the system to calm down.
///
/// Liquid Glass leans hard on motion, so every animated surface in this app routes
/// through here rather than calling `.animation` directly.
struct RespectfulAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func tgAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(RespectfulAnimation(animation: animation, value: value))
    }
}
