import SwiftUI
import AVKit

/// 1180×760 transcript viewer with the design's two-column glass layout:
/// video + speakers · scrollable diarized transcript. Top toolbar carries
/// the "Library > <title>" breadcrumb that goes back to the meeting list.
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

            if let meeting = library.selectedMeeting {
                TranscriptMainPane(meeting: meeting)
                    .id(meeting.id)
            } else {
                EmptyTranscriptPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
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
    /// Lives at the viewer root so segment-row clicks (in TranscriptScrollPane)
    /// can synchronously stop a speaker sample before kicking the main
    /// player back to playing — without waiting for the async KVO →
    /// `isPlaying` → `onReceive` chain that the SpeakersPanel previously
    /// relied on (which left both streams audible for ~16-50ms).
    @StateObject private var samplePlayer = SpeakerSamplePlayer()
    @AppStorage("transcript.viewer.columnWidth") private var columnWidth: Double = 560
    @State private var suggestionBannerDismissed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            TranscriptToolbar(
                meeting: meeting,
                hitCount: hitCount,
                search: $search
            )
            IdentitySuggestionBanner(
                meeting: meeting,
                dismissed: $suggestionBannerDismissed
            )
            if let transcript {
                HStack(alignment: .top, spacing: 0) {
                    TranscriptLeftColumn(
                        meeting: meeting,
                        transcript: transcript,
                        playerModel: playerModel,
                        samplePlayer: samplePlayer,
                        columnWidth: $columnWidth,
                        onToggleFullScreen: { isVideoFullScreen.toggle() }
                    )
                    .frame(width: columnWidth)
                    Divider().opacity(0.2)
                    TranscriptScrollPane(
                        meeting: meeting,
                        transcript: bind(transcript),
                        search: search,
                        playerModel: playerModel,
                        samplePlayer: samplePlayer
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
        .onDisappear {
            // Stop AV rendering immediately so the back-to-Library
            // transition isn't blocked on composition teardown.
            playerModel.teardown()
            samplePlayer.stop()
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
    @AppStorage("dev.fluke.meeting.summaryDisclosureSeen") private var disclosureSeen = false
    @State private var showDisclosure = false

    private var summaryEnabled: Bool {
        meeting.hasTranscript && appState.llmAvailability == .available
    }

    private var isGeneratingSummary: Bool {
        if case .running = appState.summaryGeneration[meeting.id] { return true }
        return false
    }

    private func generateOrRegenerate() {
        if !disclosureSeen {
            showDisclosure = true
            return
        }
        Task { await appState.generateSummary(for: meeting) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { appState.route = .library }) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Library")
                        .font(.system(size: 12, weight: .medium))
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
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Library (⌘[)")

            Text(meeting.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
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

            ToolbarPill(
                icon: "sparkles",
                label: isGeneratingSummary ? "Summarizing…" : "Summary"
            ) {
                generateOrRegenerate()
            }
            .disabled(!summaryEnabled || isGeneratingSummary)
            .help(summaryEnabled
                ? (meeting.summary == nil ? "Generate AI summary via Claude" : "Regenerate via Claude")
                : "Install Claude Code: npm i -g @anthropic-ai/claude-code"
            )
            ToolbarPill(icon: "square.and.arrow.down", label: "Export") {
                exportSheetReExport()
            }
            ToolbarPill(icon: "square.and.arrow.up", label: "Share") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .alert("Send transcript to Claude?", isPresented: $showDisclosure) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                disclosureSeen = true
                Task { await appState.generateSummary(for: meeting) }
            }
        } message: {
            Text("AI summary uses your Claude Code installation to generate a summary and action items. The transcript will be sent to Claude. This is the only step that ever leaves your Mac — recording and transcription stay local.")
        }
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
    @ObservedObject var samplePlayer: SpeakerSamplePlayer
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
                    SpeakersAttendeesRow(
                        meeting: meeting,
                        transcript: transcript,
                        playerModel: playerModel,
                        samplePlayer: samplePlayer
                    )
                    if !meeting.contextItems.isEmpty {
                        ContextPanel(meeting: meeting)
                    }
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

/// Speakers + Attendees layout. Side-by-side when the left column is
/// wide enough that both cards stay readable; falls back to stacked
/// when the user collapses the column. We branch on the column-width
/// `@AppStorage` value rather than `ViewThatFits` because the latter
/// can't choose between two flexible-width layouts deterministically —
/// both branches have `.frame(maxWidth: .infinity)` children, so
/// neither has a clear "ideal size" to fail to fit.
private struct SpeakersAttendeesRow: View {
    let meeting: MeetingRecord
    let transcript: MergedTranscript
    @ObservedObject var playerModel: VideoPlayerModel
    @ObservedObject var samplePlayer: SpeakerSamplePlayer
    @AppStorage("transcript.viewer.columnWidth") private var columnWidth: Double = 560

    /// Threshold below which the side-by-side layout becomes too cramped
    /// to be useful. Speakers row needs ~220pt for "Drink Sirichai" +
    /// duration, Attendees needs ~220pt for "gun.ka@finnomena.com" pills
    /// to stop wrapping every line — plus 12pt spacing and 28pt of
    /// horizontal padding on the enclosing column.
    private let sideBySideThreshold: Double = 480

    var body: some View {
        if columnWidth >= sideBySideThreshold {
            HStack(alignment: .top, spacing: 12) {
                SpeakersPanel(
                    meeting: meeting,
                    transcript: transcript,
                    playerModel: playerModel,
                    samplePlayer: samplePlayer
                )
                .frame(maxWidth: .infinity, alignment: .top)
                AttendeesPanel(meeting: meeting)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 12) {
                SpeakersPanel(
                    meeting: meeting,
                    transcript: transcript,
                    playerModel: playerModel,
                    samplePlayer: samplePlayer
                )
                AttendeesPanel(meeting: meeting)
            }
        }
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
            AVPlayerViewRepresentable(player: player)
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
                AVPlayerViewRepresentable(player: player)
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
    @ObservedObject var playerModel: VideoPlayerModel
    @ObservedObject var samplePlayer: SpeakerSamplePlayer
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
                        sampleAvailable: sampleRange(for: speaker.id) != nil,
                        isPlayingSample: samplePlayer.playingSpeaker == speaker.id,
                        canJump: hasSegments(for: speaker.id),
                        onTap: { handleRowTap(speaker: speaker) },
                        onRequestRename: { startEdit(speaker: speaker) },
                        onCommit: { commit(id: speaker.id) },
                        onPlaySample: { toggleSample(for: speaker.id) },
                        onDropAttendee: speaker.id == .me ? nil : { attendeeID in
                            apply(attendeeID: attendeeID, to: speaker.id)
                        }
                    )
                    // Suggestion chip — surfaces under speakers that the
                    // matcher believes match a previously-named voice.
                    if let suggestion = meeting.identitySuggestions.first(where: { $0.speakerID == speaker.id }) {
                        IdentitySuggestionChip(
                            suggestion: suggestion,
                            allSuggestions: meeting.identitySuggestions.filter { $0.speakerID == speaker.id },
                            onConfirm: { s in library.applyIdentitySuggestion(s, meeting: meeting.id) },
                            onReject: { s in library.rejectIdentitySuggestion(s, meeting: meeting.id) }
                        )
                        .padding(.leading, 32)
                    }
                }
            }
        }
        .padding(12)
        .background {
            GlassCard(radius: 12) { Color.clear }
        }
        .onDisappear { samplePlayer.stop() }
        // Sample player and the main video are separate AVPlayers, so a
        // sample keeps going when the user clicks a segment to seek the
        // video or hits play in the video chrome. Stop the sample as soon
        // as the main player starts moving so only one stream is audible.
        .onReceive(playerModel.$isPlaying) { isPlaying in
            if isPlaying, samplePlayer.playingSpeaker != nil {
                samplePlayer.stop()
            }
        }
    }

    private func speakingTime(for id: SpeakerID) -> TimeInterval {
        transcript.segments
            .filter { $0.speaker == id }
            .reduce(0) { $0 + ($1.end - $1.start) }
    }

    private func hasSegments(for id: SpeakerID) -> Bool {
        transcript.segments.contains { $0.speaker == id }
    }

    /// Tap-on-name behaviour. In default mode this seeks the video to
    /// the speaker's next utterance after the playhead, wrapping back
    /// to their first segment when the user is past the last. While
    /// inline rename is active for some other row, taps switch the
    /// edit target instead so the existing rename workflow keeps
    /// working without an extra Edit-button round-trip.
    private func handleRowTap(speaker: Speaker) {
        if let editingID, editingID != speaker.id {
            commit(id: editingID)
            startEdit(speaker: speaker)
            return
        }
        if editingID == speaker.id {
            return
        }
        jump(to: speaker.id)
    }

    private func startEdit(speaker: Speaker) {
        editingID = speaker.id
        draftName = speaker.displayName
    }

    /// Seek the video to the next segment of `id` whose start is past
    /// the current playhead (with a small fudge to avoid bouncing on
    /// the current segment). Wraps to the speaker's first segment when
    /// the playhead is past their last — clicking the same speaker
    /// repeatedly cycles through their utterances.
    private func jump(to id: SpeakerID) {
        let candidates = transcript.segments.filter { $0.speaker == id }
        guard let first = candidates.first else { return }
        let now = playerModel.currentTime
        let next = candidates.first(where: { $0.start > now + 0.5 }) ?? first
        // Cut the sample audio off in the same tick we resume the main
        // player. Relying on the rate-KVO → @Published → onReceive chain
        // alone leaves both streams audible for ~tens of ms — enough to
        // hear as overlap when rapidly toggling between sample + timeline.
        samplePlayer.stop()
        playerModel.seek(to: next.start)
    }

    /// Pick a representative speech range to play as the speaker sample.
    /// Prefers the longest segment ≥ 2s (short utterances are rarely
    /// recognizable as a voice); caps the sample at 6s so it doesn't
    /// turn into a chunk of the meeting played back.
    private func sampleRange(for id: SpeakerID) -> ClosedRange<TimeInterval>? {
        let candidates = transcript.segments.filter { $0.speaker == id }
        guard !candidates.isEmpty else { return nil }
        let longish = candidates.filter { $0.end - $0.start >= 2.0 }
        let pick = (longish.isEmpty ? candidates : longish)
            .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
        guard let pick else { return nil }
        let maxLength: TimeInterval = 6
        let length = min(pick.end - pick.start, maxLength)
        return pick.start...(pick.start + length)
    }

    private func sampleAudioURL(for id: SpeakerID) -> URL {
        let name = id == .me ? "mic.m4a" : "output.m4a"
        return meeting.folder.appendingPathComponent(name)
    }

    private func toggleSample(for id: SpeakerID) {
        if samplePlayer.playingSpeaker == id {
            samplePlayer.stop()
            return
        }
        guard let range = sampleRange(for: id) else { return }
        // Pause main video so the sample plays cleanly — listening to
        // both at the same time defeats the purpose.
        playerModel.player?.pause()
        samplePlayer.play(
            speaker: id,
            audioURL: sampleAudioURL(for: id),
            range: range
        )
    }

    private func commit(id: SpeakerID) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingID = nil
            return
        }
        // Manual rename only touches the display name — leave any
        // existing attendee mapping (email, role) intact so a small
        // typo fix doesn't unmap "Pim" from pim@example.com.
        // refresh: false — linkOrCreateIdentity below does the single
        // final refresh, keeping the map gesture to one UI reload.
        library.updateSpeaker(meeting: meeting.id, speakerID: id, refresh: false) { profile in
            profile.displayName = trimmed
        }
        library.linkOrCreateIdentity(speakerID: id, meeting: meeting.id)
        editingID = nil
    }

    /// Top-right "Edit / Done" button: when nothing is focused, drop the
    /// first non-Me speaker into edit mode (so a single click is enough
    /// to start typing); when editing, commit + exit. Per-row rename
    /// from the context menu uses `startEdit(speaker:)` directly.
    private func handleEditTap() {
        if let id = editingID {
            commit(id: id)
        } else if let target = meeting.speakers.first(where: { $0.id != .me }) {
            startEdit(speaker: target)
        }
    }

    /// Drop handler: resolve the dragged attendee's id back to the full
    /// `CalendarAttendee` from the meeting's calendar.json snapshot,
    /// then write the whole identity bundle (display name + email +
    /// role + attendee id) to speakers.json so the LLM prompt and
    /// future cross-meeting analytics can attribute speech to a real
    /// person rather than a name string.
    private func apply(attendeeID: String, to id: SpeakerID) {
        guard let attendee = lookupAttendee(id: attendeeID) else { return }
        // refresh: false — linkOrCreateIdentity handles the final refresh
        library.updateSpeaker(meeting: meeting.id, speakerID: id, refresh: false) { profile in
            profile.displayName = attendee.displayName
            profile.attendeeId = attendee.id
            profile.email = attendee.email
            profile.role = attendee.role
        }
        library.linkOrCreateIdentity(speakerID: id, meeting: meeting.id)
    }

    private func lookupAttendee(id: String) -> CalendarAttendee? {
        attendeePool(for: meeting).first { $0.id == id }
    }
}

