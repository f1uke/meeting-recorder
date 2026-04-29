import SwiftUI

/// Heart-of-the-app Library window. Stub for U2 — the full three-pane
/// design (sidebar / list / detail) lands in U5 once `MeetingsLibrary` is
/// in place.
struct LibraryView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Color.clear.background(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.brandAccent)
                Text("Library")
                    .font(.serif(36))
                    .foregroundStyle(Color.textPrimary)
                Text("Coming in U5 — sidebar · list · detail")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textDim)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
    }
}

#Preview { LibraryView() }
