import Foundation

enum OnboardingRecommendationKind: String, CaseIterable {
    case thumbnail
    case folder
    case login
    case webp
    case telemetry
}

struct OnboardingRecommendation: Identifiable {
    let kind: OnboardingRecommendationKind
    let title: String
    let detail: String
    let satisfied: Bool

    var id: String { kind.rawValue }
}

struct OnboardingOutcome {
    var thumbnailDisabled = false
    var webpEnabled = false
    var telemetryEnabled = false
    var loginEnabled = false
    var stagedFolder: URL?
    var movedCount = 0
    var moveSource: URL?
    var failures: [String] = []
    var notices: [String] = []
}

enum OnboardingSetup {
    static let folderName = "Screenshots"

    static var recommendedFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
    }

    static func recommendations() -> [OnboardingRecommendation] {
        let settings = AppSettings.shared
        let target = recommendedFolder
        let capture = ScreencaptureDefaults.currentLocation()?.standardizedFileURL
        let folderSatisfied = capture?.path == target.path && settings.activeFolder?.standardizedFileURL.path == target.path

        var list = [
            OnboardingRecommendation(
                kind: .thumbnail,
                title: L10n.Onboarding.recommendThumbnail,
                detail: L10n.Onboarding.recommendThumbnailDetail,
                satisfied: !ScreencaptureDefaults.showsThumbnail()
            ),
            OnboardingRecommendation(
                kind: .folder,
                title: L10n.Onboarding.recommendFolder(displayPath(target)),
                detail: folderDetail(current: capture, target: target),
                satisfied: folderSatisfied
            ),
            OnboardingRecommendation(
                kind: .webp,
                title: L10n.Convert.enable,
                detail: L10n.Onboarding.recommendWebPDetail(settings.webpDisposal),
                satisfied: settings.webpConversionEnabled
            ),
            OnboardingRecommendation(
                kind: .telemetry,
                title: L10n.Onboarding.recommendTelemetry,
                detail: L10n.Onboarding.recommendTelemetryDetail,
                satisfied: settings.analyticsEnabled
            )
        ]

        if LoginItem.isAvailable {
            list.insert(
                OnboardingRecommendation(
                    kind: .login,
                    title: L10n.Onboarding.recommendLogin,
                    detail: L10n.Onboarding.recommendLoginDetail,
                    satisfied: LoginItem.isEnabled || LoginItem.requiresApproval
                ),
                at: 2
            )
        } else {
            Log.settings.info("onboarding login recommendation hidden reason=login_item_unavailable")
        }

        let pending = list.filter { !$0.satisfied }.map(\.kind.rawValue).joined(separator: ",")
        Log.settings.info("onboarding recommendations built pending=\(pending.isEmpty ? "none" : pending, privacy: .public)")
        return list
    }

    static func enableLoginItem() throws {
        guard !LoginItem.isEnabled else {
            Log.settings.info("onboarding login item skipped reason=already_enabled")
            return
        }
        try LoginItem.setEnabled(true)
        Log.settings.info("onboarding login item enabled status=\(LoginItem.statusDescription, privacy: .public) approval=\(LoginItem.requiresApproval, privacy: .public)")
    }

    static func disableThumbnailPreview() -> Bool {
        let synced = ScreencaptureDefaults.setShowsThumbnail(false)
        let fresh = ScreencaptureDefaults.showsThumbnail()
        Log.settings.info("onboarding thumbnail disabled synced=\(synced, privacy: .public) value=\(fresh, privacy: .public)")
        return !fresh
    }

    static func enableWebP() {
        guard !AppSettings.shared.webpConversionEnabled else {
            Log.settings.info("onboarding webp skipped reason=already_enabled")
            return
        }
        AppSettings.shared.webpConversionEnabled = true
        Log.settings.info("onboarding webp enabled disposal=\(AppSettings.shared.webpDisposal.rawValue, privacy: .public)")
    }

    /* Reached only from the recommendations step, so collection starts the
       moment someone leaves the row checked and never before that. */
    static func enableTelemetry() {
        guard !AppSettings.shared.analyticsEnabled else {
            Log.settings.info("onboarding telemetry skipped reason=already_enabled")
            return
        }
        AppSettings.shared.analyticsEnabled = true
        Log.settings.info("onboarding telemetry enabled")
    }

    static func createRecommendedFolder() -> URL? {
        let target = recommendedFolder
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            Log.settings.info("onboarding folder ready path=\(target.path, privacy: .public)")
            return target
        } catch {
            Log.settings.error("onboarding folder creation failed path=\(target.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func adoptFolder(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL
        let synced = ScreencaptureDefaults.setLocation(resolved)
        let fresh = ScreencaptureDefaults.currentLocation()?.standardizedFileURL
        let matched = fresh?.path == resolved.path
        AppSettings.shared.addFolder(resolved)
        AppSettings.shared.ensureSystemCaptureFolderListed()
        Log.settings.info("onboarding folder adopted path=\(resolved.path, privacy: .public) synced=\(synced, privacy: .public) matched=\(matched, privacy: .public) active=\(AppSettings.shared.activeFolder?.path ?? "none", privacy: .public)")
        return synced && matched
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func folderDetail(current: URL?, target: URL) -> String {
        guard let current, current.path != target.path else {
            return L10n.Onboarding.recommendFolderDetail
        }
        return L10n.Onboarding.recommendFolderMoveDetail(current.lastPathComponent)
    }
}
