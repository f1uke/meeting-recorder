import SwiftUI
import AppKit

/// Floating notification shown after a successful transcription. Lives in
/// its own borderless `NSWindow` at `.floating` level so it appears on top
/// of any active app, slides in from the top-right, and auto-dismisses
/// after 8 seconds (or sooner on user click).
@MainActor
final class ToastPresenter: ObservableObject {
    private var window: NSWindow?
    private var dismissTask: Task<Void, Never>?

    /// Animate in a "Transcript ready" toast. Calling again while a toast
    /// is on-screen replaces it.
    func showTranscriptReady(
        meetingTitle: String,
        durationText: String,
        speakerCount: Int,
        folder: URL
    ) {
        let info = ToastInfo(
            headline: "Transcript ready",
            title: meetingTitle,
            subtitle: subtitleLine(duration: durationText, speakers: speakerCount),
            openTarget: folder.appendingPathComponent("transcript.md"),
            folder: folder
        )
        present(view: ToastView(
            info: info,
            onOpen: { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([info.openTarget])
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        scheduleAutoDismiss(after: 8)
    }

    /// Animate in a "Recording saved" toast — used by Stop only when the
    /// user wants to skip transcription and head straight to the next
    /// meeting. Open button reveals the meeting folder in Finder so they
    /// can confirm the audio/video files landed.
    func showRecordingSaved(
        meetingTitle: String,
        durationText: String,
        folder: URL
    ) {
        let subtitle = durationText.isEmpty
            ? "Transcribe later from Library"
            : "\(durationText) · Transcribe later from Library"
        let info = ToastInfo(
            headline: "Recording saved",
            title: meetingTitle,
            subtitle: subtitle,
            openTarget: folder,
            folder: folder
        )
        present(view: ToastView(
            info: info,
            onOpen: { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([info.openTarget])
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        scheduleAutoDismiss(after: 6)
    }

    /// Force-dismiss the current toast (no-op if none).
    func dismiss() {
        animateOut { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func present<Content: View>(view: Content) {
        // Replace any existing toast atomically.
        window?.close()
        window = nil

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 88)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true

        guard let screen = NSScreen.main else { return }
        let inset: CGFloat = 16
        let endFrame = NSRect(
            x: screen.visibleFrame.maxX - 360 - inset,
            y: screen.visibleFrame.maxY - 88 - inset,
            width: 360,
            height: 88
        )
        // Slide-in start: 24pt above its resting frame, fully transparent.
        let startFrame = endFrame.offsetBy(dx: 0, dy: 24)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        window = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let panel = window else {
            completion()
            return
        }
        let endFrame = panel.frame.offsetBy(dx: 0, dy: 16)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        } completionHandler: {
            completion()
        }
    }

    private func scheduleAutoDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func subtitleLine(duration: String, speakers: Int) -> String {
        var parts: [String] = []
        if !duration.isEmpty { parts.append(duration) }
        if speakers > 0 {
            parts.append("\(speakers) speaker\(speakers == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Content

struct ToastInfo: Sendable {
    let headline: String
    let title: String
    let subtitle: String
    let openTarget: URL
    let folder: URL
}

struct ToastView: View {
    let info: ToastInfo
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(info.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !info.subtitle.isEmpty {
                    Text(info.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Open", action: onOpen)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360, height: 88)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
