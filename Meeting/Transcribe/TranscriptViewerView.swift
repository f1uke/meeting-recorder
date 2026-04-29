import SwiftUI
import AVKit

/// 1180×760 transcript viewer with the design's three-column glass layout:
/// nav rail · video + speakers + moments · scrollable diarized transcript.
///
/// The viewer hangs off `MeetingsLibrary.selectedMeeting` — opening the
/// window with no selection shows an empty-state card. Picking a meeting
/// in the Library list (or double-clicking it) loads the transcript.json
/// and renders segments. Inline edits to segment text are written back to
/// transcript.json atomically; speaker renames flow into library.json.
struct TranscriptViewerView: View {
    @EnvironmentObject private var library: MeetingsLibrary

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.97, blue: 1.00),
                    Color(red: 0.92, green: 0.94, blue: 0.99),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                TranscriptNavRail()
                if let meeting = library.selectedMeeting {
                    TranscriptMainPane(meeting: meeting)
                        // Force a fresh load when the user switches meeting.
                        .id(meeting.id)
                } else {
                    EmptyTranscriptPlaceholder()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
    }
}

// =============================================================================
// MARK: - Nav rail
// =============================================================================

private struct TranscriptNavRail: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Color.clear
                .background(.thickMaterial)
                .overlay(GlassTint.sidebar.tintColor(for: .light))

            VStack(spacing: 6) {
                // Header gives traffic lights room.
                Color.clear.frame(height: 36)
                NavRailButton(icon: "list.bullet") { openWindow(id: "library") }
                NavRailButton(icon: "magnifyingglass", active: true) {}
                NavRailButton(icon: "sparkles") {}
                NavRailButton(icon: "flag.fill") {}
                NavRailButton(icon: "person.2.fill") {}
                Spacer()
                NavRailButton(icon: "record.circle.fill") {}
                NavRailButton(icon: "gearshape") {}
            }
            .padding(.bottom, 12)
        }
        .frame(width: 56)
    }
}

private struct NavRailButton: View {
    let icon: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.textPrimary : Color.textDim)
                .frame(width: 36, height: 36)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.black.opacity(0.08))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================
// MARK: - Main pane (toolbar + body)
// =============================================================================

private struct TranscriptMainPane: View {
    let meeting: MeetingRecord
    @State private var transcript: MergedTranscript?
    @State private var loadError: String?
    @State private var search: String = ""
    @StateObject private var playerModel = VideoPlayerModel()

