import SwiftUI

// MARK: - Theme showcase
//
// Preview-only canvas exercising every primitive in light + dark.
// Not exposed in any production view.

#Preview("Theme — Light") {
    ThemeShowcase()
        .preferredColorScheme(.light)
        .frame(width: 540, height: 760)
}

#Preview("Theme — Dark") {
    ThemeShowcase()
        .preferredColorScheme(.dark)
        .frame(width: 540, height: 760)
}

private struct ThemeShowcase: View {
    @State private var levels24: [Float] = (0..<24).map { _ in Float.random(in: 0.2...0.9) }
    @State private var levels96: [Float] = (0..<96).map { _ in Float.random(in: 0.15...1.0) }

    var body: some View {
        ZStack {
            // Backdrop so glass has something to blur over.
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.18),
                    Color(red: 0.18, green: 0.10, blue: 0.20),
                    Color(red: 0.12, green: 0.14, blue: 0.28),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    typographySection
                    colorSwatchSection
                    glassCardSection
                    buttonSection
                    iconButtonSection
                    pulseSection
                    waveformSection
                    avatarSection
                }
                .padding(20)
            }
        }
    }

    private var typographySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Typography")
                Text("Q2 Roadmap Sync")
                    .font(.serif(32))
                    .foregroundStyle(Color.textPrimary)
                Text("Window title — 15pt semibold")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("Body — 14pt regular, line-height 1.6")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textPrimary)
                Text("Dim text — 11pt")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                Text("00:14:32 · −12dB")
                    .font(.mono(13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            }
            .padding(Tokens.cardPadding)
        }
    }

    private var colorSwatchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Brand colors")
            HStack(spacing: 8) {
                swatch("Accent", .brandAccent)
                swatch("Strong", .brandAccentStrong)
                swatch("Red", .recordRed)
                swatch("Warm", .warmMark)
                swatch("Success", .brandSuccess)
            }
            SectionLabel(text: "Tag palette")
            HStack(spacing: 8) {
                swatch("Eng", .tagEngineering)
                swatch("Design", .tagDesign)
                swatch("People", .tagPeople)
                swatch("Research", .tagResearch)
                swatch("1:1", .tagOneOnOne)
            }
        }
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.textDim)
        }
    }

    private var glassCardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Glass cards")
            HStack(spacing: 10) {
                GlassCard(tint: .neutral) {
                    Text("Neutral").padding(14).foregroundStyle(Color.textPrimary)
                }
                GlassCard(tint: .sidebar) {
                    Text("Sidebar").padding(14).foregroundStyle(Color.textPrimary)
                }
                GlassCard(tint: .accentWash) {
                    Text("Accent wash").padding(14).foregroundStyle(Color.textPrimary)
                }
            }
        }
    }

    private var buttonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Buttons")
            HStack(spacing: 8) {
                GlassButton(style: .accent, action: {}) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                        Text("Start Recording")
                    }
                }
                GlassButton(style: .neutral, action: {}) {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.fill")
                        Text("Pause")
                    }
                }
            }
            GlassButton(style: .danger, action: {}) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("Stop & Transcribe")
                    Text("⌘.").font(.mono(10)).opacity(0.7)
                }
            }
        }
    }

    private var iconButtonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Icon buttons")
            HStack(spacing: 8) {
                GlassIconButton(systemImage: "magnifyingglass", size: 26, action: {})
                GlassIconButton(systemImage: "gearshape", size: 26, action: {})
                GlassIconButton(systemImage: "record.circle.fill", size: 28, action: {})
                GlassIconButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 38, action: {})
                GlassIconButton(systemImage: "sparkles", size: 36, active: true, action: {})
            }
        }
    }

    private var pulseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Pulse + status pill")
            GlassCard {
                HStack(spacing: 10) {
                    PulseDot()
                    Text("RECORDING")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Color.recordRed)
                    Spacer()
                    Text("00:14:32")
                        .font(.mono(13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                }
                .padding(Tokens.cardPadding)
            }
        }
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Waveforms")
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("You · mic").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.textPrimary).frame(width: 70, alignment: .leading)
                        WaveformBars(levels: levels24, color: .brandAccent)
                            .frame(height: 28)
                        Text("−12dB").font(.mono(10))
                            .foregroundStyle(Color.textDim)
                    }
                    HStack {
                        Text("Meeting").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.textPrimary).frame(width: 70, alignment: .leading)
                        WaveformBars(levels: levels24, color: .warmMark)
                            .frame(height: 28)
                        Text("−8dB").font(.mono(10))
                            .foregroundStyle(Color.textDim)
                    }
                }
                .padding(Tokens.cardPadding)
            }
            GlassCard(tint: .recordingDark) {
                WaveformBars(levels: levels96, color: .brandAccent, spacing: 1.5)
                    .frame(height: 36)
                    .padding(Tokens.cardPadding)
            }
        }
    }

    private var avatarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Avatars")
            HStack(spacing: 10) {
                Avatar(initials: "Y", color: .tagEngineering, size: 36)
                Avatar(initials: "T", color: .tagDesign, size: 28)
                Avatar(initials: "J", color: .tagPeople, size: 22)
                Avatar(initials: "P", color: .tagResearch, size: 18)
            }
        }
    }
}
