import SwiftUI

/// Two-pane Library window. List (meetings) · Detail (metadata + speakers
/// strip + AI summary + action items).
struct LibraryView: View {
    var body: some View {
        HStack(spacing: 0) {
            LibraryList()
                .frame(width: 380)

            Divider().opacity(0.3)

            LibraryDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 700)
        .background {
            LinearGradient(
                colors: [
                    Color(
                        light: Color(red: 0.96, green: 0.97, blue: 1.00),
                        dark: Color(red: 0.09, green: 0.10, blue: 0.13)
                    ),
                    Color(
                        light: Color(red: 0.92, green: 0.94, blue: 0.99),
                        dark: Color(red: 0.05, green: 0.06, blue: 0.09)
                    ),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

// =============================================================================
// MARK: - List
// =============================================================================

private struct LibraryList: View {
    @EnvironmentObject private var library: MeetingsLibrary

    var body: some View {
        ZStack {
            Color.clear
                .background(.regularMaterial)
                .overlay(Color.white.opacity(0.05))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ListToolbar()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                        ForEach(grouped, id: \.0) { (group, items) in
                            Text(group.uppercased())
                                .font(.sectionLabel)
                                .kerning(0.8)
                                .foregroundStyle(Color.textDim)
                                .padding(.top, 12)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                            ForEach(items) { meeting in
                                MeetingRow(
                                    meeting: meeting,
                                    isSelected: library.selection == meeting.id
                                ) { library.selection = meeting.id }
                            }
                        }

                        if library.visibleMeetings.isEmpty {
                            EmptyListPlaceholder()
                                .padding(.top, 64)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var grouped: [(String, [MeetingRecord])] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!

        var today: [MeetingRecord] = []
        var yesterday: [MeetingRecord] = []
        var thisWeek: [MeetingRecord] = []
        var earlier: [MeetingRecord] = []

        for m in library.visibleMeetings {
            if m.recordedAt >= startOfToday { today.append(m) }
            else if m.recordedAt >= startOfYesterday { yesterday.append(m) }
            else if m.recordedAt >= startOfWeek { thisWeek.append(m) }
            else { earlier.append(m) }
        }

        var groups: [(String, [MeetingRecord])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This week", thisWeek)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }
        return groups
    }
}

private struct ListToolbar: View {
    @EnvironmentObject private var library: MeetingsLibrary
    @EnvironmentObject private var appState: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(library.visibleMeetings.count) meeting\(library.visibleMeetings.count == 1 ? "" : "s")")
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .tracking(-0.3)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
                TextField("Search…", text: $library.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                Text("⌘F").font(.mono(10)).foregroundStyle(Color.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 200)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
            // Hidden button focuses the search field on ⌘F. Visible label
            // is suppressed so the shortcut is honored without showing a
            // duplicate control next to the field.
            .background {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            Button(action: { appState.showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textDim)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject private var library: MeetingsLibrary
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var queue: TranscriptionQueue

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Avatar(initials: initials, color: avatarColor, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(dateText)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.textDim)
                    HStack(spacing: 8) {
                        Label(durationText, systemImage: "clock")
                            .font(.system(size: 10.5))
                            .labelStyle(.titleAndIcon)
                        if meeting.speakerCount > 0 {
                            Label("\(meeting.speakerCount)", systemImage: "person.2.fill")
                                .font(.system(size: 10.5))
                                .labelStyle(.titleAndIcon)
                        }
                        statusBadge
                    }
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.textFaint)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.brandAccent, Color.brandAccentStrong],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .shadow(color: Color.brandAccentStrong.opacity(0.30), radius: 6, y: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                library.selection = meeting.id
                appState.route = .transcript
            }
        )
    }

    /// Inline transcription-status badge appended to the meta row when
    /// the queue has work for this folder. Tints by tone:
    ///   - blue capsule  → queued / transcribing (with %)
    ///   - amber capsule → failed (clickable retry handled in detail)
    ///   - none          → idle / completed
    @ViewBuilder
    private var statusBadge: some View {
        if let job = queue.latestJob(forFolder: meeting.folder) {
            switch job.state {
            case .queued:
                StatusPill(text: "Queued", tone: .info, isSelected: isSelected)
            case let .running(_, overall):
                StatusPill(
                    text: "Transcribing \(Int((overall * 100).rounded()))%",
                    tone: .info,
                    isSelected: isSelected
                )
            case .failed:
                StatusPill(text: "Failed", tone: .warning, isSelected: isSelected)
            case .done, .cancelled:
                EmptyView()
            }
        }
    }

    private var initials: String {
        let words = meeting.title.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }
        let combined = chars.joined()
        return combined.isEmpty ? "M" : String(combined.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        let palette: [Color] = [.tagEngineering, .tagDesign, .tagPeople, .tagResearch, .tagOneOnOne]
        return palette[abs(meeting.id.hashValue) % palette.count]
    }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: meeting.recordedAt)
    }

    private var durationText: String {
        guard let d = meeting.duration else { return "—" }
        let total = Int(d)
        let h = total / 3600
        let m = (total / 60) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

private struct EmptyListPlaceholder: View {
    @EnvironmentObject private var library: MeetingsLibrary

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.textFaint)
            Text(library.search.isEmpty ? "No meetings yet" : "No matches")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textDim)
            if library.search.isEmpty {
                Text("Start a recording from the menu bar to see it here")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// =============================================================================
// MARK: - Detail
// =============================================================================

private struct LibraryDetail: View {
    @EnvironmentObject private var library: MeetingsLibrary
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Color.clear
                .background(.regularMaterial)
                .ignoresSafeArea()

            if let meeting = library.selectedMeeting {
                VStack(spacing: 0) {
                    DetailToolbar(meeting: meeting)
                    JobStatusBanner(meeting: meeting)
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            DetailHero(meeting: meeting)
                            if meeting.calendarEvent != nil {
                                CalendarDetailSection(meeting: meeting)
                            }
                            AISummarySection(meeting: meeting)
                            ActionItemsSection(meeting: meeting)
                            if !meeting.contextItems.isEmpty {
                                ContextItemsSection(meeting: meeting)
                            }
                            if !meeting.speakers.isEmpty {
                                SpeakersStrip(meeting: meeting)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                    }
                }
            } else {
                EmptyDetailPlaceholder()
            }
        }
    }
}

private struct DetailToolbar: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: MeetingsLibrary
    @EnvironmentObject private var queue: TranscriptionQueue
    @Environment(\.openWindow) private var openWindow
    @AppStorage("dev.fluke.meeting.summaryDisclosureSeen") private var disclosureSeen = false
    @State private var showDisclosure = false
    @State private var showRetranscribeConfirm = false
    @State private var showDeleteConfirm = false

    private var summaryEnabled: Bool {
        meeting.hasTranscript && appState.llmAvailability == .available && !isGeneratingSummary
    }

    private var isGeneratingSummary: Bool {
        if case .running = appState.summaryGeneration[meeting.id] { return true }
        return false
    }

    private var hasAudio: Bool {
        let fm = FileManager.default
        let mic = meeting.folder.appendingPathComponent("mic.m4a")
        let out = meeting.folder.appendingPathComponent("output.m4a")
        return fm.fileExists(atPath: mic.path) && fm.fileExists(atPath: out.path)
    }

    private var isTranscribing: Bool {
        queue.activeJob(forFolder: meeting.folder) != nil
    }

    private var retranscribeEnabled: Bool {
        hasAudio && !isTranscribing
    }

    private func generateOrRegenerate() async {
        if !disclosureSeen {
            showDisclosure = true
            return
        }
        await appState.generateSummary(for: meeting)
    }

    private var summaryHelpText: String {
        guard summaryEnabled else {
            return "Install Claude Code: npm i -g @anthropic-ai/claude-code"
        }
        let vault = AppPreferences.shared.meetingNotesFolder
        let prefix = meeting.summary == nil
            ? "Generate AI summary via Claude"
            : "Regenerate via Claude"
        return "\(prefix); writes Markdown note to \(vault)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            ToolbarButton(icon: "play.fill", label: "Open Transcript") {
                appState.route = .transcript
            }
            .disabled(!meeting.hasTranscript)

            ToolbarButton(
                icon: "arrow.clockwise",
                label: meeting.hasTranscript ? "Re-transcribe" : "Transcribe"
            ) {
                if meeting.hasTranscript {
                    showRetranscribeConfirm = true
                } else {
                    Task { await appState.retranscribe(meeting) }
                }
            }
            .disabled(!retranscribeEnabled)
            .help(
                hasAudio
                    ? (isTranscribing
                        ? "Already transcribing"
                        : (meeting.hasTranscript
                            ? "Re-run WhisperKit + SpeakerKit on this meeting"
                            : "Run WhisperKit + SpeakerKit on this meeting"))
                    : "Audio files (mic.m4a / output.m4a) not found in folder"
            )

            ToolbarButton(
                icon: isGeneratingSummary ? "ellipsis" : "sparkles",
                label: isGeneratingSummary ? "Generating…" : "Summary"
            ) {
                Task { await generateOrRegenerate() }
            }
            .disabled(!summaryEnabled)
            .help(summaryHelpText)

            ToolbarButton(icon: "square.and.arrow.down", label: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }

            ToolbarButton(icon: "trash", label: "Delete") {
                showDeleteConfirm = true
            }
            .help("Move this meeting to the Trash")

            Toggle(isOn: starredBinding) {
                Image(systemName: meeting.starred ? "star.fill" : "star")
                    .foregroundStyle(meeting.starred ? Color.warmMark : Color.textDim)
                    .frame(width: 18, height: 18)
            }
            .toggleStyle(.button)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
        .alert("Send transcript to Claude?", isPresented: $showDisclosure) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                disclosureSeen = true
                Task { await appState.generateSummary(for: meeting) }
            }
        } message: {
            Text("AI summary uses your Claude Code installation to generate a summary, action items, and a Markdown meeting note (saved to your notes folder). The transcript will be sent to Claude. This is the only step that ever leaves your Mac — recording and transcription stay local.")
        }
        .alert("Re-transcribe meeting?", isPresented: $showRetranscribeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Re-transcribe", role: .destructive) {
                Task { await appState.retranscribe(meeting) }
            }
        } message: {
            Text("This overwrites transcript.json, transcript.md, and transcript.srt. Any inline segment edits in the Transcript Viewer will be lost. The cached AI summary will become out of date — regenerate it after.")
        }
        .alert("Delete this meeting?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                library.delete(meeting: meeting.id)
            }
        } message: {
            Text("\(meeting.folder.lastPathComponent) will be moved to the Trash, including the recording, transcripts, and AI summary. You can recover it from the Trash until you empty it.")
        }
    }

    private var starredBinding: Binding<Bool> {
        Binding(
            get: { meeting.starred },
            set: { newValue in
                library.update(meeting: meeting.id) { $0.starred = newValue }
            }
        )
    }
}

