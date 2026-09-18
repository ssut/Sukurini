import AppKit

final class StatusItemClickGestureRecognizer: NSClickGestureRecognizer {
    var galleryVisibility: (() -> Bool)?
    private(set) var wasGalleryVisibleAtPress = false
    private(set) var pressModifierFlags: NSEvent.ModifierFlags = []
    private var capturedTouchPress = false

    override func mouseDown(with event: NSEvent) {
        capturePress(event)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        capturePress(event)
        super.rightMouseDown(with: event)
    }

    override func reset() {
        super.reset()
        wasGalleryVisibleAtPress = false
        pressModifierFlags = []
        capturedTouchPress = false
    }

    func captureTouchPress() {
        guard !capturedTouchPress else { return }
        capturedTouchPress = true
        wasGalleryVisibleAtPress = galleryVisibility?() ?? false
    }

    private func capturePress(_ event: NSEvent) {
        wasGalleryVisibleAtPress = galleryVisibility?() ?? false
        pressModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }
}

final class StatusItemPanGestureRecognizer: NSPanGestureRecognizer {
    var screenshotAtPress: (() -> Screenshot?)?
    private(set) var screenshot: Screenshot?
    private(set) var mouseEvent: NSEvent?
    private var capturedTouchPress = false

    override func mouseDown(with event: NSEvent) {
        mouseEvent = event
        screenshot = screenshotAtPress?()
        super.mouseDown(with: event)
    }

    func captureTouchPress() {
        guard !capturedTouchPress else { return }
        capturedTouchPress = true
        screenshot = screenshotAtPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        mouseEvent = event
        super.mouseDragged(with: event)
    }

    override func reset() {
        super.reset()
        mouseEvent = nil
        screenshot = nil
        capturedTouchPress = false
    }
}
