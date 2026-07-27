import Combine
import Foundation

extension Notification.Name {
    static let sukuriniLanguageChanged = Notification.Name("sukurini.languageChanged")
}

final class LocalizationCenter: ObservableObject {
    static let shared = LocalizationCenter()

    private(set) var setting: AppLanguage
    private(set) var language: ResolvedLanguage
    private(set) var locale: Locale

    private var systemObserver: NSObjectProtocol?

    private init() {
        let stored = AppLanguage.stored()
        let resolved = stored.resolvedLanguage
        setting = stored
        language = resolved
        locale = resolved.locale
        observeSystemLocale()
        Log.settings.info("localization ready setting=\(stored.rawValue, privacy: .public) language=\(resolved.rawValue, privacy: .public) locale=\(resolved.locale.identifier, privacy: .public) preferred=\(Locale.preferredLanguages.prefix(3).joined(separator: ","), privacy: .public)")
    }

    deinit {
        if let systemObserver {
            NotificationCenter.default.removeObserver(systemObserver)
        }
    }

    private func observeSystemLocale() {
        systemObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.setting == .system else { return }
            Log.settings.info("localization system locale changed, re-resolving")
            self.refresh()
        }
    }

    func refresh() {
        let stored = AppLanguage.stored()
        let resolved = stored.resolvedLanguage
        let unchanged = stored == setting && resolved == language
        guard !unchanged else {
            Log.settings.debug("localization refresh skipped setting=\(stored.rawValue, privacy: .public)")
            return
        }
        let previous = language
        setting = stored
        language = resolved
        locale = resolved.locale
        Log.settings.info("localization changed setting=\(stored.rawValue, privacy: .public) language=\(previous.rawValue, privacy: .public)->\(resolved.rawValue, privacy: .public) locale=\(resolved.locale.identifier, privacy: .public)")
        broadcast()
    }

    private func broadcast() {
        guard Thread.isMainThread else {
            Log.settings.debug("localization broadcast hopped to main thread")
            DispatchQueue.main.async { [weak self] in self?.broadcast() }
            return
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .sukuriniLanguageChanged, object: self)
    }

    func dateFormatter(dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    func templateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    func relativeDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }
}
