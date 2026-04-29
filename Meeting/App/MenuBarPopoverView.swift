import SwiftUI

/// The body of the menu-bar popover. Routes to one of five surfaces
/// depending on the combined `(permissions, recording, transcribe)` state:
///
///   permission-gate → idle → recording → transcribing → done / failed
///
/// Width is fixed at 360pt; height adapts to whichever sub-view is showing.
struct MenuBarPopoverView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var transcribe: TranscriptionSession

    var body: some View {
        Group {
            if !appState.permissions.allGranted {
                // Permission gate. PermissionView is restyled in U8a; for now
                // it's the existing layout shrunk into the popover frame.
                PermissionView()
                    .padding(8)
            } else {
                switch (recording.state, transcribe.state) {
                case let (.recording(folder, started), _):
                    PopoverRecordingView(folder: folder, started: started)
                case (.starting, _):
                    PopoverTransientView(
                        label: "เริ่มบันทึก…",
                        hint: "ถ้าค้างนาน อาจมี macOS TCC dialog ซ่อนอยู่ — กด Cancel เพื่อย้อนกลับ",
                        onCancel: { recording.cancelStart() }
                    )
                case (.stopping, _):
                    PopoverTransientView(label: "หยุดบันทึก…")
                case let (_, .running(stage)):
                    PopoverTranscribingView(stage: stage)
                case let (_, .done(url)):
                    PopoverDoneView(transcriptURL: url) { transcribe.dismiss() }
                case let (_, .failed(message)):
                    PopoverFailedView(message: message) { transcribe.dismiss() }
                default:
                    PopoverIdleView()
                }
            }
        }
        .frame(width: 360)
        .padding(14)
        .background {
            // The MenuBarExtra(.window) already provides a translucent
            // popover backdrop on macOS; we lay our own subtle tint on top
            // so the cards inside have something to blur against.
            Color.clear
        }
    }
}
