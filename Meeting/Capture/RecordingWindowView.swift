import SwiftUI

/// Expanded Recording window — 720×480 dark glass with the big timer,
/// per-channel waveforms, and the marks / stop controls. Opens from the
/// expand-circle button in the popover.
///
/// While idle / starting / stopping / transcribing the window shows a
/// matching empty-state card so it doesn't render a half-broken layout
/// when the user opens it without an active recording.
struct RecordingWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession

    var body: some View {
        ZStack {
            // Dark navy/violet base — always dark regardless of system
            // appearance because the recording window is a focus surface.
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.11, blue: 0.16),
                    Color(red: 0.16, green: 0.09, blue: 0.19),
                    Color(red: 0.11, green: 0.13, blue: 0.25),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(Color.black.opacity(0.25))
            .ignoresSafeArea()

            switch recording.state {
            case let .recording(folder, started):
                RecordingActiveBody(folder: folder, started: started)
            case .starting, .stopping:
                RecordingTransientBody(label: recording.state == .starting ? "Starting…" : "Stopping…")
            case .idle:
                RecordingIdleBody()
            }
        }
        .frame(width: 720, height: 480)
        .preferredColorScheme(.dark)
    }
}

// =============================================================================
// MARK: - Active recording body
// =============================================================================

private struct RecordingActiveBody: View {
    let folder: URL
    let started: Date
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top status row
            HStack(spacing: 10) {
                StatusPill()
                if let label = sourceLabel {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.top, 14)

            // Hero timer + folder path
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text(started, style: .timer)
                    .font(.system(size: 72, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .tracking(-2)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SAVING TO")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(shortPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.bottom, 8)
                Spacer()
            }
            .padding(.top, 10)

            // Two big waveforms
            VStack(spacing: 10) {
                BigChannelMeter(
                    label: "You · mic",
                    sublabel: recording.micDeviceName ?? "Built-in microphone",
                    color: Color(red: 0.55, green: 0.75, blue: 1.00),
                    buffer: recording.micRMS
                )
                BigChannelMeter(
                    label: "Meeting · output",
                    sublabel: outputSublabel,
                    color: Color(red: 0.95, green: 0.55, blue: 0.30),
                    buffer: recording.outputRMS
                )
            }
            .padding(.top, 22)

            Spacer()

            // Marks + controls
            HStack(spacing: 12) {
                MarksCard(
                    count: recording.marks.count,
                    lastTimestamp: recording.marks.last?.timestamp,
                    onMark: { recording.mark() }
                )
                StopButton {
                    Task { await appState.stopAndTranscribe() }
                }
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 28)
    }

    private var sourceLabel: String? {
        let title = recording.currentSourceTitle
        let app = recording.currentSourceApp
        switch (title, app) {
        case (let t?, let a?): return "from \(a) — \(t)"
        case (let t?, nil): return t
        case (nil, let a?): return "from \(a)"
        case (nil, nil): return nil
        }
    }

    private var shortPath: String {
        let home = NSHomeDirectory()
        let full = folder.path(percentEncoded: false)
        if full.hasPrefix(home) {
            return "~" + full.dropFirst(home.count)
        }
        return full
    }

    private var outputSublabel: String {
        let app = recording.currentSourceApp ?? "Meeting app"
        let n = recording.tapProcessCount
        if n <= 1 { return app }
        return "\(app) (\(n) audio processes)"
    }
}

// =============================================================================
// MARK: - Transient / idle bodies
// =============================================================================

private struct RecordingTransientBody: View {
    let label: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.white)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct RecordingIdleBody: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("Not recording")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("Open the menu-bar popover and click Start Recording — the window will swap to the live view automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 64)
        }
    }
}

// =============================================================================
// MARK: - Pieces
// =============================================================================

private struct StatusPill: View {
    var body: some View {
        HStack(spacing: 8) {
            PulseDot(size: 8, color: .recordRed)
            Text("RECORDING")
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(Color.recordRed.opacity(0.95))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(Color.recordRed.opacity(0.18))
                .overlay {
                    Capsule().strokeBorder(Color.recordRed.opacity(0.4), lineWidth: 0.5)
                }
        }
    }
}

private struct BigChannelMeter: View {
    let label: String
    let sublabel: String
    let color: Color
    let buffer: RMSRingBuffer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(sublabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: 150, alignment: .leading)

                WaveformBars(
                    levels: buffer.snapshot(),
                    color: color,
                    spacing: 1.5
                )
                .frame(height: 36)

                Text(String(format: "%.0fdB", buffer.peakDB()))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
    }
}

private struct MarksCard: View {
    let count: Int
    let lastTimestamp: TimeInterval?
    let onMark: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.warmMark)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onMark) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Mark moment")
                    Text("⌘B")
                        .font(.system(size: 10, design: .monospaced))
                        .opacity(0.6)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(.white.opacity(0.12))
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("b", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                }
        }
    }

    private var label: String {
        switch (count, lastTimestamp) {
        case (0, _): return "Mark moments as you go"
        case (let n, let t?):
            let suffix = formatTimestamp(t)
            return "\(n) moment\(n == 1 ? "" : "s") marked · last at \(suffix)"
        case (let n, nil):
            return "\(n) moment\(n == 1 ? "" : "s") marked"
        }
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                Text("Stop & Transcribe")
                    .font(.system(size: 13, weight: .semibold))
                Text("⌘.")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background {
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.recordRed, Color.recordRedDeep],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                    }
                    .shadow(color: Color.recordRedDeep.opacity(0.45), radius: 12, y: 6)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
    }
}
