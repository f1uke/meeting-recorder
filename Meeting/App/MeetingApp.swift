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

        // Single unified window. Routes between library + transcript
        // are driven by `AppState.route` so navigation feels like
        // moving deeper into the same surface (matches the design).
        Window("Meetings", id: "main") {
            RootView()
                .appEnvironment(appState)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(
                recording: appState.recording,
                stopAndTranscribe: { Task { await appState.stopAndTranscribe() } },
                stopOnly: { Task { await appState.stopOnly() } },
                openSettings: { appState.showSettings = true }
            )
        }
    }
}
