import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drives the "Export video" action from a toolbar: prompts for a destination,
/// runs `MeetingVideoExporter` off the main actor, and surfaces progress /
/// errors through a small sheet. Used by both the Library detail toolbar and
/// the Transcript Viewer toolbar via `@StateObject`.
@MainActor
final class VideoExportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(Double)
        case failed(String)
    }

    @Published var phase: Phase = .idle

    private let exporter = MeetingVideoExporter()
    private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { return true }; return false }

    /// True when the meeting has a video file worth exporting.
    static func canExport(_ meeting: MeetingRecord) -> Bool {
        FileManager.default.fileExists(atPath: meeting.folder.appendingPathComponent("video.mov").path)
    }

    func start(_ meeting: MeetingRecord) {
        guard !isRunning, let destination = promptForDestination(meeting) else { return }
        let names = Dictionary(meeting.speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        phase = .running(0)

        task = Task { [exporter] in
            do {
                try await exporter.export(meetingFolder: meeting.folder, names: names, to: destination) { p in
                    Task { @MainActor in
                        if case .running = self.phase { self.phase = .running(p) }
                    }
                }
                await MainActor.run {
                    self.phase = .idle
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                if (error as? MeetingVideoExporter.ExportError) == .cancelled {
                    await MainActor.run { self.phase = .idle }
                } else {
                    await MainActor.run {
                        self.phase = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismissError() { phase = .idle }

    private func promptForDestination(_ meeting: MeetingRecord) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = Self.suggestedFileName(meeting)
        panel.canCreateDirectories = true
        panel.title = "Export Meeting Video"
        panel.message = "Export video with audio and subtitles as a single shareable .mp4."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func suggestedFileName(_ meeting: MeetingRecord) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let base = meeting.title.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Meeting" : trimmed) + ".mp4"
    }
}

extension MeetingVideoExporter.ExportError: Equatable {
    static func == (lhs: MeetingVideoExporter.ExportError, rhs: MeetingVideoExporter.ExportError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled), (.noVideo, .noVideo): return true
        case (.unreadable(let a), .unreadable(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Progress overlay

extension View {
    /// Attaches the export progress / error sheet driven by `model`.
    func videoExportSheet(_ model: VideoExportModel) -> some View {
        modifier(VideoExportSheet(model: model))
    }
}

private struct VideoExportSheet: ViewModifier {
    @ObservedObject var model: VideoExportModel

    private var presented: Binding<Bool> {
        Binding(get: { model.phase != .idle }, set: { if !$0 { model.dismissError() } })
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: presented) {
            VStack(spacing: 16) {
                switch model.phase {
                case .running(let p):
                    Text("Exporting video…")
                        .font(.system(size: 14, weight: .semibold))
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    Text("Export failed")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 280)
                    Button("OK") { model.dismissError() }
                        .keyboardShortcut(.defaultAction)
                case .idle:
                    EmptyView()
                }
            }
            .padding(28)
            .frame(minWidth: 340)
        }
    }
}
