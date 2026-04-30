import SwiftUI

/// Three-pane Library window. Sidebar (filters) · List (meetings) · Detail
/// (metadata + speakers strip). The Summary card and Action-items list
/// from the design proto are deferred to U8b once the LLM provider lands.
struct LibraryView: View {
    @EnvironmentObject private var library: MeetingsLibrary
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar()
                .frame(width: 220)

            Divider().opacity(0.3)

            LibraryList()
                .frame(width: 380)

            Divider().opacity(0.3)

            LibraryDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, minHeight: 700)
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
        .onAppear { library.rescan() }
    }
}

// =============================================================================
// MARK: - Sidebar
// =============================================================================

private struct LibrarySidebar: View {
    @EnvironmentObject private var library: MeetingsLibrary
    @Environment(\.colorScheme) private var scheme
    @State private var storage = StorageUsage(usedBytes: 0, freeBytes: 0)

    var body: some View {
        ZStack {
            Color.clear
                .background(.thickMaterial)
                .overlay(GlassTint.sidebar.tintColor(for: scheme))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header gives traffic lights room.
                Color.clear.frame(height: 44)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        SidebarSectionGroup(label: "Library") {
                            SidebarRow(
                                icon: "clock",
                                label: "All meetings",
                                count: library.meetings.count,
                                isSelected: library.sidebarFilter == .all
                            ) { library.sidebarFilter = .all }

                            SidebarRow(
                                icon: "star.fill",
                                label: "Starred",
                                count: library.meetings.filter(\.starred).count,
                                isSelected: library.sidebarFilter == .starred
                            ) { library.sidebarFilter = .starred }

                            SidebarRow(
                                icon: "flag.fill",
                                label: "Marked moments",
                                count: library.meetings.reduce(0) { $0 + $1.marks.count },
                                isSelected: library.sidebarFilter == .marked
                            ) { library.sidebarFilter = .marked }
                        }

                        // Tags + Speakers groups appear once the user
                        // accumulates them. U5 has no UI for tagging yet so
                        // these stay empty; LibraryDetail's "Add tag" button
                        // populates them in subsequent passes.
                        let allTags = Set(library.meetings.flatMap(\.tags)).sorted()
                        if !allTags.isEmpty {
                            SidebarSectionGroup(label: "Tags") {
                                ForEach(allTags, id: \.self) { tag in
                                    SidebarRow(
                                        dot: tagColor(for: tag),
                                        label: tag,
                                        count: library.meetings.filter { $0.tags.contains(tag) }.count,
                                        isSelected: library.sidebarFilter == .tag(tag)
                                    ) { library.sidebarFilter = .tag(tag) }
                                }
                            }
                        }

                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }

                StorageFooter(usage: storage)
                    .padding(12)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                    }
            }
        }
        .task { storage = library.storageUsage() }
        .onChange(of: library.meetings.count) { storage = library.storageUsage() }
    }

    private func tagColor(for name: String) -> Color {
        // Assign a stable color from the palette by hashing the tag name.
        let palette: [Color] = [.tagEngineering, .tagDesign, .tagPeople, .tagResearch, .tagOneOnOne]
        let idx = abs(name.hashValue) % palette.count
        return palette[idx]
    }
}

private struct SidebarSectionGroup<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
                .padding(.leading, 10)
                .padding(.bottom, 2)
            content()
        }
    }
}

