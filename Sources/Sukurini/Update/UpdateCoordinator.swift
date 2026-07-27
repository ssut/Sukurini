import AppKit
import Sparkle

final class UpdateCoordinator: NSObject {
    enum Availability: Equatable {
        case ready
        case notBundled
        case feedMissing
        case keyMissing
        case startFailed(String)

        var isReady: Bool {
            self == .ready
        }

        var reason: String {
            switch self {
            case .ready:
                return "ready"
            case .notBundled:
                return "not_bundled"
            case .feedMissing:
                return "feed_url_missing"
            case .keyMissing:
                return "public_key_missing"
            case .startFailed:
                return "start_failed"
            }
        }

        var explanation: String? {
            switch self {
            case .ready:
                return nil
            case .notBundled:
                return L10n.Updates.notBundled
            case .feedMissing:
                return L10n.Updates.feedMissing
            case .keyMissing:
                return L10n.Updates.keyMissing
            case .startFailed(let detail):
                return L10n.Updates.startFailed(detail)
            }
        }
    }

    static let shared = UpdateCoordinator()

    private static let feedKey = "SUFeedURL"
    private static let publicKeyKey = "SUPublicEDKey"

    private let settings = AppSettings.shared
    private var controller: SPUStandardUpdaterController?
    private var channelObserver: NSObjectProtocol?

    private(set) var availability: Availability = .notBundled

    private var updater: SPUUpdater? {
        controller?.updater
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    var lastUpdateCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    var automaticChecksEnabled: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            guard let updater else {
                Log.update.notice("automatic checks ignored reason=\(self.availability.reason, privacy: .public)")
                return
            }
            guard updater.automaticallyChecksForUpdates != newValue else { return }
            updater.automaticallyChecksForUpdates = newValue
            Log.update.info("automatic checks updated value=\(newValue, privacy: .public)")
        }
    }

    func start() {
        guard Thread.isMainThread else {
            Log.update.error("start skipped reason=not_main_thread")
            return
        }
        guard controller == nil else {
            Log.update.debug("start skipped reason=already_started")
            return
        }

        availability = Self.resolveConfiguration()
        guard availability.isReady else {
            Log.update.notice("updater inactive reason=\(self.availability.reason, privacy: .public)")
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        do {
            try controller.updater.start()
        } catch {
            availability = .startFailed(error.localizedDescription)
            Log.update.error("updater start failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        self.controller = controller
        observeChannelChanges()

        Log.update.info("updater started channel=\(self.settings.updateChannel.rawValue, privacy: .public) automatic=\(controller.updater.automaticallyChecksForUpdates, privacy: .public) interval=\(Int(controller.updater.updateCheckInterval), privacy: .public) version=\(self.currentVersion, privacy: .public)")
    }

    func checkForUpdates() {
        guard let updater else {
            Log.update.notice("manual check refused reason=\(self.availability.reason, privacy: .public)")
            presentUnavailableAlert()
            return
        }
        guard updater.canCheckForUpdates else {
            Log.update.notice("manual check refused reason=check_in_progress")
            return
        }
        Log.update.info("manual check requested channel=\(self.settings.updateChannel.rawValue, privacy: .public)")
        updater.checkForUpdates()
    }

    private func observeChannelChanges() {
        channelObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniUpdateChannelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyChannelChange()
        }
    }

    private func applyChannelChange() {
        guard let updater else { return }
        let channel = settings.updateChannel
        updater.resetUpdateCycle()
        Log.update.info("update cycle reset reason=channel_changed channel=\(channel.rawValue, privacy: .public) allowed=\(channel.allowedSparkleChannels.sorted().joined(separator: ","), privacy: .public)")
    }

    private func presentUnavailableAlert() {
        guard let explanation = availability.explanation else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.Updates.unavailableTitle
        alert.informativeText = explanation
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }

    private static func resolveConfiguration() -> Availability {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notBundled }

        let feed = Bundle.main.object(forInfoDictionaryKey: feedKey) as? String ?? ""
        guard !feed.isEmpty, URL(string: feed) != nil else { return .feedMissing }

        let key = Bundle.main.object(forInfoDictionaryKey: publicKeyKey) as? String ?? ""
        guard !key.isEmpty else { return .keyMissing }

        return .ready
    }
}

extension UpdateCoordinator: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channels = settings.updateChannel.allowedSparkleChannels
        Log.update.info("allowed channels resolved channel=\(self.settings.updateChannel.rawValue, privacy: .public) allowed=\(channels.sorted().joined(separator: ","), privacy: .public)")
        return channels
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.update.info("update found version=\(item.displayVersionString, privacy: .public) build=\(item.versionString, privacy: .public) channel=\(item.channel ?? "default", privacy: .public)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.update.info("no update available current=\(self.currentVersion, privacy: .public) channel=\(self.settings.updateChannel.rawValue, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        guard code != Int(Sparkle.SUError.noUpdateError.rawValue) else {
            Log.update.debug("update cycle finished reason=no_update")
            return
        }
        Log.update.error("update aborted code=\(code, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Log.update.info("installing update version=\(item.displayVersionString, privacy: .public) channel=\(item.channel ?? "default", privacy: .public)")
    }
}
