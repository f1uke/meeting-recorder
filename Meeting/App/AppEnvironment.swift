import SwiftUI

/// Inject every shared @ObservableObject the redesign relies on into the
/// view tree. Apply once per scene so the menu-bar popover and each Window
/// scene all see the same `AppState` and the long-lived RecordingSession /
/// TranscriptionSession instances it owns.
struct AppEnvironment: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        content
            .environmentObject(state)
            .environmentObject(state.recording)
            .environmentObject(state.queue)
            .environmentObject(state.library)
            .environmentObject(state.picker)
            .environmentObject(state.calendar)
    }
}

extension View {
    func appEnvironment(_ state: AppState) -> some View {
        modifier(AppEnvironment(state: state))
    }
}
