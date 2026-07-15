import SwiftUI

/// Compact floating HUD content for dictation. Forced-dark for contrast on
/// any background, matching the recording window aesthetic. Observes the
/// controller directly so it re-renders as the state machine advances.
struct DictationHUD: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            icon
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 300, height: 64, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.state {
        case .idle, .listening:
            PulseDot(size: 9, color: .recordRed)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .injected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.brandSuccess)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle, .listening:
            VStack(alignment: .leading, spacing: 4) {
                Text("Listening")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
                    WaveformBars(
                        levels: controller.levels.snapshot(last: 48),
                        color: .brandAccent,
                        minBarHeight: 2,
                        spacing: 2
                    )
                    .frame(height: 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .transcribing:
            label("Transcribing", sub: "Esc to cancel")

        case .injected(let text):
            label("Inserted", sub: text)

        case .failed(let message):
            label("Dictation", sub: message)

        case .cancelled:
            label("Cancelled", sub: nil)
        }
    }

    @ViewBuilder
    private func label(_ title: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
