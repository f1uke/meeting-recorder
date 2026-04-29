import SwiftUI
import ScreenCaptureKit

/// Standalone "Pick a window to record" window. Replaces the U3-era
/// `.sheet(isPresented:)` flow because sheets presented from inside a
/// `MenuBarExtra(.window)` popover dismiss the popover the moment they
/// take key focus, which made selecting a window impossible.
///
/// The window owns no state of its own — it reads/writes
/// `appState.picker.selectedWindowID` so the popover (which observes the
/// same model) shows the choice as soon as this window dismisses.
struct WindowPickerWindowView: View {
    @EnvironmentObject private var picker: WindowPickerModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            WindowPicker(model: picker)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minWidth: 460, minHeight: 420)
            Divider().opacity(0.3)
            footer
        }
        .frame(minWidth: 460, minHeight: 540)
        .background {
            Color.clear.background(.regularMaterial).ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundStyle(Color.brandAccent)
                .font(.system(size: 14))
            Text("Pick a window to record")
                .font(.serif(20))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button(action: { dismissWindow(id: "windowPicker") }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textDim)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack {
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            Spacer()
            GlassButton(style: .neutral, action: { dismissWindow(id: "windowPicker") }) {
                Text("Cancel")
            }
            .frame(width: 100)
            GlassButton(style: .accent, action: { dismissWindow(id: "windowPicker") }) {
                Text("Done")
            }
            .frame(width: 120)
            .keyboardShortcut(.return)
            .disabled(picker.selectedWindow == nil)
        }
        .padding(14)
    }

    private var footerHint: String {
        if let win = picker.selectedWindow {
            let app = win.owningApplication?.applicationName ?? "Unknown app"
            let title = win.title?.trimmingCharacters(in: .whitespaces) ?? ""
            return title.isEmpty ? app : "\(title) — \(app)"
        }
        return "Click a window in the list, then Done"
    }
}