private struct SidebarRow: View {
    var icon: String? = nil
    var dot: Color? = nil
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textDim)
                        .frame(width: 16)
                }
                if let dot {
                    Circle().fill(dot).frame(width: 9, height: 9)
                        .frame(width: 16)
                }
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 4)
                Text(String(count))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StorageFooter: View {
    let usage: StorageUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Storage")

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(height: 4)
                GeometryReader { proxy in
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.brandAccent, Color.brandAccent.opacity(0.65)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: proxy.size.width * usage.usedFraction, height: 4)
                }
                .frame(height: 4)
            }
            .frame(height: 4)

            HStack {
                Text("\(usage.usedFormatted) used")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textDim)
                Spacer()
                Text("\(usage.freeFormatted) free")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textFaint)
            }
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
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(filterLabel)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.15)
                    .foregroundStyle(Color.textPrimary)
            }
            Text(String(library.visibleMeetings.count))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.textDim)
            Spacer()

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
            .frame(width: 200)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private var filterLabel: String {
        switch library.sidebarFilter {
        case .all: return "All meetings"
        case .starred: return "Starred"
        case .marked: return "Marked moments"
        case .tag(let tag): return tag
        }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let onSelect: () -> Void
    @EnvironmentObject private var library: MeetingsLibrary
    @EnvironmentObject private var appState: AppState

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
                        if !meeting.marks.isEmpty {
                            Label("\(meeting.marks.count)", systemImage: "flag.fill")
                                .font(.system(size: 10.5))
                                .labelStyle(.titleAndIcon)
                        }
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
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            DetailHero(meeting: meeting)
                            if meeting.calendarEvent != nil {
                                CalendarDetailSection(meeting: meeting)
                            }
                            AISummarySection(meeting: meeting)
                            ActionItemsSection(meeting: meeting)
                            if !meeting.speakers.isEmpty {
                                SpeakersStrip(meeting: meeting)
                            }
                            if !meeting.marks.isEmpty {
                                DetailMomentsList(meeting: meeting)
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
    @EnvironmentObject private var transcribe: TranscriptionSession
    @Environment(\.openWindow) private var openWindow
    @AppStorage("dev.fluke.meeting.summaryDisclosureSeen") private var disclosureSeen = false
    @State private var showDisclosure = false
    @State private var showRetranscribeConfirm = false

    private var summaryEnabled: Bool {
        meeting.hasTranscript && appState.llmAvailability == .available
    }

    private var hasAudio: Bool {
        let fm = FileManager.default
        let mic = meeting.folder.appendingPathComponent("mic.m4a")
        let out = meeting.folder.appendingPathComponent("output.m4a")
        return fm.fileExists(atPath: mic.path) && fm.fileExists(atPath: out.path)
    }

    private var isTranscribing: Bool {
        if case .running = transcribe.state { return true }
        return false
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

            ToolbarButton(icon: "sparkles", label: "Summary") {
                Task { await generateOrRegenerate() }
            }
            .disabled(!summaryEnabled)
            .help(summaryEnabled
                ? (meeting.summary == nil ? "Generate AI summary via Claude" : "Regenerate via Claude")
                : "Install Claude Code: npm i -g @anthropic-ai/claude-code"
            )

            ToolbarButton(icon: "square.and.arrow.up", label: "Share") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }

            ToolbarButton(icon: "square.and.arrow.down", label: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }

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
            Text("AI summary uses your Claude Code installation to generate a summary and action items. The transcript will be sent to Claude. This is the only step that ever leaves your Mac — recording and transcription stay local.")
        }
        .alert("Re-transcribe meeting?", isPresented: $showRetranscribeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Re-transcribe", role: .destructive) {
                Task { await appState.retranscribe(meeting) }
            }
        } message: {
            Text("This overwrites transcript.json, transcript.md, and transcript.srt. Any inline segment edits in the Transcript Viewer will be lost. The cached AI summary will become out of date — regenerate it after.")
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

private struct DetailMomentsList: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Marked moments · \(meeting.marks.count)")
            VStack(spacing: 4) {
                ForEach(meeting.marks) { mark in
                    HStack(spacing: 10) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.warmMark)
                        Text(mark.note ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Text(formatTimestamp(mark.timestamp))
                            .font(.mono(10))
                            .foregroundStyle(Color.brandAccentStrong)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.regularMaterial)
                    }
                }
            }
        }
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
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
