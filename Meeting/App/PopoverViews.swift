import SwiftUI
import ScreenCaptureKit
import AppKit

// =============================================================================
// MARK: - Idle state
// =============================================================================

struct PopoverIdleView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var picker: WindowPickerModel
    @EnvironmentObject private var calendar: CalendarStore
    @ObservedObject private var prefs = AppPreferences.shared

    @Environment(\.openWindow) private var openWindow

    /// User-attached calendar event for this recording. Auto-populated by
    /// `CalendarMatcher` when the window picker selection changes; the
    /// user can switch events or detach via the card.
    @State private var selectedEvent: CalendarEvent?
    /// Tracks whether `selectedEvent` was auto-picked. Once the user
    /// manually picks (or detaches) an event, we stop overwriting their
    /// choice when the matcher rescores.
    @State private var eventIsAutoSelected = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(
                title: "Meeting",
                subtitle: "Ready to record",
                trailing: {
                    HStack(spacing: 6) {
                        GlassIconButton(systemImage: "gearshape", size: 26) {
                            openWindow(id: "main")
                            appState.showSettings = true
                        }
                        GlassIconButton(systemImage: "books.vertical", size: 26) {
                            appState.route = .library
                            openWindow(id: "main")
                        }
                    }
                }
            )

            BackgroundJobsCard()

            calendarSection

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Source")
                WindowPicker(model: picker)
            }

            SpeakerCountChip(selection: $prefs.expectedSpeakerCount)

            GlassButton(style: .accent, action: startRecording) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                    Text("Start Recording")
                }
            }
            .disabled(picker.selectedWindow == nil)

            if let error = recording.errorMessage {
                ErrorBanner(message: error)
            }

            RecentSection {
                appState.route = .library
                openWindow(id: "main")
            }
        }
        .task {
            if picker.windows.isEmpty {
                await picker.refresh()
            }
        }
        .onChange(of: picker.selectedWindow?.windowID) { _, _ in
            autoPickEventIfNeeded()
        }
        .onChange(of: calendar.relevantEvents) { _, _ in
            autoPickEventIfNeeded()
        }
        .onChange(of: selectedEvent?.id) { _, _ in
            // If the user picked or detached the event manually, treat
            // it as sticky — don't auto-overwrite on the next match cycle.
            // We can't tell "user changed it" vs "matcher changed it"
            // directly; use a small state flag set by the card actions.
        }
        .onAppear {
            autoPickEventIfNeeded()
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        switch calendar.authorization {
        case .authorized:
            CalendarNowCard(
                events: calendar.relevantEvents,
                selectedEvent: Binding(
                    get: { selectedEvent },
                    set: { newValue in
                        // Any binding write from the card is by definition
                        // user-initiated — make the choice sticky.
                        selectedEvent = newValue
                        eventIsAutoSelected = false
                    }
                )
            )
        case .notDetermined:
            CalendarPermissionPromptCard(
                state: .notDetermined,
                onAllow: {
                    Task { await appState.request(.calendar) }
                }
            )
        case .denied, .writeOnly:
            CalendarPermissionPromptCard(
                state: .denied,
                onAllow: {
                    // Re-prompt path: even though the system has us as
                    // .denied, this triggers an EventKit query that
                    // refreshes our local cache; if the user enabled
                    // access externally (System Settings, tccutil)
                    // CalendarStore picks it up.
                    Task { await appState.request(.calendar) }
                }
            )
        }
    }

    private func autoPickEventIfNeeded() {
        guard eventIsAutoSelected else { return }
        let bundleID = picker.selectedWindow?.owningApplication?.bundleIdentifier
        let best = CalendarMatcher.bestMatch(
            events: calendar.relevantEvents,
            now: Date(),
            windowBundleID: bundleID
        )
        selectedEvent = best?.event
    }

    private func startRecording() {
        guard let win = picker.selectedWindow else { return }
        let event = selectedEvent
        Task { await recording.start(window: win, event: event) }
    }
}

/// Compact card prompting for calendar access. Two states:
///   - `.notDetermined` — the user has never been asked. Allow triggers
///     the in-app TCC prompt path.
///   - `.denied` — the user (or the system) said no previously, so
///     `EKEventStore.requestFullAccessToEvents` will return immediately
///     without re-prompting. We surface the System Settings deep link
///     as the only working escape hatch.
///
/// The "Open System Settings" link appears in *both* states because some
/// menu-bar (`.accessory`) apps don't reliably get a TCC dialog even
/// with `NSApp.activate()` — giving the user a manual path means the
/// feature is still reachable when EventKit's auto-prompt misfires.
private struct CalendarPermissionPromptCard: View {
    enum State { case notDetermined, denied }

