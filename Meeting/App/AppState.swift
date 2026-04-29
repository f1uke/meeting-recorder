import Foundation
import Combine

/// Top-level shared state for the app. Owns the long-lived recording and
/// transcription view models so the menu-bar label, popover, and the
/// expanded Recording / Transcript / Library windows all observe the same
/// instances and stay in sync.
@MainActor
final class AppState: ObservableObject {
    let recording: RecordingSession
    let transcribe: TranscriptionSession
    @Published private(set) var permissions = PermissionStatus()

    init() {
        self.recording = RecordingSession()
        self.transcribe = TranscriptionSession(provider: LocalProvider())
    }

    func refreshPermissions() async {
        permissions = await PermissionManager.currentStatus()
    }

    func request(_ permission: Permission) async {
        await PermissionManager.request(permission)
        await refreshPermissions()
    }
}
