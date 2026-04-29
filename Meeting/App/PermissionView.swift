import SwiftUI

struct PermissionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meeting").font(.largeTitle).bold()
                Text("กรุณาให้สิทธิ์ก่อนเริ่มใช้งาน")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission)
                }
            }

            HStack {
                Button("Refresh") {
                    Task { await appState.refreshPermissions() }
                }
                Button("Open System Settings → Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Spacer()

            if appState.permissions.allGranted {
                Label("สิทธิ์ครบแล้ว — พร้อมเริ่ม M2", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
        .padding(24)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @EnvironmentObject private var appState: AppState

    var granted: Bool { appState.permissions.granted(for: permission) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.headline)
                Text(permission.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Request") {
                    Task { await appState.request(permission) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
