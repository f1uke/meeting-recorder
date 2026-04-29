import SwiftUI
import ScreenCaptureKit
import AppKit

@MainActor
final class WindowPickerModel: ObservableObject {
    @Published private(set) var windows: [SCWindow] = []
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var iconCache: [pid_t: NSImage] = [:]

    var selectedWindow: SCWindow? {
        guard let id = selectedWindowID else { return nil }
        return windows.first { $0.windowID == id }
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

            if let id = selectedWindowID, !windows.contains(where: { $0.windowID == id }) {
                selectedWindowID = nil
            }
        } catch {
            self.loadError = error.localizedDescription
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
            HStack(spacing: 6) {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(model.windows.count) windows")
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
                }
                .buttonStyle(.plain)
                .help("Refresh window list")
            }

            if let error = model.loadError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 10))
            }

            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groupedByApp(), id: \.appName) { group in
                        AppHeader(group: group, model: model)
                            .padding(.top, 4)
                        ForEach(group.windows, id: \.windowID) { window in
                            WindowRow(
                                window: window,
                                isSelected: model.selectedWindowID == window.windowID,
                                onSelect: { model.selectedWindowID = window.windowID }
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
                    .fill(Color.black.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
            }
        }
        .task {
            if model.windows.isEmpty {
                await model.refresh()
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
