import SwiftUI

/// The body of the menu-bar popover. For U2 this is a thin wrapper that
/// reuses the existing `ContentView` permission-gate routing; U3 will
/// replace it with the design-handoff popover (idle / recording /
/// transcribing states).
struct MenuBarPopoverView: View {
    var body: some View {
        ContentView()
            .frame(width: 360)
            .frame(minHeight: 480, idealHeight: 520)
    }
}
