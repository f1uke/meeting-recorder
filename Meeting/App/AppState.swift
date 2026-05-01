import Foundation
import Combine

/// Top-level shared state for the app. Owns the long-lived recording and
/// transcription view models so the menu-bar label, popover, and the
/// expanded Recording / Transcript / Library windows all observe the same
/// instances and stay in sync.
@MainActor
final class AppState: ObservableObject {
    let recording: RecordingSession
    let queue: TranscriptionQueue
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

    /// Drives the Settings sheet on the main window. Toggled by the
    /// gear button in toolbars and the ⌘, menu command.
    @Published var showSettings: Bool = false

    /// Per-meeting summary generation status — keyed by MeetingRecord.id
    /// so Library detail and Transcript viewer can show a spinner /
    /// surfaced error inline without juggling local state.
    @Published private(set) var summaryGeneration: [MeetingRecord.ID: SummaryGenerationState] = [:]

    init() {
        self.recording = RecordingSession()
        let library = MeetingsLibrary()
        self.library = library
        let toast = ToastPresenter()
        self.toast = toast
        self.queue = TranscriptionQueue(
            providerFactory: { Self.makeProviderSnapshot() },
            library: library,
            toast: toast
        )
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
            // Resume any transcription jobs that died with the previous
            // app process. Library scan is async (runloop-deferred) so we
            // wait one tick to give it a chance to populate first; the
            // queue scan only relies on disk markers, not the in-memory
            // index, so the order isn't strictly required for correctness.
            self.queue.scanAndEnqueueOrphans(meetingsRoot: Self.meetingsRoot)
        }
    }

    /// Hook for Settings change notifications. Each new transcription job
    /// builds its own provider via `providerFactory` at enqueue time, so
    /// settings changes simply take effect on the next enqueue — no
    /// in-flight job gets its provider yanked. This shim exists for
    /// API-call-sites in SettingsView; nothing concrete needs to happen.
    func applyTranscriptionProviderChange() {
        // Intentionally empty — see doc comment.
    }

    /// Build a provider + descriptive name/model from current preferences.
    /// Captured per-job so concurrent enqueues during a settings change
    /// each see a consistent snapshot.
    private static func makeProviderSnapshot() -> TranscriptionQueue.ProviderSnapshot {
        let prefs = AppPreferences.shared
        switch prefs.transcriptionEngine {
        case .local:
            let p = LocalProvider(modelVariant: prefs.modelVariant.rawValue)
            return (provider: p, name: "Local WhisperKit", model: prefs.modelVariant.rawValue)
        case .gemini:
            let p = GeminiProvider(
                apiKey: prefs.geminiAPIKey,
                glossary: prefs.transcriptionGlossary,
                modelName: prefs.geminiModel.rawValue,
                useBatchAPI: prefs.geminiUseBatchAPI
            )
            let suffix = prefs.geminiUseBatchAPI ? " (batch)" : ""
            return (provider: p, name: "Gemini\(suffix)", model: prefs.geminiModel.rawValue)
        case .openai:
            let p = OpenAIProvider(
                apiKey: prefs.openaiAPIKey,
                glossary: prefs.transcriptionGlossary,
                modelName: prefs.openaiModel.rawValue,
                responseFormat: prefs.openaiModel.apiResponseFormat,
                chunkDuration: prefs.openaiModel.chunkDuration,
                supportsNativeDiarization: prefs.openaiModel.supportsNativeDiarization
            )
            return (provider: p, name: "OpenAI", model: prefs.openaiModel.rawValue)
        }
    }

    private static var meetingsRoot: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meetings", isDirectory: true)
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

    /// Stop the active recording and enqueue transcription. Returns
    /// immediately so the user can start another recording while the
    /// transcript runs in the background; the toast and Library row pick
    /// up completion later.
    func stopAndTranscribe() async {
        await recording.stop()
        guard let folder = recording.lastFolder else { return }
        // Pick up the new folder before transcription writes its JSON, so
        // the Library shows the recording immediately.
        library.rescan()
        queue.enqueue(
            meetingFolder: folder,
            expectedSpeakers: AppPreferences.shared.expectedSpeakerCount.pyannoteValue
        )
    }

    private func formatDuration(_ d: TimeInterval?) -> String {
        guard let d else { return "" }
        let total = Int(d)
        let h = total / 3600
        let m = (total / 60) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Re-run transcription on an existing meeting folder. Overwrites
    /// `transcript.{json,md,srt}` in place when the job completes — any
    /// inline segment edits made in the Transcript Viewer are lost, so
    /// callers should confirm with the user first.
    func retranscribe(_ meeting: MeetingRecord) async {
        queue.enqueue(
            meetingFolder: meeting.folder,
            expectedSpeakers: AppPreferences.shared.expectedSpeakerCount.pyannoteValue
        )
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