private struct ToolbarButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DetailHero: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var library: MeetingsLibrary
    @State private var isEditingTitle = false
    @State private var draftTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(meeting.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.brandAccent.opacity(0.15)))
                        .foregroundStyle(Color.brandAccentStrong)
                }
                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
            }

            if isEditingTitle {
                HStack {
                    TextField("Meeting title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.serif(32))
                        .foregroundStyle(Color.textPrimary)
                        .onSubmit { saveTitle() }
                    Button("Save", action: saveTitle).keyboardShortcut(.return)
                    Button("Cancel") { isEditingTitle = false }
                        .keyboardShortcut(.escape)
                }
            } else {
                Text(meeting.title)
                    .font(.serif(32))
                    .foregroundStyle(Color.textPrimary)
                    .onTapGesture(count: 2) {
                        draftTitle = meeting.title
                        isEditingTitle = true
                    }
            }
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        parts.append(f.string(from: meeting.recordedAt))
        if let d = meeting.duration {
            parts.append(formatDuration(d))
        }
        if !meeting.hasTranscript {
            parts.append("transcript pending")
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let total = Int(d)
        let h = total / 3600
        let m = (total / 60) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func saveTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isEditingTitle = false
            return
        }
        library.update(meeting: meeting.id) { $0.title = trimmed }
        isEditingTitle = false
    }
}

