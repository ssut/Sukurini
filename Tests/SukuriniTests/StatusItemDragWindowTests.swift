import AppKit
import CoreGraphics
import XCTest
@testable import Sukurini

@MainActor
final class StatusItemDragWindowTests: XCTestCase {
    func testPanelProvidesRealWindowServerSourceAndCleansUp() throws {
        let application = NSApplication.shared
        if !application.isRunning {
            application.finishLaunching()
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let pointer = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let window = StatusItemDragWindow(pointer: pointer, previewSize: NSSize(width: 96, height: 64))
        defer { window.close() }
        window.orderFrontRegardless()
        pumpRunLoop()

        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(window.windowNumber, 0)
        let windowID = try XCTUnwrap(UInt32(exactly: window.windowNumber))
        XCTAssertTrue(try onScreenWindowIDs().contains(windowID))
        XCTAssertEqual(window.frame.midX, pointer.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.midY, pointer.y, accuracy: 0.5)
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 96, height: 64))
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isMainWindow)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.isReleasedWhenClosed)

        window.orderOut(nil)
        pumpRunLoop()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(try onScreenWindowIDs().contains(windowID))
        window.close()
        pumpRunLoop()
        XCTAssertFalse(try onScreenWindowIDs().contains(windowID))
    }

    func testPanelPreservesNegativeScreenCoordinatesAndMinimumSize() {
        let pointer = NSPoint(x: -664, y: 1097)
        let window = StatusItemDragWindow(pointer: pointer, previewSize: .zero)
        defer { window.close() }
        XCTAssertEqual(window.frame.midX, pointer.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.midY, pointer.y, accuracy: 0.5)
        XCTAssertEqual(window.frame.size, NSSize(width: 1, height: 1))
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.width ?? 0, 1)
        XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, 1)
    }

    func testPanelKeepsPreviewSizeWhenPointerIsBetweenPoints() {
        let window = StatusItemDragWindow(pointer: NSPoint(x: 700.5, y: 558.5), previewSize: NSSize(width: 96, height: 64))
        defer { window.close() }
        XCTAssertEqual(window.frame.size, NSSize(width: 96, height: 64))
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 96, height: 64))
        XCTAssertEqual(window.frame.midX, 700.5, accuracy: 0.5)
        XCTAssertEqual(window.frame.midY, 558.5, accuracy: 0.5)
    }

    private func onScreenWindowIDs() throws -> Set<UInt32> {
        let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        return Set(windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    private func pumpRunLoop() {
        let deadline = Date(timeIntervalSinceNow: 0.15)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}
