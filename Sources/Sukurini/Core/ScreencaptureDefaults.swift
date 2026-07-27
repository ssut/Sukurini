import CoreGraphics
import Foundation

enum ScreencaptureDefaults {
    private static let domain = "com.apple.screencapture" as CFString
    private static let locationKey = "location" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    private static let nameKey = "name" as CFString
    private static let captureAgent = "screencaptureui"

    static func currentLocation() -> URL? {
        refresh()
        guard let raw = CFPreferencesCopyAppValue(locationKey, domain) as? String, !raw.isEmpty else {
            Log.system.debug("screencapture location unset, falling back to Desktop")
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Log.system.error("screencapture location missing on disk path=\(url.path, privacy: .public)")
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        return url
    }

    @discardableResult
    static func setLocation(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Log.system.error("refusing to set screencapture location, not a directory path=\(resolved.path, privacy: .public)")
            return false
        }
        CFPreferencesSetValue(
            locationKey,
            resolved.path as CFString,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let synced = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        Log.system.info("screencapture location set path=\(resolved.path, privacy: .public) synced=\(synced, privacy: .public)")
        restartCaptureAgent(reason: "location")
        return synced
    }

    static func nameTemplate() -> String? {
        refresh()
        guard let raw = CFPreferencesCopyAppValue(nameKey, domain) as? String, !raw.isEmpty else {
            Log.system.debug("screencapture name prefix unset")
            return nil
        }
        Log.system.debug("screencapture name prefix read value=\(raw, privacy: .public)")
        return raw
    }

    static func showsThumbnail() -> Bool {
        refresh()
        guard let raw = CFPreferencesCopyAppValue(thumbnailKey, domain) else {
            Log.system.debug("screencapture show-thumbnail unset, treating as enabled")
            return true
        }
        guard let number = raw as? NSNumber else {
            Log.system.error("screencapture show-thumbnail unexpected type, treating as enabled")
            return true
        }
        let value = number.boolValue
        Log.system.debug("screencapture show-thumbnail read value=\(value, privacy: .public)")
        return value
    }

    @discardableResult
    static func setShowsThumbnail(_ enabled: Bool) -> Bool {
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetValue(
            thumbnailKey,
            value,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let synced = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        Log.system.info("screencapture show-thumbnail set value=\(enabled, privacy: .public) synced=\(synced, privacy: .public)")
        restartCaptureAgent(reason: "show_thumbnail")
        return synced
    }

    private static func refresh() {
        let synced = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard !synced else { return }
        Log.system.debug("screencapture preference refresh reported no change")
    }

    private static func captureAgentIsOnScreen() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            Log.system.debug("window list unavailable, treating capture agent as idle")
            return false
        }
        let ownerKey = kCGWindowOwnerName as String
        let owned = windows.filter { ($0[ownerKey] as? String) == captureAgent }.count
        guard owned > 0 else { return false }
        Log.system.info("capture agent has onscreen windows count=\(owned, privacy: .public)")
        return true
    }

    private static func restartCaptureAgent(reason: String) {
        guard !captureAgentIsOnScreen() else {
            Log.system.info("capture agent restart skipped reason=\(reason, privacy: .public) cause=onscreen_ui")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [captureAgent]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let status = process.terminationStatus
            Log.system.info("killall capture agent reason=\(reason, privacy: .public) status=\(status, privacy: .public) wasRunning=\(status == 0, privacy: .public)")
        } catch {
            Log.system.error("killall capture agent failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
