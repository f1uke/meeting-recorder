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
        // Menu-bar-first app: no Dock icon, keep running after the last
        // window is closed. The status item is the persistent surface.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        if let state = AppDelegate.pendingState {
            attach(state: state)
            AppDelegate.pendingState = nil
        }
    }

    /// Closing all windows shouldn't terminate the app — the menu bar
    /// item is still there and the user expects to reopen Library /
    /// Transcript from it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            button.action = #selector(handleStatusClick(_:))
            button.target = self
            // Receive both buttons so we can route left → popover,
            // right (or ctrl-click) → quit menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func handleStatusClick(_ sender: AnyObject?) {
        let isRightClick: Bool = {
            guard let event = NSApp.currentEvent else { return false }
            if event.type == .rightMouseUp { return true }
            // Treat ctrl-click as right-click to match macOS conventions.
            return event.type == .leftMouseUp && event.modifierFlags.contains(.control)
        }()
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit Meeting",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        // Attaching the menu and immediately performing a click makes
        // NSStatusItem display it. Clearing the menu afterwards keeps
        // left-click-toggles-popover working for the next interaction.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
