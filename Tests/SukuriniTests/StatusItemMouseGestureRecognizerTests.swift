import AppKit
import XCTest
@testable import Sukurini

@MainActor
final class StatusItemMouseGestureRecognizerTests: XCTestCase {
    private var gestureWindow: NSWindow?

    override func tearDown() {
        gestureWindow?.orderOut(nil)
        gestureWindow = nil
        super.tearDown()
    }

    @objc private func gestureChanged(_ gesture: NSGestureRecognizer) {}

    func testSyntheticReleaseWhilePhysicallyPressedKeepsTracking() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(gesture.state, .began)
        XCTAssertFalse(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.takeDragRequest())
    }

    func testPollingPastThresholdWaitsForPhysicalDragEvent() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .changed)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.takeDragRequest())
        XCTAssertFalse(gesture.dragWasRequested)
        XCTAssertEqual(gesture.mouseEvent?.type, .leftMouseDown)
        let dragEvent = try event(.leftMouseDragged)
        gesture.receivePhysicalMouseEvent(dragEvent)
        XCTAssertTrue(gesture.mouseEvent === dragEvent)
        XCTAssertTrue(gesture.takeDragRequest())
    }

    func testPhysicalDragEventAfterReleaseCannotRequestSession() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14, pressed: false) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertEqual(gesture.state, .ended)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.takeDragRequest())
    }

    func testPhysicalMovementRequestsDragExactlyOnce() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertEqual(gesture.state, .changed)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertTrue(gesture.takeDragRequest())
        XCTAssertFalse(gesture.takeDragRequest())
        gesture.samplePointer()
        XCTAssertFalse(gesture.takeDragRequest())
    }

    func testAcceptedDragKeepsTrackingUntilPhysicalRelease() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertTrue(gesture.takeDragRequest())
        gesture.pointerSample = { self.sample(x: 60, modifiers: [.option]) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .changed)
        XCTAssertTrue(gesture.currentModifiers.contains(.option))
        let window = try XCTUnwrap(gestureWindow)
        XCTAssertEqual(gesture.location(in: nil), window.convertPoint(fromScreen: NSPoint(x: 60, y: 10)))
        gesture.pointerSample = { self.sample(x: 70, modifiers: [.command]) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .changed)
        XCTAssertFalse(gesture.takeDragRequest())
        gesture.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(gesture.state, .changed)
        gesture.pointerSample = { self.sample(x: 80, pressed: false) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .ended)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertTrue(gesture.dragWasRequested)
        XCTAssertFalse(gesture.takeDragRequest())
    }

    func testFailedDragAttemptCancelsAndReleaseCannotBecomeClick() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertTrue(gesture.takeDragRequest())
        gesture.finishDragAttempt()
        XCTAssertEqual(gesture.state, .cancelled)
        gesture.pointerSample = { self.sample(pressed: false) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .cancelled)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertTrue(gesture.dragWasRequested)
        XCTAssertFalse(gesture.takeDragRequest())
    }

    func testReleaseBetweenThresholdAndDragRequestRejectsSession() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        gesture.pointerSample = { self.sample(x: 14, pressed: false) }
        XCTAssertFalse(gesture.takeDragRequest())
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .ended)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.dragWasRequested)
    }

    func testPhysicalReleaseWithoutMovementEndsAsClick() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(pressed: false) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .ended)
        XCTAssertFalse(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.takeDragRequest())
    }

    func testDragEventRequiresAcceptedDragRequest() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        let window = try XCTUnwrap(gestureWindow)
        XCTAssertNil(gesture.dragEvent(in: window))
        try press(gesture)
        XCTAssertNil(gesture.dragEvent(in: window))
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertNil(gesture.dragEvent(in: window))
        XCTAssertTrue(gesture.takeDragRequest())
        XCTAssertNotNil(gesture.dragEvent(in: window))
    }

    func testDragEventNormalizesForeignWindowCoordinatesAndPreservesIdentity() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        let foreignWindow = NSWindow(contentRect: NSRect(x: 400, y: 200, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let original = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 27, y: 39),
            modifierFlags: [.shift],
            timestamp: 123.25,
            windowNumber: foreignWindow.windowNumber,
            context: nil,
            eventNumber: 47,
            clickCount: 2,
            pressure: 0.75
        ))
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(original)
        XCTAssertTrue(gesture.takeDragRequest())
        for origin in [NSPoint(x: -1_400, y: 1_000), NSPoint(x: 200, y: -900)] {
            let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 100, height: 100)), styleMask: .borderless, backing: .buffered, defer: false)
            let pointer = NSPoint(x: -660, y: 1_097)
            gesture.pointerSample = {
                StatusItemPointerSample(location: pointer, isPressed: true, modifiers: [.option])
            }
            let normalized = try XCTUnwrap(gesture.dragEvent(in: window))
            XCTAssertEqual(normalized.type, .leftMouseDragged)
            XCTAssertEqual(normalized.windowNumber, window.windowNumber)
            XCTAssertEqual(window.convertPoint(toScreen: normalized.locationInWindow), pointer)
            XCTAssertEqual(normalized.timestamp, original.timestamp)
            XCTAssertEqual(normalized.eventNumber, original.eventNumber)
            XCTAssertEqual(normalized.clickCount, original.clickCount)
            XCTAssertEqual(normalized.pressure, original.pressure)
            XCTAssertTrue(normalized.modifierFlags.contains(.option))
            XCTAssertFalse(normalized.modifierFlags.contains(.shift))
        }
    }

    func testReleaseAfterDragRequestRejectsNativeHandoff() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 14) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertTrue(gesture.takeDragRequest())
        gesture.pointerSample = { self.sample(x: 14, pressed: false) }
        XCTAssertNil(gesture.dragEvent(in: try XCTUnwrap(gestureWindow)))
    }

    func testReleaseBeyondThresholdConsumesClickWithoutStartingPhantomDrag() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 30, pressed: false) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .ended)
        XCTAssertTrue(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.takeDragRequest())
        XCTAssertFalse(gesture.dragWasRequested)
    }

    func testPressSnapshotsScreenshotAndGalleryVisibility() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        let original = Screenshot(url: URL(fileURLWithPath: "/tmp/pressed.png"), created: .distantPast, size: 1)
        var screenshot: Screenshot? = original
        var visible = true
        gesture.screenshotAtPress = { screenshot }
        gesture.galleryVisibility = { visible }
        try press(gesture)
        screenshot = nil
        visible = false
        gesture.samplePointer()
        XCTAssertEqual(gesture.screenshot, original)
        XCTAssertTrue(gesture.wasGalleryVisibleAtPress)
    }

    func testOptionPressedAfterMouseDownAppliesAtDragRecognition() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        XCTAssertFalse(gesture.currentModifiers.contains(.option))
        gesture.pointerSample = { self.sample(x: 15, modifiers: [.option]) }
        gesture.receivePhysicalMouseEvent(try event(.leftMouseDragged))
        XCTAssertTrue(gesture.takeDragRequest())
        XCTAssertTrue(gesture.currentModifiers.contains(.option))
    }

    func testCommandPressedDuringTrackingCancelsWithoutClickOrDrag() throws {
        let gesture = makeGesture()
        defer { gesture.reset() }
        try press(gesture)
        gesture.pointerSample = { self.sample(x: 30, modifiers: [.command]) }
        gesture.samplePointer()
        XCTAssertEqual(gesture.state, .cancelled)
        XCTAssertFalse(gesture.takeDragRequest())
        XCTAssertFalse(gesture.didCrossDragThreshold)
    }

    func testAdmissionRejectsCommandControlAndReleasedPointer() throws {
        let gesture = makeGesture()
        XCTAssertTrue(gesture.canTrack(try event(.leftMouseDown)))
        XCTAssertFalse(gesture.canTrack(try event(.leftMouseDown, modifiers: [.command])))
        XCTAssertFalse(gesture.canTrack(try event(.leftMouseDown, modifiers: [.control])))
        XCTAssertFalse(gesture.canTrack(try event(.rightMouseDown)))
        gesture.pointerSample = { self.sample(modifiers: [.command]) }
        XCTAssertFalse(gesture.canTrack(try event(.leftMouseDown)))
        gesture.pointerSample = { self.sample(modifiers: [.control]) }
        XCTAssertFalse(gesture.canTrack(try event(.leftMouseDown)))
        gesture.pointerSample = { self.sample(pressed: false) }
        XCTAssertFalse(gesture.canTrack(try event(.leftMouseDown)))
    }

    func testResetStopsSamplingAndClearsCapturedState() throws {
        let gesture = makeGesture()
        var samples = 0
        gesture.pointerSample = {
            samples += 1
            return self.sample(modifiers: [.option])
        }
        gesture.screenshotAtPress = {
            Screenshot(url: URL(fileURLWithPath: "/tmp/pressed.png"), created: .distantPast, size: 1)
        }
        gesture.galleryVisibility = { true }
        try press(gesture)
        gesture.reset()
        let samplesAtReset = samples
        let deadline = Date(timeIntervalSinceNow: 0.04)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        XCTAssertEqual(samples, samplesAtReset)
        XCTAssertNil(gesture.screenshot)
        XCTAssertNil(gesture.mouseEvent)
        XCTAssertFalse(gesture.wasGalleryVisibleAtPress)
        XCTAssertFalse(gesture.didCrossDragThreshold)
        XCTAssertFalse(gesture.dragWasRequested)
        XCTAssertTrue(gesture.currentModifiers.isEmpty)
    }

    private func makeGesture() -> StatusItemMouseGestureRecognizer {
        let application = NSApplication.shared
        if !application.isRunning { application.finishLaunching() }
        let gesture = StatusItemMouseGestureRecognizer(target: self, action: #selector(gestureChanged(_:)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = GestureTestView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addGestureRecognizer(gesture)
        window.orderFrontRegardless()
        gestureWindow = window
        gesture.pointerSample = { self.sample() }
        return gesture
    }

    private func press(_ gesture: StatusItemMouseGestureRecognizer) throws {
        let view = try XCTUnwrap(gesture.view)
        let window = try XCTUnwrap(view.window)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        pumpRunLoop()
    }

    private func pumpRunLoop() {
        let deadline = Date(timeIntervalSinceNow: 0.05)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }

    private func sample(x: CGFloat = 10, pressed: Bool = true, modifiers: NSEvent.ModifierFlags = []) -> StatusItemPointerSample {
        StatusItemPointerSample(location: NSPoint(x: x, y: 10), isPressed: pressed, modifiers: modifiers)
    }

    private func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }
}

private final class GestureTestView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
