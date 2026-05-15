import AppKit
import Quartz

/// Singleton bridge to the native macOS Quick Look panel.
///
/// SwiftUI rows can call `QuickLookController.shared.present(images:startAt:)`
/// to pop the QL panel with a focused image; arrow keys move between the
/// images supplied so the user can flip through a meeting's captures
/// without leaving the panel. Escape dismisses (native behavior).
///
/// We bypass the responder-chain `acceptsPreviewPanelControl` dance —
/// callers always trigger explicitly, the panel lifecycle is managed by
/// AppKit, and our items list survives across opens because the singleton
/// stays alive for the app's lifetime.
@MainActor
final class QuickLookController: NSObject {
    static let shared = QuickLookController()

    private var items: [NSURL] = []

    /// Show the QL panel with `urls` as its dataset and `index` as the
    /// initially-focused item. Subsequent calls swap the dataset in place
    /// so the user always sees the latest list when they re-trigger.
    func present(images urls: [URL], startAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        items = urls.map { $0 as NSURL }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        // Reload so the panel re-queries our data source even if it was
        // already on screen with a stale set.
        panel.reloadData()
        let clamped = max(0, min(index, items.count - 1))
        panel.currentPreviewItemIndex = clamped
        panel.makeKeyAndOrderFront(nil)
    }
}

extension QuickLookController: QLPreviewPanelDataSource {
    // QLPreviewPanel calls its data source on the main thread (it's a
    // UI panel) but the Obj-C protocol isn't typed @MainActor. Mark the
    // methods nonisolated + assume MainActor inside so Swift 6 stops
    // complaining about isolation-crossing without us having to drop
    // @MainActor from the class — every other caller is from SwiftUI.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items[index] }
    }
}

extension QuickLookController: QLPreviewPanelDelegate {
    // Default behaviors are fine — the panel handles Esc, arrow keys,
    // and the Open/Share toolbar buttons natively against the URLs we
    // hand it. We only declare conformance so AppKit doesn't complain
    // about a nil delegate.
}
