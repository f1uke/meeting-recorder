import SwiftUI

/// The body of the menu-bar popover. Routes between three surfaces:
///
///   permission-gate → idle → recording
///
/// Transcription is no longer a routed state — it runs in the background
/// via `TranscriptionQueue` and surfaces inside the idle view as a small
/// status card. After "Stop & Transcribe" the popover returns straight
/// to idle so the user can start the next recording while the previous
/// transcript is still processing.
///
/// Width is fixed at 360pt; height adapts to whichever sub-view is showing.
struct MenuBarPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession

    var body: some View {
        Group {
            if !appState.permissions.allGranted {
                PermissionView()
                    .padding(8)
            } else {
                switch recording.state {
                case let .recording(folder, started):
                    PopoverRecordingView(folder: folder, started: started)
                case .starting:
                    PopoverTransientView(
                        label: "เริ่มบันทึก…",
                        hint: "ถ้าค้างนาน อาจมี macOS TCC dialog ซ่อนอยู่ — กด Cancel เพื่อย้อนกลับ",
                        onCancel: { recording.cancelStart() }
                    )
                case .stopping:
                    PopoverTransientView(label: "หยุดบันทึก…")
                default:
                    PopoverIdleView()
                }
            }
        }
        .frame(width: 360)
        .padding(14)
    }
}
