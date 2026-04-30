import SwiftUI

/// Permission gate that fronts the popover until all three TCC services
/// (Screen Recording, Microphone, Audio Capture) are granted. Restyle
/// matches the design handoff: 56pt cobalt lock icon, serif "Permissions"
/// title, and three glass rows with green-tinted granted state vs. cobalt
/// "Allow" pill.
struct PermissionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 18) {
            iconHeader
            VStack(spacing: 8) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission)
                }
            }
            footer
        }
        .padding(.vertical, 16)
    }

    private var iconHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.brandAccent, Color.brandAccentStrong],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.brandAccentStrong.opacity(0.4), radius: 8, y: 4)
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Permissions")
                .font(.serif(28))
                .foregroundStyle(Color.textPrimary)

            Text("Meeting needs three macOS privileges to record cleanly. Everything runs locally.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .lineSpacing(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: { Task { await appState.refreshPermissions() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    Text("Refresh")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: openSystemSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape").font(.system(size: 10))
                    Text("System Settings")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)

    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @EnvironmentObject private var appState: AppState

    private var granted: Bool { appState.permissions.granted(for: permission) }

    var body: some View {
        HStack(spacing: 12) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(permission.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textDim)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            statusControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55), Color.white.opacity(0.10)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(granted
                    ? Color.brandSuccess.opacity(0.18)
                    : Color.primary.opacity(0.06)
                )
                .frame(width: 32, height: 32)
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(granted ? Color.brandSuccess : Color.textDim)
        }
    }

    private var iconName: String {
        switch permission {
        case .screenRecording: "rectangle.on.rectangle"
        case .microphone: "mic.fill"
        case .audioCapture: "speaker.wave.2.fill"
        case .calendar: "calendar"
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
            Button {
                Task { await appState.request(permission) }
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color.brandAccent, Color.brandAccentStrong],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .shadow(color: Color.brandAccentStrong.opacity(0.4), radius: 4, y: 2)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
