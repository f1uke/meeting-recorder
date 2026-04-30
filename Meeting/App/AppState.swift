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
    let llm: LLMProvider
    /// Window picker model lives at app scope so the menu-bar popover and
    /// the standalone picker window share the same selection state.
    let picker: WindowPickerModel
    /// Calendar event index. Lives at app scope so the popover, recording
    /// window, and any future "today's agenda" view share one cached
    /// snapshot of the user's upcoming/current events.
    let calendar: CalendarStore
    /// Schedules "starts in 5 min" UNUserNotifications based on
    /// `calendar.upcomingEvents`. Owns no UI — `AppDelegate` handles the
    /// tap action via the shared `UNUserNotificationCenterDelegate`.
    let notifier: CalendarNotifier
    @Published private(set) var permissions = PermissionStatus()
    @Published private(set) var llmAvailability: LLMAvailability = .unavailable("not yet checked")

    /// Which view the unified main window is showing. Library on launch;
    /// switches to `.transcript` when the user opens a meeting from the
    /// detail pane or a popover row, and back via the transcript view's
    /// nav-rail back button / breadcrumb.
    @Published var route: AppRoute = .library

    /// Per-meeting summary generation status — keyed by MeetingRecord.id
    /// so Library detail and Transcript viewer can show a spinner /
    /// surfaced error inline without juggling local state.
    @Published private(set) var summaryGeneration: [MeetingRecord.ID: SummaryGenerationState] = [:]

    init() {
        self.recording = RecordingSession()
        let variant = AppPreferences.shared.modelVariant.rawValue
        self.transcribe = TranscriptionSession(provider: LocalProvider(modelVariant: variant))
        self.library = MeetingsLibrary()
        self.toast = ToastPresenter()
        self.llm = ClaudeCLIProvider()
        self.picker = WindowPickerModel()
        self.calendar = CalendarStore()
        self.notifier = CalendarNotifier(calendar: calendar)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.llmAvailability = await self.llm.availability()
            // Ask for notification permission lazily — only once we
            // have calendar access (otherwise there's nothing to notify
            // about). Safe to call repeatedly; the system caches the
            // user's prior answer.
            if self.calendar.authorization == .authorized {
                await self.notifier.requestAuthorizationIfNeeded()
            }
        }
    }

    /// Replace the underlying transcription provider — called when the
    /// user picks a different Whisper model in Settings. Cheap to do
    /// (model load is lazy on first transcribe), but no-ops mid-run so
    /// we don't yank a provider out from under an in-flight job.
    func applyModelVariantChange() {
        if case .running = transcribe.state { return }
        let variant = AppPreferences.shared.modelVariant.rawValue
        transcribe.replaceProvider(LocalProvider(modelVariant: variant))
    }

    func refreshPermissions() async {
        permissions = await PermissionManager.currentStatus()
    }

    func request(_ permission: Permission) async {
        await PermissionManager.request(permission)
        await refreshPermissions()
        if permission == .calendar {
            // Always refresh so CalendarStore.authorization picks up the
            // result (granted *or* denied) — its init reads the status
            // once and never sees changes that come through this code
            // path (which uses PermissionManager's own EKEventStore).
            calendar.refresh()
            if permissions.calendar {
                await notifier.requestAuthorizationIfNeeded()
            }
        }
    }

    /// Stop the active recording without running transcription. Used when
    /// the user has another meeting starting immediately and doesn't want
    /// to wait — the audio/video files are saved to the meeting folder so
    /// they can re-transcribe later from the Library.
    func stopOnly() async {
        // Capture the start time before stop() resets state to .idle so we
        // can show an accurate duration in the toast (transcript.json hasn't
        // been written yet, so MeetingRecord.duration is nil at this point).
        let startedAt: Date? = {
            if case let .recording(_, started) = recording.state { return started }
            return nil
        }()
        await recording.stop()
        guard let folder = recording.lastFolder else { return }
        library.rescan()
        let duration = startedAt.map { Date().timeIntervalSince($0) }
        if let record = library.meetings.first(where: { $0.folder == folder }) {
            toast.showRecordingSaved(
                meetingTitle: record.title,
                durationText: formatDuration(duration),
                folder: folder
            )
        }
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

    /// Re-run transcription on an existing meeting folder. Overwrites
    /// `transcript.{json,md,srt}` in place — any inline segment edits made
    /// in the Transcript Viewer are lost, so callers should confirm with
    /// the user first. Reuses the same `TranscriptionSession` as the
    /// post-recording flow, so progress shows in the menu-bar popover.
    func retranscribe(_ meeting: MeetingRecord) async {
        // Don't stomp on an already-running transcription (e.g. just
        // finished a recording). The button should be disabled in this
        // state, but the guard is cheap insurance.
        if case .running = transcribe.state { return }

        await transcribe.run(
            meetingFolder: meeting.folder,
            expectedSpeakers: AppPreferences.shared.expectedSpeakerCount.pyannoteValue
        )
        library.rescan()

        if case .done = transcribe.state,
           let record = library.meetings.first(where: { $0.folder == meeting.folder }) {
            toast.showTranscriptReady(
                meetingTitle: record.title,
                durationText: formatDuration(record.duration),
                speakerCount: record.speakerCount,
                folder: meeting.folder
            )
        }
    }

    /// Generate (or refresh) the AI summary for a meeting via the LLM
    /// provider. Pipes the meeting's transcript through Claude CLI,
    /// caches the result to summary.json, and re-publishes via
    /// `summaryGeneration` so any view watching the meeting picks up
    /// the new state.
    func generateSummary(for meeting: MeetingRecord) async {
        summaryGeneration[meeting.id] = .running
        do {
            let merged = try MergedTranscript.read(from: meeting.folder)
            let context = MeetingLLMContext(
                transcript: merged,
                speakerProfiles: meeting.speakerProfiles,
                calendarEvent: meeting.calendarEvent
            )
            let summary = try await llm.generateSummary(context: context)
            try summary.write(to: meeting.folder)
            summaryGeneration[meeting.id] = .done(summary)
            library.rescan()
        } catch {
            summaryGeneration[meeting.id] = .failed(error.localizedDescription)
        }
    }
}

enum SummaryGenerationState: Equatable {
    case running
    case done(Summary)
    case failed(String)
}

/// Top-level route for the unified main window. Library is the default;
/// `.transcript` swaps the layout to the viewer for the currently
/// selected meeting (the meeting itself is read off
/// `MeetingsLibrary.selectedMeeting`, so changing selection changes
/// what the transcript view loads without us having to thread the
/// MeetingRecord through the route).
enum AppRoute: Equatable {
    case library
    case transcript
}