private struct SpeakersStrip: View {
    let meeting: MeetingRecord

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Speakers · \(meeting.speakers.count)")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(meeting.speakers) { speaker in
                    SpeakerCard(speaker: speaker)
                }
            }
        }
    }
}

private struct SpeakerCard: View {
    let speaker: Speaker

    var body: some View {
        HStack(spacing: 6) {
            Avatar(initials: initials, color: avatarColor, size: 18)
            Text(speaker.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        }
        .glassBorder(cornerRadius: 10)
    }

    private var initials: String {
        let words = speaker.displayName.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }
        return chars.joined().uppercased()
    }

    private var avatarColor: Color {
        let palette: [Color] = [.tagEngineering, .tagDesign, .tagPeople, .tagResearch, .tagOneOnOne]
        return palette[abs(speaker.id.rawValue.hashValue) % palette.count]
    }
}

private struct EmptyDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.righthalf.filled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.textFaint)
            Text("Select a meeting")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.textDim)
            Text("Pick one from the list to see its details")
                .font(.system(size: 11))
                .foregroundStyle(Color.textFaint)
        }
    }
}

// =============================================================================
// MARK: - AI Summary section (U8b — Claude CLI)
// =============================================================================

private struct AISummarySection: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch state {
        case .running:
            runningCard
        case .failed(let message):
            errorCard(message)
        case .ready(let summary):
            summaryCard(summary)
        case .empty:
            EmptyView()
        }
    }

    private enum DisplayState {
        case empty
        case running
        case failed(String)
        case ready(Summary)
    }

    private var state: DisplayState {
        if let live = appState.summaryGeneration[meeting.id] {
            switch live {
            case .running: return .running
            case .failed(let msg): return .failed(msg)
            case .done(let summary): return .ready(summary)
            }
        }
        if let cached = meeting.summary { return .ready(cached) }
        return .empty
    }

    private func summaryCard(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brandAccentStrong)
                SectionLabel(text: "Summary")
                    .foregroundStyle(Color.brandAccentStrong)
                Spacer()
                Text("\(summary.providerName) · \(formattedDate(summary.generatedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textFaint)
            }
            Text(boldified(summary.summary))
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .foregroundStyle(Color.textPrimary.opacity(0.85))
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.brandAccent.opacity(0.10),
                        Color(red: 0.85, green: 0.55, blue: 0.95).opacity(0.07),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        }
        .glassBorder(cornerRadius: 14)
    }

    private var runningCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Generating summary via Claude…")
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.warmMark)
                Text("Summary failed").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
                .lineLimit(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.warmMark.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.warmMark.opacity(0.3), lineWidth: 0.5)
                }
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// Renders **bold** markdown spans inline. Falls back to plain text on
    /// parse error.
    private func boldified(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )) {
            return attr
        }
        return AttributedString(s)
    }
}

