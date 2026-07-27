import AppKit
import Quartz

final class GalleryCollectionView: NSCollectionView {

    private enum Key {
        static let space: UInt16 = 49
    }

    private var anchor: IndexPath?
    private var pressureStage = 0

    var contextMenuProvider: ((IndexPath?) -> NSMenu?)?

    weak var quickLook: QuickLookCoordinator?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        let stage = event.stage
        guard stage != pressureStage else { return }
        let previous = pressureStage
        pressureStage = stage
        Log.gallery.debug("grid pressure stage=\(previous, privacy: .public)->\(stage, privacy: .public)")

        guard stage >= 2, previous < 2, let quickLook else { return }
        let selected = selectionIndexPaths.count
        guard selected > 0 else {
            Log.gallery.info("grid force click ignored reason=no_selection")
            return
        }
        Log.gallery.info("grid force click routed to quick look selected=\(selected, privacy: .public)")
        quickLook.open()
    }

    override func keyDown(with event: NSEvent) {
        let plain = !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option)
        guard event.keyCode == Key.space, plain, let quickLook else {
            super.keyDown(with: event)
            return
        }
        let selected = selectionIndexPaths.count
        Log.gallery.info("grid space key routed to quick look selected=\(selected, privacy: .public)")
        quickLook.toggle()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLook != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLook?.begin(panel: panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLook?.end(panel: panel)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else {
            return super.menu(for: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = indexPathForItem(at: point)
        if let clicked {
            anchor = clicked
        }
        if clicked != nil, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
            Log.gallery.debug("grid took first responder on right click")
        }
        return contextMenuProvider?(clicked)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = indexPathForItem(at: point)

        if clicked != nil, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
            Log.gallery.debug("grid took first responder on item click")
        }

        if event.modifierFlags.contains(.shift), let clicked, let anchor, allowsMultipleSelection {
            extendSelection(from: anchor, to: clicked)
            return
        }

        if let clicked {
            self.anchor = clicked
        } else if !event.modifierFlags.contains(.shift) {
            self.anchor = nil
        }
        super.mouseDown(with: event)
    }

    private func extendSelection(from start: IndexPath, to end: IndexPath) {
        let range = indexPaths(from: start, to: end)
        guard !range.isEmpty else { return }
        let stale = selectionIndexPaths.subtracting(range)
        if !stale.isEmpty {
            deselectItems(at: stale)
        }
        selectItems(at: range, scrollPosition: [])
        Log.gallery.info("grid range selected count=\(range.count, privacy: .public)")
    }

    private func indexPaths(from start: IndexPath, to end: IndexPath) -> Set<IndexPath> {
        let low = min(start, end)
        let high = max(start, end)
        guard low.section < numberOfSections, high.section < numberOfSections else { return [] }

        var result: Set<IndexPath> = []
        for section in low.section...high.section {
            let count = numberOfItems(inSection: section)
            guard count > 0 else { continue }
            let first = section == low.section ? low.item : 0
            let last = section == high.section ? min(high.item, count - 1) : count - 1
            guard first <= last, first >= 0 else { continue }
            for item in first...last {
                result.insert(IndexPath(item: item, section: section))
            }
        }
        return result
    }
}

struct GalleryActivation {
    let action: String
    let rank: Int
    let count: Int
}

enum GalleryCopyMethod: String {
    case contextMenu = "context_menu"
    case drag
}

final class GalleryGridController: NSObject {

    private enum Layout {
        static let itemSize = ScreenshotItem.defaultSize
        static let interitemSpacing: CGFloat = 12
        static let lineSpacing: CGFloat = 12
        static let sectionInset = NSEdgeInsets(top: 6, left: 18, bottom: 16, right: 18)
        static let headerHeight = GallerySectionHeaderView.height
        static let pinHeaders = true
        static let batchUpdateCeiling = 64
        static let scrollTopButtonSide: CGFloat = 36
        static let scrollTopButtonInset: CGFloat = 18
        static let scrollTopRevealOffset: CGFloat = 600
        static let scrollTopFadeDuration: TimeInterval = 0.18
    }

