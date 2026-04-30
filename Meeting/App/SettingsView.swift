import SwiftUI
import AppKit
import ServiceManagement

// =============================================================================
// MARK: - Top-level window
// =============================================================================

/// Settings window. Three columns in spirit, two visually:
/// 220pt sidebar with the section list, detail pane that swaps based on
/// the selected tab. Matches the macOS-13+ Settings aesthetic but uses
/// the project's GlassCard / Material primitives so it sits next to the
/// existing Library window without looking foreign.
struct SettingsView: View {
    @State private var selection: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: 220)

            Divider().opacity(0.3)

            ScrollView(showsIndicators: false) {
                Group {
                    switch selection {
                    case .general:       GeneralTab()
                    case .recording:     RecordingTab()
                    case .transcription: ComingSoonTab(
                        title: "Transcription",
                        subtitle: "Tweak Whisper chunking, hallucination filters, and post-processing.",
                        icon: "waveform"
                    )
                    case .calendar:      ComingSoonTab(
                        title: "Calendar",
                        subtitle: "Auto-record from macOS Calendar events.",
                        icon: "calendar"
                    )
                    case .aiPrivacy:     ComingSoonTab(
                        title: "AI & Privacy",
                        subtitle: "Manage Claude CLI integration and on-device data flow.",
                        icon: "sparkles"
                    )
                    case .shortcuts:     ComingSoonTab(
                        title: "Shortcuts",
                        subtitle: "Customize keyboard shortcuts.",
                        icon: "command"
                    )
                    case .storage:       StorageTab()
                    case .about:         AboutTab()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        }
        .frame(minWidth: 760, minHeight: 580)
        .background {
            LinearGradient(
                colors: [
                    Color(
                        light: Color(red: 0.96, green: 0.97, blue: 1.00),
                        dark: Color(red: 0.09, green: 0.10, blue: 0.13)
                    ),
                    Color(
                        light: Color(red: 0.92, green: 0.94, blue: 0.99),
                        dark: Color(red: 0.05, green: 0.06, blue: 0.09)
                    ),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}

// =============================================================================
// MARK: - Tabs
// =============================================================================

enum SettingsTab: Hashable, CaseIterable {
    case general, recording, transcription, calendar, aiPrivacy, shortcuts, storage, about

    var label: String {
        switch self {
        case .general:       "General"
        case .recording:     "Recording"
        case .transcription: "Transcription"
        case .calendar:      "Calendar"
        case .aiPrivacy:     "AI & Privacy"
        case .shortcuts:     "Shortcuts"
        case .storage:       "Storage"
        case .about:         "About"
        }
    }

    var icon: String {
        switch self {
        case .general:       "house"
        case .recording:     "mic"
        case .transcription: "waveform"
        case .calendar:      "calendar"
        case .aiPrivacy:     "sparkles"
        case .shortcuts:     "command"
        case .storage:       "internaldrive"
        case .about:         "info.circle"
        }
    }

    /// Display a NEW pill next to this tab's row in the sidebar.
    var isNew: Bool {
        self == .calendar
    }
}

// =============================================================================
// MARK: - Sidebar
// =============================================================================

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.clear
                .background(.thickMaterial)
                .overlay(GlassTint.sidebar.tintColor(for: scheme))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 44)  // traffic-light room

                Text("SETTINGS")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1.0)
                    .foregroundStyle(Color.textDim)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)

                VStack(spacing: 1) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        SidebarRow(
                            tab: tab,
                            isSelected: selection == tab,
                            select: { selection = tab }
                        )
                    }
                }
                .padding(.horizontal, 12)

                Spacer()
            }
        }
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 18)
                Text(tab.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 4)
                if tab.isNew {
                    Text("NEW")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.brandAccent))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================
// MARK: - General tab
// =============================================================================

