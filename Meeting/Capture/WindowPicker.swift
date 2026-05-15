import SwiftUI
import ScreenCaptureKit
import AppKit

/// What the user selected in the source picker — either a specific
/// window or an entire display. Hashable so it can drive selection
/// state without holding references to SCWindow / SCDisplay (which
/// turn over each refresh).
enum PickerSource: Hashable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

@MainActor
final class WindowPickerModel: ObservableObject {
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var displays: [SCDisplay] = []
    @Published var selectedSource: PickerSource?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var iconCache: [pid_t: NSImage] = [:]

    /// Resolves the selection to a concrete `CaptureSource` if the
    /// picked window / display is still present in the latest scan.
    var selectedCaptureSource: CaptureSource? {
        switch selectedSource {
        case .window(let id):
            return windows.first { $0.windowID == id }.map { .window($0) }
        case .display(let id):
            return displays.first { $0.displayID == id }.map { .display($0) }
        case .none:
            return nil
        }
    }

    /// Compat shim for callers that haven't migrated to
    /// `selectedCaptureSource` yet (PopoverIdleView). Removed in Task 7.
    var selectedWindow: SCWindow? {
        if case .window(let win) = selectedCaptureSource { return win }
        return nil
    }

    func icon(for window: SCWindow) -> NSImage? {
        guard let pid = window.owningApplication?.processID else { return nil }
        if let cached = iconCache[pid] { return cached }
        let img = NSRunningApplication(processIdentifier: pid)?.icon
        if let img { iconCache[pid] = img }
        return img
    }

    func refresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            let myPID = ProcessInfo.processInfo.processIdentifier

            let filtered = content.windows.filter { Self.shouldShow($0, ownPID: myPID) }

            self.windows = filtered.sorted {
                let a = $0.owningApplication?.applicationName ?? ""
                let b = $1.owningApplication?.applicationName ?? ""
                if a == b { return ($0.title ?? "") < ($1.title ?? "") }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }

            // Displays are unfiltered — every available display is a valid
            // source. Sort with primary first, then by displayID for stable
            // ordering across refreshes.
            self.displays = content.displays.sorted { lhs, rhs in
                let lp = lhs.displayID == CGMainDisplayID()
                let rp = rhs.displayID == CGMainDisplayID()
                if lp != rp { return lp }
                return lhs.displayID < rhs.displayID
            }

            clearStaleSelection()
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    /// Test-only seam. Production code goes through `refresh()`, which
    /// can't run in unit tests because SCShareableContent requires the
    /// running app + Screen Recording TCC. Tests pass `displayIDs` to
    /// exercise the bookkeeping logic without needing real SCDisplay
    /// instances (which have no public init).
    func _seedForTests(windowIDs: [CGWindowID] = [], displayIDs: [CGDirectDisplayID] = []) {
        self.windows = []
        self.displays = []
        self._seededWindowIDs = windowIDs
        self._seededDisplayIDs = displayIDs
        clearStaleSelection()
    }
    private var _seededWindowIDs: [CGWindowID] = []
    private var _seededDisplayIDs: [CGDirectDisplayID] = []

    private func clearStaleSelection() {
        switch selectedSource {
        case .window(let id):
            let liveIDs: Set<CGWindowID> =
                Set(windows.map { $0.windowID }).union(_seededWindowIDs)
            if !liveIDs.contains(id) {
                selectedSource = nil
            }
        case .display(let id):
            let liveIDs: Set<CGDirectDisplayID> =
                Set(displays.map { $0.displayID }).union(_seededDisplayIDs)
            if !liveIDs.contains(id) {
                selectedSource = nil
            }
        case .none:
            break
        }
    }

