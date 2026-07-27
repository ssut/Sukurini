import Foundation
import ServiceManagement

enum LoginItem {
    enum Failure: LocalizedError {
        case notInstalledInApplications

        var errorDescription: String? {
            switch self {
            case .notInstalledInApplications:
                return "Move Sukurini to /Applications to enable launch at login."
            }
        }
    }

    static var isAvailable: Bool {
        guard isBundledApp else {
            Log.settings.debug("login item unavailable reason=not_an_app_bundle path=\(bundlePath, privacy: .public)")
            return false
        }
        let path = bundlePath
        let roots = installRoots()
        let installed = roots.contains { path.hasPrefix($0 + "/") }
        if !installed {
            Log.settings.debug("login item unavailable reason=outside_applications path=\(path, privacy: .public)")
        }
        return installed
    }

    static var isEnabled: Bool {
        currentStatus == .enabled
    }

    static var requiresApproval: Bool {
        currentStatus == .requiresApproval
    }

    static var statusDescription: String {
        description(for: currentStatus)
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable || !enabled else {
            Log.settings.error("login item register refused reason=outside_applications path=\(bundlePath, privacy: .public)")
            throw Failure.notInstalledInApplications
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            Log.settings.info("login item updated enabled=\(enabled, privacy: .public) status=\(description(for: service.status), privacy: .public)")
        } catch {
            Log.settings.error("login item update failed enabled=\(enabled, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    static func openSystemSettings() {
        Log.settings.info("opening login items pane in system settings")
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var bundlePath: String {
        Bundle.main.bundleURL.standardizedFileURL.path
    }

    private static var isBundledApp: Bool {
        let hasAppExtension = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        let hasIdentifier = (Bundle.main.bundleIdentifier ?? "").isEmpty == false
        return hasAppExtension && hasIdentifier
    }

    private static var currentStatus: SMAppService.Status {
        guard isBundledApp else {
            Log.settings.debug("login item status skipped reason=not_an_app_bundle path=\(bundlePath, privacy: .public)")
            return .notFound
        }
        return SMAppService.mainApp.status
    }

    private static func installRoots() -> [String] {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
        let candidates = [
            system.path,
            system.resolvingSymlinksInPath().path,
            user.path,
            user.resolvingSymlinksInPath().path
        ]
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func description(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return L10n.Startup.statusNotRegistered
        case .enabled:
            return L10n.Startup.statusEnabled
        case .requiresApproval:
            return L10n.Startup.statusRequiresApproval
        case .notFound:
            return L10n.Startup.statusNotFound
        @unknown default:
            return L10n.Startup.statusUnknown(status.rawValue)
        }
    }
}
