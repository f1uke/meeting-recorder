import AppKit
import SwiftUI

/// Owns the menu bar status item and the popover panel.
///
/// Replaces `MenuBarExtra(.window)` because on macOS 26 the SwiftUI
/// popover panel (`MenuBarExtraWindow<AnyView>`, level 101) gets stuck
/// in a "zombie" state after `SCStream.startCapture` + Core Audio Tap
/// startup: it keeps the previously-painted content on screen, stops
/// routing click events (including click-outside-to-dismiss), and
/// ignores `displayIfNeeded()`. SwiftUI's `body` re-evaluates correctly
/// — the breakage is at the AppKit panel layer.
///
/// `NSStatusItem` + `NSPopover` is the pre-MenuBarExtra path that has
/// stable behavior across macOS releases. The SwiftUI views
/// (`MenuBarLabel`, `MenuBarPopoverView`) are unchanged — we just host
/// them inside `NSHostingView` / `NSHostingController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MeetingApp.init` before `applicationDidFinishLaunching`
    /// runs so the delegate has the long-lived `AppState` to wire into
    /// the popover.
    static var pendingState: AppState?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var labelHost: NSHostingView<MenuBarLabel>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        if let state = AppDelegate.pendingState {
            attach(state: state)
            AppDelegate.pendingState = nil
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // Placeholder icon shown until `attach(state:)` swaps in the
            // SwiftUI MenuBarLabel host view.
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Meeting"
            )
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
    }

    func attach(state: AppState) {
        guard let statusItem else { return }

        // 1. Swap the placeholder icon for the SwiftUI MenuBarLabel.
        if let button = statusItem.button {
            let label = MenuBarLabel(
                recording: state.recording,
                transcribe: state.transcribe
            )
            let host = NSHostingView(rootView: label)
            host.translatesAutoresizingMaskIntoConstraints = false
            button.image = nil
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
                host.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
                host.topAnchor.constraint(equalTo: button.topAnchor),
                host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            labelHost = host
        }

        // 2. Build the popover with NSHostingController hosting the
        // SwiftUI MenuBarPopoverView. `.preferredContentSize` lets the
        // popover height adapt to whatever sub-view (idle, recording,
        // transcribing) is currently routed.
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: MenuBarPopoverView()
                .appEnvironment(state)
                .task { await state.refreshPermissions() }
        )
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
            // Bring the popover's panel to key so its SwiftUI buttons
            // (including List clicks and keyboard shortcuts) receive
            // events. Without this, key window stays on whatever was
            // active before, and clicks inside the popover can be
            // discarded.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