private struct GeneralTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var launchAtLoginRegistered: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(title: "General", subtitle: "Basic app behavior.")

            SettingsSection(label: "Startup") {
                ToggleRow(
                    title: "Launch at login",
                    description: "Open Meeting in the menu bar when you log in.",
                    isOn: launchAtLoginBinding
                )
                if let err = launchAtLoginError {
                    InlineNote(
                        text: err,
                        tone: .warning
                    )
                }
                Divider().opacity(0.4)
                MenuRow(
                    title: "Appearance",
                    selection: Binding(
                        get: { prefs.appearance },
                        set: { prefs.appearance = $0 }
                    ),
                    options: AppearancePreference.allCases,
                    label: \.displayName
                )
            }

            SettingsSection(label: "Menu bar") {
                ToggleRow(
                    title: "Show timer next to icon while recording",
                    description: nil,
                    isOn: Binding(
                        get: { prefs.showMenuBarTimer },
                        set: { prefs.showMenuBarTimer = $0 }
                    )
                )
            }

            SettingsSection(label: "Language") {
                MenuRow(
                    title: "Default transcription language",
                    description: "Force this language even when the audio is mixed. Changes apply on the next transcription.",
                    selection: Binding(
                        get: { prefs.transcriptionLanguage },
                        set: { prefs.transcriptionLanguage = $0 }
                    ),
                    options: TranscriptionLanguage.allCases,
                    label: \.displayName
                )
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginRegistered },
            set: { newValue in
                let svc = SMAppService.mainApp
                do {
                    if newValue {
                        try svc.register()
                    } else {
                        try svc.unregister()
                    }
                    launchAtLoginRegistered = svc.status == .enabled
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = "Login item could not be \(newValue ? "registered" : "removed"): \(error.localizedDescription). On dev builds (Personal Team / unsigned), macOS may refuse — install the app to /Applications and re-sign with Apple Developer Program credentials."
                    launchAtLoginRegistered = svc.status == .enabled
                }
            }
        )
    }
}

// =============================================================================
// MARK: - Recording tab
// =============================================================================

private struct RecordingTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var recording: RecordingSession
    @State private var devices: [AudioInputDevice] = []

    private var isRecording: Bool {
        if case .recording = recording.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Recording",
                subtitle: "Pick which microphone to capture and tune diarization defaults."
            )

            SettingsSection(label: "Microphone") {
                MicPickerRow(
                    selection: Binding(
                        get: { prefs.micDeviceUID },
                        set: { prefs.micDeviceUID = $0 }
                    ),
                    devices: devices,
                    onRefresh: { devices = AudioInputDevices.enumerate() }
                )
                if isRecording {
                    Divider().opacity(0.4)
                    InlineNote(
                        text: "A recording is in progress. The new microphone will apply to the next recording you start.",
                        tone: .info
                    )
                }
            }

            SettingsSection(label: "Diarization") {
                MenuRow(
                    title: "Default expected speakers",
                    description: "Sets the count Pyannote uses unless overridden in the popover. \"Auto\" lets the model decide.",
                    selection: Binding(
                        get: { prefs.expectedSpeakerCount },
                        set: { prefs.expectedSpeakerCount = $0 }
                    ),
                    options: ExpectedSpeakers.allCases,
                    label: \.displayName
                )
            }

            SettingsSection(label: "Transcription model") {
                ModelPickerRow(
                    selection: Binding(
                        get: { prefs.modelVariant },
                        set: { newValue in
                            prefs.modelVariant = newValue
                        }
                    )
                )
                Divider().opacity(0.4)
                InlineNote(
                    text: "The model loads on first use after switching. The current loaded model stays in memory until the next recording finishes.",
                    tone: .info
                )
            }
        }
        .task {
            devices = AudioInputDevices.enumerate()
        }
    }
}

