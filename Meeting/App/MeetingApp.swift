import SwiftUI

@main
struct MeetingApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Primary entry point — menu-bar icon. Click opens the popover.
        MenuBarExtra {
            MenuBarPopoverView()
                .appEnvironment(appState)
                .task { await appState.refreshPermissions() }
        } label: {
            MenuBarLabel(
                recording: appState.recording,
                transcribe: appState.transcribe
            )
        }
        .menuBarExtraStyle(.window)

        // Expanded surfaces — opened on demand from the popover via
        // `OpenWindowAction`. Each one uses `.id` so we can target it
        // explicitly with `openWindow(id: "library")` etc.
        Window("Library", id: "library") {
            LibraryView()
                .appEnvironment(appState)
        }

        Window("Recording", id: "recording") {
            RecordingWindowView()
                .appEnvironment(appState)
        }
        .windowResizability(.contentSize)

        Window("Transcript", id: "transcript") {
            TranscriptViewerView()
                .appEnvironment(appState)
        }
        .commands {
            AppCommands(recording: appState.recording) {
                Task { await appState.stopAndTranscribe() }
            }
        }
    }
}
