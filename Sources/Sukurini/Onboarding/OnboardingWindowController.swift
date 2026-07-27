import AppKit
import SwiftUI

final class OnboardingWindowController: NSObject {
    enum Presentation: String {
        case firstLaunch
        case development
        case environment
        case manual
    }

    private static let policyHolder = "onboarding"
    private static let environmentKey = "SUKURINI_ONBOARDING"
    private static let alwaysPresentDuringDevelopment = false

    private let coordinator = OnboardingCoordinator()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var lastPresentation: Presentation?

    var onFinished: ((Presentation) -> Void)?

    var backfillController: BackfillControlling? {
        get { coordinator.backfillController }
        set { coordinator.backfillController = newValue }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    static func launchPresentation() -> Presentation? {
        let settings = AppSettings.shared
        let override = ProcessInfo.processInfo.environment[environmentKey]?.lowercased()
        switch override {
        case "always":
            Log.app.info("onboarding presentation forced by environment value=always")
            return .environment
        case "never":
            Log.app.info("onboarding presentation suppressed by environment value=never")
            return nil
        default:
            break
        }
        guard settings.hasCompletedOnboarding else {
            Log.app.info("onboarding pending firstLaunch=\(settings.isFirstLaunch, privacy: .public) launches=\(settings.launchCount, privacy: .public)")
            return .firstLaunch
        }
        guard alwaysPresentDuringDevelopment else {
            Log.app.info("onboarding skipped reason=already_completed epoch=\(Int(settings.onboardingCompletedAt?.timeIntervalSince1970 ?? 0), privacy: .public)")
            return nil
        }
        Log.app.info("onboarding presented again reason=development_always_on")
        return .development
    }

    func show(reason: Presentation) {
        let reused = window != nil
        let target = window ?? makeWindow(reason: reason)
        window = target
        lastPresentation = reason

        if reused, !target.isVisible {
            target.contentView = makeHostingView(reason: reason)
            Log.app.info("onboarding content rebuilt reason=\(reason.rawValue, privacy: .public)")
        }

        ActivationPolicyCoordinator.acquireRegular(Self.policyHolder)
        NSApp.activate()
        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        target.center()
        target.makeKeyAndOrderFront(nil)
        Log.app.info("onboarding window shown reason=\(reason.rawValue, privacy: .public) reused=\(reused, privacy: .public) key=\(target.isKeyWindow, privacy: .public)")

        reassertFront(target)
    }

    @discardableResult
    func bringToFront() -> Bool {
        guard let window, window.isVisible || window.isMiniaturized else { return false }
        ActivationPolicyCoordinator.acquireRegular(Self.policyHolder)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Log.app.info("onboarding reopen handled key=\(window.isKeyWindow, privacy: .public)")
        reassertFront(window)
        return true
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    private func makeWindow(reason: Presentation) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.Layout.width, height: OnboardingView.Layout.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.Window.onboarding
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("sukurini.onboarding")
        window.contentView = makeHostingView(reason: reason)
        window.setContentSize(NSSize(width: OnboardingView.Layout.width, height: OnboardingView.Layout.height))
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        observeClose(of: window)
        Log.app.info("onboarding window created width=\(Int(OnboardingView.Layout.width), privacy: .public) height=\(Int(OnboardingView.Layout.height), privacy: .public)")
        return window
    }

    private func makeHostingView(reason: Presentation) -> NSHostingView<OnboardingView> {
        let rootView = OnboardingView(
            presentation: reason,
            coordinator: coordinator,
            backfillProvider: { [weak self] in self?.coordinator.backfillController },
            onFinish: { [weak self] in self?.dismiss(reason: "finished") }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: OnboardingView.Layout.width, height: OnboardingView.Layout.height)
        return hosting
    }

    private func dismiss(reason: String) {
        guard let window else { return }
        Log.app.info("onboarding dismiss requested reason=\(reason, privacy: .public)")
        window.performClose(nil)
    }

    private func reassertFront(_ target: NSWindow) {
        DispatchQueue.main.async { [weak target] in
            guard let target, target.isVisible else { return }
            guard !target.isKeyWindow || !NSApp.isActive else { return }
            NSApp.activate()
            target.makeKeyAndOrderFront(nil)
            target.orderFrontRegardless()
            Log.app.info("onboarding front reasserted key=\(target.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public)")
        }
    }

    private func observeClose(of window: NSWindow) {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.coordinator.complete(reason: "window_closed")
            let reason = self.lastPresentation
            self.lastPresentation = nil
            Log.app.info("onboarding window closed presentation=\(reason?.rawValue ?? "unknown", privacy: .public)")
            DispatchQueue.main.async {
                ActivationPolicyCoordinator.release(OnboardingWindowController.policyHolder)
                guard let reason else { return }
                self.onFinished?(reason)
            }
        }
    }
}
