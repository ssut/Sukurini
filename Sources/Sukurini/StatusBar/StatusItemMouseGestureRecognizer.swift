import AppKit

struct StatusItemPointerSample {
    let location: NSPoint
    let isPressed: Bool
    let modifiers: NSEvent.ModifierFlags

    static var current: StatusItemPointerSample {
        StatusItemPointerSample(
            location: NSEvent.mouseLocation,
            isPressed: NSEvent.pressedMouseButtons & 1 != 0,
            modifiers: NSEvent.modifierFlags
        )
    }
}

final class StatusItemMouseGestureRecognizer: NSGestureRecognizer {
    var screenshotAtPress: (() -> Screenshot?)?
    var galleryVisibility: (() -> Bool)?
    var pointerSample: () -> StatusItemPointerSample = { .current }
    private(set) var screenshot: Screenshot?
    private(set) var wasGalleryVisibleAtPress = false
    private(set) var didCrossDragThreshold = false
    private(set) var dragWasRequested = false
    private(set) var currentModifiers: NSEvent.ModifierFlags = []
    private(set) var mouseEvent: NSEvent?
    private var origin = NSPoint.zero
    private var pointerLocation = NSPoint.zero
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var startedAt: TimeInterval = 0

    deinit {
        timer?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func canTrack(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        let sample = pointerSample()
        return sample.isPressed
            && event.modifierFlags.union(sample.modifiers).intersection([.command, .control]).isEmpty
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let sample = pointerSample()
        guard sample.isPressed else {
            state = .failed
            return
        }
        mouseEvent = event
        origin = sample.location
        pointerLocation = sample.location
        currentModifiers = sample.modifiers
        screenshot = screenshotAtPress?()
        wasGalleryVisibleAtPress = galleryVisibility?() ?? false
        startedAt = ProcessInfo.processInfo.systemUptime
        state = .began
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.samplePointer()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.receivePhysicalMouseEvent(event)
        }
        Log.statusItem.info("physical press began x=\(sample.location.x, privacy: .public) y=\(sample.location.y, privacy: .public)")
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        receivePhysicalMouseEvent(event)
    }

    func receivePhysicalMouseEvent(_ event: NSEvent) {
        guard state == .began || state == .changed else { return }
        if event.type == .leftMouseDragged, !dragWasRequested {
            mouseEvent = event
            Log.statusItem.info("physical drag event received number=\(event.eventNumber, privacy: .public) window=\(event.windowNumber, privacy: .public)")
        }
        samplePointer()
        if event.type == .leftMouseDragged, state == .changed, !dragWasRequested {
            state = .changed
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if pointerSample().isPressed {
            Log.statusItem.info("physical press ignored synthetic_release=true")
        }
        samplePointer()
    }

    @available(macOS 26.0, *)
    override func mouseCancelled(with event: NSEvent) {
        super.mouseCancelled(with: event)
        cancelTracking(reason: "mouse_cancelled")
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        if event.keyCode == 53 {
            cancelTracking(reason: "escape")
        }
    }

    override func location(in view: NSView?) -> NSPoint {
        guard let window = self.view?.window else { return .zero }
        let point = window.convertPoint(fromScreen: pointerLocation)
        return view?.convert(point, from: nil) ?? point
    }

    override func reset() {
        removeMouseMonitor()
        timer?.invalidate()
        timer = nil
        screenshot = nil
        mouseEvent = nil
        wasGalleryVisibleAtPress = false
        didCrossDragThreshold = false
        dragWasRequested = false
        currentModifiers = []
        super.reset()
    }

    func samplePointer() {
        guard state == .began || state == .changed else { return }
        guard ProcessInfo.processInfo.systemUptime - startedAt < 120 else {
            cancelTracking(reason: "timeout")
            return
        }
        let sample = pointerSample()
        let moved = pointerLocation != sample.location
        pointerLocation = sample.location
        currentModifiers = sample.modifiers
        if !dragWasRequested, sample.modifiers.contains(.command) {
            cancelTracking(reason: "command")
            return
        }
        let distance = hypot(sample.location.x - origin.x, sample.location.y - origin.y)
        if !didCrossDragThreshold, distance >= 4 {
            didCrossDragThreshold = true
            Log.statusItem.info("physical press threshold crossed distance=\(distance, privacy: .public) pressed=\(sample.isPressed, privacy: .public)")
        }
        if didCrossDragThreshold, sample.isPressed, moved {
            state = .changed
        }
        if !sample.isPressed {
            removeMouseMonitor()
            timer?.invalidate()
            timer = nil
            Log.statusItem.info("physical press ended dragged=\(self.didCrossDragThreshold, privacy: .public)")
            state = .ended
        }
    }

    func takeDragRequest() -> Bool {
        guard state == .changed, didCrossDragThreshold, !dragWasRequested,
              mouseEvent?.type == .leftMouseDragged, pointerSample().isPressed else { return false }
        dragWasRequested = true
        return true
    }

    func dragEvent(in window: NSWindow) -> NSEvent? {
        guard dragWasRequested, let mouseEvent, mouseEvent.type == .leftMouseDragged else { return nil }
        let sample = pointerSample()
        guard sample.isPressed else { return nil }
        return NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: window.convertPoint(fromScreen: sample.location),
            modifierFlags: sample.modifiers,
            timestamp: mouseEvent.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: mouseEvent.eventNumber,
            clickCount: mouseEvent.clickCount,
            pressure: mouseEvent.pressure
        )
    }

    func finishDragAttempt() {
        guard state == .began || state == .changed else { return }
        cancelTracking(reason: "drag_attempt_finished")
    }

    private func removeMouseMonitor() {
        guard let mouseMonitor else { return }
        NSEvent.removeMonitor(mouseMonitor)
        self.mouseMonitor = nil
    }

    private func cancelTracking(reason: String) {
        guard state == .began || state == .changed else { return }
        removeMouseMonitor()
        timer?.invalidate()
        timer = nil
        state = .cancelled
        Log.statusItem.info("physical press cancelled reason=\(reason, privacy: .public)")
    }
}
