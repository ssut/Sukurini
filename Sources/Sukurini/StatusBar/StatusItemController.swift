import AppKit
import Foundation
import StatusItemDragSupport

protocol StatusItemControllerDelegate: AnyObject {
    func statusItemToggleGallery(wasVisibleAtPress: Bool, statusButton: NSStatusBarButton?)
    func statusItemIsGalleryVisible() -> Bool
    func statusItemMenu() -> NSMenu
}

final class StatusItemController: NSObject {
    enum Metrics {
        static let dragThumbnailPixel: Int = ThumbnailLoader.dragThumbnailPixel
        static let dragImageMaxSide: CGFloat = 96
        static let postDragClickSuppression: TimeInterval = 0.4
    }

    private struct DragPayload {
        let url: URL
        let name: String
        let image: NSImage
        let size: NSSize
        let cached: Bool
    }

    weak var delegate: StatusItemControllerDelegate?

    var statusButton: NSStatusBarButton? {
        statusItem?.button
    }

    private let store: ScreenshotStore
    private let thumbnails: ThumbnailLoader
    private var statusItem: NSStatusItem?
    private var icon: StatusIconAnimator?
    private var clickGesture: StatusItemClickGestureRecognizer?
    private var menuGesture: StatusItemClickGestureRecognizer?
    private var dragGesture: StatusItemPanGestureRecognizer?
    private var mouseGesture: StatusItemMouseGestureRecognizer?
    private var mouseDragWindow: StatusItemDragWindow?
    private var mouseDragSession: NSDraggingSession?
    private var mouseDragPump: StatusItemDragEventPump?
    private var lastDragEndedAt: TimeInterval?
    private var dragMovementLogged = false
    private var dragStartPoint = NSPoint.zero
    private var presentedMenu: NSMenu?
    private weak var previousMenuDelegate: NSMenuDelegate?

    init(store: ScreenshotStore, thumbnails: ThumbnailLoader) {
        self.store = store
        self.thumbnails = thumbnails
        super.init()
    }

