import AppKit
import Quartz

protocol QuickLookSource: AnyObject {
    var quickLookItems: [URL] { get }
    func quickLookPrepareResponder()
    func quickLookSourceFrame(for url: URL) -> NSRect
    func quickLookTransitionImage(for url: URL) -> NSImage?
    func quickLookStep(_ delta: Int) -> Bool
}

final class QuickLookCoordinator: NSObject {

    private enum Key {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    weak var source: QuickLookSource?

    var onStateChanged: ((Bool) -> Void)?

    private var items: [URL] = []

    var isOpen: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return QLPreviewPanel.shared().isVisible
    }

    func toggle() {
        guard !isOpen else {
            Log.gallery.info("quick look toggle closing")
            close()
            return
        }
        open()
    }

    func open() {
        guard refreshItems() else {
            Log.gallery.info("quick look open skipped reason=no_items")
            return
        }
        guard let panel = QLPreviewPanel.shared() else {
            Log.gallery.error("quick look panel unavailable")
            return
        }

        let responder = NSApp.keyWindow?.firstResponder
        let responderName = responder.map { String(describing: type(of: $0)) } ?? "none"
        let hasKeyWindow = NSApp.keyWindow != nil
        Log.gallery.info(
            "quick look opening keyWindow=\(hasKeyWindow, privacy: .public) firstResponder=\(responderName, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)"
        )

        onStateChanged?(true)

        let wasActive = NSApp.isActive
        NSApp.activate()
        guard !wasActive else {
            present(panel)
            return
        }
        Log.gallery.info("quick look deferring present until activation settles")
        DispatchQueue.main.async { [weak self] in
            self?.present(panel)
        }
    }

    private func present(_ panel: QLPreviewPanel) {
        guard refreshItems() else {
            Log.gallery.info("quick look present skipped reason=no_items")
            onStateChanged?(false)
            return
        }
        source?.quickLookPrepareResponder()
        attach(to: panel)
        panel.makeKeyAndOrderFront(nil)

        let count = items.count
        Log.gallery.info(
            "quick look opened count=\(count, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)"
        )
        verifyAttachment(panel: panel)
    }

    private func attach(to panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        guard !items.isEmpty else { return }
        panel.currentPreviewItemIndex = 0
    }

    private func verifyAttachment(panel: QLPreviewPanel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            if panel.dataSource === self {
                let count = self.items.count
                Log.gallery.info("quick look attachment verified count=\(count, privacy: .public)")
                return
            }
            Log.gallery.error("quick look data source detached, reattaching")
            self.refreshItems()
            self.attach(to: panel)
        }
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared().orderOut(nil)
        Log.gallery.info("quick look closed programmatically")
    }

    func begin(panel: QLPreviewPanel) {
        if items.isEmpty { refreshItems() }
        attach(to: panel)
        onStateChanged?(true)
        let count = items.count
        Log.gallery.info("quick look control began count=\(count, privacy: .public)")
    }

    func end(panel: QLPreviewPanel) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isOpen else {
                Log.gallery.info("quick look control transfer while open, reattaching")
                self.refreshItems()
                self.attach(to: QLPreviewPanel.shared())
                return
            }
            if panel.dataSource === self { panel.dataSource = nil }
            if panel.delegate === self { panel.delegate = nil }
            self.items = []
            self.onStateChanged?(false)
            Log.gallery.info("quick look control ended")
        }
    }

    @discardableResult
    private func refreshItems() -> Bool {
        guard let source else {
            items = []
            return false
        }
        let manager = FileManager.default
        let existing = source.quickLookItems.filter { manager.fileExists(atPath: $0.path) }
        items = existing
        return !existing.isEmpty
    }

    private func syncSelection(panel: QLPreviewPanel) {
        guard refreshItems() else {
            Log.gallery.info("quick look closing reason=selection_empty")
            panel.orderOut(nil)
            return
        }
        panel.reloadData()
        guard panel.currentPreviewItemIndex < 0 || panel.currentPreviewItemIndex >= items.count else { return }
        panel.currentPreviewItemIndex = 0
    }
}

extension QuickLookCoordinator: QLPreviewPanelDataSource {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0, index < items.count else {
            let count = items.count
            Log.gallery.error(
                "quick look item out of range index=\(index, privacy: .public) count=\(count, privacy: .public)"
            )
            return nil
        }
        return items[index] as NSURL
    }
}

extension QuickLookCoordinator: QLPreviewPanelDelegate {

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, items.count == 1 else { return false }
        let delta: Int
        switch event.keyCode {
        case Key.left, Key.up:
            delta = -1
        case Key.right, Key.down:
            delta = 1
        default:
            return false
        }
        guard let source, source.quickLookStep(delta) else {
            Log.gallery.debug("quick look step ignored delta=\(delta, privacy: .public)")
            return true
        }
        syncSelection(panel: panel)
        Log.gallery.debug("quick look stepped delta=\(delta, privacy: .public)")
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = (item as? NSURL) as URL? else { return .zero }
        return source?.quickLookSourceFrame(for: url) ?? .zero
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: QLPreviewItem!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let url = (item as? NSURL) as URL? else { return nil }
        return source?.quickLookTransitionImage(for: url)
    }
}
