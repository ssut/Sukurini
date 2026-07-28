import AppKit

protocol SearchProviding: AnyObject {
    var isReady: Bool { get }
    var usesSemanticSearch: Bool { get }
    func search(query: String, completion: @escaping (SearchOutcome) -> Void)
}

enum GalleryOpenSource: String {
    case statusItem = "status_item"
    case hotkey
    case launch
    case onboarding
    case dock
}

final class GalleryPanelController: NSObject {

    private enum Metrics {
        static let preferredSize = NSSize(width: 900, height: 600)
        static let minimumSize = NSSize(width: 520, height: 360)
        static let horizontalMargin: CGFloat = 120
        static let verticalMargin: CGFloat = 200
        static let topFraction: CGFloat = 0.18
        static let cornerRadius: CGFloat = 16
        static let headerHeight: CGFloat = 58
        static let headerPadding: CGFloat = 18
        static let gearSide: CGFloat = 26
        static let magnifierSide: CGFloat = 20
        static let searchDebounce: TimeInterval = 0.2
        static let autoHideGrace: TimeInterval = 0.6
        static let quickLookGrace: TimeInterval = 1.5
    }

    private struct SearchSession {
        var refinements = 0
        var length = 0
        var results = 0
        var mode = "filename"
        var selections = 0
    }

    private let store: ScreenshotStore
    private let thumbnails: ThumbnailLoader
    private let grid: GalleryGridController

    private var panel: GalleryPanel?
    private let searchField = NSSearchField()
    private let sortControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let magnifierView = NSImageView()
    private let gearButton = NSButton()
    private var globalMonitor: Any?

    private var pendingSearch: DispatchWorkItem?
    private var latestOutcome: SearchOutcome?
    private var latestLocalMatches = Set<String>()
    private var currentQuery = ""
    private var searchSession: SearchSession?
    private var haystacks: [String: String] = [:]
    private var isDragging = false
    private var autoHideSuppressedUntil = Date.distantPast
    private var preferencesObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var appToRestore: NSRunningApplication?

    private let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private let humanDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    weak var searchProvider: SearchProviding?