    private struct DaySection {
        let day: Date
        let title: String
        var items: [Screenshot]
    }

    private let store: ScreenshotStore
    private let thumbnails: ThumbnailLoader
    private let quickLook = QuickLookCoordinator()
    private let container = NSView()
    private let scrollView = NSScrollView()
    private let collectionView = GalleryCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scrollTopBackdrop = NSVisualEffectView()
    private let scrollTopButton = NSButton()
    private var scrollTopVisible = false

    private var sections: [DaySection] = []
    private var displayedTotal = 0
    private var filterPaths: Set<String>?
    private var rankedPaths: [String]?
    private var thumbnailPixel: Int = 360

    private var dragItemCount = 0

    private var titleCache: [Date: String] = [:]
    private var titleCacheDay = Date.distantPast
    private var titleCacheDidReset = false

    private var relativeDayFormatter = LocalizationCenter.shared.relativeDayFormatter()
    private var currentYearDayFormatter = LocalizationCenter.shared.templateFormatter("EEEEMMMd")
    private var otherYearDayFormatter = LocalizationCenter.shared.templateFormatter("yMMMEEEEd")

    var onDragStateChanged: ((Bool) -> Void)?

    var onExternalDropCompleted: ((Int) -> Void)?

    var onContextMenuStateChanged: ((Bool) -> Void)?

    var onQuickLookStateChanged: ((Bool) -> Void)?

    var onItemActivated: ((GalleryActivation) -> Void)?

    var onCopyCompleted: ((Int, GalleryCopyMethod) -> Void)?

    var containerView: NSView { container }

    var keyView: NSView { collectionView }

    var displayedCount: Int { displayedTotal }

    var isQuickLookOpen: Bool { quickLook.isOpen }

