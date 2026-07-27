import Foundation
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

enum Telemetry {
    private static let configResource = "GoogleService-Info"
    private static let configExtension = "plist"
    private static let launchEvent = "app_launch"

    private static var didAttemptStart = false

    static func start() {
        guard !didAttemptStart else {
            Log.telemetry.debug("start skipped reason=already_attempted")
            return
        }
        didAttemptStart = true

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

        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        Analytics.setAnalyticsCollectionEnabled(true)
        Analytics.logEvent(launchEvent, parameters: nil)

        Log.telemetry.info("started project=\(options.projectID ?? "unknown", privacy: .public) crashlytics=enabled analytics=enabled")
    }
}
