import Foundation

final class OnboardingCoordinator {
    private let settings = AppSettings.shared

    weak var backfillController: BackfillControlling?

    private var stagedFolder: URL?
    private var idleObserver: NSObjectProtocol?
    private var relaunching = false

    deinit {
        removeIdleObserver()
    }

    var pendingFolder: URL? { stagedFolder }

    func stageFolder(_ url: URL) {
        stagedFolder = url.standardizedFileURL
        Log.settings.info("onboarding folder staged path=\(url.path, privacy: .public)")
    }

    func flushStagedFolder(reason: String) {
        guard let target = stagedFolder else { return }
        guard backfillController?.isBackfilling != true else {
            Log.settings.info("onboarding folder switch deferred reason=\(reason, privacy: .public) cause=backfill_running path=\(target.path, privacy: .public)")
            waitForBackfillIdle()
            return
        }
        stagedFolder = nil
        removeIdleObserver()
        let applied = OnboardingSetup.adoptFolder(target)
        Log.settings.info("onboarding folder switch applied reason=\(reason, privacy: .public) applied=\(applied, privacy: .public) path=\(target.path, privacy: .public)")
    }

    func suspendForRelaunch(reason: String) {
        relaunching = true
        Log.settings.info("onboarding suspended for relaunch reason=\(reason, privacy: .public)")
    }

    func complete(reason: String) {
        guard !relaunching else {
            Log.settings.info("onboarding completion skipped reason=relaunching trigger=\(reason, privacy: .public)")
            return
        }
        flushStagedFolder(reason: reason)
        settings.markOnboardingCompleted()
        Log.settings.info("onboarding completed reason=\(reason, privacy: .public) pendingFolder=\(self.stagedFolder?.path ?? "none", privacy: .public)")
    }

    private func waitForBackfillIdle() {
        guard idleObserver == nil else { return }
        idleObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniWebPBackfillProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.backfillController?.isBackfilling != true else { return }
            Log.settings.info("onboarding backfill idle detected, resuming folder switch")
            self.flushStagedFolder(reason: "backfill_idle")
        }
        Log.settings.info("onboarding waiting for backfill to finish before switching folders")
    }

    private func removeIdleObserver() {
        guard let idleObserver else { return }
        NotificationCenter.default.removeObserver(idleObserver)
        self.idleObserver = nil
    }
}
