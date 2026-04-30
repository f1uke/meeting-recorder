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
    @ObservedObject var transcribe: TranscriptionSession
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {
        switch (recording.state, transcribe.state) {
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
            }
            .font(.system(size: 13))

        case (_, .running):
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                Text("…").font(.system(size: 13, weight: .medium))
            }
            .font(.system(size: 13))

        default:
            Image(systemName: "mic.fill")
                .font(.system(size: 13))
        }
    }
}
