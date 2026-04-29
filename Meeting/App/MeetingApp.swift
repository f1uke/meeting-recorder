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

        // Temporary debug surface — keeps the pre-redesign full-window UI
        // available during the U2-U7 transition so we can exercise flows
        // that don't fit cleanly in a 360pt popover yet. Removed in U8.
        WindowGroup("Debug · Full UI", id: "debug") {
            ContentView()
                .appEnvironment(appState)
                .frame(minWidth: 640, minHeight: 480)
                .task { await appState.refreshPermissions() }
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands(recording: appState.recording) {
                Task { await appState.stopAndTranscribe() }
            }
        }
    }
}