/// Attendee pool for the Attendees panel (drag source) and the
/// Speakers panel's drop handler — sourced solely from the Meet AX
/// scrape captured during the recording. Calendar invitees aren't
/// included: in practice Meet's tile names cover everyone who
/// actually joined, and pulling from the calendar dragged in
/// no-shows + group-invite expansions that cluttered the panel.
///
/// Entries are synthesized as `CalendarAttendee` (with `email = nil`
/// and `id = "name:<DisplayName>"`) so the drop handler can keep
/// writing the same identity-bundle shape to speakers.json without
/// branching on the source.
fileprivate func attendeePool(for meeting: MeetingRecord) -> [CalendarAttendee] {
    var seenIDs = Set<String>()
    var pool: [CalendarAttendee] = []
    for name in meeting.meetParticipants {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let synthesized = CalendarAttendee(
            displayName: trimmed,
            email: nil,
            isMe: false,
            role: nil
        )
        if seenIDs.insert(synthesized.id).inserted {
            pool.append(synthesized)
        }
    }
    return pool
}

private struct SpeakerRow: View {
    let speaker: Speaker
    let speakingTime: TimeInterval
    let isEditing: Bool
    @Binding var draftName: String
    /// True when there's a long-enough utterance from this speaker to
    /// play back as a recognizable sample. Disables the play button
    /// when false (e.g. transcript with only word-level fragments).
    let sampleAvailable: Bool
    let isPlayingSample: Bool
    /// True when this speaker has at least one segment to seek to.
    /// Disables the tap-to-jump cursor styling for empty rows (e.g.
    /// "Me" when the user never spoke).
    let canJump: Bool
    /// Single-tap on the name. Owned by the parent panel — defaults
    /// to "jump to next utterance" but switches to "change edit
    /// target" while inline rename is active.
    let onTap: () -> Void
    /// Right-click → "Rename" target. Always available, regardless
    /// of the panel's current edit state.
    let onRequestRename: () -> Void
    let onCommit: () -> Void
    let onPlaySample: () -> Void
    /// Called when an AttendeePill is dropped on this row. nil to disable
    /// the drop target — used for the "Me" row, which is auto-mapped from
    /// the mic stream.
    let onDropAttendee: ((String) -> Void)?

