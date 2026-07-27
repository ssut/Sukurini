import Foundation

extension Notification.Name {
    static let sukuriniFoldersChanged = Notification.Name("sukurini.foldersChanged")
    static let sukuriniActiveFolderChanged = Notification.Name("sukurini.activeFolderChanged")
    static let sukuriniOCREnabledChanged = Notification.Name("sukurini.ocrEnabledChanged")
    static let sukuriniOCRProgressChanged = Notification.Name("sukurini.ocrProgressChanged")
    static let sukuriniOCRPowerPolicyChanged = Notification.Name("sukurini.ocrPowerPolicyChanged")
    static let sukuriniHotKeyChanged = Notification.Name("sukurini.hotKeyChanged")
    static let sukuriniWebPConversionChanged = Notification.Name("sukurini.webpConversionChanged")
    static let sukuriniWebPBackfillProgressChanged = Notification.Name("sukurini.webpBackfillProgressChanged")
    static let sukuriniOrganizeChanged = Notification.Name("sukurini.organizeChanged")
    static let sukuriniIncludeSubfoldersChanged = Notification.Name("sukurini.includeSubfoldersChanged")
    static let sukuriniOrganizeBackfillProgressChanged = Notification.Name("sukurini.organizeBackfillProgressChanged")
    static let sukuriniSemanticEnabledChanged = Notification.Name("sukurini.semanticEnabledChanged")
    static let sukuriniSemanticModelChanged = Notification.Name("sukurini.semanticModelChanged")
    static let sukuriniSemanticStateChanged = Notification.Name("sukurini.semanticStateChanged")
    static let sukuriniDockVisibilityChanged = Notification.Name("sukurini.dockVisibilityChanged")
    static let sukuriniUpdateChannelChanged = Notification.Name("sukurini.updateChannelChanged")
    static let sukuriniAnalyticsEnabledChanged = Notification.Name("sukurini.analyticsEnabledChanged")
}

struct HotKeyBinding: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
}