    init(store: ScreenshotStore, thumbnails: ThumbnailLoader) {
        self.store = store
        self.thumbnails = thumbnails
        super.init()
        buildViews()
        updateThumbnailPixel(scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    func closeQuickLook() {
        quickLook.close()
    }

    func applyLanguage() {
        let center = LocalizationCenter.shared
        relativeDayFormatter = center.relativeDayFormatter()
        currentYearDayFormatter = center.templateFormatter("EEEEMMMd")
        otherYearDayFormatter = center.templateFormatter("yMMMEEEEd")
        let dropped = titleCache.count
        titleCache.removeAll(keepingCapacity: true)
        titleCacheDay = Date.distantPast
        scrollTopButton.toolTip = L10n.Gallery.scrollToTop
        reloadAll(preserveScroll: true)
        Log.gallery.info("grid relocalized language=\(center.language.rawValue, privacy: .public) locale=\(center.locale.identifier, privacy: .public) cachedTitlesDropped=\(dropped, privacy: .public)")
    }

    private func buildViews() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Layout.itemSize
        layout.minimumInteritemSpacing = Layout.interitemSpacing
        layout.minimumLineSpacing = Layout.lineSpacing
        layout.sectionInset = Layout.sectionInset
        layout.scrollDirection = .vertical
        layout.headerReferenceSize = NSSize(width: 0, height: Layout.headerHeight)
        layout.sectionHeadersPinToVisibleBounds = Layout.pinHeaders

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true
        collectionView.register(ScreenshotItem.self, forItemWithIdentifier: ScreenshotItem.identifier)
        collectionView.register(
            GallerySectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: GallerySectionHeaderView.identifier
        )
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([], forLocal: true)
        collectionView.contextMenuProvider = { [weak self] indexPath in
            self?.makeContextMenu(for: indexPath)
        }

        quickLook.source = self
        quickLook.onStateChanged = { [weak self] active in
            guard let self else { return }
            if active {
                self.notifyActivation("quick_look", rank: self.selectionRank(), count: max(1, self.collectionView.selectionIndexPaths.count))
            }
            self.onQuickLookStateChanged?(active)
        }
        collectionView.quickLook = quickLook
        collectionView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        buildScrollTopButton()

        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(scrollTopBackdrop)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            scrollTopBackdrop.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Layout.scrollTopButtonInset
            ),
            scrollTopBackdrop.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Layout.scrollTopButtonInset
            ),
            scrollTopBackdrop.widthAnchor.constraint(equalToConstant: Layout.scrollTopButtonSide),
            scrollTopBackdrop.heightAnchor.constraint(equalToConstant: Layout.scrollTopButtonSide)
        ])

        observeScrolling()

        Log.gallery.info(
            "grid built pinnedHeaders=\(Layout.pinHeaders, privacy: .public) headerHeight=\(Int(Layout.headerHeight), privacy: .public)"
        )
    }

    func updateThumbnailPixel(scale: CGFloat) {
        let effective = scale > 0 ? scale : 2
        let side = max(Layout.itemSize.width, Layout.itemSize.height) - ScreenshotItem.imageInset * 2
        let pixel = max(256, Int((side * effective).rounded(.up)))
        guard pixel != thumbnailPixel else { return }
        thumbnailPixel = pixel
        Log.gallery.info("thumbnail pixel updated pixel=\(pixel, privacy: .public) scale=\(Double(effective), privacy: .public)")
    }

    func reloadAll(preserveScroll: Bool) {
        let origin = scrollView.contentView.bounds.origin
        setSections(buildSections(computeDisplayed()))
        collectionView.reloadData()
        updateEmptyState()
        collectionView.layoutSubtreeIfNeeded()
        if preserveScroll {
            restoreScroll(to: origin)
        } else {
            scrollToTop()
        }
        let count = displayedTotal
        let groups = sections.count
        Log.gallery.info(
            "grid reloaded items=\(count, privacy: .public) sections=\(groups, privacy: .public) preserveScroll=\(preserveScroll, privacy: .public)"
        )
    }

    func applyRanking(_ paths: [String], resetScroll: Bool = true) {
        let origin = scrollView.contentView.bounds.origin
        rankedPaths = paths
        filterPaths = Set(paths)
        setSections(buildSections(computeDisplayed()))
        collectionView.reloadData()
        updateEmptyState()
        collectionView.layoutSubtreeIfNeeded()
        if resetScroll {
            scrollToTop()
        } else {
            restoreScroll(to: origin)
        }
        Log.gallery.info("grid ranking applied items=\(self.displayedTotal, privacy: .public) resetScroll=\(resetScroll, privacy: .public)")
    }

    func applyFilter(_ paths: Set<String>?, resetScroll: Bool = true) {
        let origin = scrollView.contentView.bounds.origin
        rankedPaths = nil
        filterPaths = paths
        setSections(buildSections(computeDisplayed()))
        collectionView.reloadData()
        updateEmptyState()
        collectionView.layoutSubtreeIfNeeded()
        if resetScroll {
            scrollToTop()
        } else {
            restoreScroll(to: origin)
        }
        let count = displayedTotal
        let groups = sections.count
        let filtered = paths != nil
        Log.gallery.info(
            "grid filter applied filtered=\(filtered, privacy: .public) items=\(count, privacy: .public) sections=\(groups, privacy: .public) resetScroll=\(resetScroll, privacy: .public)"
        )
    }

    func apply(change: StoreChange) {
        guard !change.isEmpty else { return }
        let volume = change.inserted.count + change.removedURLs.count
        let animatable = filterPaths == nil
            && rankedPaths == nil
            && !change.isFullReload
            && volume > 0
            && volume <= Layout.batchUpdateCeiling
            && !sections.isEmpty

        guard animatable else {
            Log.gallery.info(
                "grid change reload volume=\(volume, privacy: .public) fullReload=\(change.isFullReload, privacy: .public)"
            )
            reloadAll(preserveScroll: !change.isFullReload)
            return
        }

        let next = buildSections(computeDisplayed())

        guard !titleCacheDidReset else {
            Log.gallery.info("grid section titles rolled over, falling back to reload")
            reloadAll(preserveScroll: true)
            return
        }

        guard sectionsAligned(sections, next) else {
            let previousGroups = sections.count
            let nextGroups = next.count
            Log.gallery.info(
                "grid section layout changed previousSections=\(previousGroups, privacy: .public) nextSections=\(nextGroups, privacy: .public) falling back to reload"
            )
            reloadAll(preserveScroll: true)
            return
        }

        let insertedURLs = Set(change.inserted.map(\.url))
        var removals: Set<IndexPath> = []
        var insertions: Set<IndexPath> = []

        for (sectionIndex, current) in sections.enumerated() {
            let nextItems = next[sectionIndex].items
            let previousURLs = Set(current.items.map(\.url))
            var removedHere = 0
            var insertedHere = 0

            for (itemIndex, item) in current.items.enumerated() where change.removedURLs.contains(item.url) {
                removals.insert(IndexPath(item: itemIndex, section: sectionIndex))
                removedHere += 1
            }
            for (itemIndex, item) in nextItems.enumerated()
            where insertedURLs.contains(item.url) && !previousURLs.contains(item.url) {
                insertions.insert(IndexPath(item: itemIndex, section: sectionIndex))
                insertedHere += 1
            }

            guard current.items.count - removedHere + insertedHere == nextItems.count else {
                Log.gallery.error(
                    "grid batch update rejected section=\(sectionIndex, privacy: .public) previous=\(current.items.count, privacy: .public) next=\(nextItems.count, privacy: .public) removed=\(removedHere, privacy: .public) inserted=\(insertedHere, privacy: .public)"
                )
                reloadAll(preserveScroll: true)
                return
            }
        }

        collectionView.performBatchUpdates({
            self.setSections(next)
            if !removals.isEmpty { self.collectionView.deleteItems(at: removals) }
            if !insertions.isEmpty { self.collectionView.insertItems(at: insertions) }
        }, completionHandler: { [weak self] _ in
            self?.updateEmptyState()
        })

        let inserted = insertions.count
        let removed = removals.count
        let groups = sections.count
        Log.gallery.info(
            "grid batch updated inserted=\(inserted, privacy: .public) removed=\(removed, privacy: .public) sections=\(groups, privacy: .public)"
        )
    }

    func clearSelection() {
        let selected = collectionView.selectionIndexPaths
        guard !selected.isEmpty else { return }
        collectionView.deselectItems(at: selected)
        Log.gallery.info("grid selection cleared count=\(selected.count, privacy: .public)")
    }

    func selectFirstItem() {
        guard let first = firstIndexPath() else { return }
        collectionView.selectItems(at: [first], scrollPosition: [])
        scrollToTop()
        Log.gallery.debug("grid selected first item")
    }

    func openSelectionOrFirst() {
        guard let fallback = firstIndexPath() else { return }
        let target = collectionView.selectionIndexPaths.sorted().first ?? fallback
        guard let screenshot = screenshot(at: target) else { return }
        open(screenshot.url)
    }

    private func firstIndexPath() -> IndexPath? {
        guard let index = sections.firstIndex(where: { !$0.items.isEmpty }) else { return nil }
        return IndexPath(item: 0, section: index)
    }

    private func indexPath(for url: URL) -> IndexPath? {
        for (section, day) in sections.enumerated() {
            guard let item = day.items.firstIndex(where: { $0.url == url }) else { continue }
            return IndexPath(item: item, section: section)
        }
        return nil
    }

    private func flatIndex(of indexPath: IndexPath) -> Int? {
        guard indexPath.section >= 0, indexPath.section < sections.count else { return nil }
        let count = sections[indexPath.section].items.count
        guard indexPath.item >= 0, indexPath.item < count else { return nil }
        var base = 0
        for section in 0..<indexPath.section { base += sections[section].items.count }
        return base + indexPath.item
    }

    private func indexPath(atFlat flat: Int) -> IndexPath? {
        guard flat >= 0 else { return nil }
        var remaining = flat
        for (section, day) in sections.enumerated() {
            if remaining < day.items.count { return IndexPath(item: remaining, section: section) }
            remaining -= day.items.count
        }
        return nil
    }

    private func makeContextMenu(for indexPath: IndexPath?) -> NSMenu? {
        guard let indexPath, screenshot(at: indexPath) != nil else { return nil }

        if !collectionView.selectionIndexPaths.contains(indexPath) {
            let stale = collectionView.selectionIndexPaths
            if !stale.isEmpty {
                collectionView.deselectItems(at: stale)
            }
            collectionView.selectItems(at: [indexPath], scrollPosition: [])
        }

        let targets = urls(at: collectionView.selectionIndexPaths.sorted())
        guard !targets.isEmpty else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let plural = targets.count > 1
        add(to: menu, title: plural ? L10n.Gallery.openMany(targets.count) : L10n.Gallery.open, action: #selector(contextOpen), targets: targets)
        add(to: menu, title: plural ? L10n.Gallery.quickLookMany(targets.count) : L10n.Gallery.quickLook, action: #selector(contextQuickLook), targets: targets)
        add(to: menu, title: L10n.Gallery.reveal, action: #selector(contextReveal), targets: targets)
        menu.addItem(.separator())
        let asPNG = targets.contains { PNGExporter.shared.handles($0) }
        let copyTitle: String
        switch (plural, asPNG) {
        case (true, true): copyTitle = L10n.Gallery.copyManyAsPNG(targets.count)
        case (true, false): copyTitle = L10n.Gallery.copyMany(targets.count)
        case (false, true): copyTitle = L10n.Gallery.copyAsPNG
        case (false, false): copyTitle = L10n.Gallery.copy
        }
        add(to: menu, title: copyTitle, action: #selector(contextCopy), targets: targets)
        menu.addItem(.separator())
        add(to: menu, title: plural ? L10n.Gallery.trashMany(targets.count) : L10n.Gallery.trash, action: #selector(contextTrash), targets: targets)

        Log.gallery.info("grid context menu built count=\(targets.count, privacy: .public)")
        return menu
    }

    private func add(to menu: NSMenu, title: String, action: Selector, targets: [URL]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = targets
        menu.addItem(item)
    }

    private func targets(from sender: Any?) -> [URL] {
        ((sender as? NSMenuItem)?.representedObject as? [URL]) ?? []
    }

    @objc private func contextOpen(_ sender: Any?) {
        let urls = targets(from: sender).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Log.gallery.info("context open count=\(urls.count, privacy: .public)")
        urls.forEach { NSWorkspace.shared.open($0) }
        notifyActivation("open", rank: selectionRank(), count: urls.count)
    }

    @objc private func contextQuickLook(_ sender: Any?) {
        let count = targets(from: sender).count
        Log.gallery.info("context quick look requested count=\(count, privacy: .public)")
        quickLook.open()
    }

    @objc private func contextReveal(_ sender: Any?) {
        let urls = targets(from: sender).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Log.gallery.info("context reveal count=\(urls.count, privacy: .public)")
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        notifyActivation("reveal", rank: selectionRank(), count: urls.count)
    }

    @objc private func contextCopy(_ sender: Any?) {
        let urls = targets(from: sender).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(PNGExporter.shared.pasteboardWriters(for: urls))
        Log.gallery.info("context copy count=\(urls.count, privacy: .public) asPNG=\(PNGExporter.shared.isActive, privacy: .public)")
        notifyActivation("copy", rank: selectionRank(), count: urls.count)
        onCopyCompleted?(urls.count, .contextMenu)
    }

    @objc private func contextTrash(_ sender: Any?) {
        let urls = targets(from: sender).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        Log.gallery.info("context trash requested count=\(urls.count, privacy: .public)")
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error {
                Log.gallery.error("context trash failed error=\(error.localizedDescription, privacy: .public)")
            } else {
                Log.gallery.info("context trash completed count=\(urls.count, privacy: .public)")
            }
        }
    }

    private func screenshot(at indexPath: IndexPath) -> Screenshot? {
        guard indexPath.section >= 0, indexPath.section < sections.count else { return nil }
        let items = sections[indexPath.section].items
        guard indexPath.item >= 0, indexPath.item < items.count else { return nil }
        return items[indexPath.item]
    }

    private func setSections(_ next: [DaySection]) {
        sections = next
        displayedTotal = next.reduce(0) { $0 + $1.items.count }
    }

    private func sectionsAligned(_ lhs: [DaySection], _ rhs: [DaySection]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs[index].day != rhs[index].day { return false }
        return true
    }

    private func buildSections(_ items: [Screenshot]) -> [DaySection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        refreshTitleCacheIfNeeded(today: today)
        guard !items.isEmpty else { return [] }
        if rankedPaths != nil {
            return [DaySection(day: Date.distantFuture, title: L10n.Gallery.bestMatches, items: items)]
        }

        var result: [DaySection] = []
        var bucket: [Screenshot] = []
        var day: Date?
        var dayStart = Date.distantPast
        var dayEnd = Date.distantPast

        for item in items {
            if day != nil, item.created >= dayStart, item.created < dayEnd {
                bucket.append(item)
                continue
            }
            if let day {
                result.append(
                    DaySection(day: day, title: title(for: day, calendar: calendar, today: today), items: bucket)
                )
            }
            let start = calendar.startOfDay(for: item.created)
            let interval = calendar.dateInterval(of: .day, for: item.created)
            dayStart = interval?.start ?? start
            dayEnd = interval?.end ?? start.addingTimeInterval(86400)
            day = start
            bucket = [item]
        }
        if let day {
            result.append(
                DaySection(day: day, title: title(for: day, calendar: calendar, today: today), items: bucket)
            )
        }
        return result
    }

    private func refreshTitleCacheIfNeeded(today: Date) {
        titleCacheDidReset = false
        guard titleCacheDay != today else { return }
        let hadEntries = !titleCache.isEmpty
        titleCache.removeAll(keepingCapacity: true)
        titleCacheDay = today
        titleCacheDidReset = hadEntries
        Log.gallery.info("section title cache reset rolledOver=\(hadEntries, privacy: .public)")
    }

    private func title(for day: Date, calendar: Calendar, today: Date) -> String {
        if let cached = titleCache[day] { return cached }
        let resolved: String
        if calendar.isDateInToday(day) || calendar.isDateInYesterday(day) {
            resolved = relativeDayFormatter.string(from: day)
        } else if calendar.isDate(day, equalTo: today, toGranularity: .year) {
            resolved = currentYearDayFormatter.string(from: day)
        } else {
            resolved = otherYearDayFormatter.string(from: day)
        }
        titleCache[day] = resolved
        return resolved
    }

    private func computeDisplayed() -> [Screenshot] {
        if let rankedPaths {
            var lookup: [String: Screenshot] = [:]
            lookup.reserveCapacity(store.items.count)
            for item in store.items { lookup[item.path] = item }
            return rankedPaths.compactMap { lookup[$0] }
        }
        guard let filterPaths else { return store.items }
        return store.items.filter { filterPaths.contains($0.path) }
    }

    private func updateEmptyState() {
        let isEmpty = sections.isEmpty
        emptyLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        emptyLabel.stringValue = (filterPaths == nil && rankedPaths == nil)
            ? L10n.Gallery.emptyFolder
            : L10n.Gallery.emptySearch
    }

    private func buildScrollTopButton() {
        scrollTopBackdrop.translatesAutoresizingMaskIntoConstraints = false
        scrollTopBackdrop.material = .hudWindow
        scrollTopBackdrop.blendingMode = .withinWindow
        scrollTopBackdrop.state = .active
        scrollTopBackdrop.wantsLayer = true
        scrollTopBackdrop.layer?.cornerRadius = Layout.scrollTopButtonSide / 2
        scrollTopBackdrop.layer?.cornerCurve = .continuous
        scrollTopBackdrop.layer?.masksToBounds = true
        scrollTopBackdrop.layer?.borderWidth = 1
        scrollTopBackdrop.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollTopBackdrop.alphaValue = 0
        scrollTopBackdrop.isHidden = true

        let symbol = NSImage(
            systemSymbolName: "chevron.up",
            accessibilityDescription: L10n.Gallery.scrollToTop
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))

        scrollTopButton.translatesAutoresizingMaskIntoConstraints = false
        scrollTopButton.image = symbol
        scrollTopButton.imagePosition = .imageOnly
        scrollTopButton.isBordered = false
        scrollTopButton.bezelStyle = .regularSquare
        scrollTopButton.contentTintColor = .secondaryLabelColor
        scrollTopButton.toolTip = L10n.Gallery.scrollToTop
        scrollTopButton.target = self
        scrollTopButton.action = #selector(scrollTopClicked)
        scrollTopBackdrop.addSubview(scrollTopButton)

        NSLayoutConstraint.activate([
            scrollTopButton.leadingAnchor.constraint(equalTo: scrollTopBackdrop.leadingAnchor),
            scrollTopButton.trailingAnchor.constraint(equalTo: scrollTopBackdrop.trailingAnchor),
            scrollTopButton.topAnchor.constraint(equalTo: scrollTopBackdrop.topAnchor),
            scrollTopButton.bottomAnchor.constraint(equalTo: scrollTopBackdrop.bottomAnchor)
        ])
    }

    private func observeScrolling() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func clipViewBoundsChanged() {
        updateScrollTopVisibility()
    }

    private func updateScrollTopVisibility() {
        let offset = scrollView.contentView.bounds.origin.y
        let shouldShow = offset > Layout.scrollTopRevealOffset && displayedTotal > 0
        setScrollTopVisible(shouldShow)
    }

    private func setScrollTopVisible(_ visible: Bool) {
        guard visible != scrollTopVisible else { return }
        scrollTopVisible = visible
        Log.gallery.debug("grid scroll-top button visible=\(visible, privacy: .public)")

        if visible {
            scrollTopBackdrop.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.scrollTopFadeDuration
            scrollTopBackdrop.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            guard !self.scrollTopVisible else { return }
            self.scrollTopBackdrop.isHidden = true
        })
    }

    @objc private func scrollTopClicked() {
        Log.gallery.info("grid scroll-top clicked")
        scrollToTop(animated: true)
    }

    private func scrollToTop() {
        scrollToTop(animated: false)
    }

    private func scrollToTop(animated: Bool) {
        let destination = NSPoint(x: 0, y: 0)
        guard animated else {
            scrollView.contentView.scroll(to: destination)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            updateScrollTopVisibility()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().setBoundsOrigin(destination)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.updateScrollTopVisibility()
        })
    }

    private func restoreScroll(to origin: NSPoint) {
        let visibleHeight = scrollView.contentView.bounds.height
        let documentHeight = collectionView.frame.height
        let maxY = max(0, documentHeight - visibleHeight)
        let clamped = NSPoint(x: origin.x, y: min(origin.y, maxY))
        scrollView.contentView.scroll(to: clamped)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func urls(at indexPaths: [IndexPath]) -> [URL] {
        indexPaths.compactMap { screenshot(at: $0)?.url }
    }

    private func open(_ url: URL) {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.gallery.error("open skipped file missing file=\(name, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
        notifyActivation("open", rank: rank(for: url), count: 1)
        Log.gallery.info("opened screenshot file=\(name, privacy: .public)")
    }

    private func notifyActivation(_ action: String, rank: Int, count: Int) {
        onItemActivated?(GalleryActivation(action: action, rank: rank, count: count))
    }

    private func rank(for url: URL) -> Int {
        guard let indexPath = indexPath(for: url), let flat = flatIndex(of: indexPath) else { return 0 }
        return flat + 1
    }

    private func selectionRank() -> Int {
        guard let first = collectionView.selectionIndexPaths.sorted().first else { return 0 }
        guard let flat = flatIndex(of: first) else { return 0 }
        return flat + 1
    }
}

extension GalleryGridController: NSCollectionViewDataSource {

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard section >= 0, section < sections.count else { return 0 }
        return sections[section].items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ScreenshotItem.identifier, for: indexPath)
        guard let cell = item as? ScreenshotItem, let screenshot = screenshot(at: indexPath) else { return item }
        cell.onOpen = { [weak self] url in self?.open(url) }
        cell.configure(with: screenshot.url, loader: thumbnails, maxPixel: thumbnailPixel)
        return cell
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        guard kind == NSCollectionView.elementKindSectionHeader else {
            Log.gallery.error("unexpected supplementary kind=\(kind, privacy: .public)")
            return NSView()
        }
        let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: GallerySectionHeaderView.identifier,
            for: indexPath
        )
        guard let header = view as? GallerySectionHeaderView else {
            Log.gallery.error("section header dequeue returned unexpected view")
            return view
        }
        guard indexPath.section >= 0, indexPath.section < sections.count else { return header }
        header.configure(title: sections[indexPath.section].title)
        return header
    }
}

