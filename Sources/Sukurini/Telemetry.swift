import Foundation
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

enum TelemetryEvent: String {
    case appLaunch = "app_launch"
    case screenshotDetected = "screenshot_detected"
    case settingChanged = "setting_changed"
    case screenshotCopied = "screenshot_copied"
    case galleryOpened = "gallery_opened"
    case gallerySearched = "gallery_searched"
    case gallerySearchSelected = "gallery_search_selected"
    case galleryCopied = "gallery_copied"
}

enum Telemetry {
    private static let configResource = "GoogleService-Info"
    private static let configExtension = "plist"
    private static let startReason = "start"

    private static let lock = NSLock()
    private static var didAttemptStart = false
    private static var isConfigured = false
    private static var isCollecting = false
    private static var settingObserver: NSObjectProtocol?

    static func start() {
        lock.lock()
        let alreadyAttempted = didAttemptStart
        didAttemptStart = true
        lock.unlock()

        guard !alreadyAttempted else {
            Log.telemetry.debug("start skipped reason=already_attempted")
            return
        }

        guard Thread.isMainThread else {
            Log.telemetry.error("start skipped reason=not_main_thread")
            return
        }

        guard FirebaseApp.app() == nil else {
            Log.telemetry.notice("start skipped reason=already_configured")
            return
        }

        let isBundled = Bundle.main.bundleURL.pathExtension == "app"

        guard let configPath = Bundle.main.path(forResource: configResource, ofType: configExtension) else {
            Log.telemetry.notice("start skipped reason=config_absent bundled=\(isBundled, privacy: .public)")
            return
        }

        guard let options = FirebaseOptions(contentsOfFile: configPath) else {
            Log.telemetry.error("start skipped reason=config_unreadable bundled=\(isBundled, privacy: .public)")
            return
        }

        guard !options.googleAppID.isEmpty else {
            Log.telemetry.error("start skipped reason=config_missing_app_id")
            return
        }

        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            Log.telemetry.error("start skipped reason=missing_bundle_id")
            return
        }

        if options.bundleID != bundleID {
            Log.telemetry.error("start skipped reason=bundle_id_mismatch expected=\(options.bundleID, privacy: .public) actual=\(bundleID, privacy: .public)")
            return
        }

        FirebaseApp.configure(options: options)

        guard FirebaseApp.app() != nil else {
            Log.telemetry.error("start failed reason=configure_produced_no_app")
            return
        }

        Analytics.setUserID(nil)

        lock.lock()
        isConfigured = true
        lock.unlock()

        observeSetting()
        applyCollectionSetting(reason: Self.startReason)

        Log.telemetry.info("started project=\(options.projectID ?? "unknown", privacy: .public) collection=\(AppSettings.shared.analyticsEnabled, privacy: .public)")

        logLaunch()
    }

    static func log(_ event: TelemetryEvent, _ parameters: [String: String] = [:]) {
        lock.lock()
        let allowed = isCollecting
        lock.unlock()

        guard allowed else {
            Log.telemetry.debug("event dropped name=\(event.rawValue, privacy: .public) reason=collection_off")
            return
        }

        Analytics.logEvent(event.rawValue, parameters: parameters.isEmpty ? nil : parameters)
        Log.telemetry.debug("event logged name=\(event.rawValue, privacy: .public) params=\(describe(parameters), privacy: .public)")
    }

    static func bucket(_ value: Int) -> String {
        switch value {
        case ..<1: return "0"
        case 1: return "1"
        case 2...5: return "2_5"
        case 6...10: return "6_10"
        case 11...25: return "11_25"
        case 26...50: return "26_50"
        case 51...100: return "51_100"
        case 101...500: return "101_500"
        default: return "500_plus"
        }
    }

    static func flag(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    private static func observeSetting() {
        guard settingObserver == nil else { return }
        settingObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniAnalyticsEnabledChanged,
            object: nil,
            queue: .main
        ) { _ in
            applyCollectionSetting(reason: "settings")
        }
        Log.telemetry.debug("observing analytics setting")
    }

    private static func applyCollectionSetting(reason: String) {
        let enabled = AppSettings.shared.analyticsEnabled

        lock.lock()
        let configured = isConfigured
        let wasCollecting = isCollecting
        isCollecting = configured && enabled
        lock.unlock()

        guard configured else {
            Log.telemetry.debug("collection change ignored reason=not_configured desired=\(enabled, privacy: .public)")
            return
        }

        /* Crash reporting rides the same switch as analytics. Two toggles would
           mean explaining which one covers what, and one that quietly stays on
           is worse than no switch at all. */
        Analytics.setConsent([
            .analyticsStorage: enabled ? .granted : .denied,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied
        ])
        Analytics.setAnalyticsCollectionEnabled(enabled)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)

        if !enabled, wasCollecting {
            Analytics.resetAnalyticsData()
            Log.telemetry.notice("analytics data reset after opt out")
        }

        Log.telemetry.info("collection applied value=\(enabled, privacy: .public) analytics=\(enabled, privacy: .public) crashlytics=\(enabled, privacy: .public) reason=\(reason, privacy: .public)")

        guard enabled, !wasCollecting, reason != Self.startReason else { return }
        log(.settingChanged, ["setting": "analytics", "state": flag(true)])
    }

    private static func logLaunch() {
        let settings = AppSettings.shared
        log(.appLaunch, [
            "first_launch": flag(settings.isFirstLaunch),
            "launches": bucket(settings.launchCount),
            "language": LocalizationCenter.shared.language.rawValue,
            "folders": bucket(settings.folders.count),
            "ocr": flag(settings.ocrEnabled),
            "semantic": flag(settings.semanticSearchEnabled),
            "webp": flag(settings.webpConversionEnabled),
            "organize": flag(settings.organizeEnabled),
            "dock": flag(settings.alwaysShowInDock),
            "hotkey": flag(settings.galleryHotKey != nil),
            "paste_hotkey": flag(settings.pasteLatestHotKey != nil)
        ])
    }

    private static func describe(_ parameters: [String: String]) -> String {
        guard !parameters.isEmpty else { return "none" }
        return parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}
