import Foundation
import ScreenCaptureKit
import AppKit

/// `@unchecked Sendable` because `SCWindow` / `SCDisplay` are ObjC reference
/// types that the compiler can't verify. All cross-actor transfers happen
/// inside `@MainActor`-isolated code; the annotation satisfies Swift 6 strict
/// concurrency without introducing real races — mirrors the project's
/// `KitBox`/`DiarizerBox`/`AutoRecordResolveResult` pattern.
enum CaptureSource: @unchecked Sendable {
    case window(SCWindow)
    case display(SCDisplay)

    var title: String {
        switch self {
        case .window(let w):
            return w.title ?? "Untitled Window"
        case .display:
            return "Screen Recording"
        }
    }

    var app: String {
        switch self {
        case .window(let w):
            return w.owningApplication?.applicationName ?? "Unknown"
        case .display(let d):
            return Self.displayLabel(displayID: d.displayID)
        }
    }

    var bundleID: String? {
        switch self {
        case .window(let w):
            return w.owningApplication?.bundleIdentifier
        case .display:
            return nil
        }
    }

    var pid: pid_t? {
        switch self {
        case .window(let w):
            return w.owningApplication?.processID
        case .display:
            return nil
        }
    }

    static func displayLabel(displayID: CGDirectDisplayID) -> String {
        let screens = NSScreen.screens
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let matched = screens.first { screen in
            (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
        }
        let name: String
        if let matched, !matched.localizedName.isEmpty {
            name = matched.localizedName
        } else {
            let idx = screens.firstIndex { screen in
                (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
            }
            name = "Display \((idx ?? 0) + 1)"
        }
        if displayID == CGMainDisplayID() {
            return "\(name) (primary)"
        }
        return name
    }
}