extension GalleryGridController: NSCollectionViewPrefetching {

    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        thumbnails.prefetch(urls: urls(at: indexPaths), maxPixel: thumbnailPixel)
    }

    func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        thumbnails.cancelPrefetch(urls: urls(at: indexPaths), maxPixel: thumbnailPixel)
    }
}

extension GalleryGridController: NSCollectionViewDelegate {

    func collectionView(
        _ collectionView: NSCollectionView,
        canDragItemsAt indexPaths: Set<IndexPath>,
        with event: NSEvent
    ) -> Bool {
        true
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard let screenshot = screenshot(at: indexPath) else {
            Log.drag.error(
                "drag writer skipped out of range section=\(indexPath.section, privacy: .public) item=\(indexPath.item, privacy: .public)"
            )
            return nil
        }
        let url = screenshot.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            let name = url.lastPathComponent
            Log.drag.error("drag writer skipped file missing file=\(name, privacy: .public)")
            return nil
        }
        return PNGExporter.shared.pasteboardWriter(for: url)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
    ) {
        session.draggingFormation = indexPaths.count > 1 ? .stack : .default
        dragItemCount = indexPaths.count
        onDragStateChanged?(true)
        let count = indexPaths.count
        notifyActivation("drag", rank: selectionRank(), count: count)
        Log.drag.info("gallery drag started count=\(count, privacy: .public)")
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        dragOperation operation: NSDragOperation
    ) {
        let count = dragItemCount
        dragItemCount = 0
        onDragStateChanged?(false)
        let raw = Int(operation.rawValue)
        guard !operation.isEmpty else {
            Log.drag.info("gallery drag cancelled operation=\(raw, privacy: .public) count=\(count, privacy: .public)")
            return
        }
        Log.drag.info("gallery drag dropped operation=\(raw, privacy: .public) count=\(count, privacy: .public)")
        onCopyCompleted?(count, .drag)
        onExternalDropCompleted?(count)
    }
}

