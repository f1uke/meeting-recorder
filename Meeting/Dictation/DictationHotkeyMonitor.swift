import CoreGraphics
import Foundation

/// Owns a listen-only `CGEventTap` that watches for a double-tap of the
/// Control key (start / stop dictation) and the Esc key (cancel).
///
/// Deliberately NOT `@MainActor`: the tap callback fires on its run-loop
/// thread. Results are delivered through `@Sendable` closures that hop to
/// the MainActor themselves.
///
/// Requires the Accessibility TCC grant. When it's missing, `tapCreate`
/// returns nil and `start()` returns false so the caller can nudge the
/// user toward Settings. The same Accessibility grant also authorizes the
/// synthetic Command-V that `TextInjector` posts, so one permission covers
/// both the trigger and the injection.
final class DictationHotkeyMonitor: @unchecked Sendable {
    private let onTrigger: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var detector = DoubleTapDetector()
    private var lastControlDown = false

    init(onTrigger: @escaping @Sendable () -> Void,
         onCancel: @escaping @Sendable () -> Void) {
        self.onTrigger = onTrigger
        self.onCancel = onCancel
    }

    var isRunning: Bool { tap != nil }

    /// Create + install the tap on a dedicated run-loop thread. Returns
    /// false when the tap can't be created (missing Accessibility grant).
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DictationHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap

        // Run the tap's source on its own thread so a busy main run loop
        // (SwiftUI, capture startup) never delays key delivery.
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "dev.fluke.meeting.dictation.hotkey"
        thread.start()
        self.thread = thread
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopSourceInvalidate(src) }
        tap = nil
        runLoopSource = nil
        thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap that blocks too long or on certain
            // user input; re-enable so we keep receiving events.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let controlDown = event.flags.contains(.maskControl)
            // Any other modifier held alongside control breaks the pair so
            // chords never masquerade as a double-tap.
            let otherModifier = event.flags.contains(.maskCommand)
                || event.flags.contains(.maskAlternate)
                || event.flags.contains(.maskShift)
            let now = ProcessInfo.processInfo.systemUptime
            if controlDown && !lastControlDown {
                if otherModifier {
                    detector.otherInputHappened()
                } else if detector.controlPressed(at: now) {
                    onTrigger()
                }
            }
            lastControlDown = controlDown

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 {          // Esc
                onCancel()
            } else {
                detector.otherInputHappened()
            }

        default:
            break
        }
    }
}