    let state: State
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: state == .denied ? "calendar.badge.exclamationmark" : "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state == .denied ? Color.warmMark : Color.brandAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                        .lineLimit(3)
                }
                Spacer(minLength: 6)
                if state == .notDetermined {
                    Button(action: onAllow) {
                        Text("Allow")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                Capsule().fill(LinearGradient(
                                    colors: [Color.brandAccent, Color.brandAccentStrong],
                                    startPoint: .top, endPoint: .bottom
                                ))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: openCalendarSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 9))
                    Text(state == .denied ? "Open System Settings" : "Or open System Settings")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.brandAccent)
                .padding(.leading, 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (state == .denied ? Color.warmMark : Color.brandAccent).opacity(0.30),
                            lineWidth: 0.5
                        )
                }
        }
    }

    private var titleText: String {
        switch state {
        case .notDetermined: "Connect Apple Calendar"
        case .denied: "Calendar access blocked"
        }
    }

    private var detailText: String {
        switch state {
        case .notDetermined:
            "Pre-fill meeting titles and attendees from your calendar."
        case .denied:
            "Enable Meeting under Privacy & Security → Calendars to use event titles and attendee lists."
        }
    }

    private func openCalendarSettings() {
        // Direct deep link to Privacy → Calendars in System Settings.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.warmMark)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.warmMark.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.warmMark.opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}

// =============================================================================
// MARK: - Recording state
// =============================================================================

struct PopoverRecordingView: View {
    let folder: URL
    let started: Date
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PulseDot()
                Text("RECORDING")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Color.recordRed)
                Spacer()
                Text(started, style: .timer)
                    .font(.mono(13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                GlassIconButton(systemImage: "books.vertical", size: 24) {
                    appState.route = .library
                    openWindow(id: "main")
                }
                .help("Open Library")
            }

            BackgroundJobsCard()

            if let event = recording.currentEvent {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let count = event.totalAttendeeCount
                    if count > 0 {
                        Text("· \(count) attendee\(count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textDim)
                    }
                }
            }

            if let title = sourceLabel {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(spacing: 6) {
                LiveChannelMeter(
                    label: "You · mic",
                    color: .brandAccent,
                    buffer: recording.micRMS
                )
                LiveChannelMeter(
                    label: "Meeting",
                    color: .warmMark,
                    buffer: recording.outputRMS
                )
            }

            VStack(spacing: 6) {
                GlassButton(style: .danger, action: stopAndTranscribe) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("Stop & Transcribe")
                        Text("⌘.").font(.mono(10)).opacity(0.7)
                    }
                }
                .keyboardShortcut(".", modifiers: .command)

                Button(action: stopOnly) {
                    HStack(spacing: 4) {
                        Text("Stop only · Save for later")
                        Text("⇧⌘.").font(.mono(10)).opacity(0.7)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .help("Stop the recording and save it. Transcribe later from Library.")
            }
        }
    }

    private var sourceLabel: String? {
        let title = recording.currentSourceTitle
        let app = recording.currentSourceApp
        switch (title, app) {
        case (let t?, let a?): return "\(t) — \(a)"
        case (let t?, nil): return t
        case (nil, let a?): return a
        case (nil, nil): return folder.lastPathComponent
        }
    }

    private func stopAndTranscribe() {
        Task { await appState.stopAndTranscribe() }
    }

    private func stopOnly() {
        Task { await appState.stopOnly() }
    }
}

// =============================================================================
// MARK: - Starting / Stopping (transient)
// =============================================================================

struct PopoverTransientView: View {
    let label: String
    var hint: String? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// =============================================================================
// MARK: - Background jobs card (idle-view inset)
// =============================================================================

/// Small status block that appears at the top of the popover idle view
/// whenever the transcription queue has work in flight. Click to open the
/// Library and select the running meeting.
struct BackgroundJobsCard: View {
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var library: MeetingsLibrary
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let running = queue.runningJob {
            content(running: running)
        } else if queue.activeCount > 0 {
            // Edge case: nothing running but jobs queued (worker hop in
            // progress). Show a generic "queued" message so the indicator
            // doesn't disappear and reappear.
            queuedOnlyContent
        }
    }

