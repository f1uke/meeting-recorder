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
        let info = TranscriptReadyInfo(
            title: meetingTitle,
            subtitle: subtitleLine(duration: durationText, speakers: speakerCount),
            transcriptURL: folder.appendingPathComponent("transcript.md"),
            folder: folder
        )
        present(view: TranscriptReadyToastView(
            info: info,
            onOpen: { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([info.transcriptURL])
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        scheduleAutoDismiss(after: 8)
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

struct TranscriptReadyInfo: Sendable {
    let title: String
    let subtitle: String
    let transcriptURL: URL
    let folder: URL
}

struct TranscriptReadyToastView: View {
    let info: TranscriptReadyInfo
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.brandSuccess, Color.brandSuccess.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 38, height: 38)
                    .shadow(color: Color.brandSuccess.opacity(0.4), radius: 4, y: 2)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Transcript ready")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("\(info.title) · \(info.subtitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onOpen) {
                Text("Open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(
                                colors: [Color.brandAccent, Color.brandAccentStrong],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .shadow(color: Color.brandAccentStrong.opacity(0.4), radius: 3, y: 1)
                    }
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.textFaint)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 360, height: 88)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        }
        .glassBorder(cornerRadius: 14)
        .padding(8)
    }
}
