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
                    case .transcription: TranscriptionTab()
                    case .dictation:     DictationTab()
                    case .permissions:   PermissionsTab()
                    case .calendar:      CalendarTab()
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
    case general, recording, transcription, dictation, permissions, calendar, aiPrivacy, shortcuts, storage, about

    var label: String {
        switch self {
        case .general:       "General"
        case .recording:     "Recording"
        case .transcription: "Transcription"
        case .dictation:     "Dictation"
        case .permissions:   "Permissions"
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
        case .dictation:     "text.cursor"
        case .permissions:   "lock.shield"
        case .calendar:      "calendar"
        case .aiPrivacy:     "sparkles"
        case .shortcuts:     "command"
        case .storage:       "internaldrive"
        case .about:         "info.circle"
        }
    }

    /// Display a NEW pill next to this tab's row in the sidebar.
    var isNew: Bool {
        switch self {
        case .calendar, .permissions, .dictation: true
        default: false
        }
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
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// =============================================================================
// MARK: - General tab
// =============================================================================

private struct GeneralTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var appState: AppState
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

            SettingsSection(label: "Notifications") {
                ActionRow(
                    title: "Test “Recording saved”",
                    description: "Fires the toast shown after Stop only.",
                    buttonLabel: "Send",
                    action: testRecordingSavedToast
                )
                Divider().opacity(0.4)
                ActionRow(
                    title: "Test “Transcript ready”",
                    description: "Fires the toast shown after Stop & Transcribe.",
                    buttonLabel: "Send",
                    action: testTranscriptReadyToast
                )
            }
        }
    }

    private var meetingsFolder: URL {
        AppPreferences.shared.meetingsFolderURL
    }

    private func testRecordingSavedToast() {
        appState.toast.showRecordingSaved(
            meetingTitle: "Test meeting",
            durationText: "8m",
            folder: meetingsFolder
        )
    }

    private func testTranscriptReadyToast() {
        appState.toast.showTranscriptReady(
            meetingTitle: "Test meeting",
            durationText: "8m",
            speakerCount: 3,
            folder: meetingsFolder
        )
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
                subtitle: "Pick which microphone to capture."
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

            IdentityMatchingSection()
        }
        .task {
            devices = AudioInputDevices.enumerate()
        }
    }
}

// MARK: - Identity Matching