extension GalleryGridController: QuickLookSource {

    var quickLookItems: [URL] {
        urls(at: collectionView.selectionIndexPaths.sorted())
    }

    func quickLookPrepareResponder() {
        guard let window = collectionView.window else {
            Log.gallery.error("quick look responder prep skipped reason=no_window")
            return
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== collectionView {
            window.makeFirstResponder(collectionView)
        }
        Log.gallery.info(
            "quick look responder prepared key=\(window.isKeyWindow, privacy: .public) grid=\(window.firstResponder === self.collectionView, privacy: .public)"
        )
    }

    func quickLookSourceFrame(for url: URL) -> NSRect {
        guard let indexPath = indexPath(for: url) else { return .zero }
        guard let item = collectionView.item(at: indexPath) else { return .zero }
        let view = item.view
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func quickLookTransitionImage(for url: URL) -> NSImage? {
        thumbnails.cachedThumbnail(for: url, maxPixel: thumbnailPixel)
    }

    func quickLookStep(_ delta: Int) -> Bool {
        guard let current = collectionView.selectionIndexPaths.sorted().first else { return false }
        guard let flat = flatIndex(of: current) else { return false }
        guard let next = indexPath(atFlat: flat + delta) else { return false }

        let stale = collectionView.selectionIndexPaths
        if !stale.isEmpty { collectionView.deselectItems(at: stale) }
        collectionView.selectItems(at: [next], scrollPosition: .nearestHorizontalEdge)

        let target = flat + delta
        Log.gallery.info("grid quick look moved to index=\(target, privacy: .public)")
        return true
    }
}

extension GalleryGridController: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        onContextMenuStateChanged?(true)
        Log.gallery.debug("grid context menu opened")
    }

    func menuDidClose(_ menu: NSMenu) {
        onContextMenuStateChanged?(false)
        Log.gallery.debug("grid context menu closed")
    }
}
