import SwiftUI

/// Split transcript viewer with video player + scrollable diarized
/// transcript. Stub for U2 — full layout lands in U7.
struct TranscriptViewerView: View {
    var body: some View {
        ZStack {
            Color.clear.background(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.brandAccent)
                Text("Transcript")
                    .font(.serif(36))
                    .foregroundStyle(Color.textPrimary)
                Text("Coming in U7 — video player + segments + search")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textDim)
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
    }
}
