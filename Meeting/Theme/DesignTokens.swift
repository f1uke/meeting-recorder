import SwiftUI
import AppKit

// MARK: - Adaptive helper

extension Color {
    /// Build a Color that resolves differently in Light vs Dark mode.
    /// Wraps NSColor's dynamic provider — works on macOS 11+.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let resolved = appearance.bestMatch(from: [.aqua, .darkAqua])
            return resolved == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Brand tokens
//
// Approximate sRGB conversions of the design's `oklch(...)` values from
// docs/design_handoff_meeting_app/README.md. The original oklch literals
// are kept as comments so the spec is recoverable.

extension Color {
    /// Cobalt blue. Primary buttons, links, selection highlight, accent gradients.
    static let brandAccent = Color(red: 0.32, green: 0.55, blue: 0.91)        // oklch(0.65 0.18 250)
    /// Gradient end for accent buttons / pills.
    static let brandAccentStrong = Color(red: 0.22, green: 0.40, blue: 0.84)  // oklch(0.55 0.18 252)

    /// Recording dot, Stop & Transcribe button.
    static let recordRed = Color(red: 1.00, green: 0.36, blue: 0.34)          // #FF5D57
    /// Gradient end for the red Stop button.
    static let recordRedDeep = Color(red: 0.91, green: 0.29, blue: 0.26)      // #E94942

    /// Marked moments, action item left border, "+ Mark" link.
    static let warmMark = Color(red: 0.94, green: 0.47, blue: 0.25)           // oklch(0.78 0.16 25)

    /// Granted state, "Transcript ready" toast.
    static let brandSuccess = Color(
        light: Color(red: 0.11, green: 0.61, blue: 0.36),                     // oklch(0.45 0.18 145)
        dark: Color(red: 0.31, green: 0.78, blue: 0.55)                       // oklch(0.6 0.18 145)
    )

    // MARK: Text — semantic, adaptive

    static let textPrimary = Color(
        light: Color(red: 0.047, green: 0.055, blue: 0.078),                  // #0C0E14
        dark: Color(red: 0.910, green: 0.918, blue: 0.937)                    // #E8EAEF
    )
    static let textDim = Color(
        light: Color.black.opacity(0.55),
        dark: Color(red: 0.604, green: 0.628, blue: 0.675)                    // #9AA0AC
    )
    static let textFaint = Color(
        light: Color.black.opacity(0.40),
        dark: Color(red: 0.357, green: 0.388, blue: 0.439)                    // #5B6370
    )

    // MARK: Tag palette — sidebar dots and list pills.
    // All sit on the `oklch(0.7 0.16 H)` ring with H rotated by category.

    static let tagEngineering = Color(red: 0.40, green: 0.62, blue: 0.95)     // H=250 cobalt
    static let tagDesign      = Color(red: 0.86, green: 0.45, blue: 0.85)     // H=320 magenta
    static let tagPeople      = Color(red: 0.95, green: 0.55, blue: 0.30)     // H=30  warm
    static let tagResearch    = Color(red: 0.40, green: 0.78, blue: 0.45)     // H=145 green
    static let tagOneOnOne    = Color(red: 0.85, green: 0.70, blue: 0.30)     // H=75  gold
}

// MARK: - Glass tints
//
// Named layers from the design handoff. SwiftUI's Material API gives us
// adaptive frosted glass for free; these tints sit *on top* of the material
// to push the layer toward the design's intended hue.

enum GlassTint {
    /// Default popover / card surface.
    case neutral
    /// Library sidebar — slightly cool blue wash.
    case sidebar
    /// Recording window — forced-dark navy/violet base, ignores Light mode.
    case recordingDark
    /// AI summary card — subtle blue-violet wash.
    case accentWash

    func tintColor(for scheme: ColorScheme) -> Color {
        switch self {
        case .neutral:
            return scheme == .dark
                ? Color.white.opacity(0.04)
                : Color.white.opacity(0.20)
        case .sidebar:
            return scheme == .dark
                ? Color(red: 0.078, green: 0.118, blue: 0.196).opacity(0.45)
                : Color(red: 0.882, green: 0.910, blue: 0.961).opacity(0.50)
        case .recordingDark:
            return Color(red: 0.078, green: 0.086, blue: 0.118).opacity(0.40)
        case .accentWash:
            return scheme == .dark
                ? Color.brandAccent.opacity(0.10)
                : Color.brandAccent.opacity(0.06)
        }
    }
}

// MARK: - Fonts

extension Font {
    /// Hero serif — bundled "New York" if available, else system serif.
    /// Used for window titles like "Q2 Roadmap Sync".
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("NewYorkSerif-Regular", size: size, relativeTo: .largeTitle)
            .weight(weight)
    }

    /// Uppercase section labels: "RECENT", "SOURCE", "LIBRARY", etc.
    /// 10-11pt, tracked, 700 weight in design — render with `.kerning(0.8)`.
    static let sectionLabel = Font.system(size: 10, weight: .bold)

    /// Monospaced timer / timestamp / dB / file path.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
            .monospacedDigit()
    }
}

// MARK: - Layout constants

enum Tokens {
    /// Card / popover container corner radius.
    static let cardRadius: CGFloat = 14
    /// Smaller card radius for inner rows.
    static let rowRadius: CGFloat = 10
    /// Pill / capsule height for primary action buttons.
    static let primaryButtonHeight: CGFloat = 38
    /// Default padding inside cards.
    static let cardPadding: CGFloat = 14
    /// Padding inside main panes (Library detail, etc).
    static let panePadding: CGFloat = 24
}