// =============================================================================
// MARK: - Action items list
// =============================================================================

private struct ActionItemsSection: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let items = items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.textDim)
                    SectionLabel(text: "Action items · \(items.count)")
                }
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        ActionItemRow(item: item)
                    }
                }
            }
        }
    }

    private var items: [ActionItem]? {
        if case let .done(summary) = appState.summaryGeneration[meeting.id] {
            return summary.actionItems
        }
        return meeting.summary?.actionItems
    }
}

private struct ActionItemRow: View {
    let item: ActionItem

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.textFaint, lineWidth: 1.2)
                .frame(width: 14, height: 14)
            Text(item.speaker)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.brandAccentStrong)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(Color.brandAccent.opacity(0.18))
                }
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 6)
            Text(item.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.textFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(.regularMaterial)
        }
        .glassBorder(cornerRadius: 9)
    }
}

// =============================================================================
// MARK: - Context items (clipboard + browser-URL captures)
// =============================================================================

/// Card on the Library detail surfacing what the user copied and which
/// links they opened during the meeting, with per-item delete. Same
/// curation behaviour as the Transcript Viewer's ContextPanel — the
/// user can prune unrelated copies before the next AI summary picks
/// them up.
struct ContextItemsSection: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var library: MeetingsLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textDim)
                SectionLabel(text: "Captured · \(meeting.contextItems.count)")
                Spacer()
            }
            VStack(spacing: 4) {
                ForEach(meeting.contextItems) { item in
                    ContextItemRow(
                        item: item,
                        meetingFolder: meeting.folder,
                        onDelete: {
                            library.deleteContextItem(
                                meeting: meeting.id,
                                itemID: item.id
                            )
                        }
                    )
                }
            }
        }
    }
}

