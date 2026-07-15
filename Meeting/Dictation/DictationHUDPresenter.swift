import AppKit
import Combine
import SwiftUI

/// Hosts the dictation HUD in a borderless, non-activating floating panel
/// near the bottom-center of the active screen. Shows the panel whenever
/// the controller is non-idle and slides it out when it returns to idle.
///
/// Critical constraint: the panel is `.nonactivatingPanel`, never becomes
/// key, and this presenter never calls `NSApp.activate`. Dictation injects
/// text into the *previously* focused app via a synthetic Command-V, so the
/// target field must keep focus the entire time the HUD is up.
@MainActor
final class DictationHUDPresenter {
    private let controller: DictationController
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    private let hudSize = NSSize(width: 300, height: 64)

    init(controller: DictationController) {
        self.controller = controller
        // Drive show/hide off the state machine. The SwiftUI content updates
        // itself for state changes while shown; the presenter only cares
        // about the idle <-> non-idle boundary.
        cancellable = controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .idle {
                    self.hide()
                } else {
                    self.show()
                }
            }
    }

    private func show() {
        guard panel == nil else { return }

        let host = NSHostingView(rootView: DictationHUD(controller: controller))
        host.frame = NSRect(origin: .zero, size: hudSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hudSize),
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
        // Never take key/main - the target app must keep focus for injection.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let endFrame = NSRect(
            x: vf.midX - hudSize.width / 2,
            y: vf.minY + 96,
            width: hudSize.width,
            height: hudSize.height
        )
        let startFrame = endFrame.offsetBy(dx: 0, dy: -20)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        // orderFrontRegardless shows the panel without activating the app.
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
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
