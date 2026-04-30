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
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.clear
                .background(.thickMaterial)
                .overlay(GlassTint.sidebar.tintColor(for: scheme))

            VStack(spacing: 6) {
                // Header gives traffic lights room.
                Color.clear.frame(height: 36)
                NavRailButton(icon: "list.bullet") { appState.route = .library }
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
                            .fill(Color.primary.opacity(0.10))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
    @State private var isVideoFullScreen: Bool = false
    @StateObject private var playerModel = VideoPlayerModel()
    @AppStorage("transcript.viewer.columnWidth") private var columnWidth: Double = 380

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
                        playerModel: playerModel,
                        columnWidth: $columnWidth,
                        onToggleFullScreen: { isVideoFullScreen.toggle() }
                    )
                    .frame(width: columnWidth)
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
        .overlay {
            if isVideoFullScreen {
                FullscreenVideoOverlay(
                    playerModel: playerModel,
                    onExit: { withAnimation(.easeInOut(duration: 0.2)) { isVideoFullScreen = false } }
                )
                .transition(.opacity)
            }
        }
        .task(id: meeting.id) { await loadTranscript() }
        .onAppear {
            playerModel.load(folder: meeting.folder)
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
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Button(action: { appState.route = .library }) {
                    Text("Library")
                        .foregroundStyle(Color.textDim)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
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
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
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
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
    @Binding var columnWidth: Double
    let onToggleFullScreen: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Inset video by the same amount as the cards inside the
            // ScrollView so they line up vertically. The 14pt inset gives
            // every card's shadow (radius 12) clearance from the
            // ScrollView's clip rect — without it the shadow's left/right
            // halves get sliced off.
            VideoPanel(
                playerModel: playerModel,
                columnWidth: $columnWidth,
                onToggleFullScreen: onToggleFullScreen
            )
            .padding(.horizontal, 14)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    SpeakersPanel(meeting: meeting, transcript: transcript)
                    AttendeesPanel(meeting: meeting)
                    MomentsPanel(meeting: meeting, playerModel: playerModel)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 16)
    }
}

/// Header row that toggles a panel's collapsed state. Chevron rotates
/// 0° → 90° as the panel opens. The full row is the click target;
/// trailing slot lets each panel attach its own action button (Edit
/// for Speakers, hint label for Attendees) so it stays clickable
/// without firing the toggle.
private struct CollapsibleHeader<Trailing: View>: View {
    let label: String
    @Binding var isExpanded: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.textDim)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    SectionLabel(text: label)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
    }
}

private struct VideoPanel: View {
    @ObservedObject var playerModel: VideoPlayerModel
    @Binding var columnWidth: Double
    let onToggleFullScreen: () -> Void

    @Environment(\.colorScheme) private var scheme
    @AppStorage("transcript.viewer.videoHeight") private var videoHeight: Double = 220
    @State private var dragStartHeight: Double?
    @State private var dragStartWidth: Double?

    private let minHeight: Double = 140
    private let maxHeight: Double = 520
    private let minWidth: Double = 320
    private let maxWidth: Double = 760

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                videoSurface
                Button(action: onToggleFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background {
                            Circle().fill(.black.opacity(0.45))
                                .background(.ultraThinMaterial, in: Circle())
                        }
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Fullscreen")
            }
            .frame(height: videoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        scheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color.black.opacity(0.12),
                        lineWidth: 0.5
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                CornerResizeHandle(
                    width: $columnWidth,
                    height: $videoHeight,
                    dragStartWidth: $dragStartWidth,
                    dragStartHeight: $dragStartHeight,
                    widthRange: minWidth...maxWidth,
                    heightRange: minHeight...maxHeight
                )
                .padding(6)
            }
            .shadow(
                color: Color.black.opacity(scheme == .dark ? 0.40 : 0.18),
                radius: 12, y: 6
            )
        }
    }

    @ViewBuilder
    private var videoSurface: some View {
        if let player = playerModel.player {
            VideoPlayer(player: player)
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
        }
    }
}

