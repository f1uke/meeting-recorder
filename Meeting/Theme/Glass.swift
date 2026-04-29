import SwiftUI

// MARK: - GlassCard
//
// Liquid Glass container for popover bodies, list rows, AI summary, etc.
// SwiftUI's `Material` (`.regularMaterial` / `.thickMaterial`) gives us the
// frosted-glass blur for free, and on macOS 26 (Tahoe) Apple has rewritten
// Material under the hood to use the new Liquid Glass effect — so plain
// `.regularMaterial` automatically picks up the system styling when running
// on Tahoe and stays as classic vibrancy on macOS 15.
//
// On top of the material we paint a `GlassTint` color (semi-transparent),
// then add a hairline border + soft inset highlight + outer shadow to match
// the design handoff's `inset 0 1px 0 rgba(255,255,255,0.55)` look.

struct GlassCard<Content: View>: View {
    var radius: CGFloat = Tokens.cardRadius
    var tint: GlassTint = .neutral
    var material: Material = .regularMaterial
    var shadow: GlassShadow = .card
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content()
            .background {
                shape
                    .fill(material)
                    .overlay { shape.fill(tint.tintColor(for: scheme)) }
                    .overlay { shape.strokeBorder(borderGradient, lineWidth: 0.5) }
            }
            .compositingGroup()
            .shadow(color: shadow.color(for: scheme),
                    radius: shadow.radius,
                    y: shadow.yOffset)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color.white.opacity(0.18), Color.white.opacity(0.04)]
                : [Color.white.opacity(0.70), Color.white.opacity(0.30)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

enum GlassShadow {
    case none
    case card     // 0 12px 36px rgba(0,0,0,0.18)
    case window   // 0 32px 80px rgba(0,0,0,0.4)
    case button   // 0 6px 18px <accent at 45%>

    var radius: CGFloat {
        switch self {
        case .none: 0
        case .card: 12
        case .window: 32
        case .button: 6
        }
    }
    var yOffset: CGFloat {
        switch self {
        case .none: 0
        case .card: 6
        case .window: 16
        case .button: 4
        }
    }
    func color(for scheme: ColorScheme) -> Color {
        switch self {
        case .none: return .clear
        case .card: return Color.black.opacity(scheme == .dark ? 0.30 : 0.18)
        case .window: return Color.black.opacity(scheme == .dark ? 0.55 : 0.40)
        case .button: return Color.brandAccent.opacity(0.45)
        }
    }
}

// MARK: - GlassPill — capsule background style

/// Capsule glass pill used as the background for row chips and small status
/// badges (e.g. "RECORDING" pill, mark count chip, "+ Mark" link).
struct GlassPill: View {
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill(tint ?? GlassTint.neutral.tintColor(for: scheme))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        scheme == .dark
                            ? Color.white.opacity(0.14)
                            : Color.white.opacity(0.55),
                        lineWidth: 0.5
                    )
            }
    }
}

// MARK: - GlassButton

/// Three-variant primary button matching the design handoff:
/// - `.accent` — cobalt gradient (Start Recording, Allow, Open)
/// - `.danger` — red gradient (Stop & Transcribe)
/// - `.neutral` — translucent glass (Pause, secondary actions)
struct GlassButton<Label: View>: View {
    enum Style { case accent, danger, neutral }

    var style: Style = .accent
    var height: CGFloat = Tokens.primaryButtonHeight
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(foreground)
                .font(.system(size: 13, weight: .semibold))
                .background { background }
                .overlay { highlight }
                .clipShape(Capsule(style: .continuous))
                .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
    }

    private var background: some View {
        Group {
            switch style {
            case .accent:
                LinearGradient(
                    colors: [Color.brandAccent, Color.brandAccentStrong],
                    startPoint: .top, endPoint: .bottom
                )
            case .danger:
                LinearGradient(
                    colors: [Color.recordRed.opacity(0.95), Color.recordRedDeep],
                    startPoint: .top, endPoint: .bottom
                )
            case .neutral:
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay { Capsule(style: .continuous).fill(GlassTint.neutral.tintColor(for: scheme)) }
            }
        }
    }

    private var highlight: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(style == .neutral ? 0.55 : 0.40),
                             Color.white.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.5
            )
    }

    private var foreground: Color {
        switch style {
        case .accent, .danger: return .white
        case .neutral: return .textPrimary
        }
    }

    private var shadowColor: Color {
        switch style {
        case .accent: return Color.brandAccent.opacity(0.45)
        case .danger: return Color.recordRedDeep.opacity(0.45)
        case .neutral: return Color.black.opacity(scheme == .dark ? 0.25 : 0.10)
        }
    }
    private var shadowRadius: CGFloat { style == .neutral ? 4 : 12 }
    private var shadowY: CGFloat { style == .neutral ? 2 : 6 }
}

// MARK: - GlassIconButton

/// Small circular glass icon button used in popover headers and toolbars.
/// Three sizes from the design: 26pt (popover header), 28pt (list toolbar),
/// 38pt (popover expand button).
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 28
    var active: Bool = false
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(active ? Color.textPrimary : Color.textDim)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay {
                            Circle().fill(
                                active
                                    ? Color.black.opacity(scheme == .dark ? 0.18 : 0.08)
                                    : GlassTint.neutral.tintColor(for: scheme)
                            )
                        }
                }
                .overlay {
                    Circle().strokeBorder(
                        scheme == .dark
                            ? Color.white.opacity(0.14)
                            : Color.white.opacity(0.55),
                        lineWidth: 0.5
                    )
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}
