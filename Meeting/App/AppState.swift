import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var permissions = PermissionStatus()

    func refreshPermissions() async {
        permissions = await PermissionManager.currentStatus()
    }

    func request(_ permission: Permission) async {
        await PermissionManager.request(permission)
        await refreshPermissions()
    }
}
