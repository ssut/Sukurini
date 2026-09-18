import AppKit
import XCTest
@testable import Sukurini

@MainActor
final class StatusItemGestureRoutingTests: XCTestCase {
    private final class RecordingDelegate: StatusItemControllerDelegate {
        var isGalleryVisible = false
        var toggles: [Bool] = []

        func statusItemToggleGallery(wasVisibleAtPress: Bool, statusButton: NSStatusBarButton?) {
            toggles.append(wasVisibleAtPress)
        }

        func statusItemIsGalleryVisible() -> Bool {
            isGalleryVisible
        }

        func statusItemMenu() -> NSMenu {
            NSMenu()
        }
    }

    func testWindowDeliveredClickTogglesExactlyOnce() throws {
        try withStatusItem { _, delegate, button in
            try send(.leftMouseDown, to: button)
            try send(.leftMouseUp, to: button)
            awaitToggle(delegate)
            XCTAssertEqual(delegate.toggles, [false])
        }
    }

    func testWindowDeliveredClickWithSmallReleaseOffsetTogglesExactlyOnce() throws {
        try withStatusItem { _, delegate, button in
            try send(.leftMouseDown, to: button)
            try send(.leftMouseUp, to: button, offset: NSPoint(x: 1, y: -1))
            awaitToggle(delegate)
            XCTAssertEqual(delegate.toggles, [false])
        }
    }

    func testWindowDeliveredDragWithEmptyStoreConsumesClickAndAllowsNextClick() throws {
        try withStatusItem { _, delegate, button in
            try send(.leftMouseDown, to: button)
            try send(.leftMouseDragged, to: button, offset: NSPoint(x: 0, y: -20))
            try send(.leftMouseDragged, to: button, offset: NSPoint(x: 0, y: -40))
            try send(.leftMouseUp, to: button, offset: NSPoint(x: 0, y: -40))
            XCTAssertTrue(delegate.toggles.isEmpty)
            try send(.leftMouseDown, to: button)
            try send(.leftMouseUp, to: button)
            awaitToggle(delegate)
            XCTAssertEqual(delegate.toggles, [false])
        }
    }

    func testWindowDeliveredClickPreservesGalleryVisibilityAtPress() throws {
        try withStatusItem { _, delegate, button in
            delegate.isGalleryVisible = true
            try send(.leftMouseDown, to: button)
            delegate.isGalleryVisible = false
            try send(.leftMouseUp, to: button)
            awaitToggle(delegate)
            XCTAssertEqual(delegate.toggles, [true])
        }
    }

    private func withStatusItem(_ body: (StatusItemController, RecordingDelegate, NSStatusBarButton) throws -> Void) throws {
        let application = NSApplication.shared
        if !application.isRunning {
            application.finishLaunching()
        }
        let controller = StatusItemController(store: ScreenshotStore(), thumbnails: ThumbnailLoader())
        let delegate = RecordingDelegate()
        controller.delegate = delegate
        controller.install()
        pumpRunLoop(duration: 0.2)
        let button = try XCTUnwrap(controller.statusButton)
        for case let gesture as StatusItemMouseGestureRecognizer in button.gestureRecognizers {
            gesture.pointerSample = {
                StatusItemPointerSample(location: .zero, isPressed: false, modifiers: [])
            }
        }
        XCTAssertNotNil(button.window)
        XCTAssertTrue(awaitHittable(button), "status item button never became hit-testable")
        try withExtendedLifetime(controller) {
            try body(controller, delegate, button)
        }
    }

    private func send(_ type: NSEvent.EventType, to button: NSStatusBarButton, offset: NSPoint = .zero) throws {
        let window = try XCTUnwrap(button.window)
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: center.x + offset.x, y: center.y + offset.y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        window.sendEvent(event)
        pumpRunLoop()
    }

    private func awaitHittable(_ button: NSStatusBarButton, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let window = button.window, let root = window.contentView?.superview ?? window.contentView {
                let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let target = root.hitTest(root.superview == nil ? center : root.convert(center, from: nil))
                if let target, target === button || target.isDescendant(of: button) { return true }
            }
            pumpRunLoop(duration: 0.02)
        }
        return false
    }

    private func awaitToggle(_ delegate: RecordingDelegate, timeout: TimeInterval = 2) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while delegate.toggles.isEmpty, Date() < deadline {
            pumpRunLoop(duration: 0.02)
        }
        pumpRunLoop(duration: 0.1)
    }

    private func pumpRunLoop(duration: TimeInterval = 0.05) {
        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }
}
