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
    let library: MeetingsLibrary
    let toast: ToastPresenter
    @Published private(set) var permissions = PermissionStatus()

    init() {
        self.recording = RecordingSession()
        self.transcribe = TranscriptionSession(provider: LocalProvider())
        self.library = MeetingsLibrary()
        self.toast = ToastPresenter()
    }

    func refreshPermissions() async {
        permissions = await PermissionManager.currentStatus()
    }

    func request(_ permission: Permission) async {
        await PermissionManager.request(permission)
        await refreshPermissions()
    }

    /// Stop the active recording and immediately kick off transcription on
    /// the resulting folder. Used by both the popover and the expanded
    /// Recording window so the post-stop flow stays consistent.
    func stopAndTranscribe() async {
        await recording.stop()
        guard let folder = recording.lastFolder else { return }
        // Pick up the new folder before transcription writes its JSON, so
        // the Library shows the recording immediately.
        library.rescan()
        await transcribe.run(
            meetingFolder: folder,
            expectedSpeakers: AppPreferences.shared.expectedSpeakerCount.pyannoteValue
        )
        // Re-read after transcript.json lands so duration / speakers fill in.
        library.rescan()

        // Surface a "Transcript ready" toast on success so the user sees
        // completion even if they've moved on to another app.
        if case .done = transcribe.state, let record = library.meetings.first(where: { $0.folder == folder }) {
            toast.showTranscriptReady(
                meetingTitle: record.title,
                durationText: formatDuration(record.duration),
                speakerCount: record.speakerCount,
                folder: folder
            )
        }
    }

    private func formatDuration(_ d: TimeInterval?) -> String {
        guard let d else { return "" }
        let total = Int(d)
        let h = total / 3600
        let m = (total / 60) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
