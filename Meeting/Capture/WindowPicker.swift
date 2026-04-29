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

struct WindowPicker: View {
    @ObservedObject var model: WindowPickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh window list")
            }

            if let error = model.loadError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            List(selection: deferredSelection) {
                ForEach(groupedByApp(), id: \.appName) { group in
                    Section(header: AppHeader(group: group, model: model)) {
                        ForEach(group.windows, id: \.windowID) { window in
                            WindowRow(window: window)
                                .tag(window.windowID as CGWindowID?)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 280)
        }
        .task {
            if model.windows.isEmpty {
                await model.refresh()
            }
        }
    }

    // List on macOS writes the selection binding synchronously inside the
    // click event, which lands in the middle of a view-update cycle and
    // triggers SwiftUI's "Publishing changes from within view updates"
    // warning when the destination is @Published. Defer the write one
    // runloop tick to land outside the active update.
    private var deferredSelection: Binding<CGWindowID?> {
        Binding(
            get: { model.selectedWindowID },
            set: { newValue in
                DispatchQueue.main.async {
                    model.selectedWindowID = newValue
                }
            }
        )
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
        HStack(spacing: 8) {
            if let first = group.windows.first, let icon = model.icon(for: first) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(group.appName)
                .font(.headline)
            Text("(\(group.windows.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct WindowRow: View {
    let window: SCWindow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(window.title ?? "")
                .lineLimit(1)
            Spacer()
            Text(dimensions)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var dimensions: String {
        "\(Int(window.frame.width))×\(Int(window.frame.height))"
    }
}