    deinit {
        mouseDragPump?.stop(reason: "controller_deinit")
        mouseDragWindow?.close()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    func install() {
        guard statusItem == nil else {
            Log.statusItem.info("install skipped reason=already_installed")
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = nil
        item.isVisible = true
        statusItem = item

        guard let button = item.button else {
            Log.statusItem.error("install failed reason=no_button")
            return
        }
        let animator = StatusIconAnimator { [weak button] image in
            button?.image = image
        }
        icon = animator
        animator.renderIdle()
        button.imagePosition = .imageOnly
        button.toolTip = "Sukurini"
        button.target = self
        button.action = #selector(statusButtonAction(_:))
        _ = button.sendAction(on: [.leftMouseUp])
        installGestures(on: button)

        store.addObserver { [weak self] _ in self?.warmDragAssets() }
        warmDragAssets()

        Log.statusItem.info("status item installed w=\(Int(button.bounds.width), privacy: .public) h=\(Int(button.bounds.height), privacy: .public)")
    }

    func playRipple() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.playRipple()
            }
            return
        }
        guard let icon else {
            Log.statusItem.error("ripple skipped reason=not_installed")
            return
        }
        Log.statusItem.info("new screenshot indicator requested")
        icon.activate()
    }

    private func installGestures(on button: NSStatusBarButton) {
        if #available(macOS 27.0, *) {
            let mouse = StatusItemMouseGestureRecognizer(target: self, action: #selector(statusItemMouseChanged(_:)))
            mouse.allowedTouchTypes = []
            mouse.delaysPrimaryMouseButtonEvents = true
            mouse.delegate = self
            mouse.screenshotAtPress = { [weak self] in self?.store.validatedLatest() }
            mouse.galleryVisibility = { [weak self] in self?.delegate?.statusItemIsGalleryVisible() ?? false }
            mouseGesture = mouse
            button.addGestureRecognizer(mouse)
        }

        let drag = StatusItemPanGestureRecognizer(target: self, action: #selector(statusItemDragged(_:)))
        drag.buttonMask = 0x1
        drag.delaysPrimaryMouseButtonEvents = true
        drag.delegate = self
        drag.screenshotAtPress = { [weak self] in self?.store.validatedLatest() }
        dragGesture = drag
        button.addGestureRecognizer(drag)

        let click = StatusItemClickGestureRecognizer(target: self, action: #selector(statusItemClicked(_:)))
        click.buttonMask = 0x1
        click.delaysPrimaryMouseButtonEvents = true
        click.delegate = self
        click.galleryVisibility = { [weak self] in self?.delegate?.statusItemIsGalleryVisible() ?? false }
        clickGesture = click
        button.addGestureRecognizer(click)

        let menu = StatusItemClickGestureRecognizer(target: self, action: #selector(statusItemMenuClicked(_:)))
        menu.buttonMask = 0x2
        menu.allowedTouchTypes = []
        menu.delaysSecondaryMouseButtonEvents = true
        menu.delegate = self
        menuGesture = menu
        button.addGestureRecognizer(menu)
        Log.statusItem.info("input installed mode=gestures physicalMouseTracking=\(self.mouseGesture != nil, privacy: .public)")
    }

    @objc private func statusButtonAction(_ sender: Any?) {
        guard presentedMenu == nil, mouseDragWindow == nil, let button = statusItem?.button else { return }
        guard !isSuppressingPostDragClick else {
            Log.statusItem.info("button activation ignored reason=post_drag_click")
            return
        }
        if let mouseGesture, mouseGesture.state == .began || mouseGesture.state == .changed {
            Log.statusItem.info("button activation ignored reason=physical_press_active")
            return
        }
        Log.statusItem.info("button activation source=native")
        completeClick(wasVisibleAtPress: delegate?.statusItemIsGalleryVisible() ?? false, button: button)
    }

    @objc private func statusItemClicked(_ gesture: StatusItemClickGestureRecognizer) {
        guard gesture.state == .ended, let button = statusItem?.button else { return }
        let flags: NSEvent.ModifierFlags
        if #available(macOS 26.0, *) {
            flags = gesture.modifierFlags
        } else {
            flags = gesture.pressModifierFlags
        }
        if flags.union(gesture.pressModifierFlags).contains(.control) {
            presentMenu(from: button)
        } else {
            completeClick(wasVisibleAtPress: gesture.wasGalleryVisibleAtPress, button: button)
        }
    }

    @objc private func statusItemMenuClicked(_ gesture: StatusItemClickGestureRecognizer) {
        guard gesture.state == .ended, let button = statusItem?.button else { return }
        presentMenu(from: button)
    }

    @objc private func statusItemDragged(_ gesture: StatusItemPanGestureRecognizer) {
        Log.statusItem.debug("pan action state=\(gesture.state.rawValue, privacy: .public)")
        guard gesture.state == .began, let button = statusItem?.button else { return }
        guard let screenshot = gesture.screenshot else {
            Log.drag.info("drag not started reason=no_screenshot")
            return
        }
        guard FileManager.default.fileExists(atPath: screenshot.path) else {
            Log.drag.info("drag not started reason=screenshot_removed")
            return
        }
        let flags: NSEvent.ModifierFlags
        if #available(macOS 26.0, *) {
            flags = gesture.modifierFlags
        } else {
            flags = gesture.mouseEvent?.modifierFlags ?? []
        }
        let payload = prepareDragPayload(for: screenshot)
        beginDrag(payload: payload, gesture: gesture, button: button, forcesPNG: flags.contains(.option))
    }

    @objc private func statusItemMouseChanged(_ gesture: StatusItemMouseGestureRecognizer) {
        guard let button = statusItem?.button else { return }
        if gesture.state == .ended, !gesture.didCrossDragThreshold {
            if gesture.currentModifiers.contains(.control) {
                presentMenu(from: button)
            } else {
                completeClick(wasVisibleAtPress: gesture.wasGalleryVisibleAtPress, button: button)
            }
            return
        }
        guard gesture.takeDragRequest() else { return }
        var sessionStarted = false
        defer { if !sessionStarted { gesture.finishDragAttempt() } }
        guard let screenshot = gesture.screenshot else {
            Log.drag.info("drag not started reason=no_screenshot source=physical_press")
            return
        }
        guard FileManager.default.fileExists(atPath: screenshot.path) else {
            Log.drag.info("drag not started reason=screenshot_removed source=physical_press")
            return
        }
        let forcesPNG = gesture.currentModifiers.contains(.option)
        let payload = prepareDragPayload(for: screenshot)
        sessionStarted = beginDrag(payload: payload, gesture: gesture, button: button, forcesPNG: forcesPNG)
    }

    private func completeClick(wasVisibleAtPress: Bool, button: NSStatusBarButton) {
        if !wasVisibleAtPress {
            icon?.clear(reason: "gallery_opened")
        }
        Log.statusItem.info("gallery toggle requested wasVisibleAtPress=\(wasVisibleAtPress, privacy: .public)")
        delegate?.statusItemToggleGallery(wasVisibleAtPress: wasVisibleAtPress, statusButton: button)
    }

    private func warmDragAssets() {
        guard let latest = store.latest else { return }
        PNGExporter.shared.warm(latest.url, forcingPNG: true)
        guard thumbnails.cachedThumbnail(for: latest.url, maxPixel: Metrics.dragThumbnailPixel) == nil else { return }
        thumbnails.thumbnail(for: latest.url, maxPixel: Metrics.dragThumbnailPixel, lowPriority: true) { url, image in
            Log.drag.debug("drag thumbnail warmed file=\(url.lastPathComponent, privacy: .public) ok=\(image != nil, privacy: .public)")
        }
    }

    private func prepareDragPayload(for screenshot: Screenshot) -> DragPayload {
        let cached = thumbnails.cachedThumbnail(for: screenshot.url, maxPixel: Metrics.dragThumbnailPixel)
            ?? thumbnails.loadSync(for: screenshot.url, maxPixel: Metrics.dragThumbnailPixel)
        let image = cached ?? NSWorkspace.shared.icon(forFile: screenshot.path)
        let payload = DragPayload(
            url: screenshot.url,
            name: screenshot.name,
            image: image,
            size: StatusItemController.fittedSize(for: image),
            cached: cached != nil
        )
        Log.drag.debug("drag payload ready file=\(payload.name, privacy: .public) cached=\(payload.cached, privacy: .public) w=\(Int(payload.size.width), privacy: .public) h=\(Int(payload.size.height), privacy: .public)")
        return payload
    }

    @discardableResult
    private func beginDrag(payload: DragPayload, gesture: NSGestureRecognizer, button: NSStatusBarButton, forcesPNG: Bool) -> Bool {
        if let mouse = gesture as? StatusItemMouseGestureRecognizer {
            return beginPhysicalMouseDrag(payload: payload, gesture: mouse, forcesPNG: forcesPNG)
        }
        let writer = PNGExporter.shared.pasteboardWriter(for: payload.url, forcingPNG: forcesPNG)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let frame = NSRect(
            x: button.bounds.midX - payload.size.width / 2,
            y: button.bounds.midY - payload.size.height / 2,
            width: payload.size.width,
            height: payload.size.height
        )
        item.setDraggingFrame(frame, contents: payload.image)

        let session: NSDraggingSession
        if #available(macOS 27.0, *) {
            guard let started = SukuriniBeginGestureDraggingSession(button, [item], gesture, self) else {
                Log.drag.error("drag not started reason=gesture_session_rejected")
                return false
            }
            session = started
        } else {
            guard let event = (gesture as? StatusItemPanGestureRecognizer)?.mouseEvent else {
                Log.drag.error("drag not started reason=no_mouse_event")
                return false
            }
            session = button.beginDraggingSession(with: [item], event: event, source: self)
        }
        icon?.clear(reason: "dragged")
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        Log.drag.info("drag session started file=\(payload.name, privacy: .public) cached=\(payload.cached, privacy: .public) forcesPNG=\(forcesPNG, privacy: .public) png=\(writer is NSPasteboardItem, privacy: .public)")
        return true
    }

    private func beginPhysicalMouseDrag(payload: DragPayload, gesture: StatusItemMouseGestureRecognizer, forcesPNG: Bool) -> Bool {
        guard mouseDragWindow == nil else {
            Log.drag.info("drag not started reason=session_active")
            return false
        }
        let pointer = gesture.pointerSample()
        guard pointer.isPressed else { return false }
        let window = StatusItemDragWindow(pointer: pointer.location, previewSize: payload.size)
        window.orderFrontRegardless()
        guard let view = window.contentView, let event = gesture.dragEvent(in: window) else {
            window.close()
            Log.drag.info("drag not started reason=physical_press_ended_or_missing_event")
            return false
        }
        let writer = PNGExporter.shared.pasteboardWriter(for: payload.url, forcingPNG: forcesPNG)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(NSRect(origin: .zero, size: payload.size), contents: payload.image)
        mouseDragWindow = window
        gesture.finishDragAttempt()
        DispatchQueue.main.async { [weak self, window, view] in
            guard let self, self.mouseDragWindow === window else { return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else {
                self.closeMouseDragWindow()
                Log.drag.info("drag not started reason=released_before_native_handoff")
                return
            }
            Log.drag.info("drag session requested api=mouse_event source=native_window event=\(event.eventNumber, privacy: .public) window=\(window.windowNumber, privacy: .public)")
            let session = view.beginDraggingSession(with: [item], event: event, source: self)
            if self.mouseDragWindow === window { self.mouseDragSession = session }
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
            let pump = StatusItemDragEventPump(
                window: window,
                eventNumber: event.eventNumber,
                origin: window.convertPoint(toScreen: event.locationInWindow)
            )
            self.mouseDragPump = pump
            pump.start()
            self.icon?.clear(reason: "dragged")
            Log.drag.info("drag session started file=\(payload.name, privacy: .public) cached=\(payload.cached, privacy: .public) forcesPNG=\(forcesPNG, privacy: .public) source=native_window")
        }
        return true
    }

    private var isSuppressingPostDragClick: Bool {
        guard let lastDragEndedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - lastDragEndedAt < Metrics.postDragClickSuppression
    }

    private func closeMouseDragWindow() {
        mouseDragPump?.stop(reason: "session_closed")
        mouseDragPump = nil
        mouseDragWindow?.close()
        mouseDragWindow = nil
        mouseDragSession = nil
    }

    private func presentMenu(from button: NSStatusBarButton) {
        guard let item = statusItem else {
            Log.statusItem.error("menu skipped reason=no_status_item")
            return
        }
        guard presentedMenu == nil else {
            Log.statusItem.error("menu skipped reason=already_presenting")
            return
        }
        guard let menu = delegate?.statusItemMenu() else {
            Log.statusItem.error("menu skipped reason=no_delegate")
            return
        }
        let existingDelegate = menu.delegate
        previousMenuDelegate = existingDelegate === self ? nil : existingDelegate
        menu.delegate = self
        presentedMenu = menu
        item.menu = menu
        Log.statusItem.info("menu attached items=\(menu.numberOfItems, privacy: .public)")

        button.performClick(nil)

        restoreMenuOwnership()
        Log.statusItem.info("menu dismissed detached=\(item.menu == nil, privacy: .public)")
    }

    private func restoreMenuOwnership() {
        statusItem?.menu = nil
        if let menu = presentedMenu, menu.delegate === self {
            menu.delegate = previousMenuDelegate
        }
        presentedMenu = nil
        previousMenuDelegate = nil
    }

    private static func fittedSize(for image: NSImage) -> NSSize {
        let source = image.size
        guard source.width > 1, source.height > 1 else {
            return NSSize(width: Metrics.dragImageMaxSide, height: Metrics.dragImageMaxSide)
        }
        let ratio = Metrics.dragImageMaxSide / max(source.width, source.height)
        return NSSize(
            width: max(1, (source.width * ratio).rounded()),
            height: max(1, (source.height * ratio).rounded())
        )
    }
}