/// One row in the context list. Used by both the Library detail (read-
/// only) and the Transcript Viewer (with delete). `onDelete == nil`
/// hides the trailing trash button.
struct ContextItemRow: View {
    let item: ContextItem
    let meetingFolder: URL
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                if let title = primaryLine {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                }
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Text(formatOffset(item.offset))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.textFaint)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from context")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(.regularMaterial)
        }
        .glassBorder(cornerRadius: 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click opens the URL or reveals the image in Finder
            // — gives the user a way to inspect a row without leaving
            // the Library/Transcript view.
            handleOpen()
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
        case .url:
            Image(systemName: item.source == .browser ? "safari" : "link")
                .font(.system(size: 12))
                .foregroundStyle(Color.brandAccent)
        case .image:
            if let thumb = thumbnail() {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textDim)
            }
        }
    }

    private var primaryLine: String? {
        switch item.kind {
        case .text:
            return item.text?.replacingOccurrences(of: "\n", with: " ")
        case .url:
            return item.pageTitle ?? item.text
        case .image:
            return "Image"
        }
    }

    private var secondaryLine: String? {
        switch item.kind {
        case .text:
            switch item.source {
            case .clipboard: return "Clipboard"
            case .browser: return nil
            }
        case .url:
            // For a browser visit, primary line is the page title and
            // secondary is the URL itself. For a clipboard URL, primary
            // is the URL and we don't need a secondary.
            if item.pageTitle != nil { return item.text }
            return item.browserName ?? "Clipboard"
        case .image:
            return item.imageFilename
        }
    }

    private func thumbnail() -> NSImage? {
        guard item.kind == .image, let filename = item.imageFilename else { return nil }
        let url = ContextCaptureFile.imagesFolder(in: meetingFolder)
            .appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }

    private func handleOpen() {
        switch item.kind {
        case .url:
            if let str = item.text, let url = URL(string: str) {
                NSWorkspace.shared.open(url)
            }
        case .image:
            if let filename = item.imageFilename {
                let url = ContextCaptureFile.imagesFolder(in: meetingFolder)
                    .appendingPathComponent(filename)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .text:
            // Plain text — copy back to clipboard for the user's
            // convenience. No side effect on disk.
            if let text = item.text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func formatOffset(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Calendar section

/// Detail-pane card surfacing the `CalendarEvent` captured at recording
/// time: organizer, attendees with chips, location, and the conference URL
/// (clickable). Hidden when the meeting has no calendar.json.
private struct CalendarDetailSection: View {
    let meeting: MeetingRecord

    private var event: CalendarEvent? { meeting.calendarEvent }

    var body: some View {
        guard let event else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    SectionLabel(text: "Calendar")
                    Spacer()
                    if let url = event.openInCalendarURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 3) {
                                Text("Open in Calendar")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.brandAccent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(event.title)
                            .font(.serif(20))
                            .foregroundStyle(Color.textPrimary)

                        timeAndCalendarRow(event: event)

                        if let location = event.location, !location.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.textDim)
                                Text(location)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(2)
                            }
                        }

                        if let conf = event.conferenceURL {
                            Button {
                                NSWorkspace.shared.open(conf)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 11))
                                    Text(conf.host ?? conf.absoluteString)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundStyle(Color.brandAccent)
                            }
                            .buttonStyle(.plain)
                        }

                        if let organizer = event.organizer {
                            attendeeRow(label: "Organizer", attendees: [organizer])
                        }

                        if !event.attendees.isEmpty {
                            attendeeRow(
                                label: "Attendees · \(event.attendees.count)",
                                attendees: event.attendees
                            )
                        }

                        if !meeting.meetParticipants.isEmpty {
                            meetParticipantsRow(names: meeting.meetParticipants)
                        }
                    }
                    .padding(Tokens.cardPadding)
                }
            }
        )
    }

    private func timeAndCalendarRow(event: CalendarEvent) -> some View {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let timeText = "\(f.string(from: event.startDate)) – \(timeOnly(event.endDate))"
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textDim)
                Text(timeText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textPrimary)
            }
            if let cal = event.calendarName, !cal.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textDim)
                    Text(cal)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textDim)
                }
            }
        }
    }

    private func timeOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func attendeeRow(label: String, attendees: [CalendarAttendee]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textDim)
            FlowLayout(spacing: 6) {
                ForEach(attendees) { attendee in
                    AttendeeChip(attendee: attendee)
                }
            }
        }
    }

    private func meetParticipantsRow(names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Joined via Meet · \(names.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.textDim)
                Image(systemName: "video.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textDim)
            }
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    MeetParticipantChip(name: name)
                }
            }
        }
    }
}

