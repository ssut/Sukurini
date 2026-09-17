import AppKit

final class StatusItemDragWindow: NSPanel {
    init(pointer: NSPoint, previewSize: NSSize) {
        let size = NSSize(width: max(1, previewSize.width), height: max(1, previewSize.height))
        let origin = NSPoint(x: (pointer.x - size.width / 2).rounded(), y: (pointer.y - size.height / 2).rounded())
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSView(frame: NSRect(origin: .zero, size: size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
