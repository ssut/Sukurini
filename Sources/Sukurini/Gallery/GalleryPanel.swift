import AppKit

final class GalleryPanel: NSPanel {

    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        Log.gallery.debug("panel cancelOperation routed to escape handler")
        escapeHandler?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        Log.gallery.debug("panel keyDown escape routed to escape handler")
        escapeHandler?()
    }
}