/// Quarter-arc curving from top-right to bottom-left, with the bulge
/// pulled toward the bottom-right corner — visually "wraps" the corner
/// it's anchored to as a "drag this corner to resize" affordance.
private struct ResizeHookShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        }
    }
}

/// 2D-resize gripper at the bottom-right corner of the video. Drag freely:
/// horizontal motion adjusts the entire left column's width (so the cards
/// below the video resize too), vertical motion adjusts video height.
/// Rendered as a thin curved arc that hints at the diagonal-drag direction.
private struct CornerResizeHandle: View {
    @Binding var width: Double
    @Binding var height: Double
    @Binding var dragStartWidth: Double?
    @Binding var dragStartHeight: Double?
    let widthRange: ClosedRange<Double>
    let heightRange: ClosedRange<Double>

    @State private var isHovering = false

    private let arcSize: CGFloat = 16

    var body: some View {
        ResizeHookShape()
            .stroke(
                Color.white.opacity(isHovering ? 0.95 : 0.7),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: arcSize, height: arcSize)
            .padding(4)
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? 1.15 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                // No public diagonal-resize cursor on macOS, so use
                // crosshair as the closest "drag-to-resize" affordance.
                if hovering {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        if dragStartHeight == nil { dragStartHeight = height }
                        let w = (dragStartWidth ?? width) + Double(value.translation.width)
                        let h = (dragStartHeight ?? height) + Double(value.translation.height)
                        width = max(widthRange.lowerBound, min(widthRange.upperBound, w))
                        height = max(heightRange.lowerBound, min(heightRange.upperBound, h))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        dragStartHeight = nil
                    }
            )
            .help("Drag to resize")
    }
}

/// Black overlay that takes over the entire transcript pane when the user
/// hits the fullscreen button on `VideoPanel`. Esc / the close button
/// returns to the inline video.
private struct FullscreenVideoOverlay: View {
    @ObservedObject var playerModel: VideoPlayerModel
    let onExit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player = playerModel.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle().fill(.black.opacity(0.55))
                            .background(.ultraThinMaterial, in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(20)
            .help("Exit fullscreen (Esc)")
        }
    }
}

private struct SpeakersPanel: View {
    let meeting: MeetingRecord
    let transcript: MergedTranscript
    @EnvironmentObject private var library: MeetingsLibrary

    @State private var editingID: SpeakerID?
    @State private var draftName: String = ""
    @AppStorage("transcript.viewer.expand.speakers") private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleHeader(label: "Speakers · \(meeting.speakers.count)", isExpanded: $isExpanded) {
                Button(action: handleEditTap) {
                    Text(editingID == nil ? "Edit" : "Done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                ForEach(meeting.speakers) { speaker in
                    SpeakerRow(
                        speaker: speaker,
                        speakingTime: speakingTime(for: speaker.id),
                        isEditing: editingID == speaker.id,
                        draftName: $draftName,
                        onStartEdit: {
                            editingID = speaker.id
                            draftName = speaker.displayName
                        },
                        onCommit: { commit(id: speaker.id) },
                        onDropAttendee: speaker.id == .me ? nil : { name in
                            apply(name: name, to: speaker.id)
                        }
                    )
                }
            }
        }
        .padding(12)
        .background {
            GlassCard(radius: 12) { Color.clear }
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

    /// Top-right "Edit / Done" button: when nothing is focused, drop the
    /// first non-Me speaker into edit mode (so a single click is enough
    /// to start typing); when editing, commit + exit.
    private func handleEditTap() {
        if let id = editingID {
            commit(id: id)
        } else if let target = meeting.speakers.first(where: { $0.id != .me }) {
            draftName = target.displayName
            editingID = target.id
        }
    }

    private func apply(name: String, to id: SpeakerID) {
        library.update(meeting: meeting.id) { override in
            override.customSpeakerNames[id.rawValue] = name
        }
    }
}

private struct SpeakerRow: View {
    let speaker: Speaker
    let speakingTime: TimeInterval
    let isEditing: Bool
    @Binding var draftName: String
    let onStartEdit: () -> Void
    let onCommit: () -> Void
    /// Called when an AttendeePill is dropped on this row. nil to disable
    /// the drop target — used for the "Me" row, which is auto-mapped from
    /// the mic stream.
    let onDropAttendee: ((String) -> Void)?