extension StatusItemController: NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard gestureRecognizer === dragGesture else { return true }
        if #available(macOS 26.0, *) {
            return gestureRecognizer.modifierFlags.intersection([.command, .control]).isEmpty
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        guard presentedMenu == nil, mouseDragWindow == nil else { return false }
        (gestureRecognizer as? StatusItemClickGestureRecognizer)?.captureTouchPress()
        (gestureRecognizer as? StatusItemPanGestureRecognizer)?.captureTouchPress()
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        Log.statusItem.debug("gesture admission kind=\(String(describing: type(of: gestureRecognizer)), privacy: .public) type=\(event.type.rawValue, privacy: .public) flags=\(event.modifierFlags.rawValue, privacy: .public)")
        guard presentedMenu == nil, mouseDragWindow == nil else { return false }
        guard !isSuppressingPostDragClick else {
            Log.statusItem.info("gesture admission rejected reason=post_drag_click")
            return false
        }
        if event.modifierFlags.contains(.command) { return false }
        if let mouseGesture {
            let tracksPhysicalPress = mouseGesture.canTrack(event)
            if gestureRecognizer === mouseGesture { return tracksPhysicalPress }
            if tracksPhysicalPress { return false }
        }
        if gestureRecognizer === dragGesture {
            return !event.modifierFlags.contains(.control)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer === clickGesture && otherGestureRecognizer === dragGesture
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        guard otherGestureRecognizer !== clickGesture,
              otherGestureRecognizer !== menuGesture,
              otherGestureRecognizer !== dragGesture,
              otherGestureRecognizer !== mouseGesture else { return false }
        return otherGestureRecognizer.view === statusItem?.button
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        previousMenuDelegate?.menuWillOpen?(menu)
        Log.statusItem.info("menu opened items=\(menu.numberOfItems, privacy: .public)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        previousMenuDelegate?.menuNeedsUpdate?(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        previousMenuDelegate?.menuDidClose?(menu)
        restoreMenuOwnership()
        Log.statusItem.info("menu closed detached=\(self.statusItem?.menu == nil, privacy: .public)")
    }
}

extension StatusItemController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return .copy
        case .withinApplication:
            return []
        @unknown default:
            return []
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        store.setDragHold(true)
        dragMovementLogged = false
        dragStartPoint = screenPoint
        Log.drag.info("drag will begin x=\(Int(screenPoint.x), privacy: .public) y=\(Int(screenPoint.y), privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard !dragMovementLogged, screenPoint != dragStartPoint else { return }
        dragMovementLogged = true
        Log.drag.info("drag moved x=\(Int(screenPoint.x), privacy: .public) y=\(Int(screenPoint.y), privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.setDragHold(false)
        if mouseDragSession == nil || mouseDragSession === session {
            if mouseDragWindow != nil {
                lastDragEndedAt = ProcessInfo.processInfo.systemUptime
            }
            closeMouseDragWindow()
        }
        Log.drag.info("drag ended operation=\(operation.rawValue, privacy: .public) copy=\(operation.contains(.copy), privacy: .public)")
        guard !operation.isEmpty else { return }
        Telemetry.log(.screenshotCopied, ["source": "menu_bar", "method": "drag"])
    }
}