    @ViewBuilder
    private func content(running: TranscriptionJob) -> some View {
        let title = library.meetings.first(where: { $0.folder == running.meetingFolder })?.title
            ?? running.meetingFolder.lastPathComponent
        Button(action: { openInLibrary(folder: running.meetingFolder) }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                    Text("Transcribing")
                        .font(.system(size: 11, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Color.brandAccent)
                    Spacer()
                    Text(percentText(for: running))
                        .font(.mono(11))
                        .foregroundStyle(Color.textDim)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressBar(value: progressValue(for: running))
                    .frame(height: 4)
                if queue.queuedCount > 0 {
                    Text("\(queue.queuedCount) queued")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textFaint)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.brandAccent.opacity(0.30), lineWidth: 0.5)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var queuedOnlyContent: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(queue.activeCount) transcription\(queue.activeCount == 1 ? "" : "s") queued")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.brandAccent.opacity(0.20), lineWidth: 0.5)
                }
        }
    }

    private func progressValue(for job: TranscriptionJob) -> Double {
        if case let .running(_, overall) = job.state { return overall }
        return 0
    }

    private func percentText(for job: TranscriptionJob) -> String {
        let pct = Int((progressValue(for: job) * 100).rounded())
        return "\(pct)%"
    }

    private func openInLibrary(folder: URL) {
        if let record = library.meetings.first(where: { $0.folder == folder }) {
            library.selection = record.id
        }
        appState.route = .library
        openWindow(id: "main")
    }
}

private struct ProgressBar: View {
    let value: Double  // 0...1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.brandAccent, Color.brandAccent.opacity(0.7)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: proxy.size.width * max(0, min(1, value)))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
    }
}

// =============================================================================
// MARK: - Header
// =============================================================================

struct PopoverHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

// =============================================================================
// MARK: - Speaker count chip
// =============================================================================

struct SpeakerCountChip: View {
    @Binding var selection: ExpectedSpeakers
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            Text("Expected speakers")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(ExpectedSpeakers.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            scheme == .dark
                                ? Color.white.opacity(0.14)
                                : Color.white.opacity(0.45),
                            lineWidth: 0.5
                        )
                }
        }
    }
}

// =============================================================================
// MARK: - Recent section (stub for U3, real data in U5)
// =============================================================================

struct RecentSection: View {
    @EnvironmentObject private var library: MeetingsLibrary
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let openLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Recent")
                Spacer()
                Button(action: openLibrary) {
                    HStack(spacing: 2) {
                        Text("Open Library")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if library.recent.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(Color.textFaint)
                    Text("No recent meetings yet")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textFaint)
                }
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(library.recent) { meeting in
                        Button {
                            library.selection = meeting.id
                            appState.route = .transcript
                            openWindow(id: "main")
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.brandAccent.opacity(0.7))
                                    .frame(width: 6, height: 6)
                                Text(meeting.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(durationText(meeting))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.textDim)
                                Text(relativeText(meeting))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.textFaint)
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
                .offset(y: -8)
        }
    }

    private func durationText(_ m: MeetingRecord) -> String {
        guard let d = m.duration else { return "—" }
        let total = Int(d)
        let h = total / 3600
        let mm = (total / 60) % 60
        return h > 0 ? "\(h)h\(mm)m" : "\(mm)m"
    }

    private func relativeText(_ m: MeetingRecord) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: m.recordedAt, relativeTo: Date())
    }
}

// =============================================================================
// MARK: - Live waveform (driven by RMSRingBuffer)
// =============================================================================

struct LiveChannelMeter: View {
    let label: String
    let color: Color
    let buffer: RMSRingBuffer
    /// Number of bars to render. Popover uses 24, recording window uses 96.
    var barCount: Int = 24
    /// Visual refresh rate. ~15 Hz feels smooth without melting CPU.
    var refreshHz: Double = 15

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / refreshHz)) { _ in
            let levels = buffer.snapshot(last: barCount)
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textDim)
                    .frame(width: 64, alignment: .leading)

                WaveformBars(levels: levels, color: color)
                    .frame(height: 22)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                    }

                Text(peakText)
                    .font(.mono(9))
                    .foregroundStyle(Color.textFaint)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private var peakText: String {
        String(format: "%.0fdB", buffer.peakDB())
    }
}