    @FocusState private var fieldFocused: Bool
    @State private var isDropTarget: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Avatar(initials: initials, color: avatarColor, size: 22)
            if isEditing {
                TextField("Name", text: $draftName, onCommit: onCommit)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
            } else {
                Text(speaker.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onStartEdit)
            }
            Spacer()
            Text(formatDuration(speakingTime))
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.textDim)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.brandAccent.opacity(isDropTarget ? 0.12 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.brandAccent.opacity(isDropTarget ? 0.55 : 0),
                    style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])
                )
        }
        .modifier(SpeakerRowDropModifier(
            isEnabled: onDropAttendee != nil,
            isTargeted: $isDropTarget,
            onDrop: { onDropAttendee?($0) }
        ))
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

/// Conditionally attaches a dropDestination — `.dropDestination` always
/// installs a target, even with `isEnabled` flag, so we gate via a
/// modifier that returns the unchanged view when disabled.
private struct SpeakerRowDropModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.dropDestination(for: String.self) { items, _ in
                guard let name = items.first else { return false }
                onDrop(name)
                return true
            } isTargeted: { hovering in
                isTargeted = hovering
            }
        } else {
            content
        }
    }
}

// =============================================================================
// MARK: - Attendees panel (drag source)
// =============================================================================

private struct AttendeesPanel: View {
    let meeting: MeetingRecord
    @AppStorage("transcript.viewer.expand.attendees") private var isExpanded: Bool = true

    private var pool: [CalendarAttendee] {
        guard let event = meeting.calendarEvent else { return [] }
        var out: [CalendarAttendee] = []
        if let organizer = event.organizer { out.append(organizer) }
        out.append(contentsOf: event.attendees)
        var seen = Set<String>()
        return out.filter { att in
            guard !att.isMe else { return false }
            return seen.insert(att.id).inserted
        }
    }

    private var assignedNames: Set<String> {
        Set(meeting.speakers.map { $0.displayName })
    }

    var body: some View {
        if pool.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                CollapsibleHeader(label: "Attendees · \(pool.count)", isExpanded: $isExpanded) {
                    if isExpanded {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.point.up.left")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Drag onto a speaker")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Color.textFaint)
                    }
                }
                if isExpanded {
                    FlowLayout(spacing: 6) {
                        ForEach(pool) { att in
                            AttendeePill(
                                attendee: att,
                                isAssigned: assignedNames.contains(att.displayName)
                            )
                            .draggable(att.displayName) {
                                AttendeePill(attendee: att, isAssigned: false)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background {
                GlassCard(radius: 12) { Color.clear }
            }
        }
    }
}

private struct AttendeePill: View {
    let attendee: CalendarAttendee
    let isAssigned: Bool

    var body: some View {
        HStack(spacing: 5) {
            Avatar(initials: initials, color: avatarColor, size: 16)
            Text(attendee.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isAssigned ? Color.textFaint : Color.textPrimary)
                .lineLimit(1)
            if isAssigned {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.brandSuccess)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule().strokeBorder(
                        Color.primary.opacity(0.10),
                        lineWidth: 0.5
                    )
                }
        }
        .opacity(isAssigned ? 0.55 : 1.0)
    }

    private var initials: String {
        let words = attendee.displayName.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first.map(String.init) }
        let combined = chars.joined()
        return combined.isEmpty ? "?" : String(combined.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        let palette: [Color] = [.tagEngineering, .tagDesign, .tagPeople, .tagResearch, .tagOneOnOne]
        return palette[abs(attendee.id.hashValue) % palette.count]
    }
}

