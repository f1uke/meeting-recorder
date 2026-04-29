import SwiftUI
import ScreenCaptureKit
import AppKit

// =============================================================================
// MARK: - Idle state
// =============================================================================

struct PopoverIdleView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    @StateObject private var picker = WindowPickerModel()
    @ObservedObject private var prefs = AppPreferences.shared

    @Environment(\.openWindow) private var openWindow
    @State private var showWindowPickerSheet = false
    @State private var showSettingsSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(
                title: "Meeting",
                subtitle: "Ready to record",
                trailing: {
                    HStack(spacing: 6) {
                        GlassIconButton(systemImage: "magnifyingglass", size: 26) {
                            // Search — wired to library search in U5
                            openWindow(id: "library")
                        }
                        GlassIconButton(systemImage: "gearshape", size: 26) {
                            showSettingsSheet = true
                        }
                    }
                }
            )

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Source")
                WindowChip(
                    window: picker.selectedWindow,
                    icon: picker.selectedWindow.flatMap { picker.icon(for: $0) },
                    onChange: { showWindowPickerSheet = true }
                )
            }

            SpeakerCountChip(selection: $prefs.expectedSpeakerCount)

            HStack(spacing: 10) {
                GlassButton(style: .accent, action: startRecording) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                        Text("Start Recording")
                    }
                }
                .disabled(picker.selectedWindow == nil)

                GlassIconButton(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    size: 38
                ) {
                    openWindow(id: "recording")
                }
            }

            RecentSection {
                openWindow(id: "library")
            }
        }
        .sheet(isPresented: $showWindowPickerSheet) {
            WindowPickerSheet(picker: picker, onDismiss: { showWindowPickerSheet = false })
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsStubSheet(onDismiss: { showSettingsSheet = false })
        }
        .task {
            if picker.windows.isEmpty {
                await picker.refresh()
            }
        }
    }

    private func startRecording() {
        guard let win = picker.selectedWindow else { return }
        Task { await recording.start(window: win) }
    }
}

// =============================================================================
// MARK: - Recording state
// =============================================================================

struct PopoverRecordingView: View {
    let folder: URL
    let started: Date
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PulseDot()
                Text("RECORDING")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Color.recordRed)
                Spacer()
                Text(started, style: .timer)
                    .font(.mono(13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
            }

            if let title = sourceLabel {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Live waveform — stub levels during U3, real RMS in U4.
            VStack(spacing: 6) {
                StubChannelMeter(label: "You · mic", color: .brandAccent)
                StubChannelMeter(label: "Meeting", color: .warmMark)
            }

            HStack(spacing: 8) {
                GlassIconButton(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    size: 38
                ) {
                    openWindow(id: "recording")
                }
                GlassButton(style: .danger, action: stopAndTranscribe) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("Stop & Transcribe")
                        Text("⌘.").font(.mono(10)).opacity(0.7)
                    }
                }
            }
        }
    }

    private var sourceLabel: String? {
        let title = recording.currentSourceTitle
        let app = recording.currentSourceApp
        switch (title, app) {
        case (let t?, let a?): return "\(t) — \(a)"
        case (let t?, nil): return t
        case (nil, let a?): return a
        case (nil, nil): return folder.lastPathComponent
        }
    }

    private func stopAndTranscribe() {
        Task { await appState.stopAndTranscribe() }
    }
}

// =============================================================================
// MARK: - Starting / Stopping (transient)
// =============================================================================

struct PopoverTransientView: View {
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// =============================================================================
// MARK: - Transcribing state
// =============================================================================

struct PopoverTranscribingView: View {
    let stage: TranscriptionSession.Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(
                title: "Transcribing",
                subtitle: stage.localizedName,
                trailing: { EmptyView() }
            )

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(stageDisplayLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Text(percentText)
                            .font(.mono(12))
                            .foregroundStyle(Color.textDim)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.06))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color.brandAccent, Color(red: 0.40, green: 0.78, blue: 0.95)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: proxy.size.width * progressFraction)
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 6) {
                        ForEach(TranscriptionSession.Stage.pipeline, id: \.self) { s in
                            Capsule()
                                .fill(stripeColor(for: s))
                                .frame(height: 4)
                        }
                    }

                    Text("Running locally on your Mac. No data leaves the device.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
                .padding(Tokens.cardPadding)
            }
        }
    }

    private var progressFraction: Double {
        let order = TranscriptionSession.Stage.pipeline
        guard let idx = order.firstIndex(of: stage) else { return 0 }
        return Double(idx + 1) / Double(order.count)
    }

    private var percentText: String {
        "\(Int(progressFraction * 100))%"
    }

    private var stageDisplayLabel: String {
        switch stage {
        case .loadingModels: return "Loading models"
        case .transcribingMic: return "Mic transcription"
        case .transcribingOutput: return "Output transcription"
        case .merging: return "Diarization + merge"
        case .writing: return "Writing transcript"
        }
    }

    private func stripeColor(for s: TranscriptionSession.Stage) -> Color {
        let order = TranscriptionSession.Stage.pipeline
        guard let i = order.firstIndex(of: s),
              let cur = order.firstIndex(of: stage) else {
            return Color.black.opacity(0.08)
        }
        if i < cur { return Color.brandAccent }
        if i == cur { return Color.brandAccent.opacity(0.5) }
        return Color.black.opacity(0.08)
    }
}

