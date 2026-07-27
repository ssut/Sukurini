import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let dockHolder = "dock"
    private static let postOnboardingGalleryDelay: TimeInterval = 0.35

    private let settings = AppSettings.shared
    private let store = ScreenshotStore()
    private let thumbnails = ThumbnailLoader()
    private let menuController = AppMenuController()
    private let preferences = PreferencesWindowController()
    private let onboarding = OnboardingWindowController()

    private lazy var gallery = GalleryPanelController(store: store, thumbnails: thumbnails)
    private lazy var statusItem = StatusItemController(store: store, thumbnails: thumbnails)
    private lazy var converter = ConversionCoordinator(store: store, thumbnails: thumbnails)
    private lazy var organizer = OrganizeCoordinator(store: store, index: searchIndex)

    private let hotKeyCenter = HotKeyCenter()

    private var searchIndex: SearchIndex?
    private var ocrIndexer: OCRIndexer?
    private var semantic: SemanticCoordinator?
    private var searchBridge: HybridSearchProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Telemetry.start()
        Log.app.info("launching bundle=\(Bundle.main.bundleURL.path, privacy: .public)")

        let loginItemLaunch = AppDelegate.launchedAsLoginItem()

        installMainMenu()
        applyDockVisibility(reason: "launch")
        settings.ensureSystemCaptureFolderListed()
        setupSearch()
        setupControllers()
        setupConversion()
        setupOrganize()
        observeSettings()
        observeStore()
        UpdateCoordinator.shared.start()

        store.activate(folder: settings.activeFolder)
        startConversionCatchUp()
        ocrIndexer?.start()
        let screenieWarning = warnIfScreenieRunning()
        let onboardingPresentation = resolveOnboarding(loginItemLaunch: loginItemLaunch)
        if let onboardingPresentation {
            scheduleOnboarding(onboardingPresentation)
        } else {
            scheduleLaunchGallery(loginItemLaunch: loginItemLaunch, screenieWarning: screenieWarning)
        }

        Log.app.info("launched activeFolder=\(self.settings.activeFolder?.path ?? "none", privacy: .public)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Log.app.info("dock reopen requested hasVisibleWindows=\(hasVisibleWindows, privacy: .public) policy=\(ActivationPolicyCoordinator.describe(NSApp.activationPolicy()), privacy: .public)")

        if onboarding.bringToFront() {
            return false
        }

        if preferences.bringToFront() {
            return false
        }

        if menuController.bringAboutToFront() {
            return false
        }

        Log.app.info("dock reopen fallback showing gallery")
        showGalleryFromDock()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        organizer.cancelOrganize()
        ocrIndexer?.stop()
        hotKeyCenter.stop()
        Log.app.info("terminating")
    }

    private func setupSearch() {
        guard settings.ocrEnabled || settings.semanticSearchEnabled else {
            Log.app.info("search disabled by settings")
            return
        }
        guard searchIndex == nil else { return }
        guard let index = SearchIndex() else {
            Log.app.error("search index unavailable, falling back to filename search")
            return
        }
        searchIndex = index
        organizer.attachIndex(index)

        let coordinator = SemanticCoordinator(store: store, index: index)
        semantic = coordinator
        preferences.semanticController = coordinator

        let indexer = OCRIndexer(store: store, index: index)
        indexer.semantic = coordinator
        ocrIndexer = indexer
        preferences.ocrProgressProvider = { [weak indexer] in indexer?.progress ?? (done: 0, total: 0) }

        searchBridge = HybridSearchProvider(index: index, semantic: coordinator)
        coordinator.refresh(reason: "setup")
    }

    private func setupControllers() {
        menuController.onShowPreferences = { [weak self] in
            self?.preferences.show()
        }

        menuController.onShowOnboarding = { [weak self] in
            self?.onboarding.show(reason: .manual)
        }

        menuController.onCheckForUpdates = {
            UpdateCoordinator.shared.checkForUpdates()
        }

        onboarding.onFinished = { [weak self] presentation in
            self?.galleryAfterOnboarding(presentation)
        }

        gallery.menuProvider = { [weak self] in
            self?.menuController.buildMenu() ?? NSMenu()
        }
        gallery.searchProvider = searchBridge ?? searchIndex

        statusItem.delegate = self
        statusItem.install()
        gallery.prewarm()

        hotKeyCenter.onTrigger = { [weak self] in
            guard let self else { return }
            Log.app.info("hotkey triggered galleryVisible=\(self.gallery.isVisible, privacy: .public)")
            self.gallery.toggle(
                wasVisibleAtPress: self.gallery.isVisible,
                statusButton: self.statusItem.statusButton
            )
        }
        hotKeyCenter.start()
    }

    private func setupConversion() {
        settings.ensureConversionTimestamp()
        store.setConverter(converter)
        store.setConversionEnabled(settings.webpConversionEnabled)
        preferences.backfillController = converter
        onboarding.backfillController = converter
        PNGExporter.shared.purgeExpired()
        Log.app.info("conversion configured enabled=\(self.settings.webpConversionEnabled, privacy: .public) disposal=\(self.settings.webpDisposal.rawValue, privacy: .public) copyAsPNG=\(self.settings.copyAsPNGEnabled, privacy: .public)")
    }

    private func startConversionCatchUp() {
        guard settings.webpConversionEnabled else { return }
        guard let since = settings.webpConversionEnabledAt else {
            Log.app.info("conversion catch-up skipped reason=no_enabled_timestamp")
            return
        }
        Log.app.info("conversion catch-up requested since=\(Int(since.timeIntervalSince1970), privacy: .public)")
        converter.startCatchUp(since: since)
    }

    private func setupOrganize() {
        store.setIncludeSubfolders(settings.includeSubfolders)
        store.setOrganize(enabled: settings.organizeEnabled, pattern: settings.organizeFormat)
        preferences.organizeController = organizer
        Log.app.info("organize configured enabled=\(self.settings.organizeEnabled, privacy: .public) format=\(self.settings.organizeFormat, privacy: .public) subfolders=\(self.settings.includeSubfolders, privacy: .public)")
    }

    private func applyDockVisibility(reason: String) {
        let visible = settings.alwaysShowInDock
        Log.app.info("dock visibility applying value=\(visible, privacy: .public) reason=\(reason, privacy: .public)")
        if visible {
            ActivationPolicyCoordinator.acquireRegular(Self.dockHolder)
        } else {
            ActivationPolicyCoordinator.release(Self.dockHolder)
        }
    }

    private func observeSettings() {
        NotificationCenter.default.addObserver(
            forName: .sukuriniDockVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDockVisibility(reason: "settings")
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniActiveFolderChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("active folder changed, retargeting store path=\(self.settings.activeFolder?.path ?? "none", privacy: .public)")
            self.store.activate(folder: self.settings.activeFolder)
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniOCREnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.settings.ocrEnabled {
                if self.searchIndex == nil {
                    self.setupSearch()
                    self.gallery.searchProvider = self.searchBridge ?? self.searchIndex
                }
                self.ocrIndexer?.start()
            } else if self.settings.semanticSearchEnabled {
                self.ocrIndexer?.start()
            } else {
                self.ocrIndexer?.stop()
                self.preferences.ocrProgressProvider = nil
            }
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniSemanticEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("semantic setting changed enabled=\(self.settings.semanticSearchEnabled, privacy: .public)")
            if self.searchIndex == nil {
                self.setupSearch()
                self.gallery.searchProvider = self.searchBridge ?? self.searchIndex
            }
            self.semantic?.refresh(reason: "settings")
            if self.settings.semanticSearchEnabled {
                self.ocrIndexer?.start()
            } else if !self.settings.ocrEnabled {
                self.ocrIndexer?.stop()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniSemanticModelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("semantic model changed value=\(self.settings.semanticModelIdentifier, privacy: .public)")
            self.semantic?.refresh(reason: "model-changed")
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniSemanticStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let semantic = self.semantic else { return }
            guard semantic.isReady else { return }
            semantic.prewarmTextTower()
            self.ocrIndexer?.start()
            self.ocrIndexer?.requestReconcileNow()
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniWebPConversionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("conversion setting changed enabled=\(self.settings.webpConversionEnabled, privacy: .public) disposal=\(self.settings.webpDisposal.rawValue, privacy: .public)")
            self.store.setConversionEnabled(self.settings.webpConversionEnabled)
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniOrganizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("organize setting changed enabled=\(self.settings.organizeEnabled, privacy: .public) format=\(self.settings.organizeFormat, privacy: .public)")
            self.store.setOrganize(enabled: self.settings.organizeEnabled, pattern: self.settings.organizeFormat)
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniIncludeSubfoldersChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("include subfolders changed value=\(self.settings.includeSubfolders, privacy: .public)")
            self.store.setIncludeSubfolders(self.settings.includeSubfolders)
        }

        NotificationCenter.default.addObserver(
            forName: .sukuriniLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.app.info("language changed, rebuilding main menu value=\(LocalizationCenter.shared.language.rawValue, privacy: .public)")
            self.installMainMenu()
        }
    }

    private func observeStore() {
        store.addObserver { [weak self] change in
            guard let self else { return }
            guard !change.isFullReload else { return }
            let arrivals = change.arrivals
            guard !arrivals.isEmpty else { return }
            Log.app.info("new screenshots detected count=\(arrivals.count, privacy: .public)")
            self.statusItem.playRipple()
        }
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            Log.app.info("launch source undetermined reason=no_apple_event")
            return false
        }
        guard event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else {
            Log.app.info("launch source undetermined reason=not_open_application")
            return false
        }
        guard let property = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else {
            Log.app.info("launch source user reason=no_launch_property")
            return false
        }
        let loginItem = property.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        Log.app.info("launch source resolved loginItem=\(loginItem, privacy: .public)")
        return loginItem
    }

    private func resolveOnboarding(loginItemLaunch: Bool) -> OnboardingWindowController.Presentation? {
        guard let presentation = OnboardingWindowController.launchPresentation() else { return nil }
        guard !loginItemLaunch else {
            Log.app.info("onboarding deferred reason=login_item_launch presentation=\(presentation.rawValue, privacy: .public)")
            return nil
        }
        return presentation
    }

    private func scheduleOnboarding(_ presentation: OnboardingWindowController.Presentation) {
        Log.app.info("onboarding scheduled presentation=\(presentation.rawValue, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onboarding.show(reason: presentation)
        }
    }

    private func galleryAfterOnboarding(_ presentation: OnboardingWindowController.Presentation) {
        guard presentation != .manual else {
            Log.app.info("post-onboarding gallery skipped reason=manual_presentation")
            return
        }
        Log.app.info("post-onboarding gallery scheduled presentation=\(presentation.rawValue, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postOnboardingGalleryDelay) { [weak self] in
            guard let self else { return }
            guard !self.onboarding.isVisible else {
                Log.app.info("post-onboarding gallery skipped reason=onboarding_visible_again")
                return
            }
            guard !self.gallery.isVisible else {
                Log.app.info("post-onboarding gallery skipped reason=already_visible")
                return
            }
            Log.app.info("post-onboarding gallery presenting items=\(self.store.items.count, privacy: .public)")
            self.gallery.show(relativeTo: self.statusItem.statusButton)
        }
    }

    private func scheduleLaunchGallery(loginItemLaunch: Bool, screenieWarning: Bool) {
        guard !loginItemLaunch else {
            Log.app.info("launch gallery skipped reason=login_item_launch")
            return
        }
        guard !screenieWarning else {
            Log.app.info("launch gallery skipped reason=screenie_alert_pending")
            return
        }
        Log.app.info("launch gallery scheduled")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.gallery.isVisible else {
                Log.app.info("launch gallery skipped reason=already_visible")
                return
            }
            Log.app.info("launch gallery presenting items=\(self.store.items.count, privacy: .public)")
            self.gallery.show(relativeTo: self.statusItem.statusButton)
        }
    }

    private func showGalleryFromDock() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.gallery.isVisible else {
                Log.app.info("dock reopen gallery skipped reason=already_visible")
                return
            }
            Log.app.info("dock reopen gallery presenting items=\(self.store.items.count, privacy: .public)")
            self.gallery.show(relativeTo: self.statusItem.statusButton)
        }
    }

    private func warnIfScreenieRunning() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "noah.SimpleScreen")
        guard !running.isEmpty else { return false }
        Log.app.warning("screenie is running, both apps may rewrite screencapture location")

        let key = "didWarnAboutScreenie"
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.async {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L10n.Menu.screenieTitle
            alert.informativeText = L10n.Menu.screenieBody
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.Common.ok)
            alert.runModal()
        }
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.Menu.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.Menu.edit)
        editMenu.addItem(withTitle: L10n.Menu.undo, action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.Menu.redo, action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.Menu.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.Menu.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.Menu.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.Menu.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.Menu.window)
        windowMenu.addItem(withTitle: L10n.Menu.close, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        Log.app.info("main menu installed language=\(LocalizationCenter.shared.language.rawValue, privacy: .public)")
    }
}

extension AppDelegate: StatusItemControllerDelegate {
    func statusItemToggleGallery(wasVisibleAtPress: Bool, statusButton: NSStatusBarButton?) {
        gallery.toggle(wasVisibleAtPress: wasVisibleAtPress, statusButton: statusButton)
    }

    func statusItemIsGalleryVisible() -> Bool {
        gallery.isVisible
    }

    func statusItemMenu() -> NSMenu {
        menuController.buildMenu()
    }
}
