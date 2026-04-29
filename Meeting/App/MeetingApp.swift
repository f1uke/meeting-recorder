import SwiftUI

@main
struct MeetingApp: App {
    @StateObject private var appState: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        // The adaptor instantiates AppDelegate eagerly, but
        // applicationDidFinishLaunching hasn't run yet — so we hand the
        // state off via a static reference for the delegate to pick up
        // when it's ready to attach the popover content.
        AppDelegate.pendingState = state
    }

    var body: some Scene {
        // No MenuBarExtra scene — AppDelegate owns the status item and
        // popover via NSStatusItem + NSPopover. See AppDelegate.swift
        // for why we can't use MenuBarExtra(.window) on macOS 26.

        // Window scenes are openable on demand from the popover via
        // `OpenWindowAction`. They use `id` so we can target each one
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