    private static let blockedBundlePrefixes: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenter",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.coreservices",
        "com.apple.WebKit",
        "com.apple.Spotlight",
        "com.apple.wallpaper",
    ]

    private static func shouldShow(_ window: SCWindow, ownPID: pid_t) -> Bool {
        guard let app = window.owningApplication else { return false }
        if app.processID == ownPID { return false }
        if window.windowLayer != 0 { return false }
        if window.frame.width < 100 || window.frame.height < 100 { return false }

        let appName = app.applicationName.trimmingCharacters(in: .whitespaces)
        if appName.isEmpty { return false }

        let bundleID = app.bundleIdentifier
        if Self.blockedBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return false
        }

        let title = (window.title ?? "").trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return false }

        return true
    }
}

fileprivate struct AppGroup {
    let appName: String
    let windows: [SCWindow]
}

/// Compact inline window picker for use inside the menu-bar popover.
///
/// Does NOT use `List(selection:)` because that:
///   1. Synchronously writes the selection binding mid-render, which
///      triggers "Publishing changes from within view updates" with a
///      `@Published` destination.
///   2. Can dismiss `MenuBarExtra(.window)` popovers on row click in
///      some macOS releases, since List rows in macOS sometimes call
///      `becomeFirstResponder` paths that flip key window away from
///      the non-activating popover panel.
///
/// Instead we render rows as plain `Button`s in a `ScrollView` — clicks
/// stay inside the popover and selection updates are deferred via a
/// regular @Published assignment.
struct WindowPicker: View {
    @ObservedObject var model: WindowPickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let error = model.loadError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 10))
            }
            listBody
        }
        .task {
            if model.windows.isEmpty && model.displays.isEmpty {
                await model.refresh()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                let total = model.windows.count + model.displays.count
                Text("\(total) sources")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textFaint)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh source list")
        }
    }

    @ViewBuilder
    private var listBody: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !model.displays.isEmpty {
                    DisplaysHeader(count: model.displays.count)
                        .padding(.top, 4)
                    ForEach(model.displays, id: \.displayID) { display in
                        DisplayRow(
                            display: display,
                            isSelected: model.selectedSource == .display(display.displayID),
                            onSelect: {
                                model.selectedSource = .display(display.displayID)
                            }
                        )
                    }
                }
                ForEach(groupedByApp(), id: \.appName) { group in
                    AppHeader(group: group, model: model)
                        .padding(.top, 4)
                    ForEach(group.windows, id: \.windowID) { window in
                        WindowRow(
                            window: window,
                            isSelected: model.selectedSource == .window(window.windowID),
                            onSelect: { model.selectedSource = .window(window.windowID) }
                        )
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .frame(height: 180)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
        }
    }

    private func groupedByApp() -> [AppGroup] {
        let grouped = Dictionary(grouping: model.windows) { window in
            window.owningApplication?.applicationName ?? "Unknown"
        }
        return grouped
            .map { AppGroup(appName: $0.key, windows: $0.value) }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }
}

private struct AppHeader: View {
    let group: AppGroup
    let model: WindowPickerModel

    var body: some View {
        HStack(spacing: 6) {
            if let first = group.windows.first, let icon = model.icon(for: first) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            }
            Text(group.appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("(\(group.windows.count))")
                .font(.system(size: 10))
                .foregroundStyle(Color.textFaint)
            Spacer()
        }
        .padding(.horizontal, 6)
    }
}

private struct WindowRow: View {
    let window: SCWindow
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Spacer().frame(width: 18)
                Text(window.title ?? "Untitled")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(dimensions)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.textFaint)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.brandAccent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.brandAccent.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var dimensions: String {
        "\(Int(window.frame.width))×\(Int(window.frame.height))"
    }
}

private struct DisplaysHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.brandAccent)
            Text("Displays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("(\(count))")
                .font(.system(size: 10))
                .foregroundStyle(Color.textFaint)
            Spacer()
        }
        .padding(.horizontal, 6)
    }
}

private struct DisplayRow: View {
    let display: SCDisplay
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Spacer().frame(width: 18)
                Text(CaptureSource.displayLabel(displayID: display.displayID))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(dimensions)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.textFaint)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.brandAccent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.brandAccent.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var dimensions: String {
        "\(Int(display.frame.width))×\(Int(display.frame.height))"
    }
}
