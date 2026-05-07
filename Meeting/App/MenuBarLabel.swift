import SwiftUI

/// The label rendered as the menu bar icon. Reactively reflects whether the
/// app is idle, recording, or transcribing so the user can see status from
/// anywhere on the system without opening the popover.
///
/// SwiftUI renders this view inside `MenuBarExtra(label:)`, which limits the
/// vocabulary of supported primitives — Image + Text + simple shapes are
/// safe. Custom shaders / complex hierarchies may not render.
struct MenuBarLabel: View {
    @ObservedObject var recording: RecordingSession
    @ObservedObject var queue: TranscriptionQueue
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        switch (recording.state, queue.activeCount) {
        case let (.recording(_, started), _):
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.red)
                if prefs.showMenuBarTimer {
                    // Built-in self-updating timer — no per-second tick needed.
                    Text(started, style: .timer)
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .medium))
                }
                if let gateState = recording.micGateState {
                    micGateIcon(for: gateState,
                                source: recording.micGateSource ?? "meeting app")
                }
            }
            .font(.system(size: 13))

        case (_, let active) where active > 0:
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                if active > 1 {
                    Text("\(active)").font(.system(size: 13, weight: .medium))
                } else {
                    Text("…").font(.system(size: 13, weight: .medium))
                }
            }
            .font(.system(size: 13))

        default:
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 13))
        }
    }

    /// Tiny status badge that mirrors what the active mic-gate detector
    /// (Meet or Discord) is currently reading. Color/icon picked so the
    /// user can tell at a glance from across the room which of the four
    /// states is live — green = recording your voice, red = silenced,
    /// yellow = something is wrong with detection.
    @ViewBuilder
    private func micGateIcon(for state: MicGateDetectionState,
                             source: String) -> some View {
        switch state {
        case .awaitingDetection:
            Image(systemName: "mic.fill")
                .foregroundStyle(.gray)
                .help("Looking for \(source) mic button…")
        case .detected(let isMicActive):
            if isMicActive {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.green)
                    .help("Mic is on in \(source) — voice will be transcribed")
            } else {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.red)
                    .help("Mic is muted in \(source) — this audio will be skipped from the transcript")
            }
        case .lost:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help("\(source) mic detection lost — bring the meeting window or PiP back to resume tracking")
        }
    }
}
