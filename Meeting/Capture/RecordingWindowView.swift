import SwiftUI

/// Expanded Recording window. Stub for U2 — the full dark-glass layout with
/// 72pt timer, dual 96-bar waveforms, and mark/stop controls lands in U6.
struct RecordingWindowView: View {
    @EnvironmentObject private var recording: RecordingSession

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.11, blue: 0.16),
                    Color(red: 0.16, green: 0.09, blue: 0.19),
                    Color(red: 0.11, green: 0.13, blue: 0.25),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Recording")
                    .font(.serif(36))
                    .foregroundStyle(.white)
                Text("Coming in U6 — 72pt timer + dual waveforms")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Text(stateDescription)
                    .font(.mono(11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 720, height: 480)
    }

    private var stateDescription: String {
        switch recording.state {
        case .idle: return "idle"
        case .starting: return "starting…"
        case .recording(let folder, _): return folder.lastPathComponent
        case .stopping: return "stopping…"
        }
    }
}
