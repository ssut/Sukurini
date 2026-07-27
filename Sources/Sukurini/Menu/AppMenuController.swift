import AppKit

final class AppMenuController: NSObject {
    private static let aboutHolder = "about"
    private static let authorName = "Suhun Han (ssut)"
    private static let authorURL = "https://github.com/ssut"

    private let settings = AppSettings.shared
    private var aboutWindow: NSWindow?
    private var aboutCloseObserver: NSObjectProtocol?

    var onShowPreferences: (() -> Void)?
    var onShowOnboarding: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let preferences = NSMenuItem(title: L10n.Menu.preferences, action: #selector(showPreferences), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        menu.addItem(.separator())

        let folders = NSMenuItem(title: L10n.Menu.folders, action: nil, keyEquivalent: "")
        folders.submenu = buildFoldersMenu()
        menu.addItem(folders)

        menu.addItem(.separator())

        let setup = NSMenuItem(title: L10n.Menu.setupGuide, action: #selector(showOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let updates = NSMenuItem(title: L10n.Menu.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let about = NSMenuItem(title: L10n.Menu.about, action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: L10n.Menu.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func buildFoldersMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let active = settings.activeFolder
        let folders = settings.folders

        if folders.isEmpty {
            let empty = NSMenuItem(title: L10n.Menu.noFolders, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }

        for folder in folders {
            let item = NSMenuItem(title: folder.lastPathComponent, action: #selector(selectFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            item.state = folder.path == active?.path ? .on : .off
            item.toolTip = folder.path
            if !FileManager.default.fileExists(atPath: folder.path) {
                item.title = L10n.Menu.folderMissing(folder.lastPathComponent)
            }
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let add = NSMenuItem(title: L10n.Menu.addFolder, action: #selector(addFolder), keyEquivalent: "")
        add.target = self
        submenu.addItem(add)

        return submenu
    }

    @objc private func selectFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        Log.app.info("menu selected folder path=\(folder.path, privacy: .public)")
        settings.activeFolder = folder
    }

    @objc private func addFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Menu.watchFolderPrompt
        panel.message = L10n.Menu.watchFolderMessage
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.app.debug("add folder cancelled")
            return
        }
        Log.app.info("menu added folder path=\(url.path, privacy: .public)")
        settings.addFolder(url)
    }

    @objc private func showPreferences() {
        Log.app.info("menu opened preferences")
        onShowPreferences?()
    }

    @objc private func showOnboarding() {
        Log.app.info("menu opened onboarding")
        onShowOnboarding?()
    }

    @objc private func checkForUpdates() {
        Log.app.info("menu requested update check")
        onCheckForUpdates?()
    }

    @objc private func showAbout() {
        ActivationPolicyCoordinator.acquireRegular(AppMenuController.aboutHolder)
        NSApp.activate()

        let known = Set(NSApp.windows.map { ObjectIdentifier($0) })
        NSApp.orderFrontStandardAboutPanel(options: [.credits: AppMenuController.aboutCredits()])

        if aboutWindow == nil {
            aboutWindow = NSApp.windows.first { !known.contains(ObjectIdentifier($0)) }
            if let window = aboutWindow {
                window.isReleasedWhenClosed = false
                window.level = .floating
                window.collectionBehavior.insert(.moveToActiveSpace)
                observeAboutClose(of: window)
            }
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        Log.app.info("about shown resolved=\(self.aboutWindow != nil, privacy: .public)")
        reassertAboutFront()
    }

    @discardableResult
    func bringAboutToFront() -> Bool {
        guard let window = aboutWindow, window.isVisible || window.isMiniaturized else {
            Log.app.info("about reopen not handled reason=no_open_window exists=\(self.aboutWindow != nil, privacy: .public)")
            return false
        }

        ActivationPolicyCoordinator.acquireRegular(Self.aboutHolder)

        if window.isMiniaturized {
            Log.app.info("about deminiaturizing on reopen")
            window.deminiaturize(nil)
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Log.app.info("about reopen handled key=\(window.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public)")

        reassertAboutFront()
        return true
    }

    private func reassertAboutFront() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.aboutWindow, window.isVisible || window.isMiniaturized else { return }
            if window.isKeyWindow, NSApp.isActive {
                Log.app.info("about already front")
                return
            }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            Log.app.info("about front reasserted key=\(window.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public)")
        }
    }

    private static func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSMutableAttributedString(
            string: "\(L10n.Menu.aboutTagline)\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )

        var authorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .paragraphStyle: paragraph
        ]
        if let url = URL(string: authorURL) {
            authorAttributes[.link] = url
        }
        credits.append(NSAttributedString(string: authorName, attributes: authorAttributes))

        return credits
    }

    private func observeAboutClose(of window: NSWindow) {
        aboutCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            ActivationPolicyCoordinator.release(AppMenuController.aboutHolder)
            Log.app.info("about closed")
        }
    }

    @objc private func quit() {
        Log.app.info("menu requested quit")
        NSApp.terminate(nil)
    }
}
