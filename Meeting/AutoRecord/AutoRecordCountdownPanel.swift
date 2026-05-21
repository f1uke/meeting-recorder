import SwiftUI
import AppKit

/// Borderless, non-activating NSPanel that displays the auto-record countdown.
/// Modeled on `ToastPresenter` but with two buttons (Cancel / Start now) and
/// a countdown label instead of an open target.
///
/// Position: bottom-right of the main screen, 360×140 pt, at `.floating` level.
/// The panel stays visible across all Spaces and does not steal focus.
@MainActor
final class AutoRecordCountdownPanel: ObservableObject {

    private var window: NSPanel?

    /// Show or refresh the countdown panel. Calling while the panel is already
    /// on-screen updates the `remaining` counter in place without re-creating
    /// the window.
    func show(
        event: CalendarEvent,
        subtitle: String,
        remaining: Int,
        onCancel: @escaping () -> Void,
        onStartNow: @escaping () -> Void
    ) {
        let content = AutoRecordCountdownView(
            event: event,
            subtitle: subtitle,
            remaining: remaining,
            onCancel: { [weak self] in
                onCancel()
                self?.dismiss()
            },
            onStartNow: { [weak self] in
                onStartNow()
                self?.dismiss()
            }
        )

        // If the panel already exists, just swap the root view (updates the counter).
        if let window {
            if let hosting = window.contentView as? NSHostingView<AutoRecordCountdownView> {
                hosting.rootView = content
            }
            return
        }

        // --- Build the panel ---
        let hosting = NSHostingView(rootView: content)
        let panelSize = NSSize(width: 360, height: 140)
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false

        // --- Position bottom-right of main screen, 24 pt inset ---
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let inset: CGFloat = 24
            let endOrigin = NSPoint(
                x: f.maxX - panelSize.width - inset,
                y: f.minY + inset
            )
            let endFrame = NSRect(origin: endOrigin, size: panelSize)
            // Slide-in from below: start 24 pt lower, fully transparent.
            let startFrame = endFrame.offsetBy(dx: 0, dy: -24)
            panel.setFrame(startFrame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            window = panel

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(endFrame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
            window = panel
        }
    }

    /// Slide the panel out and close it.
    func dismiss() {
        guard let panel = window else { return }
        window = nil
        let endFrame = panel.frame.offsetBy(dx: 0, dy: -16)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        } completionHandler: {
            panel.close()
        }
    }
}

// MARK: - SwiftUI content

private struct AutoRecordCountdownView: View {
    let event: CalendarEvent
    let subtitle: String
    let remaining: Int
    let onCancel: () -> Void
    let onStartNow: () -> Void

    var body: some View {
        GlassCard(tint: .recordingDark) {
            VStack(alignment: .leading, spacing: 10) {
                // Row 1: pulse indicator + countdown label
                HStack(spacing: 6) {
                    PulseDot()
                    Text("Recording in \(remaining)s")
                        .font(.mono(13))
                        .foregroundStyle(Color.textPrimary)
                }

                // Row 2: event title
                Text(event.title)
                    .font(.serif(16))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                // Row 3: subtitle (time / attendees)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textDim)
                    .lineLimit(2)

                // Row 4: Cancel / Start now buttons
                HStack(spacing: 8) {
                    GlassButton(style: .neutral, action: onCancel) {
                        Text("Cancel")
                    }
                    .keyboardShortcut(.cancelAction)

                    GlassButton(style: .accent, action: onStartNow) {
                        Text("Start now")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }
}
