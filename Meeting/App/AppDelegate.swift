import AppKit
import Combine
import SwiftUI
import UserNotifications

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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by `MeetingApp.init` before `applicationDidFinishLaunching`
    /// runs so the delegate has the long-lived `AppState` to wire into
    /// the popover.
    static var pendingState: AppState?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var labelHost: NSHostingView<MenuBarLabel>?
    /// Combine subscriptions for SwiftUI state → statusItem width sync.
    /// `NSStatusItem.variableLength` only auto-sizes based on `button.image`
    /// or `button.title`; once we replace the image with a hosting view, we
    /// have to drive `statusItem.length` ourselves whenever the SwiftUI
    /// content's fitting size changes (idle → recording → transcribing).
    private var labelObservers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-first app: no Dock icon, keep running after the last
        // window is closed. The status item is the persistent surface.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        // Apply persisted user prefs that need NSApp to exist (e.g. the
        // appearance override). Safe here because NSApp is fully online.
        AppPreferences.shared.applyAppKitSideEffects()
        // Become the notification-center delegate so we receive both the
        // foreground-presentation hook (so banners show even when we're
        // frontmost) and the user-tap hook for the calendar reminders
        // scheduled by `CalendarNotifier`.
        UNUserNotificationCenter.current().delegate = self
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
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                host.topAnchor.constraint(greaterThanOrEqualTo: button.topAnchor),
                host.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor),
            ])
            labelHost = host
        }

        // Drive statusItem.length from SwiftUI's fitting size whenever
        // the recording or transcription state changes — otherwise the
        // status bar button stays the width it had at attach time and
        // clips wider content (e.g. "0:00" timer next to the red dot).
        labelObservers.removeAll()
        Publishers.CombineLatest(state.recording.$state, state.transcribe.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemWidth()
            }
            .store(in: &labelObservers)
        // Initial size — content is already laid out at attach time.
        refreshStatusItemWidth()

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

    private func refreshStatusItemWidth() {
        guard let statusItem, let host = labelHost else { return }
        // Force SwiftUI/AppKit to flush the latest layout pass before we
        // read fittingSize; otherwise the size reflects the previous state.
        host.layoutSubtreeIfNeeded()
        let contentWidth = host.fittingSize.width
        // 4pt leading inset (set in the constraint above) + 6pt trailing
        // breathing room so the timer doesn't kiss the menu bar edge.
        let length = max(contentWidth + 10, 28)
        if abs(statusItem.length - length) > 0.5 {
            statusItem.length = length
        }
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

    private func showPopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown { return }
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners + play sound even when the app is currently active,
    /// so the user actually sees the 5-min reminder regardless of focus.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle taps on the calendar reminder: surface the popover so the
    /// user can hit "Start Recording" with one click.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        // The completion handler is not Sendable, so we can't capture it
        // into a `Task @MainActor`. Call it synchronously here and let
        // the UI hop happen on its own.
        completionHandler()
        guard kind == "meeting.upcoming" else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.showPopover()
        }
    }
}
