import SwiftUI
import ScreenCaptureKit

struct RecordingMainView: View {
    @StateObject private var session = RecordingSession()
    @StateObject private var picker = WindowPickerModel()
    @StateObject private var transcribe = TranscriptionSession(provider: LocalProvider())
    @StateObject private var prefs = AppPreferences.shared

    var body: some View {
        switch (session.state, transcribe.state) {
        case (.recording(let folder, let started), _):
            RecordingActiveView(folder: folder, startedAt: started) {
                Task {
                    await session.stop()
                    if let saved = session.lastFolder {
                        await transcribe.run(
                            meetingFolder: saved,
                            expectedSpeakers: prefs.expectedSpeakerCount.pyannoteValue
                        )
                    }
                }
            }
        case (_, .running(let stage)):
            TranscriptionProgressView(stage: stage, folder: session.lastFolder)
        case (_, .done(let url)):
            TranscriptionDoneView(transcriptURL: url) {
                transcribe.dismiss()
            }
        case (_, .failed(let message)):
            TranscriptionFailedView(message: message) {
                transcribe.dismiss()
            }
        default:
            IdleView(session: session, picker: picker, prefs: prefs)
        }
    }
}

private struct IdleView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var picker: WindowPickerModel
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WindowPicker(model: picker)

            Divider()

            HStack(spacing: 16) {
                SpeakerCountPicker(selection: $prefs.expectedSpeakerCount)
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    guard let window = picker.selectedWindow else { return }
                    Task { await session.start(window: window) }
                } label: {
                    Label("เริ่มบันทึก", systemImage: "record.circle.fill")
                        .font(.title3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(picker.selectedWindow == nil || session.state == .starting)

                if session.state == .starting {
                    ProgressView().controlSize(.small)
                    Text("กำลังเริ่ม…").foregroundStyle(.secondary)
                }

                Spacer()

                if let folder = session.lastFolder {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last saved").font(.caption).foregroundStyle(.secondary)
                        Button(folder.lastPathComponent) {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if let error = session.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
    }
}

private struct RecordingActiveView: View {
    let folder: URL
    let startedAt: Date
    let onStop: () -> Void

    @State private var elapsed: TimeInterval = 0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .opacity(elapsed.truncatingRemainder(dividingBy: 2) < 1 ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5), value: elapsed)
                Text("กำลังบันทึก")
                    .font(.title2)
                    .bold()
            }

            Text(formatElapsed(elapsed))
                .font(.system(size: 56, weight: .light, design: .monospaced))
                .foregroundStyle(.primary)

            VStack(spacing: 4) {
                Text("Saving to").font(.caption).foregroundStyle(.secondary)
                Button(folder.path(percentEncoded: false)) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Button(action: onStop) {
                Label("หยุดบันทึก", systemImage: "stop.fill")
                    .font(.title3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onReceive(tick) { _ in
            elapsed = Date().timeIntervalSince(startedAt)
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

private struct SpeakerCountPicker: View {
    @Binding var selection: ExpectedSpeakers

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.wave.2")
                .foregroundStyle(.secondary)
            Text("Speakers:").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                ForEach(ExpectedSpeakers.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }
}

private struct TranscriptionProgressView: View {
    let stage: TranscriptionSession.Stage
    let folder: URL?

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
            Text(stage.localizedName)
                .font(.title3)
            if let folder {
                Text(folder.lastPathComponent)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("กำลังถอดเสียง — เริ่มครั้งแรกอาจใช้เวลาสักครู่ขณะดาวน์โหลดโมเดล")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct TranscriptionDoneView: View {
    let transcriptURL: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Transcript พร้อมแล้ว")
                .font(.title2.bold())
            VStack(spacing: 4) {
                Text("ไฟล์เก็บที่").font(.caption).foregroundStyle(.secondary)
                Button(transcriptURL.deletingLastPathComponent().path(percentEncoded: false)) {
                    NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Button("เปิด Markdown") {
                    NSWorkspace.shared.open(transcriptURL)
                }
                .buttonStyle(.borderedProminent)
                Button("เสร็จ") { onDismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct TranscriptionFailedView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("ถอดเสียงไม่สำเร็จ").font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("กลับ") { onDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
