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

    var body: some Commands {
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