    var body: some View {
        VStack(spacing: 0) {
            TranscriptToolbar(
                meeting: meeting,
                hitCount: hitCount,
                search: $search
            )
            if let transcript {
                HStack(alignment: .top, spacing: 0) {
                    TranscriptLeftColumn(
                        meeting: meeting,
                        transcript: transcript,
                        playerModel: playerModel
                    )
                    .frame(width: 380)
                    Divider().opacity(0.2)
                    TranscriptScrollPane(
                        meeting: meeting,
                        transcript: bind(transcript),
                        search: search,
                        playerModel: playerModel
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                LoadingTranscriptPlaceholder(error: loadError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
        .task(id: meeting.id) { await loadTranscript() }
        .onAppear {
            playerModel.load(videoURL: meeting.folder.appendingPathComponent("video.mov"))
        }
    }

    private var hitCount: Int? {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let transcript else { return nil }
        let needle = trimmed.lowercased()
        return transcript.segments.reduce(0) { acc, seg in
            acc + seg.text.lowercased().occurrences(of: needle)
        }
    }

    private func loadTranscript() async {
        loadError = nil
        guard meeting.hasTranscript else {
            loadError = "No transcript yet — recording may still be processing."
            transcript = nil
            return
        }
        do {
            transcript = try MergedTranscript.read(from: meeting.folder)
        } catch {
            loadError = error.localizedDescription
            transcript = nil
        }
    }

    /// Binding that lets edits in segments update both the local @State and
    /// rewrite transcript.json atomically.
    private func bind(_ value: MergedTranscript) -> Binding<MergedTranscript> {
        Binding(
            get: { transcript ?? value },
            set: { newValue in
                transcript = newValue
                do {
                    try newValue.write(to: meeting.folder)
                } catch {
                    NSLog("[Meeting/TranscriptViewer] write failed: %@",
                          String(describing: error))
                }
            }
        )
    }
}

// =============================================================================
// MARK: - Toolbar
// =============================================================================

private struct TranscriptToolbar: View {
    let meeting: MeetingRecord
    let hitCount: Int?
    @Binding var search: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text("Library")
                    .foregroundStyle(Color.textDim)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.textFaint)
                Text(meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
                TextField("Search transcript", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .frame(maxWidth: .infinity)
                if let hits = hitCount {
                    Text("\(hits) hit\(hits == 1 ? "" : "s")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.textDim)
                } else {
                    Text("⌘F")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 240)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
            }
            .background {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            ToolbarPill(icon: "sparkles", label: "Summary") {}
                .disabled(true)
                .help("Summary requires Claude Code — coming in U8b")
            ToolbarPill(icon: "square.and.arrow.down", label: "Export") {
                exportSheetReExport()
            }
            ToolbarPill(icon: "square.and.arrow.up", label: "Share") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5)
        }
    }

    /// Re-runs the existing TranscriptExporter against the current
    /// transcript.json so .md and .srt are regenerated after edits.
    private func exportSheetReExport() {
        do {
            let merged = try MergedTranscript.read(from: meeting.folder)
            try TranscriptExporter.writeAll(merged, in: meeting.folder)
            NSWorkspace.shared.activateFileViewerSelecting([
                meeting.folder.appendingPathComponent("transcript.md")
            ])
        } catch {
            NSLog("[Meeting/TranscriptViewer] re-export failed: %@",
                  String(describing: error))
        }
    }
}

private struct ToolbarPill: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12))
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
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================
// MARK: - Left column
// =============================================================================

private struct TranscriptLeftColumn: View {
    let meeting: MeetingRecord
    let transcript: MergedTranscript
    @ObservedObject var playerModel: VideoPlayerModel

    var body: some View {
        VStack(spacing: 12) {
            VideoPanel(playerModel: playerModel)
            SpeakersPanel(meeting: meeting, transcript: transcript)
            MomentsPanel(meeting: meeting, playerModel: playerModel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

private struct VideoPanel: View {
    @ObservedObject var playerModel: VideoPlayerModel

    var body: some View {
        VStack(spacing: 0) {
            if let player = playerModel.player {
                VideoPlayer(player: player)
                    .aspectRatio(16/10, contentMode: .fit)
                    .background(Color.black)
            } else {
                ZStack {
                    Color.black
                    if playerModel.loadError != nil {
                        VStack(spacing: 4) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("video.mov missing")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .aspectRatio(16/10, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
        }
    }
}

private struct SpeakersPanel: View {
    let meeting: MeetingRecord
    let transcript: MergedTranscript
    @EnvironmentObject private var library: MeetingsLibrary

    @State private var editingID: SpeakerID?
    @State private var draftName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Speakers · \(transcript.speakers.count)")
                Spacer()
                Button(editingID == nil ? "Edit" : "Done") {
                    if let id = editingID { commit(id: id) }
                    editingID = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandAccent)
            }

            ForEach(transcript.speakers) { speaker in
                SpeakerRow(
                    speaker: speaker,
                    speakingTime: speakingTime(for: speaker.id),
                    isEditing: editingID == speaker.id,
                    draftName: $draftName,
                    onStartEdit: {
                        editingID = speaker.id
                        draftName = speaker.displayName
                    },
                    onCommit: { commit(id: speaker.id) }
                )
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
                }
        }
    }

    private func speakingTime(for id: SpeakerID) -> TimeInterval {
        transcript.segments
            .filter { $0.speaker == id }
            .reduce(0) { $0 + ($1.end - $1.start) }
    }

    private func commit(id: SpeakerID) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingID = nil
            return
        }
        library.update(meeting: meeting.id) { override in
            override.customSpeakerNames[id.rawValue] = trimmed
        }
        editingID = nil
    }
}

private struct SpeakerRow: View {
    let speaker: Speaker
    let speakingTime: TimeInterval
    let isEditing: Bool
    @Binding var draftName: String
    let onStartEdit: () -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Avatar(initials: initials, color: avatarColor, size: 22)
            if isEditing {
                TextField("Name", text: $draftName, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text(speaker.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .onTapGesture(count: 2, perform: onStartEdit)
            }
            Spacer()
            Text(formatDuration(speakingTime))
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.textDim)
        }
        .padding(.vertical, 3)
    }

    private var initials: String {
        let words = speaker.displayName.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }
        let combined = chars.joined()
        return combined.isEmpty ? "?" : String(combined.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        let palette: [Color] = [.tagEngineering, .tagDesign, .tagPeople, .tagResearch, .tagOneOnOne]
        return palette[abs(speaker.id.rawValue.hashValue) % palette.count]
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let total = Int(d)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct MomentsPanel: View {
    let meeting: MeetingRecord
    @ObservedObject var playerModel: VideoPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Moments · \(meeting.marks.count)")
            if meeting.marks.isEmpty {
                Text("Hit ⌘B during recording to mark moments here")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
                    .padding(.vertical, 4)
            } else {
                ForEach(meeting.marks) { mark in
                    Button {
                        playerModel.seek(to: mark.timestamp)
                    } label: {
                        HStack(spacing: 8) {
                            Text(formatTimestamp(mark.timestamp))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.brandAccentStrong)
                                .frame(width: 50, alignment: .leading)
                            Text(mark.note ?? "Marked moment")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
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

// =============================================================================
// MARK: - Transcript scroll pane
// =============================================================================

private struct TranscriptScrollPane: View {
    let meeting: MeetingRecord
    @Binding var transcript: MergedTranscript
    let search: String
    @ObservedObject var playerModel: VideoPlayerModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                heroBlock

                ForEach(transcript.segments) { segment in
                    SegmentRow(
                        segment: segment,
                        speakers: transcript.speakers,
                        searchQuery: search,
                        actionItem: actionItem(for: segment),
                        onSeek: { playerModel.seek(to: segment.start) },
                        onCommitEdit: { newText in
                            transcript = transcript.updatingSegment(id: segment.id, text: newText)
                        }
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    /// Match action items (from cached summary.json) to segments by
    /// timestamp. An action item highlights the segment containing its
    /// parsed timestamp; ties are resolved by closest-start-time.
    private func actionItem(for segment: TranscriptSegment) -> ActionItem? {
        guard let items = meeting.summary?.actionItems else { return nil }
        return items.first { item in
            guard let t = item.timestampSeconds else { return false }
            return t >= segment.start && t < segment.end
        }
    }

    @ViewBuilder
    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.serif(36))
                .foregroundStyle(Color.textPrimary)
            Text(metaLine)
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        parts.append(f.string(from: meeting.recordedAt))
        let total = Int(transcript.duration)
        let m = total / 60
        let s = total % 60
        parts.append(s == 0 ? "\(m) min" : String(format: "%d:%02d", m, s))
        parts.append("\(transcript.speakers.count) speakers")
        if !transcript.providers.isEmpty {
            parts.append(transcript.providers.joined(separator: " + "))
        }
        return parts.joined(separator: " · ")
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakers: [Speaker]
    let searchQuery: String
    let actionItem: ActionItem?
    let onSeek: () -> Void
    let onCommitEdit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Avatar(initials: initials, color: speakerColor, size: 20)
                    Text(displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                Button(action: onSeek) {
                    Text(formatTimestamp(segment.start))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.textDim)
                }
                .buttonStyle(.plain)
                .padding(.leading, 26)
            }
            .frame(width: 110, alignment: .leading)

            if isEditing {
                editingBody
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlightedText)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) {
                            draft = segment.text
                            isEditing = true
                        }
                    if actionItem != nil {
                        HStack(spacing: 6) {
                            Text("ACTION ITEM")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.warmMark)
                                .kerning(0.6)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background {
                                    Capsule().fill(Color.warmMark.opacity(0.18))
                                }
                            Text("Auto-detected by Claude")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, actionItem != nil ? 16 : 0)
        .padding(.vertical, actionItem != nil ? 12 : 0)
        .background {
            if actionItem != nil {
                LinearGradient(
                    colors: [
                        Color.warmMark.opacity(0.15),
                        Color.clear,
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .leading) {
            if actionItem != nil {
                Rectangle()
                    .fill(Color.warmMark)
                    .frame(width: 2)
            }
        }
    }

    private var editingBody: some View {
        VStack(spacing: 4) {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 60)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.brandAccent, lineWidth: 1)
                                .shadow(color: Color.brandAccent.opacity(0.15), radius: 0)
                        }
                }
            HStack {
                Spacer()
                Button("Cancel") {
                    isEditing = false
                }
                .keyboardShortcut(.escape)
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != segment.text {
                        onCommitEdit(trimmed)
                    }
                    isEditing = false
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
    }

    private var displayName: String {
        speakers.first(where: { $0.id == segment.speaker })?.displayName
            ?? segment.speaker.rawValue
    }

    private var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }
        let combined = chars.joined()
        return combined.isEmpty ? "?" : String(combined.prefix(2)).uppercased()
    }

    private var speakerColor: Color {
        let palette: [Color] = [.tagEngineering, .tagDesign, .tagPeople, .tagResearch, .tagOneOnOne]
        return palette[abs(segment.speaker.rawValue.hashValue) % palette.count]
    }

    /// Build an `AttributedString` with the search-match runs highlighted
    /// in warm yellow. Returns plain text when search is empty.
    private var highlightedText: AttributedString {
        var attr = AttributedString(segment.text)
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return attr }

        var cursor = attr.startIndex
        while cursor < attr.endIndex,
              let range = attr[cursor..<attr.endIndex]
                  .range(of: trimmed, options: .caseInsensitive) {
            attr[range].backgroundColor = Color.warmMark.opacity(0.35)
            attr[range].foregroundColor = Color(red: 0.35, green: 0.21, blue: 0)
            cursor = range.upperBound
        }
        return attr
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

// =============================================================================
// MARK: - Empty + loading states
// =============================================================================

private struct EmptyTranscriptPlaceholder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.textFaint)
            Text("No transcript open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.textDim)
            Text("Pick a meeting in the Library to load its transcript")
                .font(.system(size: 12))
                .foregroundStyle(Color.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Open Library") { openWindow(id: "library") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct LoadingTranscriptPlaceholder: View {
    let error: String?

    var body: some View {
        VStack(spacing: 12) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.warmMark)
                Text("Couldn't load transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                ProgressView().controlSize(.regular)
                Text("Loading…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textDim)
            }
        }
    }
}

// =============================================================================
// MARK: - Video player model
// =============================================================================

@MainActor
final class VideoPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loadError: String?
    private var loadedURL: URL?

    func load(videoURL: URL) {
        guard videoURL != loadedURL else { return }
        loadedURL = videoURL
        if FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) {
            player = AVPlayer(url: videoURL)
            loadError = nil
        } else {
            player = nil
            loadError = "Missing"
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

// =============================================================================
// MARK: - Helpers
// =============================================================================

private extension String {
    func occurrences(of substring: String) -> Int {
        guard !substring.isEmpty else { return 0 }
        var count = 0
        var range = startIndex..<endIndex
        while let found = self.range(of: substring, options: [], range: range) {
            count += 1
            range = found.upperBound..<endIndex
        }
        return count
    }
}
