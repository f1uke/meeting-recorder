import SwiftUI

// MARK: - PulseDot
//
// 1.6s ease-in-out pulse — opacity 1 → 0.45 → 1 — used as the recording
// indicator in the menu bar popover and the expanded recording window.

struct PulseDot: View {
    var size: CGFloat = 8
    var color: Color = .recordRed

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: size * 0.6)
            .opacity(pulsing ? 0.45 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

// MARK: - WaveformBars
//
// Live-RMS bar visualizer. Driven by a `[Float]` ring buffer (0...1) that
// gets pushed from `MicRecorder` / `ProcessAudioTap` later in U4. For now
// it just renders whatever levels you hand it.
//
// Renders via `Canvas` so high-frequency redraws (target ~30Hz) stay cheap.

struct WaveformBars: View {
    /// Levels in 0...1, length determines bar count. Older samples on the
    /// left, newest on the right.
    let levels: [Float]
    /// Bar fill — gradient from this color (top) to a 70%-luminance variant
    /// (bottom) for the recording window's tall bars; popover's short bars
    /// effectively render as solid since the gradient is squashed.
    var color: Color = .brandAccent
    var minBarHeight: CGFloat = 2
    var spacing: CGFloat = 2
    var cornerRadius: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            guard !levels.isEmpty else { return }
            let n = CGFloat(levels.count)
            let totalSpacing = spacing * (n - 1)
            let barWidth = max(1, (size.width - totalSpacing) / n)
            let gradient = Gradient(colors: [color, color.opacity(0.55)])
            for (i, level) in levels.enumerated() {
                let h = max(minBarHeight, CGFloat(level.clamped(to: 0...1)) * size.height)
                let x = CGFloat(i) * (barWidth + spacing)
                let y = (size.height - h) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                ctx.fill(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
            }
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

// MARK: - SectionLabel
//
// 10pt, 700 weight, uppercase, tracked. Used as headers everywhere:
// SOURCE, RECENT, LIBRARY, TAGS, SPEAKERS, STORAGE, ...

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.sectionLabel)
            .kerning(0.8)
            .foregroundStyle(Color.textDim)
    }
}

// MARK: - Avatar
//
// Gradient circle with initials. Used everywhere a speaker shows up:
// transcript segments, speaker legend, library list rows.

struct Avatar: View {
    let initials: String
    var color: Color = .brandAccent
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}
