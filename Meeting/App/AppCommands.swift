import SwiftUI

/// Global menu-bar commands. Provides ⌘. (Stop & Transcribe) and
/// ⇧⌘. (Stop Only) keyboard shortcuts that fire whenever the app is the
/// frontmost process — Library window focused, popover open, anywhere —
/// not just when the popover holds keyboard focus. Gated on recording
/// state so the menu items grey out when there's nothing to stop.
struct AppCommands: Commands {
    @ObservedObject var recording: RecordingSession
    let stopAndTranscribe: () -> Void
    let stopOnly: () -> Void
    let openSettings: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replace SwiftUI's auto-generated "Settings…" with one that opens
        // the Settings sheet on the main window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "main")  // ensure main window is up first
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Recording") {
            Button("Stop & Transcribe") {
                stopAndTranscribe()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!recording.isRecording)

            Button("Stop Only") {
                stopOnly()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!recording.isRecording)
        }
    }
}
