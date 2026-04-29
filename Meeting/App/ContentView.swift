import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.permissions.allGranted {
                RecordingMainView()
            } else {
                PermissionView()
            }
        }
    }
}
