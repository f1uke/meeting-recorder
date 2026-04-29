import SwiftUI

/// Unified main-window root. Routes between the Library and the
/// Transcript viewer in-place, instead of opening two separate Window
/// scenes — matches the design where the transcript is a deeper view
/// of a Library meeting (breadcrumb "Library > <title>") rather than
/// a window of its own.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.route {
            case .library:
                LibraryView()
            case .transcript:
                TranscriptViewerView()
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
    }
}