    var menuProvider: (() -> NSMenu)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: ScreenshotStore, thumbnails: ThumbnailLoader) {
        self.store = store
        self.thumbnails = thumbnails
        self.grid = GalleryGridController(store: store, thumbnails: thumbnails)
        super.init()

        grid.onContextMenuStateChanged = { [weak self] active in
            guard let self else { return }
            self.autoHideSuppressedUntil = active ? .distantFuture : Date().addingTimeInterval(Metrics.autoHideGrace)
            Log.gallery.debug("gallery auto-hide suppression contextMenu=\(active, privacy: .public)")
        }

        grid.onQuickLookStateChanged = { [weak self] active in
            guard let self else { return }
            self.onMain { self.handleQuickLookStateChanged(active) }
        }

        grid.onDragStateChanged = { [weak self] active in
            guard let self else { return }
            self.isDragging = active
            self.store.setDragHold(active)
            if !active {
                self.autoHideSuppressedUntil = Date().addingTimeInterval(Metrics.autoHideGrace)
            }
            Log.gallery.info("drag guard updated active=\(active, privacy: .public)")
        }

        grid.onExternalDropCompleted = { [weak self] count in
            guard let self else { return }
            self.onMain { self.handleExternalDropCompleted(count: count) }
        }

        grid.onItemActivated = { [weak self] activation in
            guard let self else { return }
            self.onMain { self.handleItemActivated(activation) }
        }

        grid.onCopyCompleted = { [weak self] count, method in
            guard let self else { return }
            self.onMain { self.handleCopyCompleted(count: count, method: method) }
        }

        store.addObserver { [weak self] change in
            guard let self else { return }
            self.onMain { self.handleStoreChange(change) }
        }

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniPreferencesWillShow,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.onMain { self.handlePreferencesWillShow() }
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyLanguage()
        }
        Log.gallery.info("gallery observing preferences visibility")
    }

    deinit {
        removeGlobalMonitor()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    private func applyLanguage() {
        searchField.placeholderString = L10n.Gallery.searchPlaceholder
        gearButton.toolTip = L10n.Gallery.settingsTooltip
        rebuildSortMenu()
        grid.applyLanguage()
        Log.gallery.info("gallery relocalized language=\(LocalizationCenter.shared.language.rawValue, privacy: .public)")
    }

    func prewarm() {
        guard panel == nil else { return }
        let started = Date()
        buildPanel()
        grid.reloadAll(preserveScroll: false)
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let count = store.items.count
        Log.gallery.info("gallery prewarmed items=\(count, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
    }

    func show(relativeTo statusButton: NSStatusBarButton?, source: GalleryOpenSource) {
        prewarm()
        guard let panel else { return }
        let started = Date()

        position(panel: panel, statusButton: statusButton)
        grid.updateThumbnailPixel(scale: panel.backingScaleFactor)

        if !currentQuery.isEmpty || !searchField.stringValue.isEmpty {
            flushSearchSession(reason: "reopened")
            searchField.stringValue = ""
            currentQuery = ""
            pendingSearch?.cancel()
            grid.applyFilter(nil)
        }
        updateSortControlVisibility()

        grid.clearSelection()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        installGlobalMonitor()

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let count = store.items.count
        let key = panel.isKeyWindow
        Telemetry.log(.galleryOpened, ["source": source.rawValue, "library": Telemetry.bucket(count)])
        Log.gallery.info(
            "gallery shown source=\(source.rawValue, privacy: .public) items=\(count, privacy: .public) elapsedMs=\(elapsed, privacy: .public) key=\(key, privacy: .public)"
        )
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        removeGlobalMonitor()
        grid.closeQuickLook()
        panel.orderOut(nil)
        restoreAppFocus()
        flushSearchSession(reason: "hidden")
        Log.gallery.info("gallery hidden")
    }

    func toggle(wasVisibleAtPress: Bool, statusButton: NSStatusBarButton?, source: GalleryOpenSource) {
        Log.gallery.info("gallery toggle wasVisibleAtPress=\(wasVisibleAtPress, privacy: .public) source=\(source.rawValue, privacy: .public)")
        if wasVisibleAtPress {
            hide()
        } else {
            show(relativeTo: statusButton, source: source)
        }
    }

    private func buildPanel() {
        let panel = GalleryPanel(
            contentRect: NSRect(origin: .zero, size: Metrics.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.escapeHandler = { [weak self] in self?.handleEscape() }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Metrics.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.maskImage = Self.roundedCornerMask(radius: Metrics.cornerRadius)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        configureSearchField()
        configureMagnifier()
        configureGearButton()
        configureSortControl()

        header.addSubview(magnifierView)
        header.addSubview(searchField)
        header.addSubview(sortControl)
        header.addSubview(gearButton)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        let gridView = grid.containerView

        effect.addSubview(header)
        effect.addSubview(separator)
        effect.addSubview(gridView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            header.topAnchor.constraint(equalTo: effect.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            magnifierView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Metrics.headerPadding),
            magnifierView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            magnifierView.widthAnchor.constraint(equalToConstant: Metrics.magnifierSide),
            magnifierView.heightAnchor.constraint(equalToConstant: Metrics.magnifierSide),

            searchField.leadingAnchor.constraint(equalTo: magnifierView.trailingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: sortControl.leadingAnchor, constant: -8),

            sortControl.trailingAnchor.constraint(equalTo: gearButton.leadingAnchor, constant: -12),
            sortControl.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            gearButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Metrics.headerPadding),
            gearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: Metrics.gearSide),
            gearButton.heightAnchor.constraint(equalToConstant: Metrics.gearSide),

            separator.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            gridView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            gridView.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        panel.contentView = effect
        self.panel = panel
        Log.gallery.info("gallery panel constructed")
    }

    private static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }

    private func configureSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.Gallery.searchPlaceholder
        searchField.font = .systemFont(ofSize: 19, weight: .regular)
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell?.image = NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: L10n.Gallery.clear
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        }
    }

    private func configureMagnifier() {
        magnifierView.translatesAutoresizingMaskIntoConstraints = false
        magnifierView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.Gallery.search)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        magnifierView.contentTintColor = .secondaryLabelColor
        magnifierView.imageScaling = .scaleProportionallyDown
    }

    private func configureGearButton() {
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        gearButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.Gallery.settings)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        gearButton.isBordered = false
        gearButton.bezelStyle = .inline
        gearButton.imagePosition = .imageOnly
        gearButton.contentTintColor = .secondaryLabelColor
        gearButton.target = self
        gearButton.action = #selector(gearTapped(_:))
        gearButton.toolTip = L10n.Gallery.settingsTooltip
    }

    private func position(panel: GalleryPanel, statusButton: NSStatusBarButton?) {
        let screen = targetScreen(statusButton: statusButton)
        let visible = screen.visibleFrame
        let width = min(Metrics.preferredSize.width, max(Metrics.minimumSize.width, visible.width - Metrics.horizontalMargin))
        let height = min(Metrics.preferredSize.height, max(Metrics.minimumSize.height, visible.height - Metrics.verticalMargin))
        let x = visible.midX - width / 2
        let top = visible.maxY - visible.height * Metrics.topFraction
        let y = max(visible.minY + 24, top - height)
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
        panel.setFrame(frame, display: false)
        Log.gallery.info(
            "gallery positioned width=\(Int(frame.width), privacy: .public) height=\(Int(frame.height), privacy: .public) screen=\(Int(visible.width), privacy: .public)x\(Int(visible.height), privacy: .public)"
        )
    }

    private func targetScreen(statusButton: NSStatusBarButton?) -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return hit }
        if let buttonScreen = statusButton?.window?.screen { return buttonScreen }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    @objc private func gearTapped(_ sender: NSButton) {
        guard let menu = menuProvider?() else {
            Log.gallery.error("gear tapped without menu provider")
            return
        }
        autoHideSuppressedUntil = .distantFuture
        Log.gallery.info("gear menu opening items=\(menu.numberOfItems, privacy: .public)")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
        autoHideSuppressedUntil = Date().addingTimeInterval(Metrics.autoHideGrace)
        Log.gallery.info("gear menu closed")
    }

    private func handleEscape() {
        if !searchField.stringValue.isEmpty {
            Log.gallery.info("escape cleared query")
            searchField.stringValue = ""
            pendingSearch?.cancel()
            runSearch("")
            panel?.makeFirstResponder(searchField)
            return
        }
        Log.gallery.info("escape closed gallery")
        hide()
    }

    private func scheduleSearch(for text: String) {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch(text) }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.searchDebounce, execute: work)
    }

    private func runSearch(_ query: String) {
        currentQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSortControlVisibility()
        guard !trimmed.isEmpty else {
            flushSearchSession(reason: "cleared")
            grid.applyFilter(nil)
            Log.search.info("gallery filter cleared")
            return
        }

        noteSearch(length: trimmed.count)

        guard let provider = searchProvider, provider.isReady else {
            let offline = localMatches(for: trimmed)
            grid.applyFilter(offline)
            noteResults(count: offline.count, mode: "filename")
            return
        }

        let local = localMatches(for: trimmed)
        if !provider.usesSemanticSearch {
            grid.applyFilter(local)
        }

        provider.search(query: query) { [weak self] outcome in
            guard let self else { return }
            self.onMain {
                guard outcome.query == self.currentQuery else {
                    Log.search.info("gallery discarded stale search response")
                    return
                }
                self.present(outcome, local: local)
            }
        }
    }

    private func present(_ outcome: SearchOutcome, local: Set<String>) {
        latestOutcome = outcome
        latestLocalMatches = local
        let mode = (searchProvider?.usesSemanticSearch ?? false) ? "semantic" : "ocr"

        guard outcome.isRanked else {
            let merged = local.union(outcome.paths)
            grid.applyFilter(merged, resetScroll: false)
            noteResults(count: merged.count, mode: mode)
            Log.search.info("gallery filter indexed=\(outcome.paths.count, privacy: .public) merged=\(merged.count, privacy: .public)")
            return
        }

        noteResults(count: outcome.paths.count, mode: mode)

        switch AppSettings.shared.gallerySortOrder {
        case .relevance:
            grid.applyRanking(outcome.paths)
            Log.search.info("gallery ranked results=\(outcome.paths.count, privacy: .public)")
        case .date:
            grid.applyFilter(Set(outcome.paths))
            Log.search.info("gallery date-sorted results=\(outcome.paths.count, privacy: .public)")
        }
    }

    private func noteSearch(length: Int) {
        if searchSession == nil {
            searchSession = SearchSession()
            Log.search.debug("search session started")
        }
        searchSession?.refinements += 1
        searchSession?.length = length
    }

    private func noteResults(count: Int, mode: String) {
        guard searchSession != nil else { return }
        searchSession?.results = count
        searchSession?.mode = mode
    }

    private func flushSearchSession(reason: String) {
        guard let session = searchSession else { return }
        searchSession = nil
        Telemetry.log(.gallerySearched, [
            "mode": session.mode,
            "results": Telemetry.bucket(session.results),
            "length": Telemetry.bucket(session.length),
            "refinements": Telemetry.bucket(session.refinements),
            "selected": Telemetry.flag(session.selections > 0)
        ])
        Log.search.info(
            "search session flushed reason=\(reason, privacy: .public) mode=\(session.mode, privacy: .public) results=\(session.results, privacy: .public) refinements=\(session.refinements, privacy: .public) selections=\(session.selections, privacy: .public)"
        )
    }

    private func handleItemActivated(_ activation: GalleryActivation) {
        guard searchSession != nil else { return }
        searchSession?.selections += 1
        Telemetry.log(.gallerySearchSelected, [
            "action": activation.action,
            "rank": Telemetry.bucket(activation.rank),
            "count": Telemetry.bucket(activation.count)
        ])
        Log.search.info(
            "search result activated action=\(activation.action, privacy: .public) rank=\(activation.rank, privacy: .public) count=\(activation.count, privacy: .public)"
        )
    }

    private func handleCopyCompleted(count: Int, method: GalleryCopyMethod) {
        Telemetry.log(.galleryCopied, [
            "count": Telemetry.bucket(count),
            "method": method.rawValue,
            "in_search": Telemetry.flag(searchSession != nil)
        ])
        Log.gallery.info(
            "gallery copy recorded count=\(count, privacy: .public) method=\(method.rawValue, privacy: .public)"
        )
    }

    private func configureSortControl() {
        sortControl.translatesAutoresizingMaskIntoConstraints = false
        sortControl.bezelStyle = .inline
        sortControl.controlSize = .small
        sortControl.font = .systemFont(ofSize: 11, weight: .medium)
        sortControl.target = self
        sortControl.action = #selector(sortChanged(_:))
        sortControl.isHidden = true
        sortControl.menu?.autoenablesItems = false
        sortControl.setContentHuggingPriority(.required, for: .horizontal)
        sortControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        rebuildSortMenu()
    }

    private func rebuildSortMenu() {
        sortControl.removeAllItems()
        for order in GallerySortOrder.allCases {
            let item = NSMenuItem()
            item.title = order.title
            item.toolTip = order.summary
            item.representedObject = order.rawValue
            item.isEnabled = true
            sortControl.menu?.addItem(item)
        }
        let active = AppSettings.shared.gallerySortOrder
        sortControl.selectItem(at: GallerySortOrder.allCases.firstIndex(of: active) ?? 0)
        sortControl.toolTip = active.summary
    }

    private func updateSortControlVisibility() {
        let typing = !currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rankable = searchProvider?.usesSemanticSearch ?? false
        let shouldShow = typing && rankable
        guard sortControl.isHidden == shouldShow else { return }
        sortControl.isHidden = !shouldShow
        if shouldShow { rebuildSortMenu() }
        Log.gallery.debug("sort control visible=\(shouldShow, privacy: .public)")
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let order = GallerySortOrder(rawValue: raw) else { return }
        AppSettings.shared.gallerySortOrder = order
        sortControl.toolTip = order.summary
        Log.gallery.info("sort order changed value=\(order.rawValue, privacy: .public)")
        guard let outcome = latestOutcome, outcome.query == currentQuery else {
            pendingSearch?.cancel()
            runSearch(currentQuery)
            return
        }
        present(outcome, local: latestLocalMatches)
    }

    private func localMatches(for needle: String) -> Set<String> {
        let key = needle.precomposedStringWithCanonicalMapping.lowercased()
        var matches = Set<String>()
        for item in store.items where haystack(for: item).contains(key) {
            matches.insert(item.path)
        }
        return matches
    }

    private func haystack(for item: Screenshot) -> String {
        if let cached = haystacks[item.path] { return cached }
        let composed = "\(item.name) \(fileDateFormatter.string(from: item.created)) \(humanDateFormatter.string(from: item.created))"
        let normalized = composed.precomposedStringWithCanonicalMapping.lowercased()
        haystacks[item.path] = normalized
        return normalized
    }

    private func handleStoreChange(_ change: StoreChange) {
        if change.isFullReload {
            haystacks.removeAll(keepingCapacity: true)
        } else {
            for url in change.removedURLs { haystacks.removeValue(forKey: url.path) }
        }

        guard !currentQuery.isEmpty else {
            grid.apply(change: change)
            return
        }
        let trimmed = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            grid.apply(change: change)
            return
        }
        grid.applyFilter(localMatches(for: trimmed), resetScroll: false)
        Log.gallery.info("store change re-applied under active query")
    }

    private func handleExternalDropCompleted(count: Int) {
        guard isVisible else {
            Log.gallery.info("external drop completed while hidden count=\(count, privacy: .public)")
            return
        }
        isDragging = false
        autoHideSuppressedUntil = .distantPast
        Log.gallery.info("external drop completed count=\(count, privacy: .public) closing gallery")
        hide()
    }

    private func handlePreferencesWillShow() {
        guard isVisible else {
            Log.gallery.debug("preferences opening while gallery already hidden")
            return
        }
        isDragging = false
        autoHideSuppressedUntil = .distantPast
        Log.gallery.info("preferences opening, closing gallery")
        hide()
    }

    private func handleQuickLookStateChanged(_ active: Bool) {
        if active { captureAppFocus() }
        autoHideSuppressedUntil = Date().addingTimeInterval(
            active ? Metrics.quickLookGrace : Metrics.autoHideGrace
        )

        guard let panel else { return }
        panel.level = active ? .normal : .floating
        Log.gallery.info(
            "gallery quick look state active=\(active, privacy: .public) level=\(panel.level.rawValue, privacy: .public)"
        )

        guard !active, panel.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(self.grid.keyView)
            Log.gallery.info("gallery reclaimed key after quick look key=\(panel.isKeyWindow, privacy: .public)")
        }
    }

    private func captureAppFocus() {
        guard appToRestore == nil else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        guard front != NSRunningApplication.current else { return }
        appToRestore = front
        Log.gallery.info("captured frontmost app bundle=\(front.bundleIdentifier ?? "unknown", privacy: .public)")
    }

    private func restoreAppFocus() {
        guard let target = appToRestore else { return }
        appToRestore = nil
        guard NSApp.isActive else {
            Log.gallery.info("app focus restore skipped reason=not_active")
            return
        }
        guard !target.isTerminated else {
            Log.gallery.info("app focus restore skipped reason=terminated")
            return
        }
        let restored = target.activate()
        Log.gallery.info(
            "app focus restored bundle=\(target.bundleIdentifier ?? "unknown", privacy: .public) ok=\(restored, privacy: .public)"
        )
    }

    private var shouldSuppressAutoHide: Bool {
        isDragging || grid.isQuickLookOpen || Date() < autoHideSuppressedUntil
    }

    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if self.grid.isQuickLookOpen {
                Log.gallery.info("outside click while quick look open, closing both")
                self.hide()
                return
            }
            if self.shouldSuppressAutoHide {
                Log.gallery.debug("outside click ignored while auto hide suppressed")
                return
            }
            if let frame = self.panel?.frame, frame.contains(NSEvent.mouseLocation) { return }
            Log.gallery.info("outside click detected")
            self.hide()
        }
        Log.gallery.debug("global mouse monitor installed")
    }

    private func removeGlobalMonitor() {
        guard let globalMonitor else { return }
        NSEvent.removeMonitor(globalMonitor)
        self.globalMonitor = nil
        Log.gallery.debug("global mouse monitor removed")
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

extension GalleryPanelController: NSWindowDelegate {

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        if shouldSuppressAutoHide {
            Log.gallery.info("resign key ignored while auto hide suppressed")
            return
        }
        Log.gallery.info("panel resigned key")
        hide()
    }
}

extension GalleryPanelController: NSSearchFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch(for: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            grid.openSelectionOrFirst()
            return true
        case #selector(NSResponder.moveDown(_:)):
            panel?.makeFirstResponder(grid.keyView)
            grid.selectFirstItem()
            Log.gallery.debug("focus moved from search field to grid")
            return true
        default:
            return false
        }
    }
}