/// Slim chip for a Meet-scraped participant — no email/role/isMe data, just
/// the display name as Meet's UI showed it. Visually distinct from
/// AttendeeChip (calendar source) so the user can see at a glance which
/// list a name came from.
private struct MeetParticipantChip: View {
    let name: String

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map { String($0) } }.joined().uppercased()
    }

    private var chipColor: Color {
        // Stable per-name color via hash → tag palette. Cycles through 5
        // hues so a long list of participants doesn't look monochrome.
        let palette: [Color] = [
            Color(red: 0.55, green: 0.45, blue: 0.85),
            Color(red: 0.45, green: 0.65, blue: 0.85),
            Color(red: 0.85, green: 0.55, blue: 0.45),
            Color(red: 0.55, green: 0.75, blue: 0.55),
            Color(red: 0.85, green: 0.65, blue: 0.55),
        ]
        let h = abs(name.hashValue)
        return palette[h % palette.count]
    }

    var body: some View {
        HStack(spacing: 6) {
            Avatar(initials: initials, color: chipColor, size: 16)
            Text(name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.regularMaterial)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }
}

private struct AttendeeChip: View {
    let attendee: CalendarAttendee

    var body: some View {
        HStack(spacing: 6) {
            Avatar(initials: initials, color: chipColor, size: 16)
            Text(attendee.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            if attendee.isMe {
                Text("you")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(Color.brandAccent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(.regularMaterial)
        }
    }

    private var initials: String {
        let parts = attendee.displayName
            .split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2)
        let chars = parts.compactMap { $0.first }
        return String(chars).uppercased()
    }

    private var chipColor: Color {
        attendee.isMe ? Color.brandAccent : Color.textDim
    }
}

// =============================================================================
// MARK: - Transcription status (queue-driven)
// =============================================================================

/// Inline tag rendered in `MeetingRow`'s metadata strip and (in a larger
/// form) by `JobStatusBanner` below. Picks tone-appropriate colours and
/// inverts when the parent row is the selected blue background.
private struct StatusPill: View {
    enum Tone { case info, warning }
    let text: String
    let tone: Tone
    let isSelected: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(textColor)
            .background {
                Capsule().fill(backgroundColor)
            }
    }

    private var backgroundColor: Color {
        if isSelected { return Color.white.opacity(0.25) }
        switch tone {
        case .info:    return Color.brandAccent.opacity(0.15)
        case .warning: return Color.warmMark.opacity(0.18)
        }
    }

    private var textColor: Color {
        if isSelected { return .white }
        switch tone {
        case .info:    return Color.brandAccent
        case .warning: return Color.warmMark
        }
    }
}

/// Status strip rendered between the detail toolbar and the scrollable
/// content when the queue has work for this meeting. Lets the user
/// cancel an in-flight or queued job and retry one that failed without
/// having to dig into a settings menu.
private struct JobStatusBanner: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var queue: TranscriptionQueue

