import AppKit
import XCTest
@testable import Sukurini

@MainActor
final class StatusItemDragEventPumpTests: XCTestCase {
    private final class RecordingSource: NSObject, NSDraggingSource {
        var moves: [NSPoint] = []
        var ended: NSPoint?

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            moves.append(screenPoint)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ended = screenPoint
        }
    }

    private var window: StatusItemDragWindow?
    private var posted: [NSEvent] = []
    private var pointer = StatusItemPointerSample(location: NSPoint(x: -664, y: 1097), isPressed: true, modifiers: [])
    private var escapePressed = false
    private var clock: TimeInterval = 100

    override func tearDown() {
        window?.close()
        window = nil
        posted = []
        super.tearDown()
    }

    func testMovementPostsDragEventsInSourceWindowCoordinates() throws {
        let pump = makePump()
        pointer = sample(x: -600, y: 900)
        pump.tick()
        let event = try XCTUnwrap(posted.last)
        let window = try XCTUnwrap(window)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertEqual(event.windowNumber, window.windowNumber)
        XCTAssertEqual(event.eventNumber, 77)
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        XCTAssertEqual(screenPoint.x, -600, accuracy: 0.01)
        XCTAssertEqual(screenPoint.y, 900, accuracy: 0.01)
        XCTAssertFalse(pump.isFinished)
    }

    func testStationaryPointerPostsNothing() {
        let pump = makePump()
        pump.tick()
        pump.tick()
        XCTAssertTrue(posted.isEmpty)
        XCTAssertEqual(pump.postedDragCount, 0)
    }

    func testReleaseAfterMovementPostsFinalDragThenMouseUpOnce() throws {
        let pump = makePump()
        pointer = sample(x: -640, y: 549, pressed: false)
        pump.tick()
        pump.tick()
        XCTAssertEqual(posted.map(\.type), [.leftMouseDragged, .leftMouseUp])
        let window = try XCTUnwrap(window)
        let release = window.convertPoint(toScreen: try XCTUnwrap(posted.last).locationInWindow)
        XCTAssertEqual(release.x, -640, accuracy: 0.01)
        XCTAssertEqual(release.y, 549, accuracy: 0.01)
        XCTAssertTrue(pump.isFinished)
    }

    func testReleaseWithoutMovementPostsOnlyMouseUp() {
        let pump = makePump()
        pointer = sample(x: -664, y: 1097, pressed: false)
        pump.tick()
        XCTAssertEqual(posted.map(\.type), [.leftMouseUp])
        XCTAssertTrue(pump.isFinished)
    }

    func testEscapePostsCancelKeyBeforeMouseUp() throws {
        let pump = makePump()
        escapePressed = true
        pump.tick()
        XCTAssertEqual(posted.map(\.type), [.keyDown, .leftMouseUp])
        XCTAssertEqual(try XCTUnwrap(posted.first).keyCode, StatusItemDragEventPump.Metrics.escapeKeyCode)
        XCTAssertTrue(pump.isFinished)
    }

    func testTimeoutCancelsSession() {
        let pump = makePump()
        clock += StatusItemDragEventPump.Metrics.timeout
        pump.tick()
        XCTAssertEqual(posted.map(\.type), [.keyDown, .leftMouseUp])
        XCTAssertTrue(pump.isFinished)
    }

    func testStopPreventsFurtherEvents() {
        let pump = makePump()
        pump.stop(reason: "test")
        pointer = sample(x: 0, y: 0, pressed: false)
        pump.tick()
        XCTAssertTrue(posted.isEmpty)
    }

    func testModifiersAreForwarded() throws {
        let pump = makePump()
        pointer = StatusItemPointerSample(location: NSPoint(x: 1, y: 2), isPressed: true, modifiers: [.option])
        pump.tick()
        XCTAssertTrue(try XCTUnwrap(posted.last).modifierFlags.contains(.option))
    }

    func testTimerDrivesLiveDragSessionWithoutSystemMouseEvents() throws {
        guard ProcessInfo.processInfo.environment["SUKURINI_INTERACTIVE_TESTS"] == "1" else {
            throw XCTSkip("set SUKURINI_INTERACTIVE_TESTS=1 to run against WindowServer")
        }
        let application = NSApplication.shared
        if !application.isRunning {
            application.finishLaunching()
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let start = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 12)
        let size = NSSize(width: 96, height: 64)
        let window = StatusItemDragWindow(pointer: start, previewSize: size)
        self.window = window
        window.orderFrontRegardless()
        let view = try XCTUnwrap(window.contentView)
        let source = RecordingSource()
        let item = NSDraggingItem(pasteboardWriter: "sukurini-pump-test" as NSString)
        item.setDraggingFrame(NSRect(origin: .zero, size: size), contents: NSImage(size: size))
        let first = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: window.convertPoint(fromScreen: start),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 77,
            clickCount: 1,
            pressure: 1
        ))
        let target = NSPoint(x: start.x + 120, y: start.y - 400)
        var step = 0
        let pump = StatusItemDragEventPump(window: window, eventNumber: 77, origin: start)
        pump.isEscapePressed = { false }
        pump.pointerSample = {
            step += 1
            let progress = min(1, CGFloat(step) / 60)
            return StatusItemPointerSample(
                location: NSPoint(x: start.x + 120 * progress, y: start.y - 400 * progress),
                isPressed: step < 70,
                modifiers: []
            )
        }
        _ = view.beginDraggingSession(with: [item], event: first, source: source)
        pump.start()
        let deadline = Date(timeIntervalSinceNow: 5)
        while source.ended == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        pump.stop(reason: "test_finished")
        let ended = try XCTUnwrap(source.ended)
        XCTAssertGreaterThan(source.moves.count, 30)
        XCTAssertEqual(ended.x, target.x, accuracy: 1)
        XCTAssertEqual(ended.y, target.y, accuracy: 1)
    }

    private func makePump() -> StatusItemDragEventPump {
        let window = StatusItemDragWindow(pointer: pointer.location, previewSize: NSSize(width: 96, height: 64))
        self.window = window
        let pump = StatusItemDragEventPump(window: window, eventNumber: 77, origin: pointer.location)
        pump.pointerSample = { [unowned self] in self.pointer }
        pump.isEscapePressed = { [unowned self] in self.escapePressed }
        pump.uptime = { [unowned self] in self.clock }
        pump.post = { [unowned self] in self.posted.append($0) }
        return pump
    }

    private func sample(x: CGFloat, y: CGFloat, pressed: Bool = true) -> StatusItemPointerSample {
        StatusItemPointerSample(location: NSPoint(x: x, y: y), isPressed: pressed, modifiers: [])
    }
}
