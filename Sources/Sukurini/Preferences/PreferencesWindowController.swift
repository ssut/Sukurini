import AppKit
import SwiftUI

extension Notification.Name {
    static let sukuriniPreferencesWillShow = Notification.Name("sukurini.preferencesWillShow")
}

final class PreferencesWindowController: NSObject {
    fileprivate static let policyHolder = "preferences"

    private enum Layout {
        static let width: CGFloat = 520
        static let minWidth: CGFloat = 460
        static let minHeight: CGFloat = 420
        static let fallbackHeight: CGFloat = 820
        static let probeHeight: CGFloat = 3000
        static let screenMargin: CGFloat = 80
    }

    var ocrProgressProvider: (() -> (done: Int, total: Int))?
    weak var backfillController: BackfillControlling?
    weak var organizeController: OrganizeControlling?
    weak var semanticController: SemanticCoordinator?

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var appliedContentSize: NSSize?

    override init() {
        super.init()
        observeLanguage()
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    private func observeLanguage() {
        languageObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniLanguageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let window = self?.window else { return }
            window.title = L10n.Window.preferences
            Log.settings.info("preferences window title relocalized language=\(LocalizationCenter.shared.language.rawValue, privacy: .public)")
        }
    }

    func show() {
        AppSettings.shared.ensureSystemCaptureFolderListed()

        let reused = window != nil
        let target = window ?? makeWindow()
        window = target
        if reused {
            refitIfUntouched(target)
        }

        ActivationPolicyCoordinator.acquireRegular(Self.policyHolder)
        NotificationCenter.default.post(name: .sukuriniPreferencesWillShow, object: self)

        NSApp.activate()
        if target.isMiniaturized {
            Log.settings.info("preferences deminiaturizing on show")
            target.deminiaturize(nil)
        }
        target.makeKeyAndOrderFront(nil)
        Log.settings.info("preferences window shown reused=\(reused, privacy: .public) policy=\(Self.policyName(NSApp.activationPolicy()), privacy: .public) key=\(target.isKeyWindow, privacy: .public)")

        reassertFront(target)
    }

    @discardableResult
    func bringToFront() -> Bool {
        guard let window, window.isVisible || window.isMiniaturized else {
            Log.settings.info("preferences reopen not handled reason=no_open_window exists=\(self.window != nil, privacy: .public)")
            return false
        }

        ActivationPolicyCoordinator.acquireRegular(Self.policyHolder)

        if window.isMiniaturized {
            Log.settings.info("preferences deminiaturizing on reopen")
            window.deminiaturize(nil)
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Log.settings.info("preferences reopen handled key=\(window.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public) policy=\(Self.policyName(NSApp.activationPolicy()), privacy: .public)")

        reassertFront(window)
        return true
    }

    private func reassertFront(_ target: NSWindow) {
        DispatchQueue.main.async { [weak target] in
            guard let target else { return }
            guard target.isVisible || target.isMiniaturized else {
                Log.settings.info("preferences front reassert skipped reason=not_visible")
                return
            }
            if target.isKeyWindow, NSApp.isActive {
                Log.settings.info("preferences already front policy=\(PreferencesWindowController.policyName(NSApp.activationPolicy()), privacy: .public)")
                return
            }
            NSApp.activate()
            target.makeKeyAndOrderFront(nil)
            target.orderFrontRegardless()
            Log.settings.info("preferences front reasserted key=\(target.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public) policy=\(PreferencesWindowController.policyName(NSApp.activationPolicy()), privacy: .public)")
        }
    }

    private func makeRootView() -> PreferencesView {
        PreferencesView(
            ocrProgressProvider: { [weak self] in self?.ocrProgressProvider?() },
            backfillProvider: { [weak self] in self?.backfillController },
            organizeProvider: { [weak self] in self?.organizeController },
            semanticProvider: { [weak self] in self?.semanticController }
        )
    }

    private func refitIfUntouched(_ window: NSWindow) {
        guard !window.isVisible, !window.isMiniaturized else {
            Log.settings.debug("preferences refit skipped reason=window_onscreen visible=\(window.isVisible, privacy: .public) miniaturized=\(window.isMiniaturized, privacy: .public)")
            return
        }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard let applied = appliedContentSize else { return }
        guard abs(current.width - applied.width) < 1, abs(current.height - applied.height) < 1 else {
            Log.settings.info("preferences refit skipped reason=user_resized current=\(Int(current.width), privacy: .public)x\(Int(current.height), privacy: .public) applied=\(Int(applied.width), privacy: .public)x\(Int(applied.height), privacy: .public)")
            return
        }
        let height = Self.resolvedHeight(for: makeRootView())
        guard abs(height - current.height) >= 1 else {
            Log.settings.debug("preferences refit unnecessary height=\(Int(height), privacy: .public)")
            return
        }
        applyContentHeight(height, to: window)
        Log.settings.info("preferences refit applied from=\(Int(current.height), privacy: .public) to=\(Int(height), privacy: .public)")
    }

    private func applyContentHeight(_ height: CGFloat, to window: NSWindow) {
        let top = window.frame.maxY
        let width = window.contentRect(forFrameRect: window.frame).width
        window.setContentSize(NSSize(width: width, height: height))
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: false)
        appliedContentSize = window.contentRect(forFrameRect: window.frame).size
    }