private struct MomentsPanel: View {
    let meeting: MeetingRecord
    @ObservedObject var playerModel: VideoPlayerModel
    @AppStorage("transcript.viewer.expand.moments") private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleHeader(label: "Moments · \(meeting.marks.count)", isExpanded: $isExpanded) {
                EmptyView()
            }
            if isExpanded {
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
        }
        .padding(12)
        .background {
            GlassCard(radius: 12) { Color.clear }
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
                        speakers: meeting.speakers,
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
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
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
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 22)
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
            attr[range].foregroundColor = Color(
                light: Color(red: 0.35, green: 0.21, blue: 0),
                dark: Color(red: 1.00, green: 0.86, blue: 0.50)
            )
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
    @EnvironmentObject private var appState: AppState

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
            Button("Open Library") { appState.route = .library }
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
    private var loadedFolder: URL?

    /// Build a player that plays `video.mov` with `mic.m4a` and
    /// `output.m4a` mixed in as parallel audio tracks. The recording
    /// pipeline writes audio separately so diarization can isolate
    /// participants — but the user expects to *hear* the meeting back,
    /// so playback re-composites them.
    func load(folder: URL) {
        guard folder != loadedFolder else { return }
        loadedFolder = folder

        let videoURL = folder.appendingPathComponent("video.mov")
        let micURL = folder.appendingPathComponent("mic.m4a")
        let outputURL = folder.appendingPathComponent("output.m4a")

        guard FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) else {
            player = nil
            loadError = "Missing"
            return
        }

        let micExists = FileManager.default.fileExists(atPath: micURL.path(percentEncoded: false))
        let outputExists = FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false))

        Task { @MainActor in
            do {
                let composition = try await Self.buildComposition(
                    videoURL: videoURL,
                    micURL: micExists ? micURL : nil,
                    outputURL: outputExists ? outputURL : nil
                )
                let item = AVPlayerItem(asset: composition)
                self.player = AVPlayer(playerItem: item)
                self.loadError = nil
            } catch {
                NSLog("[Meeting/TranscriptViewer] composition build failed, falling back to video-only: %@",
                      String(describing: error))
                self.player = AVPlayer(url: videoURL)
                self.loadError = nil
            }
        }
    }

    private nonisolated static func buildComposition(
        videoURL: URL,
        micURL: URL?,
        outputURL: URL?
    ) async throws -> AVMutableComposition {
        // PreferPreciseDurationAndTiming forces Fig to pre-scan the file
        // so seek tables are exact — without it FigFilePlayer can emit
        // err=-12860 when seeking near track boundaries.
        let assetOptions: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL, options: assetOptions)
        let videoDuration = try await videoAsset.load(.duration)

        if let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoDuration),
                of: videoTrack, at: .zero
            )
        }

        for url in [micURL, outputURL].compactMap({ $0 }) {
            let asset = AVURLAsset(url: url, options: assetOptions)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let compTrack = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { continue }
            let audioDuration = try await asset.load(.duration)
            let usable = CMTimeMinimum(audioDuration, videoDuration)
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: usable),
                of: track, at: .zero
            )
            // Pad any tail beyond the audio file with silence so the
            // composition track spans the full video duration. Without
            // this, seeking into the unpadded tail makes Fig walk past
            // the end of the audio sample table and log err=-12860.
            if usable < videoDuration {
                compTrack.insertEmptyTimeRange(
                    CMTimeRange(start: usable, duration: videoDuration - usable)
                )
            }
        }

        return composition
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // Screen recordings have sparse keyframes (~2s apart at 30fps),
        // so zero-tolerance seeks force the decoder to walk too far back
        // and trigger FigFilePlayer err=-12860. Frame accuracy isn't
        // needed for transcript navigation — quarter-second tolerance
        // lands on the nearest keyframe and stays smooth.
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
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
