import AppKit
import Foundation

protocol StatusItemControllerDelegate: AnyObject {
    func statusItemToggleGallery(wasVisibleAtPress: Bool, statusButton: NSStatusBarButton?)
    func statusItemIsGalleryVisible() -> Bool
    func statusItemMenu() -> NSMenu
}

final class StatusItemController: NSObject {
    enum Metrics {
        static let dragThreshold: CGFloat = 4
        static let dragThumbnailPixel: Int = ThumbnailLoader.dragThumbnailPixel
        static let dragImageMaxSide: CGFloat = 96
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
    private var presentedMenu: NSMenu?
    private weak var previousMenuDelegate: NSMenuDelegate?

    init(store: ScreenshotStore, thumbnails: ThumbnailLoader) {
        self.store = store
        self.thumbnails = thumbnails
        super.init()
    }

    deinit {
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
        _ = button.sendAction(on: [.leftMouseDown, .rightMouseDown])

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

    @objc private func statusButtonAction(_ sender: Any?) {
        guard let button = statusItem?.button else {
            Log.statusItem.error("click ignored reason=no_button")
            return
        }
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let wantsMenu = event?.type == .rightMouseDown || flags.contains(.control)
        let typeName = StatusItemController.describe(event?.type)
        Log.statusItem.info("button action type=\(typeName, privacy: .public) wantsMenu=\(wantsMenu, privacy: .public)")

        if wantsMenu {
            presentMenu(from: button)
            return
        }
        guard let event, event.type == .leftMouseDown else {
            completeClick(wasVisibleAtPress: delegate?.statusItemIsGalleryVisible() ?? false, button: button)
            return
        }
        trackLeftMouse(from: event, button: button)
    }

    private func trackLeftMouse(from event: NSEvent, button: NSStatusBarButton) {
        let wasVisibleAtPress = delegate?.statusItemIsGalleryVisible() ?? false
        let payload = store.validatedLatest().map { prepareDragPayload(for: $0) }
        if payload == nil {
            Log.drag.info("drag payload unavailable reason=no_screenshot")
        }

        guard let window = button.window else {
            Log.statusItem.error("tracking aborted reason=no_window")
            completeClick(wasVisibleAtPress: wasVisibleAtPress, button: button)
            return
        }

        let origin = event.locationInWindow
        var travelled: CGFloat = 0
        var crossedThreshold = false
        var samples = 0
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                break
            }
            samples += 1
            let dx = next.locationInWindow.x - origin.x
            let dy = next.locationInWindow.y - origin.y
            travelled = (dx * dx + dy * dy).squareRoot()
            if travelled >= Metrics.dragThreshold {
                crossedThreshold = true
                break
            }
        }
        Log.statusItem.info("tracking finished drag=\(crossedThreshold, privacy: .public) travelled=\(Int(travelled), privacy: .public) samples=\(samples, privacy: .public)")

        guard crossedThreshold else {
            completeClick(wasVisibleAtPress: wasVisibleAtPress, button: button)
            return
        }
        guard let payload else {
            Log.drag.info("drag not started reason=no_screenshot")
            return
        }
        beginDrag(payload: payload, event: event, button: button)
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
        PNGExporter.shared.warm(latest.url)
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

    private func beginDrag(payload: DragPayload, event: NSEvent, button: NSStatusBarButton) {
        icon?.clear(reason: "dragged")
        let item = NSDraggingItem(pasteboardWriter: PNGExporter.shared.pasteboardWriter(for: payload.url))
        let frame = NSRect(
            x: button.bounds.midX - payload.size.width / 2,
            y: button.bounds.midY - payload.size.height / 2,
            width: payload.size.width,
            height: payload.size.height
        )
        item.setDraggingFrame(frame, contents: payload.image)

        let session = button.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        Log.drag.info("drag session started file=\(payload.name, privacy: .public) cached=\(payload.cached, privacy: .public)")
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

    private static func describe(_ type: NSEvent.EventType?) -> String {
        guard let type else { return "none" }
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        default: return "raw\(type.rawValue)"
        }
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
        Log.drag.info("drag will begin x=\(Int(screenPoint.x), privacy: .public) y=\(Int(screenPoint.y), privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store.setDragHold(false)
        Log.drag.info("drag ended operation=\(operation.rawValue, privacy: .public) copy=\(operation.contains(.copy), privacy: .public)")
        guard !operation.isEmpty else { return }
        Telemetry.log(.screenshotCopied, ["source": "menu_bar", "method": "drag"])
    }
}