    private func makeWindow() -> NSWindow {
        let rootView = makeRootView()
        let height = Self.resolvedHeight(for: rootView)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: Layout.width, height: height)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.Window.preferences
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("sukurini.preferences")
        window.contentView = hosting
        window.contentMinSize = NSSize(width: Layout.minWidth, height: Layout.minHeight)
        window.setContentSize(NSSize(width: Layout.width, height: height))
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        appliedContentSize = window.contentRect(forFrameRect: window.frame).size
        observeClose(of: window)
        Log.settings.info("preferences window created width=\(Int(Layout.width), privacy: .public) height=\(Int(height), privacy: .public)")
        return window
    }

    private static func resolvedHeight(for view: PreferencesView) -> CGFloat {
        let probe = NSHostingView(rootView: view)
        probe.sizingOptions = [.intrinsicContentSize]
        probe.frame = NSRect(x: 0, y: 0, width: Layout.width, height: Layout.probeHeight)
        probe.layoutSubtreeIfNeeded()
        let intrinsic = probe.intrinsicContentSize.height
        let fitting = probe.fittingSize.height
        let natural = [intrinsic, fitting]
            .filter { $0.isFinite && $0 > Layout.minHeight && $0 < Layout.probeHeight }
            .max()
        let ceiling = max(Layout.minHeight, screenBudget())
        let resolved = min((natural ?? Layout.fallbackHeight).rounded(.up), ceiling)
        Log.settings.info("preferences height resolved intrinsic=\(Int(intrinsic), privacy: .public) fitting=\(Int(fitting), privacy: .public) natural=\(Int(natural ?? -1), privacy: .public) ceiling=\(Int(ceiling), privacy: .public) resolved=\(Int(resolved), privacy: .public)")
        return resolved
    }

    private static func screenBudget() -> CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame.height else {
            Log.settings.info("preferences screen budget unavailable, using fallback")
            return Layout.fallbackHeight
        }
        return visible - Layout.screenMargin
    }

    private func observeClose(of window: NSWindow) {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            Log.settings.info("preferences window closed policy=\(PreferencesWindowController.policyName(NSApp.activationPolicy()), privacy: .public)")
            DispatchQueue.main.async {
                if let window, window.isVisible {
                    Log.settings.info("activation policy restore skipped reason=window_visible_again")
                    return
                }
                ActivationPolicyCoordinator.release(PreferencesWindowController.policyHolder)
            }
        }
    }

    private static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown(\(policy.rawValue))"
        }
    }
}