    @FocusState private var fieldFocused: Bool
    @State private var isDropTarget: Bool = false
    @State private var isHoveringSample: Bool = false

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
                    .onTapGesture(perform: onTap)
                    .help(canJump
                        ? "Click to jump to \(speaker.displayName)'s next utterance — right-click to rename"
                        : "Right-click to rename")
                    .contextMenu {
                        Button("Rename", action: onRequestRename)
                    }
            }
            Spacer()
            sampleButton
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

    /// Tiny play/stop button that auditions the speaker's voice. Stays
    /// visible (but dimmed) when no sample is available so the row's
    /// trailing layout doesn't shift between speakers.
    @ViewBuilder
    private var sampleButton: some View {
        Button(action: onPlaySample) {
            Image(systemName: isPlayingSample ? "stop.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(
                    isPlayingSample ? Color.white : Color.brandAccent
                )
                .frame(width: 18, height: 18)
                .background {
                    Circle()
                        .fill(
                            isPlayingSample
                                ? Color.brandAccent
                                : Color.brandAccent.opacity(isHoveringSample ? 0.18 : 0.10)
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!sampleAvailable)
        .opacity(sampleAvailable ? 1.0 : 0.35)
        .onHover { isHoveringSample = $0 }
        .help(
            isPlayingSample
                ? "Stop sample"
                : sampleAvailable
                    ? "Play sample of \(speaker.displayName)'s voice"
                    : "No long-enough utterance to sample"
        )
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
        attendeePool(for: meeting)
    }

    /// Set of `CalendarAttendee.id` values already mapped to a
    /// speaker in this meeting. Drives the checkmark + dimmed style on
    /// `AttendeePill` so the user can see who's been assigned.
    /// Falls back to display-name match for legacy speakers.json
    /// entries without an attendeeId.
    private var assignedAttendeeIDs: Set<String> {
        var ids = Set<String>()
        for profile in meeting.speakerProfiles {
            if let attendeeId = profile.attendeeId {
                ids.insert(attendeeId)
            }
        }
        return ids
    }

    private var assignedNames: Set<String> {
        Set(meeting.speakerProfiles
            .filter { $0.attendeeId == nil }
            .map { $0.displayName })
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
                            let isAssigned = assignedAttendeeIDs.contains(att.id)
                                || assignedNames.contains(att.displayName)
                            AttendeePill(
                                attendee: att,
                                isAssigned: isAssigned
                            )
                            .draggable(att.id) {
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

// =============================================================================
// MARK: - Context items panel (delete-enabled)
// =============================================================================

/// Left-column card listing every clipboard / browser-URL item captured
/// during the meeting, with a per-item trash button. Deletes rewrite
/// `<meeting>/context.json` (and remove the underlying image file when
/// applicable) before kicking off a Library rescan, so the next AI
/// summary run sees the curated list rather than every random copy.
private struct ContextPanel: View {
    let meeting: MeetingRecord
    @EnvironmentObject private var library: MeetingsLibrary
    @AppStorage("transcript.viewer.expand.context") private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleHeader(
                label: "Captured · \(meeting.contextItems.count)",
                isExpanded: $isExpanded
            ) {
                EmptyView()
            }

            if isExpanded {
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
        .padding(12)
        .background {
            GlassCard(radius: 12) { Color.clear }
        }
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
    @ObservedObject var samplePlayer: SpeakerSamplePlayer

    /// Cached active segment id. Updated only when playback crosses a
    /// segment boundary, so the SegmentRow `isActive` parameter is stable
    /// across the 5Hz currentTime ticks and SwiftUI doesn't re-diff every
    /// visible row on every tick.
    @State private var activeID: TranscriptSegment.ID?

    var body: some View {
        // Action-item lookup is rebuilt per body, but with binary search
        // it's O(items · log segments) — well under a millisecond at
        // realistic sizes (≤ ~50 items, a few thousand segments).
        let actionItemMap = actionItemMap()

        ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    heroBlock

                    ForEach(transcript.segments) { segment in
                        SegmentRow(
                            segment: segment,
                            speakers: meeting.speakers,
                            searchQuery: search,
                            actionItem: actionItemMap[segment.id],
                            isActive: activeID == segment.id,
                            onSeek: {
                                // Synchronous stop kills any in-flight
                                // speaker sample before the main player
                                // ramps back to rate=1 — see SpeakersPanel
                                // jump(to:) for the rationale.
                                samplePlayer.stop()
                                playerModel.seek(to: segment.start)
                            },
                            onCommitEdit: { newText in
                                transcript = transcript.updatingSegment(id: segment.id, text: newText)
                            },
                            onDelete: {
                                transcript = transcript.removingSegment(id: segment.id)
                            }
                        )
                        .id(segment.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .onReceive(playerModel.$currentTime) { time in
                let newID = activeSegmentID(at: time)
                guard newID != activeID else { return }
                activeID = newID
                // Only chase playback while the player is moving — if the
                // user paused to read a different part of the transcript,
                // don't yank them back to the playhead.
                guard let newID, playerModel.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    /// Binary-search the segment array (sorted by start) for the one whose
    /// [start, end) contains `time`. Falls back to the rightmost segment
    /// with `start <= time` so the highlight doesn't blink off during
    /// silence between segments. O(log n) per playback tick instead of
    /// the O(n²) "scan-per-row × rows" the previous computed-property
    /// approach degraded into for long meetings.
    private func activeSegmentID(at time: TimeInterval) -> TranscriptSegment.ID? {
        let segments = transcript.segments
        guard !segments.isEmpty else { return nil }
        var lo = 0
        var hi = segments.count - 1
        var best = -1
        while lo <= hi {
            let mid = (lo &+ hi) >> 1
            if segments[mid].start <= time {
                best = mid
                lo = mid &+ 1
            } else {
                hi = mid &- 1
            }
        }
        guard best >= 0 else { return nil }
        return segments[best].id
    }

    /// Pre-compute a `[segment.id: action-item]` lookup via
    /// `ActionItemMatcher` — speaker-aware window matching that snaps
    /// past short filler segments. See `ActionItemMatcher.match` for
    /// the algorithm and rationale.
    private func actionItemMap() -> [TranscriptSegment.ID: ActionItem] {
        ActionItemMatcher.match(
            items: meeting.summary?.actionItems ?? [],
            segments: transcript.segments,
            speakers: meeting.speakers,
            speakerProfiles: meeting.speakerProfiles
        )
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
    /// Highlights this row as the one currently being played. Drives the
    /// brandAccent left rule, the row's tinted background fill, and the
    /// "Now" pulse next to the timestamp.
    let isActive: Bool
    let onSeek: () -> Void
    let onCommitEdit: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The whole left column doubles as a "play from here" target —
            // wrapping it in a Button makes the click region predictable
            // (a Button consumes its own clicks, so the outer row tap
            // gesture below doesn't double-fire).
            Button(action: onSeek) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Avatar(initials: initials, color: speakerColor, size: 20)
                        Text(displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isActive ? Color.brandAccent : Color.textPrimary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        if isActive {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.brandAccent)
                        }
                        Text(formatTimestamp(segment.start))
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(isActive ? Color.brandAccent : Color.textDim)
                    }
                    .padding(.leading, 22)
                }
                .frame(width: 110, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isEditing {
                editingBody
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(highlightedText)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Double-tap edits; the surrounding row tap below
                        // handles single-tap seek. SwiftUI prefers the
                        // higher-count gesture when both are available
                        // on the same hit, so a real double-click goes to
                        // edit while a single click falls through to seek.
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
                .contentShape(Rectangle())
                .onTapGesture { if !isEditing { onSeek() } }
            }
        }
        .padding(.horizontal, (actionItem != nil || isActive) ? 12 : 0)
        .padding(.vertical, (actionItem != nil || isActive) ? 8 : 0)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.brandAccent.opacity(0.10))
            } else if actionItem != nil {
                LinearGradient(
                    colors: [
                        Color.warmMark.opacity(0.15),
                        Color.clear,
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Color.brandAccent)
                    .frame(width: 2)
            } else if actionItem != nil {
                Rectangle()
                    .fill(Color.warmMark)
                    .frame(width: 2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                draft = segment.text
                isEditing = true
            } label: {
                Label("Edit text", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete segment", systemImage: "trash")
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
// MARK: - AVPlayerView NSViewRepresentable
// =============================================================================

/// Direct `AVPlayerView` wrapper instead of SwiftUI's `VideoPlayer`. On
/// macOS 26 / Xcode 26 Release builds, `VideoPlayer` aborts in
/// `swift::getSuperclassMetadata` while AVKit_SwiftUI's internal generic
/// class tries to demangle its `So12AVPlayerViewC` superclass — a runtime
/// metadata-init bug we can't reach from app code. Driving `AVPlayerView`
/// ourselves through `NSViewRepresentable` sidesteps the failing generic
/// class entirely and gives us a stable inline player with native chrome.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
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
    /// Current playback position in seconds. Updated ~5×/sec by a periodic
    /// time observer while a player is attached. Drives the active-segment
    /// highlight in the transcript scroll pane.
    @Published private(set) var currentTime: TimeInterval = 0
    /// True whenever AVPlayer.rate ≠ 0. Drives the auto-scroll-to-active
    /// behavior — we only chase playback while it's actually moving.
    @Published private(set) var isPlaying: Bool = false
    private var loadedFolder: URL?
    private var rateObservation: NSKeyValueObservation?

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
                let p = AVPlayer(playerItem: item)
                self.player = p
                self.attachObservers(to: p)
                self.loadError = nil
            } catch {
                NSLog("[Meeting/TranscriptViewer] composition build failed, falling back to video-only: %@",
                      String(describing: error))
                let p = AVPlayer(url: videoURL)
                self.player = p
                self.attachObservers(to: p)
                self.loadError = nil
            }
        }
    }

    /// Wire up the periodic-time + rate observers. Old player and its
    /// observers get released together when `self.player` is reassigned —
    /// AVPlayer retains its periodic-observer block, so dropping the
    /// player reference reaps the closure too. Only the KVO observation
    /// is kept on `self`, which we explicitly invalidate below.
    private func attachObservers(to p: AVPlayer) {
        rateObservation?.invalidate()
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Periodic observer's queue is .main, so we're already on
            // MainActor — assumeIsolated lets us write @Published state
            // without a Task hop.
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.currentTime = seconds
                }
            }
        }
        rateObservation = p.observe(\.rate, options: [.initial, .new]) { [weak self] _, change in
            let isPlaying = (change.newValue ?? 0) != 0
            Task { @MainActor [weak self] in
                self?.isPlaying = isPlaying
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

    /// Pause + detach observers + drop the player so the view-back
    /// transition doesn't wait on AVFoundation to tear down a playing
    /// composition mid-render. Safe to call from `.onDisappear`; the
    /// next `.onAppear` will rebuild via `load(folder:)`.
    func teardown() {
        player?.pause()
        rateObservation?.invalidate()
        rateObservation = nil
        player = nil
        loadedFolder = nil
    }
}

// =============================================================================
// MARK: - Speaker sample player
// =============================================================================

/// Plays a short audio snippet for a single speaker (mic.m4a for "Me",
/// output.m4a for diarized speakers) so the user can hear who they are
/// while remapping. Auto-stops at the end of the requested range via a
/// boundary-time observer; clicking play on a different speaker (or the
/// same speaker again) cancels the in-flight playback first.
@MainActor
final class SpeakerSamplePlayer: ObservableObject {
    @Published private(set) var playingSpeaker: SpeakerID?

    private var player: AVPlayer?
    private var endObserver: Any?
    private var endNotificationObserver: NSObjectProtocol?

    func play(speaker: SpeakerID, audioURL: URL, range: ClosedRange<TimeInterval>) {
        stop()
        guard FileManager.default.fileExists(
            atPath: audioURL.path(percentEncoded: false)
        ) else { return }

        let item = AVPlayerItem(url: audioURL)
        let p = AVPlayer(playerItem: item)
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
        let end = CMTime(seconds: range.upperBound, preferredTimescale: 600)

        let token = p.addBoundaryTimeObserver(
            forTimes: [NSValue(time: end)],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.playingSpeaker == speaker else { return }
                self.stop()
            }
        }
        endObserver = token
        // Belt-and-suspenders: when `end` lands past the audio file's real
        // duration (e.g. last-segment timestamp drifts a bit past EOF, or
        // the file got truncated), the boundary observer never fires and
        // playback ends silently — leaving `playingSpeaker` stuck. The
        // EOF notification covers that path so stop() always runs.
        endNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playingSpeaker == speaker else { return }
                self.stop()
            }
        }
        // Zero-tolerance seek matters for sample playback because the
        // segment ranges come from word-level WhisperKit timestamps;
        // a quarter-second of slop would clip the sample's first word.
        p.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        p.play()
        player = p
        playingSpeaker = speaker
    }

    func stop() {
        if let endObserver, let player {
            player.removeTimeObserver(endObserver)
        }
        endObserver = nil
        if let endNotificationObserver {
            NotificationCenter.default.removeObserver(endNotificationObserver)
        }
        endNotificationObserver = nil
        player?.pause()
        player = nil
        playingSpeaker = nil
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

// MARK: - Identity Suggestion Chip

/// Inline chip under a `speaker_N` row when the matcher believes that
/// speaker matches a previously-named voice. ✓ confirms (applies the
/// mapping + updates the global centroid); ✗ adds a per-meeting rejection
/// so the same pair won't be suggested again here.
private struct IdentitySuggestionChip: View {
    let suggestion: IdentitySuggestion
    let allSuggestions: [IdentitySuggestion]
    let onConfirm: (IdentitySuggestion) -> Void
    let onReject: (IdentitySuggestion) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11))
                .foregroundStyle(Color.brandAccent)
            Text("น่าจะเป็น ")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            + Text(suggestion.identityDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            + Text(" · \(suggestion.confidencePercent)%")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            Spacer(minLength: 4)
            Button(action: { onConfirm(suggestion) }) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.brandSuccess)
            }
            .buttonStyle(.plain)
            .help("ยืนยัน")
            Button(action: { onReject(suggestion) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textFaint)
            }
            .buttonStyle(.plain)
            .help("ปิด")
            if allSuggestions.count > 1 {
                Menu {
                    ForEach(Array(allSuggestions.dropFirst().prefix(2)), id: \.id) { s in
                        Button("\(s.identityDisplayName) · \(s.confidencePercent)%") {
                            onConfirm(s)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textFaint)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.brandAccent.opacity(0.08))
        )
    }
}

/// Top-of-viewer banner that summarizes how many suggestions are pending
/// when ≥2 speakers have one. Lets the user dismiss it for the session
/// (state is in-memory; reopening the viewer brings it back).
private struct IdentitySuggestionBanner: View {
    let meeting: MeetingRecord
    @Binding var dismissed: Bool

    var body: some View {
        let count = meeting.identitySuggestions.count
        if count >= 2 && !dismissed {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Color.brandAccent)
                Text("พบ \(count) suggestion จากผู้พูดในมีตติ้งอื่น — เลื่อนดูในการ์ด Speakers")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button("ปิด") { dismissed = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.brandAccent.opacity(0.08))
        }
    }
}
