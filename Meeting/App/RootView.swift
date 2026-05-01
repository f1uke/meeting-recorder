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
        .sheet(isPresented: $appState.showSettings) {
            SettingsSheet()
                .appEnvironment(appState)
        }
    }
}

private struct SettingsSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsView()
            .frame(width: 820, height: 640)
            .overlay(alignment: .topTrailing) {
                Button("Done") { appState.showSettings = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding(.top, 12)
                    .padding(.trailing, 16)
            }
    }
}
