import SwiftUI

@main
struct MeetingApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 640, minHeight: 480)
                .task { await appState.refreshPermissions() }
        }
        .windowResizability(.contentSize)
    }
}