final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let folders = "folders"
        static let activeFolder = "activeFolder"
        static let ocrEnabled = "ocrEnabled"
        static let lazyIndexOnBattery = "lazyIndexOnBattery"
        static let pauseIndexingOnLowPower = "pauseIndexingOnLowPower"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let webpConversionEnabled = "webpConversionEnabled"
        static let webpConversionEnabledAt = "webpConversionEnabledAt"
        static let webpDisposal = "webpDisposal"
        static let copyAsPNGEnabled = "copyAsPNGEnabled"
        static let organizeEnabled = "organizeEnabled"
        static let organizeFormat = "organizeFormat"
        static let includeSubfolders = "includeSubfolders"
        static let semanticEnabled = "semanticSearchEnabled"
        static let semanticModel = "semanticModel"
        static let alwaysShowInDock = "alwaysShowInDock"
        static let gallerySortOrder = "gallerySortOrder"
        static let firstLaunchedAt = "firstLaunchedAt"
        static let launchCount = "launchCount"
        static let onboardingCompletedAt = "onboardingCompletedAt"
        static let updateChannel = "updateChannel"
        static let analyticsEnabled = "analyticsEnabled"
    }

    private let defaults: UserDefaults

    private static let legacyDomain = "com.suhunhan.sukurini"

    private static let migratableKeys = [
        Key.folders,
        Key.activeFolder,
        Key.ocrEnabled,
        Key.lazyIndexOnBattery,
        Key.pauseIndexingOnLowPower,
        Key.hotKeyCode,
        Key.hotKeyModifiers,
        Key.organizeEnabled,
        Key.organizeFormat,
        Key.includeSubfolders,
        "didWarnAboutScreenie"
    ]

    private(set) var isFirstLaunch = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyDomainIfNeeded()
        recordLaunch()
        seedIfNeeded()
    }

    private func migrateLegacyDomainIfNeeded() {
        guard defaults.object(forKey: Key.folders) == nil else { return }
        guard let legacy = UserDefaults(suiteName: Self.legacyDomain) else { return }
        guard legacy.object(forKey: Key.folders) != nil else { return }

        var moved = 0
        for key in Self.migratableKeys {
            guard let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            moved += 1
        }
        Log.settings.info("migrated settings from legacy domain keys=\(moved, privacy: .public)")
    }

    private func recordChange(_ setting: String, _ state: String) {
        Telemetry.log(.settingChanged, ["setting": setting, "state": state])
    }

    var folders: [URL] {
        get {
            let paths = defaults.stringArray(forKey: Key.folders) ?? []
            return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        set {
            let previous = (defaults.stringArray(forKey: Key.folders) ?? []).count
            var seen = Set<String>()
            let unique = newValue.map { $0.standardizedFileURL }.filter { seen.insert($0.path).inserted }
            defaults.set(unique.map(\.path), forKey: Key.folders)
            Log.settings.info("folders updated count=\(unique.count, privacy: .public)")
            if previous != unique.count { recordChange("folders", Telemetry.bucket(unique.count)) }
            NotificationCenter.default.post(name: .sukuriniFoldersChanged, object: self)
        }
    }

    var activeFolder: URL? {
        get {
            guard let path = defaults.string(forKey: Key.activeFolder), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        set {
            let resolved = newValue?.standardizedFileURL
            defaults.set(resolved?.path ?? "", forKey: Key.activeFolder)
            Log.settings.info("activeFolder updated path=\(resolved?.path ?? "none", privacy: .public)")
            NotificationCenter.default.post(name: .sukuriniActiveFolderChanged, object: self)
        }
    }

    var ocrEnabled: Bool {
        get { defaults.object(forKey: Key.ocrEnabled) as? Bool ?? true }
        set {
            let previous = ocrEnabled
            defaults.set(newValue, forKey: Key.ocrEnabled)
            Log.settings.info("ocrEnabled updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("ocr", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniOCREnabledChanged, object: self)
        }
    }

    var lazyIndexOnBattery: Bool {
        get { defaults.object(forKey: Key.lazyIndexOnBattery) as? Bool ?? true }
        set {
            let previous = lazyIndexOnBattery
            defaults.set(newValue, forKey: Key.lazyIndexOnBattery)
            Log.settings.info("lazyIndexOnBattery updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("battery_lazy_index", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniOCRPowerPolicyChanged, object: self)
        }
    }

    var pauseIndexingOnLowPower: Bool {
        get { defaults.object(forKey: Key.pauseIndexingOnLowPower) as? Bool ?? true }
        set {
            let previous = pauseIndexingOnLowPower
            defaults.set(newValue, forKey: Key.pauseIndexingOnLowPower)
            Log.settings.info("pauseIndexingOnLowPower updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("low_power_pause", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniOCRPowerPolicyChanged, object: self)
        }
    }

    var webpConversionEnabled: Bool {
        get { defaults.object(forKey: Key.webpConversionEnabled) as? Bool ?? false }
        set {
            let previous = defaults.object(forKey: Key.webpConversionEnabled) as? Bool ?? false
            defaults.set(newValue, forKey: Key.webpConversionEnabled)
            if newValue {
                if !previous || webpConversionEnabledAt == nil { stampConversionEnabled() }
            } else {
                defaults.removeObject(forKey: Key.webpConversionEnabledAt)
                Log.settings.info("webpConversionEnabledAt cleared")
            }
            Log.settings.info("webpConversionEnabled updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("webp", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniWebPConversionChanged, object: self)
        }
    }

    var webpConversionEnabledAt: Date? {
        defaults.object(forKey: Key.webpConversionEnabledAt) as? Date
    }

    func ensureConversionTimestamp() {
        guard webpConversionEnabled, webpConversionEnabledAt == nil else { return }
        stampConversionEnabled()
        Log.settings.info("webpConversionEnabledAt seeded for an already-enabled setting, catch-up starts from now")
    }

    private func stampConversionEnabled() {
        let now = Date()
        defaults.set(now, forKey: Key.webpConversionEnabledAt)
        Log.settings.info("webpConversionEnabledAt recorded epoch=\(Int(now.timeIntervalSince1970), privacy: .public)")
    }

    var webpDisposal: WebPDisposal {
        get {
            guard let raw = defaults.string(forKey: Key.webpDisposal),
                  let parsed = WebPDisposal(rawValue: raw) else { return .fallback }
            return parsed
        }
        set {
            let previous = webpDisposal
            defaults.set(newValue.rawValue, forKey: Key.webpDisposal)
            Log.settings.info("webpDisposal updated value=\(newValue.rawValue, privacy: .public)")
            if previous != newValue { recordChange("webp_disposal", newValue.rawValue) }
            NotificationCenter.default.post(name: .sukuriniWebPConversionChanged, object: self)
        }
    }

    var copyAsPNGEnabled: Bool {
        get { defaults.object(forKey: Key.copyAsPNGEnabled) as? Bool ?? false }
        set {
            let previous = copyAsPNGEnabled
            defaults.set(newValue, forKey: Key.copyAsPNGEnabled)
            Log.settings.info("copyAsPNGEnabled updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("copy_as_png", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniWebPConversionChanged, object: self)
        }
    }

    var exportsCopiesAsPNG: Bool {
        webpConversionEnabled && copyAsPNGEnabled
    }

    var organizeEnabled: Bool {
        get { defaults.object(forKey: Key.organizeEnabled) as? Bool ?? false }
        set {
            let previous = organizeEnabled
            defaults.set(newValue, forKey: Key.organizeEnabled)
            Log.settings.info("organizeEnabled updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("organize", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniOrganizeChanged, object: self)
        }
    }

    var organizeFormat: String {
        get {
            let stored = defaults.string(forKey: Key.organizeFormat) ?? ""
            guard case .success(let resolved) = DateFolderFormat.resolve(stored) else {
                return DateFolderFormat.defaultPattern
            }
            return resolved.pattern
        }
        set {
            let previous = organizeFormat
            defaults.set(newValue, forKey: Key.organizeFormat)
            Log.settings.info("organizeFormat updated value=\(newValue, privacy: .public)")
            if previous != organizeFormat {
                recordChange("organize_format", organizeFormat == DateFolderFormat.defaultPattern ? "default" : "custom")
            }
            NotificationCenter.default.post(name: .sukuriniOrganizeChanged, object: self)
        }
    }

    var includeSubfolders: Bool {
        get { defaults.object(forKey: Key.includeSubfolders) as? Bool ?? false }
        set {
            let previous = includeSubfolders
            defaults.set(newValue, forKey: Key.includeSubfolders)
            Log.settings.info("includeSubfolders updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("include_subfolders", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniIncludeSubfoldersChanged, object: self)
        }
    }

    var semanticSearchEnabled: Bool {
        get { defaults.object(forKey: Key.semanticEnabled) as? Bool ?? false }
        set {
            let previous = semanticSearchEnabled
            defaults.set(newValue, forKey: Key.semanticEnabled)
            Log.settings.info("semanticSearchEnabled updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("semantic", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniSemanticEnabledChanged, object: self)
        }
    }

    var semanticModelIdentifier: String {
        get {
            let stored = defaults.string(forKey: Key.semanticModel) ?? ""
            return SemanticModelCatalog.resolved(id: stored.isEmpty ? nil : stored).id
        }
        set {
            let resolved = SemanticModelCatalog.resolved(id: newValue).id
            guard resolved != semanticModelIdentifier else { return }
            defaults.set(resolved, forKey: Key.semanticModel)
            Log.settings.info("semanticModel updated value=\(resolved, privacy: .public)")
            recordChange("semantic_model", resolved)
            NotificationCenter.default.post(name: .sukuriniSemanticModelChanged, object: self)
        }
    }

    var alwaysShowInDock: Bool {
        get { defaults.object(forKey: Key.alwaysShowInDock) as? Bool ?? false }
        set {
            let previous = alwaysShowInDock
            defaults.set(newValue, forKey: Key.alwaysShowInDock)
            Log.settings.info("alwaysShowInDock updated value=\(newValue, privacy: .public)")
            if previous != newValue { recordChange("dock", Telemetry.flag(newValue)) }
            NotificationCenter.default.post(name: .sukuriniDockVisibilityChanged, object: self)
        }
    }

    var analyticsEnabled: Bool {
        get { defaults.object(forKey: Key.analyticsEnabled) as? Bool ?? true }
        set {
            guard newValue != analyticsEnabled else { return }
            defaults.set(newValue, forKey: Key.analyticsEnabled)
            Log.settings.info("analyticsEnabled updated value=\(newValue, privacy: .public)")
            NotificationCenter.default.post(name: .sukuriniAnalyticsEnabledChanged, object: self)
        }
    }

    var language: AppLanguage {
        get { AppLanguage.stored(defaults) }
        set {
            guard newValue != language else { return }
            defaults.set(newValue.rawValue, forKey: AppLanguage.defaultsKey)
            Log.settings.info("language updated value=\(newValue.rawValue, privacy: .public) resolved=\(newValue.resolvedLanguage.rawValue, privacy: .public)")
            recordChange("language", newValue.rawValue)
            LocalizationCenter.shared.refresh()
        }
    }

    var updateChannel: UpdateChannel {
        get { UpdateChannel.resolved(defaults.string(forKey: Key.updateChannel)) }
        set {
            guard newValue != updateChannel else { return }
            defaults.set(newValue.rawValue, forKey: Key.updateChannel)
            Log.settings.info("updateChannel updated value=\(newValue.rawValue, privacy: .public)")
            recordChange("update_channel", newValue.rawValue)
            NotificationCenter.default.post(name: .sukuriniUpdateChannelChanged, object: self)
        }
    }

    var gallerySortOrder: GallerySortOrder {
        get {
            guard let raw = defaults.string(forKey: Key.gallerySortOrder),
                  let parsed = GallerySortOrder(rawValue: raw) else { return .relevance }
            return parsed
        }
        set {
            let previous = gallerySortOrder
            defaults.set(newValue.rawValue, forKey: Key.gallerySortOrder)
            Log.settings.info("gallerySortOrder updated value=\(newValue.rawValue, privacy: .public)")
            if previous != newValue { recordChange("gallery_sort", newValue.rawValue) }
        }
    }

    var galleryHotKey: HotKeyBinding? {
        get {
            guard let code = defaults.object(forKey: Key.hotKeyCode) as? Int, code >= 0 else { return nil }
            let modifiers = defaults.object(forKey: Key.hotKeyModifiers) as? Int ?? 0
            return HotKeyBinding(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers))
        }
        set {
            let previous = galleryHotKey
            if let newValue {
                defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyCode)
                defaults.set(Int(newValue.carbonModifiers), forKey: Key.hotKeyModifiers)
                Log.settings.info("hotkey set code=\(newValue.keyCode, privacy: .public) modifiers=\(newValue.carbonModifiers, privacy: .public)")
            } else {
                defaults.removeObject(forKey: Key.hotKeyCode)
                defaults.removeObject(forKey: Key.hotKeyModifiers)
                Log.settings.info("hotkey cleared")
            }
            if previous != newValue { recordChange("hotkey", newValue == nil ? "cleared" : "set") }
            NotificationCenter.default.post(name: .sukuriniHotKeyChanged, object: self)
        }
    }

    func isSystemCaptureFolder(_ url: URL) -> Bool {
        guard let system = ScreencaptureDefaults.currentLocation() else { return false }
        return system.standardizedFileURL.path == url.standardizedFileURL.path
    }

    func canRemoveFolder(_ url: URL) -> Bool {
        !isSystemCaptureFolder(url)
    }

    func ensureSystemCaptureFolderListed() {
        guard let system = ScreencaptureDefaults.currentLocation()?.standardizedFileURL else { return }
        var current = folders
        guard !current.contains(where: { $0.path == system.path }) else { return }
        current.append(system)
        folders = current
        Log.settings.info("system capture folder added to list path=\(system.path, privacy: .public)")
        if activeFolder == nil { activeFolder = system }
    }

    func addFolder(_ url: URL) {
        let resolved = url.standardizedFileURL
        var current = folders
        guard !current.contains(where: { $0.path == resolved.path }) else {
            activeFolder = resolved
            return
        }
        current.append(resolved)
        folders = current
        activeFolder = resolved
    }

    func removeFolder(_ url: URL) {
        let resolved = url.standardizedFileURL
        guard canRemoveFolder(resolved) else {
            Log.settings.info("remove refused, system capture folder path=\(resolved.path, privacy: .public)")
            return
        }
        let remaining = folders.filter { $0.path != resolved.path }
        folders = remaining
        if activeFolder?.path == resolved.path {
            activeFolder = remaining.first
        }
    }

    var firstLaunchedAt: Date? {
        defaults.object(forKey: Key.firstLaunchedAt) as? Date
    }

    var launchCount: Int {
        defaults.integer(forKey: Key.launchCount)
    }

    var onboardingCompletedAt: Date? {
        defaults.object(forKey: Key.onboardingCompletedAt) as? Date
    }

    var hasCompletedOnboarding: Bool {
        onboardingCompletedAt != nil
    }

    func markOnboardingCompleted() {
        guard onboardingCompletedAt == nil else {
            Log.settings.info("onboarding completion already recorded epoch=\(Int(self.onboardingCompletedAt?.timeIntervalSince1970 ?? 0), privacy: .public)")
            return
        }
        let now = Date()
        defaults.set(now, forKey: Key.onboardingCompletedAt)
        Log.settings.info("onboarding completion recorded epoch=\(Int(now.timeIntervalSince1970), privacy: .public)")
    }

    private func recordLaunch() {
        let existingInstall = defaults.object(forKey: Key.folders) != nil
        let count = defaults.integer(forKey: Key.launchCount) + 1
        defaults.set(count, forKey: Key.launchCount)

        guard defaults.object(forKey: Key.firstLaunchedAt) == nil else {
            Log.settings.info("launch recorded count=\(count, privacy: .public) first=false")
            return
        }
        let now = Date()
        defaults.set(now, forKey: Key.firstLaunchedAt)
        isFirstLaunch = true
        Log.settings.info("first launch recorded epoch=\(Int(now.timeIntervalSince1970), privacy: .public) count=\(count, privacy: .public) existingInstall=\(existingInstall, privacy: .public)")
    }

    private func seedIfNeeded() {
        guard defaults.stringArray(forKey: Key.folders) == nil else { return }
        let seed = ScreencaptureDefaults.currentLocation() ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard let seed else { return }
        defaults.set([seed.standardizedFileURL.path], forKey: Key.folders)
        defaults.set(seed.standardizedFileURL.path, forKey: Key.activeFolder)
        Log.settings.info("seeded folders from screencapture location path=\(seed.path, privacy: .public)")
    }
}
