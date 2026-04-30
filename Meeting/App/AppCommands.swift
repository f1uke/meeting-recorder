import SwiftUI

/// Global menu-bar commands. Provides ⌘B (Mark moment) and ⌘. (Stop &
/// Transcribe) keyboard shortcuts that fire whenever the app is the
/// frontmost process — Library window focused, Recording window focused,
/// popover open, anywhere — not just when the popover holds keyboard
/// focus.
///
/// Both commands are gated on the recording state so the menu items grey
/// out (and the shortcuts no-op) when there's nothing to mark or stop.
struct AppCommands: Commands {
    @ObservedObject var recording: RecordingSession
    let stopAndTranscribe: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replace SwiftUI's auto-generated "Settings…" with one that opens
        // our window scene. Required because we're using a regular Window
        // (not the `Settings` scene) so SwiftUI doesn't wire ⌘, by itself.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Recording") {
            Button("Mark Moment") {
                recording.mark()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!recording.isRecording)

            Button("Stop & Transcribe") {
                stopAndTranscribe()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!recording.isRecording)
        }
    }
}