private struct IdentityMatchingSection: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var identityStore: IdentityStore
    @State private var showingManage = false
    @State private var confirmingReset = false

    var body: some View {
        SettingsSection(label: "Identity matching") {
            ToggleRow(
                title: "Suggest speakers from past meetings",
                description: "After each transcribe, embed each diarized speaker and surface chips in the Transcript Viewer when their voice matches a previously-named speaker.",
                isOn: Binding(
                    get: { prefs.identitySuggestionsEnabled },
                    set: { prefs.identitySuggestionsEnabled = $0 }
                )
            )
            Divider().opacity(0.4)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggestion threshold")
                        .font(.system(size: 13, weight: .medium))
                    Text("Conservative suggests less but is more accurate. Aggressive surfaces more candidates that may need rejection.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
                Spacer()
                Slider(
                    value: Binding(
                        get: { prefs.identityMinSuggestScore },
                        set: { prefs.identityMinSuggestScore = $0 }
                    ),
                    in: 0.45...0.70,
                    step: 0.05
                )
                .frame(width: 160)
                .disabled(!prefs.identitySuggestionsEnabled)
            }
            Divider().opacity(0.4)
            ToggleRow(
                title: "Auto-name when confident",
                description: "When a speaker's voice matches a known person above the threshold below, fill in their name automatically. Auto-named speakers show a ✨ badge and can be reverted.",
                isOn: Binding(
                    get: { prefs.autoNameSpeakersEnabled },
                    set: { prefs.autoNameSpeakersEnabled = $0 }
                )
            )
            .disabled(!prefs.identitySuggestionsEnabled)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-name threshold")
                        .font(.system(size: 13, weight: .medium))
                    Text("Only auto-name at or above this confidence. Higher is safer.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(prefs.autoNameThreshold * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.textDim)
                    Slider(
                        value: Binding(
                            get: { prefs.autoNameThreshold },
                            set: { prefs.autoNameThreshold = $0 }
                        ),
                        in: 0.60...0.95,
                        step: 0.05
                    )
                    .frame(width: 160)
                }
                .disabled(!prefs.identitySuggestionsEnabled || !prefs.autoNameSpeakersEnabled)
            }
            Divider().opacity(0.4)
            HStack {
                Text("Stored identities: \(identityStore.identities.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textDim)
                Spacer()
                Button("Manage…") { showingManage = true }
                    .disabled(identityStore.identities.isEmpty)
                Button("Reset all…") { confirmingReset = true }
                    .foregroundStyle(Color.recordRed)
                    .disabled(identityStore.identities.isEmpty)
            }
        }
        .sheet(isPresented: $showingManage) {
            ManageIdentitiesView()
        }
        .alert("Reset all identities?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                identityStore.reset()
                deleteAllEmbeddingsFiles()
            }
        } message: {
            Text("Deletes every saved voice fingerprint and per-meeting embedding cache. Can't be undone.")
        }
    }

    private func deleteAllEmbeddingsFiles() {
        let root = AppPreferences.shared.meetingsFolderURL
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for f in folders {
            let url = f.appendingPathComponent(MeetingEmbeddingsFile.filename)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private struct ManageIdentitiesView: View {
    @EnvironmentObject private var identityStore: IdentityStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stored Identities")
                .font(.system(size: 18, weight: .semibold))
            if identityStore.identities.isEmpty {
                Text("No identities saved yet.")
                    .foregroundStyle(Color.textDim)
            } else {
                List(identityStore.identities) { identity in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.displayName).font(.system(size: 13, weight: .medium))
                            Text("\(identity.meetingCount) meetings · last seen \(relativeDate(identity.updatedAt))")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                        }
                        Spacer()
                        Button("Forget") { identityStore.delete(id: identity.id) }
                            .foregroundStyle(Color.recordRed)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 240)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// =============================================================================
// MARK: - Transcription tab
// =============================================================================

private struct TranscriptionTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Transcription",
                subtitle: "Pick which engine turns audio into text. Diarization (who said what) always runs locally via SpeakerKit."
            )

            SettingsSection(label: "Engine") {
                EnginePickerRow(
                    selection: Binding(
                        get: { prefs.transcriptionEngine },
                        set: { newValue in
                            prefs.transcriptionEngine = newValue
                            appState.applyTranscriptionProviderChange()
                        }
                    )
                )
            }

            switch prefs.transcriptionEngine {
            case .local:
                SettingsSection(label: "Local model") {
                    ModelPickerRow(
                        selection: Binding(
                            get: { prefs.modelVariant },
                            set: { newValue in
                                prefs.modelVariant = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        )
                    )
                    Divider().opacity(0.4)
                    InlineNote(
                        text: "The model loads on first use after switching. The current loaded model stays in memory until the next recording finishes.",
                        tone: .info
                    )
                }
            case .gemini:
                SettingsSection(label: "Gemini model") {
                    GeminiModelPickerRow(
                        selection: Binding(
                            get: { prefs.geminiModel },
                            set: { newValue in
                                prefs.geminiModel = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        )
                    )
                }

                SettingsSection(label: "Gemini API") {
                    APIKeyRow(
                        title: "API key",
                        description: "Get one at ai.google.dev. Stored in macOS preferences (will move to Keychain in a later release).",
                        value: Binding(
                            get: { prefs.geminiAPIKey },
                            set: { newValue in
                                prefs.geminiAPIKey = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        )
                    )
                    Divider().opacity(0.4)
                    ToggleRow(
                        title: "Use Batch API (50% cheaper, slower)",
                        description: "Submits all chunks as one batch job instead of individual calls. Google charges half as much, but batches typically take a few minutes — and up to 24 h — to finish. Keep the app open until transcription completes.",
                        isOn: Binding(
                            get: { prefs.geminiUseBatchAPI },
                            set: { newValue in
                                prefs.geminiUseBatchAPI = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        )
                    )
                }

                SettingsSection(label: "Glossary") {
                    GlossaryEditorRow(
                        value: Binding(
                            get: { prefs.transcriptionGlossary },
                            set: { newValue in
                                prefs.transcriptionGlossary = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        ),
                        resetToDefault: {
                            prefs.transcriptionGlossary = TranscriptionEngine.defaultGlossary
                            appState.applyTranscriptionProviderChange()
                        }
                    )
                }

            case .openai:
                SettingsSection(label: "OpenAI model") {
                    OpenAIModelPickerRow(
                        selection: Binding(
                            get: { prefs.openaiModel },
                            set: { newValue in
                                prefs.openaiModel = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        )
                    )
                }

                SettingsSection(label: "OpenAI API") {
                    APIKeyRow(
                        title: "API key",
                        description: "Get one at platform.openai.com → API keys. Stored in macOS preferences (will move to Keychain in a later release).",
                        value: Binding(
                            get: { prefs.openaiAPIKey },
                            set: { newValue in
                                prefs.openaiAPIKey = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        )
                    )
                }

                SettingsSection(label: "Glossary") {
                    GlossaryEditorRow(
                        value: Binding(
                            get: { prefs.transcriptionGlossary },
                            set: { newValue in
                                prefs.transcriptionGlossary = newValue
                                appState.applyTranscriptionProviderChange()
                            }
                        ),
                        resetToDefault: {
                            prefs.transcriptionGlossary = TranscriptionEngine.defaultGlossary
                            appState.applyTranscriptionProviderChange()
                        }
                    )
                }
            }
        }
    }
}

private struct EnginePickerRow: View {
    @Binding var selection: TranscriptionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TranscriptionEngine.allCases) { engine in
                Button(action: { selection = engine }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == engine ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(selection == engine ? Color.brandAccent : Color.textDim)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text(engine.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                                .fixedSize(horizontal: false, vertical: true)
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

private struct GeminiModelPickerRow: View {
    @Binding var selection: GeminiModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GeminiModel.allCases) { model in
                Button(action: { selection = model }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == model ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(selection == model ? Color.brandAccent : Color.textDim)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text(model.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                                .fixedSize(horizontal: false, vertical: true)
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

private struct OpenAIModelPickerRow: View {
    @Binding var selection: OpenAIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(OpenAIModel.allCases) { model in
                Button(action: { selection = model }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection == model ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(selection == model ? Color.brandAccent : Color.textDim)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text(model.description)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                                .fixedSize(horizontal: false, vertical: true)
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

private struct APIKeyRow: View {
    let title: String
    let description: String
    @Binding var value: String
    @State private var revealed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Group {
                    if revealed {
                        TextField("paste your API key", text: $value)
                    } else {
                        SecureField("paste your API key", text: $value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.mono(11))

                Button(action: { revealed.toggle() }) {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide" : "Reveal")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct GlossaryEditorRow: View {
    @Binding var value: String
    let resetToDefault: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Domain glossary")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text("Comma-separated terms primed into the cloud provider's system prompt so Thai-leaning transcription doesn't butcher inline English jargon.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $value)
                .font(.mono(11))
                .frame(minHeight: 80, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        }
                }
            HStack {
                Spacer()
                Button("Reset to default", action: resetToDefault)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                        .padding(6)
                        .contentShape(Rectangle())
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
// MARK: - Dictation tab
// =============================================================================

private struct DictationTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var appState: AppState

    private var accessibilityGranted: Bool { appState.permissions.accessibility }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Dictation",
                subtitle: "Talk instead of type anywhere in macOS. Double-tap Ctrl, speak, and the text is inserted at your cursor in the frontmost app."
            )

            SettingsSection(label: "Voice dictation") {
                ToggleRow(
                    title: "Enable system-wide dictation",
                    description: "Double-tap Ctrl to start and stop. It also stops after a short silence. Press Esc to cancel.",
                    isOn: Binding(
                        get: { prefs.dictationEnabled },
                        set: { prefs.dictationEnabled = $0 }
                    )
                )
                if prefs.dictationEnabled && !accessibilityGranted {
                    Divider().opacity(0.4)
                    InlineNote(
                        text: "Dictation needs Accessibility access to detect the hotkey and paste into other apps. Grant it below.",
                        tone: .warning
                    )
                }
            }

            SettingsSection(label: "Accessibility access") {
                PermissionSettingRow(
                    permission: .accessibility,
                    extraNote: "One grant covers both detecting the double-tap Ctrl hotkey and inserting the transcribed text into whatever app has focus."
                )
            }

            SettingsSection(label: "Transcription engine") {
                MenuRow(
                    title: "Engine",
                    description: engineDescription,
                    selection: Binding(
                        get: { prefs.dictationEngine },
                        set: { prefs.dictationEngine = $0 }
                    ),
                    options: DictationEngine.allCases,
                    label: \.displayName
                )
                .disabled(!prefs.dictationEnabled)

                if prefs.dictationEngine == .gemini && prefs.geminiAPIKey.isEmpty {
                    Divider().opacity(0.4)
                    InlineNote(
                        text: "No Gemini API key is set (Transcription tab). Dictation will fall back to the local model until you add one.",
                        tone: .info
                    )
                }
            }

            SettingsSection(label: "Language") {
                MenuRow(
                    title: "Dictation language",
                    description: "Force this language for dictation. Thai keeps Thai script for Thai-English code-switching.",
                    selection: Binding(
                        get: { prefs.dictationLanguage },
                        set: { prefs.dictationLanguage = $0 }
                    ),
                    options: TranscriptionLanguage.allCases,
                    label: \.displayName
                )
                .disabled(!prefs.dictationEnabled)
            }
        }
    }

    private var engineDescription: String {
        prefs.dictationEngine.description
    }
}

// =============================================================================
// MARK: - Permissions tab
// =============================================================================

private struct PermissionsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Permissions",
                subtitle: "Required permissions are checked at the popover gate; optional ones unlock extra features and can be granted any time."
            )

            SettingsSection(label: "Required") {
                let required = Permission.allCases.filter { $0.isRequired }
                ForEach(Array(required.enumerated()), id: \.element) { index, permission in
                    PermissionSettingRow(permission: permission)
                    if index < required.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }

            SettingsSection(label: "Optional") {
                let optional = Permission.allCases.filter { !$0.isRequired }
                ForEach(Array(optional.enumerated()), id: \.element) { index, permission in
                    PermissionSettingRow(permission: permission, extraNote: optionalContext(for: permission))
                    if index < optional.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Refresh") {
                    Task { await appState.refreshPermissions() }
                }
                .controlSize(.small)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Per-permission rationale shown only in the optional section. Required
    /// perms already have their detail line; the extra note is for the
    /// "what does this unlock?" context that's hard to fit in the row.
    private func optionalContext(for permission: Permission) -> String? {
        switch permission {
        case .accessibility:
            return "When granted, Meeting reads Google Meet's mic-button state in Chrome and skips transcribing the moments you were muted (no more Whisper hallucinations on echo / silence)."
        case .calendar:
            return "When granted, Meeting auto-fills meeting titles and attendee lists from your Calendar, and reminds you 5 minutes before scheduled calls."
        default:
            return nil
        }
    }
}

private struct PermissionSettingRow: View {
    let permission: Permission
    var extraNote: String? = nil
    @EnvironmentObject private var appState: AppState

    private var granted: Bool { appState.permissions.granted(for: permission) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(granted ? Color.brandSuccess : Color.textDim)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    Text(permission.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let extraNote {
                        Text(extraNote)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                statusControl
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        if granted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Granted")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.brandSuccess)
        } else {
            Button("Allow") {
                Task { await appState.request(permission) }
            }
            .controlSize(.small)
        }
    }

    private var iconName: String {
        switch permission {
        case .screenRecording: "rectangle.on.rectangle"
        case .microphone: "mic.fill"
        case .audioCapture: "speaker.wave.2.fill"
        case .accessibility: "accessibility"
        case .calendar: "calendar"
        }
    }
}

// =============================================================================
// MARK: - Calendar tab
// =============================================================================

private struct CalendarTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var appState: AppState
    @State private var draftEmail: String = ""
    @State private var draftError: String?

    private var sortedEmails: [String] {
        prefs.myEmails.sorted()
    }

    private var unaddedSuggestions: [String] {
        let current = prefs.myEmails
        return calendar.suggestedMyEmails().filter { !current.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Calendar",
                subtitle: "Tell Meeting which email addresses are yours so it can map you to the right speaker."
            )

            SettingsSection(label: "My email addresses") {
                VStack(alignment: .leading, spacing: 0) {
                    if sortedEmails.isEmpty {
                        Text("No emails added yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textDim)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(sortedEmails.enumerated()), id: \.element) { index, email in
                            HStack(spacing: 8) {
                                Image(systemName: "envelope")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.textDim)
                                Text(email)
                                    .font(.mono(12))
                                    .foregroundStyle(Color.textPrimary)
                                    .textSelection(.enabled)
                                Spacer()
                                Button(action: { remove(email) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.textFaint)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            if index < sortedEmails.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }

                    Divider().opacity(0.4)

                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textDim)
                        TextField("name@example.com", text: $draftEmail, onCommit: addDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        Button("Add", action: addDraft)
                            .controlSize(.small)
                            .disabled(draftEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if let err = draftError {
                        Divider().opacity(0.4)
                        InlineNote(text: err, tone: .warning)
                    }
                }
            }

            if !unaddedSuggestions.isEmpty {
                SettingsSection(label: "Suggested from your calendars") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detected from your connected calendar accounts. Click to add.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textDim)
                        FlowChips(items: unaddedSuggestions, onPick: add)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            SettingsSection(label: "Group expansions") {
                GroupExpansionsEditor()
            }

            SettingsSection(label: "Auto-record") {
                ToggleRow(
                    title: "Auto-record calendar meetings",
                    description: "Start a recording with a \(prefs.autoRecordCountdownSeconds)-second confirmation when an eligible event begins.",
                    isOn: Binding(
                        get: { prefs.autoRecordEnabled },
                        set: { prefs.autoRecordEnabled = $0 }
                    )
                )

                Divider().opacity(0.4)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Confirmation window")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                        Text("How long to show the countdown before auto-starting.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textDim)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { prefs.autoRecordCountdownSeconds },
                        set: { prefs.autoRecordCountdownSeconds = $0 }
                    )) {
                        Text("3 s").tag(3)
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                        Text("30 s").tag(30)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!prefs.autoRecordEnabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().opacity(0.4)

                if calendar.authorization == .authorized {
                    AutoRecordCalendarList(prefs: prefs, store: calendar)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .disabled(!prefs.autoRecordEnabled)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Calendars")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Text("Grant access to choose which calendars trigger auto-record.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                        }
                        Spacer(minLength: 8)
                        Button("Grant Calendar access") {
                            Task { await appState.request(.calendar) }
                        }
                        .disabled(!prefs.autoRecordEnabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("When auto-record can't capture the right window".uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.0)
                        .foregroundStyle(Color.textDim)
                    Picker("", selection: Binding(
                        get: { prefs.autoRecordSourceFallback },
                        set: { prefs.autoRecordSourceFallback = $0 }
                    )) {
                        ForEach(AutoRecordSourceFallback.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(!prefs.autoRecordEnabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if prefs.autoRecordEnabled
                    && prefs.autoRecordEnabledCalendarIDs.isEmpty
                    && calendar.authorization == .authorized {
                    InlineNote(
                        text: "Pick at least one calendar above — auto-record won't fire until you do.",
                        tone: .warning
                    )
                }
            }
        }
    }

    private func addDraft() {
        let email = draftEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !email.isEmpty else { return }
        guard email.contains("@"), email.contains(".") else {
            draftError = "“\(draftEmail)” doesn't look like an email address."
            return
        }
        add(email)
        draftEmail = ""
        draftError = nil
    }

    private func add(_ email: String) {
        var updated = prefs.myEmails
        updated.insert(email.lowercased())
        prefs.myEmails = updated
    }

    private func remove(_ email: String) {
        var updated = prefs.myEmails
        updated.remove(email)
        prefs.myEmails = updated
    }
}

// MARK: - Auto-record calendar list

private struct AutoRecordCalendarList: View {
    @ObservedObject var prefs: AppPreferences
    @ObservedObject var store: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calendars")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.textDim)
                .padding(.bottom, 2)
            ForEach(store.allCalendars()) { entry in
                Toggle(isOn: binding(for: entry.id)) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textPrimary)
                        if let sub = entry.subtitle {
                            Text(sub)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textDim)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { prefs.autoRecordEnabledCalendarIDs.contains(id) },
            set: { newValue in
                if newValue {
                    prefs.autoRecordEnabledCalendarIDs.insert(id)
                } else {
                    prefs.autoRecordEnabledCalendarIDs.remove(id)
                }
            }
        )
    }
}

/// Editor for the manual group → members map. Used when EventKit can't
/// expand a Workspace group invite (e.g. `team@example.com`) so the
/// calendar surfaces a single group entry instead of the actual people.
/// Once a group is mapped here, `CalendarStore.snapshot` substitutes the
/// expansion when building `calendar.json` for new recordings.
private struct GroupExpansionsEditor: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var newGroupEmail: String = ""
    @State private var draftMemberName: [String: String] = [:]
    @State private var draftMemberEmail: [String: String] = [:]
    @State private var showAddGroupRow = false

    private var sortedGroups: [String] {
        prefs.groupExpansions.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sortedGroups.isEmpty && !showAddGroupRow {
                Text("Add a group email (e.g. team@example.com) plus its members. The calendar will substitute these names whenever the group appears as an attendee.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            ForEach(Array(sortedGroups.enumerated()), id: \.element) { idx, groupEmail in
                groupBlock(for: groupEmail)
                if idx < sortedGroups.count - 1 || showAddGroupRow {
                    Divider().opacity(0.3)
                }
            }

            if showAddGroupRow {
                addGroupInline
            }

            HStack {
                Spacer()
                Button(showAddGroupRow ? "Cancel" : "Add group") {
                    if showAddGroupRow {
                        newGroupEmail = ""
                    }
                    showAddGroupRow.toggle()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func groupBlock(for groupEmail: String) -> some View {
        let members = prefs.groupExpansions[groupEmail] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brandAccent)
                Text(groupEmail)
                    .font(.mono(12))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(members.count == 1 ? "1 member" : "\(members.count) members")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textFaint)
                Button(action: { removeGroup(groupEmail) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textFaint)
                }
                .buttonStyle(.plain)
                .help("Remove group")
            }

            if !members.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(members) { member in
                        memberChip(groupEmail: groupEmail, member: member)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(
                    "Name (optional)",
                    text: Binding(
                        get: { draftMemberName[groupEmail] ?? "" },
                        set: { draftMemberName[groupEmail] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 140)

                TextField(
                    "name@example.com",
                    text: Binding(
                        get: { draftMemberEmail[groupEmail] ?? "" },
                        set: { draftMemberEmail[groupEmail] = $0 }
                    ),
                    onCommit: { addMember(to: groupEmail) }
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

                Button("Add", action: { addMember(to: groupEmail) })
                    .controlSize(.small)
                    .disabled(!isValidEmail(draftMemberEmail[groupEmail] ?? ""))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func memberChip(groupEmail: String, member: GroupMember) -> some View {
        HStack(spacing: 4) {
            Text(member.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Text(member.email)
                .font(.mono(10))
                .foregroundStyle(Color.textDim)
                .lineLimit(1)
            Button(action: { removeMember(from: groupEmail, member: member) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(Color.primary.opacity(0.06))
        }
    }

    private var addGroupInline: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color.textDim)
            TextField("group@example.com", text: $newGroupEmail, onCommit: saveNewGroup)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Button("Save", action: saveNewGroup)
                .controlSize(.small)
                .disabled(!isValidEmail(newGroupEmail))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func saveNewGroup() {
        let trimmed = newGroupEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard isValidEmail(trimmed) else { return }
        var updated = prefs.groupExpansions
        if updated[trimmed] == nil { updated[trimmed] = [] }
        prefs.groupExpansions = updated
        newGroupEmail = ""
        showAddGroupRow = false
    }

    private func removeGroup(_ groupEmail: String) {
        var updated = prefs.groupExpansions
        updated.removeValue(forKey: groupEmail)
        prefs.groupExpansions = updated
        draftMemberName.removeValue(forKey: groupEmail)
        draftMemberEmail.removeValue(forKey: groupEmail)
    }

    private func addMember(to groupEmail: String) {
        let emailRaw = (draftMemberEmail[groupEmail] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard isValidEmail(emailRaw) else { return }
        let nameRaw = draftMemberName[groupEmail] ?? ""
        let member = GroupMember(name: nameRaw, email: emailRaw)
        var updated = prefs.groupExpansions
        var members = updated[groupEmail] ?? []
        if !members.contains(where: { $0.email == member.email }) {
            members.append(member)
        }
        updated[groupEmail] = members
        prefs.groupExpansions = updated
        draftMemberName[groupEmail] = ""
        draftMemberEmail[groupEmail] = ""
    }

    private func removeMember(from groupEmail: String, member: GroupMember) {
        var updated = prefs.groupExpansions
        updated[groupEmail]?.removeAll { $0.email == member.email }
        prefs.groupExpansions = updated
    }

    private func isValidEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }
}

/// Wrapping row of capsule chips. Each chip is a button; new lines wrap
/// automatically when the row runs out of horizontal room.
private struct FlowChips: View {
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(action: { onPick(item) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text(item)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.brandAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule()
                            .fill(Color.brandAccent.opacity(0.10))
                            .overlay {
                                Capsule().strokeBorder(
                                    Color.brandAccent.opacity(0.30),
                                    lineWidth: 0.5
                                )
                            }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}


// =============================================================================
// MARK: - Storage tab
// =============================================================================

private struct StorageTab: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @EnvironmentObject private var library: MeetingsLibrary
    @State private var usage = StorageUsage(usedBytes: 0, freeBytes: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DetailHeader(
                title: "Storage",
                subtitle: "Pick where recordings are saved on disk and where Markdown notes are exported."
            )

            SettingsSection(label: "Recordings folder") {
                FolderPickerRow(
                    description: "New recordings save here as timestamped subfolders. Existing recordings stay in the previous location when you change this — move them yourself if you want them re-indexed.",
                    path: Binding(
                        get: { prefs.meetingsFolder },
                        set: { prefs.meetingsFolder = $0 }
                    ),
                    defaultPath: AppPreferences.defaultMeetingsFolder
                )
            }

            SettingsSection(label: "Meeting notes folder") {
                FolderPickerRow(
                    description: "Where “Generate Note” writes the per-meeting Markdown file. Designed for an Obsidian vault. Filename format: yyyy-MM-dd-<title-slug>.md.",
                    path: Binding(
                        get: { prefs.meetingNotesFolder },
                        set: { prefs.meetingNotesFolder = $0 }
                    ),
                    defaultPath: AppPreferences.defaultMeetingNotesFolder
                )
            }

            SettingsSection(label: "Video retention") {
                MenuRow(
                    title: "Delete recorded video",
                    description: "Video files are large. After this many days, a meeting's video.mov is moved to the Trash — audio, transcript, and everything else are always kept. Starred meetings are never touched.",
                    selection: Binding(
                        get: { prefs.videoRetention },
                        set: {
                            prefs.videoRetention = $0
                            library.pruneExpiredVideos()
                        }
                    ),
                    options: VideoRetention.allCases,
                    label: \.displayName
                )
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

private struct ActionRow: View {
    let title: String
    let description: String?
    let buttonLabel: String
    let action: () -> Void

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
            Spacer(minLength: 8)
            Button(buttonLabel, action: action)
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

private struct FolderPickerRow: View {
    let description: String?
    @Binding var path: String
    let defaultPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textDim)
                Text(path)
                    .font(.mono(11))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: choose)
                    .controlSize(.small)
                Button("Reveal", action: reveal)
                    .controlSize(.small)
            }
            if path != defaultPath {
                HStack {
                    Spacer()
                    Button("Reset to default") {
                        path = defaultPath
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brandAccent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path(percentEncoded: false)
        }
    }

    private func reveal() {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