    var body: some View {
        if let job = queue.latestJob(forFolder: meeting.folder),
           !shouldHide(job: job) {
            content(for: job)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Rectangle().fill(backgroundColor(for: job))
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                }
        }
    }

    private func shouldHide(job: TranscriptionJob) -> Bool {
        // Don't surface successful or cancelled jobs — those are normal
        // outcomes; the row badge already disappears for them.
        switch job.state {
        case .done, .cancelled: return true
        default: return false
        }
    }

    @ViewBuilder
    private func content(for job: TranscriptionJob) -> some View {
        HStack(spacing: 12) {
            switch job.state {
            case .queued:
                ProgressView().controlSize(.small)
                Text("Queued for transcription")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("· \(queueLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                Spacer()
                Button("Cancel") { queue.cancel(job.id) }
                    .controlSize(.small)
            case let .running(stage, overall):
                Image(systemName: "waveform")
                    .foregroundStyle(Color.brandAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.localizedName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("\(Int((overall * 100).rounded()))% · \(job.providerName) (\(job.modelName))")
                        .font(.mono(11))
                        .foregroundStyle(Color.textDim)
                    if let status = job.lastStatus {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("\(status.summary) · last check \(status.relativeAgo(now: ctx.date))")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.textFaint)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                }
                Spacer()
                Button("Cancel") { queue.cancel(job.id) }
                    .controlSize(.small)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.warmMark)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription failed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                        .lineLimit(2)
                }
                Spacer()
                Button("Retry") { queue.retry(job.id) }
                    .controlSize(.small)
                Button("Dismiss") { queue.dismiss(job.id) }
                    .controlSize(.small)
            case .done, .cancelled:
                EmptyView()  // hidden via shouldHide
            }
        }
    }

    private func backgroundColor(for job: TranscriptionJob) -> Color {
        switch job.state {
        case .failed: return Color.warmMark.opacity(0.10)
        default:      return Color.brandAccent.opacity(0.08)
        }
    }

    /// Position-in-queue suffix for queued jobs. Just shows "next up" if
    /// this is the head of the queue, otherwise "Nth in queue".
    private var queueLabel: String {
        let queued = queue.jobs.compactMap { job -> TranscriptionJob? in
            if case .queued = job.state { return job }
            return nil
        }
        guard let idx = queued.firstIndex(where: { $0.meetingFolder == meeting.folder }) else {
            return "queued"
        }
        return idx == 0 ? "next up" : "\(idx + 1) in queue"
    }
}

/// Minimal flow layout for attendee chips. SwiftUI's built-in `Layout`
/// machinery; wraps to next line when horizontal space runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let arranged = arrange(subviews: subviews, in: width)
        return arranged.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews: subviews, in: bounds.width)
        for (subview, offset) in zip(subviews, arranged.offsets) {
            subview.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(subviews: Subviews, in width: CGFloat)
        -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return (offsets, CGSize(width: totalWidth, height: y + rowHeight))
    }
}