// =============================================================================
// MARK: - Done / Failed
// =============================================================================

struct PopoverDoneView: View {
    let transcriptURL: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.brandSuccess, Color.brandSuccess.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.brandSuccess.opacity(0.4), radius: 8, y: 3)

            Text("Transcript ready")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)

            Text(transcriptURL.deletingLastPathComponent().lastPathComponent)
                .font(.mono(11))
                .foregroundStyle(Color.textDim)

            HStack(spacing: 8) {
                GlassButton(style: .accent, action: openInDefault) {
                    Text("Open Markdown")
                }
                GlassButton(style: .neutral, action: onDismiss) {
                    Text("Done")
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func openInDefault() {
        NSWorkspace.shared.open(transcriptURL)
    }
}

struct PopoverFailedView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.warmMark)
            Text("Transcription failed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            GlassButton(style: .accent, action: onDismiss) {
                Text("Back")
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

// =============================================================================
// MARK: - Header
// =============================================================================

struct PopoverHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

// =============================================================================
// MARK: - Window chip (Source picker)
// =============================================================================

struct WindowChip: View {
    let window: SCWindow?
    let icon: NSImage?
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onChange) {
                Text(window == nil ? "Pick" : "Change")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.brandAccent, Color.brandAccentStrong],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 32, height: 32)
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "macwindow")
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private var primaryText: String {
        if let window {
            let title = window.title?.trimmingCharacters(in: .whitespaces)
            return (title?.isEmpty == false ? title! : "Untitled window")
        }
        return "Choose a window…"
    }

    private var secondaryText: String {
        if let window {
            return window.owningApplication?.applicationName ?? ""
        }
        return "Required to start recording"
    }
}

// =============================================================================
// MARK: - Speaker count chip
// =============================================================================

struct SpeakerCountChip: View {
    @Binding var selection: ExpectedSpeakers

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            Text("Expected speakers")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(ExpectedSpeakers.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
                }
        }
    }
}

// =============================================================================
// MARK: - Recent section (stub for U3, real data in U5)
// =============================================================================

struct RecentSection: View {
    let openLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Recent")
                Spacer()
                Button(action: openLibrary) {
                    HStack(spacing: 2) {
                        Text("Open Library")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                }
                .buttonStyle(.plain)
            }

            // Empty state — Library wiring lands in U5.
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .foregroundStyle(Color.textFaint)
                Text("No recent meetings yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
            }
            .padding(.vertical, 6)
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
                .offset(y: -8)
        }
    }
}

// =============================================================================
// MARK: - Stub waveform (animated until U4 wires real RMS)
// =============================================================================

struct StubChannelMeter: View {
    let label: String
    let color: Color
    private let barCount = 24

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let levels = generatedLevels(for: context.date)
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textDim)
                    .frame(width: 64, alignment: .leading)

                WaveformBars(levels: levels, color: color)
                    .frame(height: 22)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.04))
                    }

                Text(meterText(levels: levels))
                    .font(.mono(9))
                    .foregroundStyle(Color.textFaint)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func generatedLevels(for date: Date) -> [Float] {
        // Deterministic-looking jitter so bars feel alive without per-tick
        // state mutation. Real RMS replaces this in U4.
        let seed = date.timeIntervalSinceReferenceDate
        return (0..<barCount).map { i in
            let phase = Double(i) * 0.6 + seed * 8
            let noise = sin(phase) * 0.35 + sin(phase * 0.4) * 0.25 + 0.55
            return Float(min(max(noise, 0.08), 0.95))
        }
    }

    private func meterText(levels: [Float]) -> String {
        let peak = levels.max() ?? 0
        let db = 20 * log10(Double(max(peak, 0.001)))
        return String(format: "%.0fdB", db)
    }
}

// =============================================================================
// MARK: - Window picker sheet
// =============================================================================

struct WindowPickerSheet: View {
    @ObservedObject var picker: WindowPickerModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a window")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textDim)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            WindowPicker(model: picker)
                .padding(12)
                .frame(minHeight: 320)

            HStack {
                Spacer()
                GlassButton(style: .accent, action: onDismiss) {
                    Text(picker.selectedWindow == nil ? "Cancel" : "Done")
                        .padding(.horizontal, 8)
                }
                .frame(width: 120)
            }
            .padding(12)
        }
        .frame(width: 420, height: 520)
        .background {
            Color.clear.background(.regularMaterial).ignoresSafeArea()
        }
    }
}

// =============================================================================
// MARK: - Settings stub
// =============================================================================

struct SettingsStubSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.serif(28))
                .foregroundStyle(Color.textPrimary)
            Text("Coming soon — audio device picker, model size, AI toggle")
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
                .multilineTextAlignment(.center)
            GlassButton(style: .accent, action: onDismiss) {
                Text("Close")
            }
            .frame(width: 100)
        }
        .padding(32)
        .frame(width: 360)
        .background {
            Color.clear.background(.regularMaterial).ignoresSafeArea()
        }
    }
}

// =============================================================================
// MARK: - TranscriptionSession.Stage helpers
// =============================================================================

extension TranscriptionSession.Stage {
    /// Linear ordering used by the popover progress bar / pipeline strip.
    static let pipeline: [TranscriptionSession.Stage] = [
        .loadingModels, .transcribingMic, .transcribingOutput, .merging, .writing,
    ]
}
