import AppKit
import XCTest
@testable import Sukurini

@MainActor
final class StatusItemGesturesTests: XCTestCase {
    func testClickKeepsVisibilityFromPressUntilReset() throws {
        var visible = true
        let gesture = StatusItemClickGestureRecognizer(target: nil, action: nil)
        gesture.galleryVisibility = { visible }
        gesture.mouseDown(with: try mouseEvent(.leftMouseDown, flags: [.control]))
        visible = false
        XCTAssertTrue(gesture.wasGalleryVisibleAtPress)
        XCTAssertTrue(gesture.pressModifierFlags.contains(.control))
        gesture.reset()
        XCTAssertFalse(gesture.wasGalleryVisibleAtPress)
        XCTAssertTrue(gesture.pressModifierFlags.isEmpty)
    }

    func testRightClickCapturesItsOwnModifiers() throws {
        let gesture = StatusItemClickGestureRecognizer(target: nil, action: nil)
        gesture.buttonMask = 0x2
        gesture.rightMouseDown(with: try mouseEvent(.rightMouseDown, flags: [.option]))
        XCTAssertEqual(gesture.pressModifierFlags, [.option])
    }

    func testPanKeepsPressedScreenshotWhenLatestChanges() throws {
        let original = screenshot("original.png")
        var latest: Screenshot? = original
        let gesture = StatusItemPanGestureRecognizer(target: nil, action: nil)
        gesture.screenshotAtPress = { latest }
        gesture.mouseDown(with: try mouseEvent(.leftMouseDown))
        latest = screenshot("new.png")
        gesture.mouseDragged(with: try mouseEvent(.leftMouseDragged, flags: [.option]))
        XCTAssertEqual(gesture.screenshot, original)
        XCTAssertEqual(gesture.mouseEvent?.type, .leftMouseDragged)
        XCTAssertTrue(gesture.mouseEvent?.modifierFlags.contains(.option) == true)
    }

    func testPanResetDoesNotReusePreviousScreenshotOrEvent() throws {
        var latest: Screenshot? = screenshot("original.png")
        let gesture = StatusItemPanGestureRecognizer(target: nil, action: nil)
        gesture.screenshotAtPress = { latest }
        gesture.mouseDown(with: try mouseEvent(.leftMouseDown, flags: [.option]))
        gesture.reset()
        XCTAssertNil(gesture.screenshot)
        XCTAssertNil(gesture.mouseEvent)
        latest = nil
        gesture.mouseDown(with: try mouseEvent(.leftMouseDown))
        XCTAssertNil(gesture.screenshot)
        XCTAssertFalse(gesture.mouseEvent?.modifierFlags.contains(.option) == true)
    }

    func testTouchPressKeepsInitialGalleryStateAcrossAdditionalTouches() {
        var visible = true
        let gesture = StatusItemClickGestureRecognizer(target: nil, action: nil)
        gesture.galleryVisibility = { visible }
        gesture.captureTouchPress()
        visible = false
        gesture.captureTouchPress()
        XCTAssertTrue(gesture.wasGalleryVisibleAtPress)
        gesture.reset()
        gesture.captureTouchPress()
        XCTAssertFalse(gesture.wasGalleryVisibleAtPress)
    }

    func testTouchPanDoesNotPickAnImageArrivingAfterEmptyPress() {
        var latest: Screenshot?
        let gesture = StatusItemPanGestureRecognizer(target: nil, action: nil)
        gesture.screenshotAtPress = { latest }
        gesture.captureTouchPress()
        latest = screenshot("new.png")
        gesture.captureTouchPress()
        XCTAssertNil(gesture.screenshot)
        XCTAssertNil(gesture.mouseEvent)
        gesture.reset()
        gesture.captureTouchPress()
        XCTAssertEqual(gesture.screenshot, latest)
    }

    private func mouseEvent(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func screenshot(_ name: String) -> Screenshot {
        Screenshot(url: URL(fileURLWithPath: "/tmp/\(name)"), created: Date(timeIntervalSince1970: 0), size: 1)
    }
}