private struct MicPickerRow: View {
    @Binding var selection: String?
    let devices: [AudioInputDevice]
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input device")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    Text(currentDeviceCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                        .lineLimit(2)
                }
                Spacer()
                Picker("", selection: $selection) {
                    Text("Follow system default").tag(String?.none)
                    if !devices.isEmpty {
                        Divider()
                        ForEach(devices) { device in
                            Text(deviceLabel(device))
                                .tag(String?.some(device.uid))
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 220)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh device list")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var currentDeviceCaption: String {
        if let uid = selection {
            if let device = devices.first(where: { $0.uid == uid }) {
                return device.isDefault
                    ? "Pinned to “\(device.name)” (currently the system default)."
                    : "Pinned to “\(device.name)”."
            }
            return "Pinned device not connected — falls back to system default."
        }
        if let defaultDevice = devices.first(where: \.isDefault) {
            return "Following system default: \(defaultDevice.name)."
        }
        return "Following system default."
    }

    private func deviceLabel(_ device: AudioInputDevice) -> String {
        device.isDefault ? "\(device.name) (system default)" : device.name
    }
}

private struct ModelPickerRow: View {
    @Binding var selection: ModelVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ModelVariant.allCases) { variant in
                Button(action: { selection = variant }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == variant ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(selection == variant ? Color.brandAccent : Color.textDim)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variant.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text(variant.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// =============================================================================
// MARK: - Storage tab
// =============================================================================

private struct StorageTab: View {
    @EnvironmentObject private var library: MeetingsLibrary
    @State private var usage = StorageUsage(usedBytes: 0, freeBytes: 0)

    private var meetingsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Storage",
                subtitle: "Where recordings live on disk."
            )

            SettingsSection(label: "Meetings folder") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.textDim)
                        Text(meetingsFolder.path)
                            .font(.mono(11))
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([meetingsFolder])
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            SettingsSection(label: "Disk usage") {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10)).frame(height: 6)
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color.brandAccent, Color.brandAccent.opacity(0.65)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: proxy.size.width * usage.usedFraction, height: 6)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text("\(usage.usedFormatted) used by Meeting")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textDim)
                        Spacer()
                        Text("\(usage.freeFormatted) free on disk")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textFaint)
                    }
                    Text("\(library.meetings.count) meetings recorded.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .task { usage = library.storageUsage() }
        .onChange(of: library.meetings.count) { usage = library.storageUsage() }
    }
}

// =============================================================================
// MARK: - About tab
// =============================================================================

private struct AboutTab: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(title: "About", subtitle: "Meeting — local-first meeting recorder.")

            SettingsSection(label: "Version") {
                LabeledRow(title: "App version", value: version)
                Divider().opacity(0.4)
                LabeledRow(title: "Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            }

            SettingsSection(label: "Credits") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription powered by **WhisperKit** + **SpeakerKit** by Argmax, Inc.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textDim)
                    Text("Recording uses Apple ScreenCaptureKit + Core Audio HAL.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textDim)
                    Text("AI summaries via Anthropic's Claude Code CLI (optional).")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

// =============================================================================
// MARK: - Coming Soon tab
// =============================================================================

private struct ComingSoonTab: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(title: title, subtitle: subtitle)

            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.textFaint)
                Text("Coming soon")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textDim)
                Text("This section is reserved for upcoming functionality.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
    }
}

// =============================================================================
// MARK: - Reusable row primitives
// =============================================================================

private struct DetailHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.serif(28))
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.textDim)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(1.0)
                .foregroundStyle(Color.textDim)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            }
            .glassBorder(cornerRadius: 12)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MenuRow<Value: Hashable>: View {
    let title: String
    var description: String? = nil
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct LabeledRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(value)
                .font(.mono(11))
                .foregroundStyle(Color.textDim)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct InlineNote: View {
    enum Tone { case info, warning }
    let text: String
    let tone: Tone

    private var color: Color {
        switch tone {
        case .info: Color.brandAccent
        case .warning: Color.warmMark
        }
    }

    private var icon: String {
        switch tone {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle().fill(color.opacity(0.06))
        }
    }
}
