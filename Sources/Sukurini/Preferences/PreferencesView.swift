import AppKit
import Combine
import SwiftUI

struct PreferencesView: View {
    private enum Tab: Hashable {
        case general
        case folders
        case images
        case search
    }

    private enum Layout {
        static let tabMinHeight: CGFloat = 400
    }

    private let ocrProgressProvider: () -> (done: Int, total: Int)?
    private let backfillProvider: () -> BackfillControlling?
    private let organizeProvider: () -> OrganizeControlling?
    private let semanticProvider: () -> SemanticCoordinator?

    @State private var folders: [URL] = []
    @State private var activeFolder: URL?
    @State private var captureNotice: String?
    @State private var captureNoticeIsError = false
    @State private var showsThumbnail = true
    @State private var thumbnailNotice: String?
    @State private var launchAtLogin = false
    @State private var alwaysShowInDock = false
    @State private var loginAvailable = false
    @State private var loginNeedsApproval = false
    @State private var loginStatus = "Unknown"
    @State private var loginError: String?
    @State private var ocrEnabled = true
    @State private var lazyIndexOnBattery = true
    @State private var pauseIndexingOnLowPower = true
    @State private var ocrProgress: (done: Int, total: Int)?
    @State private var hotKey: HotKeyBinding?
    @State private var isRecording = false
    @State private var shortcutNotice: String?
    @State private var shortcutNoticeIsError = false
    @State private var recorder = HotKeyRecorder()
    @State private var selectedTab = Tab.general
    @State private var webpEnabled = false
    @State private var webpDisposal = WebPDisposal.fallback
    @State private var copyAsPNG = false
    @State private var conversionSince: Date?
    @State private var backfillIsCatchUp = false
    @State private var backfillProgress: BackfillProgress?
    @State private var backfillEstimate: BackfillEstimate?
    @State private var backfillRunning = false
    @State private var convertNotice: String?
    @State private var convertNoticeIsError = false
    @State private var organizeEnabled = false
    @State private var includeSubfolders = false
    @State private var organizeFormatDraft = DateFolderFormat.defaultPattern
    @State private var organizeFormatSaved = DateFolderFormat.defaultPattern
    @State private var organizeSampleDate = Date()
    @State private var organizeProgress: OrganizeProgress?
    @State private var organizeEstimate: OrganizeEstimate?
    @State private var organizeRunning = false
    @State private var organizeNotice: String?
    @State private var organizeNoticeIsError = false
    @State private var semanticEnabled = false
    @State private var semanticModelID = SemanticModelCatalog.defaultIdentifier
    @State private var semanticState = SemanticState.disabled
    @State private var semanticIndexed = 0
    @State private var semanticResumable: Int64 = 0
    @State private var showRemoveConfirmation = false
    @State private var updateChannel = UpdateChannel.stable
    @State private var automaticUpdates = false
    @State private var updateAvailability = UpdateCoordinator.Availability.notBundled
    @State private var lastUpdateCheck: Date?
    @State private var language = AppSettings.shared.language
    @State private var analyticsEnabled = false
    @ObservedObject private var localization = LocalizationCenter.shared

    init(
        ocrProgressProvider: @escaping () -> (done: Int, total: Int)?,
        backfillProvider: @escaping () -> BackfillControlling?,
        organizeProvider: @escaping () -> OrganizeControlling?,
        semanticProvider: @escaping () -> SemanticCoordinator? = { nil }
    ) {
        self.ocrProgressProvider = ocrProgressProvider
        self.backfillProvider = backfillProvider
        self.organizeProvider = organizeProvider
        self.semanticProvider = semanticProvider
    }

    var body: some View {
        observingLifecycle
    }

    private var tabs: some View {
        TabView(selection: tabBinding) {
            generalTab
                .tabItem { Label(L10n.Tabs.general, systemImage: "gearshape") }
                .tag(Tab.general)
            foldersTab
                .tabItem { Label(L10n.Tabs.folders, systemImage: "folder") }
                .tag(Tab.folders)
            imagesTab
                .tabItem { Label(L10n.Tabs.images, systemImage: "photo") }
                .tag(Tab.images)
            searchTab
                .tabItem { Label(L10n.Tabs.search, systemImage: "text.magnifyingglass") }
                .tag(Tab.search)
        }
    }

    private var observingLifecycle: some View {
        observingLibrary
            .onAppear { reloadAll() }
            .onDisappear { stopRecording(reason: "disappear") }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniPreferencesWillShow)) { _ in onMain { reloadAll() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniHotKeyChanged)) { _ in onMain { reloadHotKey() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniHotKeyRegistrationChanged)) { note in
                onMain { applyRegistrationState(note) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                onMain { handleWindowClose(note) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniDockVisibilityChanged)) { _ in onMain { reloadDockVisibility() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniUpdateChannelChanged)) { _ in onMain { reloadUpdates() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniAnalyticsEnabledChanged)) { _ in onMain { reloadAnalytics() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniLanguageChanged)) { _ in onMain { relocalize() } }
    }

    private var observingLibrary: some View {
        observingIndex
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniFoldersChanged)) { _ in onMain { reloadFolders() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniActiveFolderChanged)) { _ in onMain { reloadFolders() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniWebPConversionChanged)) { _ in onMain { reloadConversion() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniWebPBackfillProgressChanged)) { _ in onMain { reloadBackfillProgress() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniOrganizeChanged)) { _ in onMain { reloadOrganize() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniIncludeSubfoldersChanged)) { _ in onMain { reloadOrganize() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniOrganizeBackfillProgressChanged)) { _ in onMain { reloadOrganizeProgress() } }
    }

    private var observingIndex: some View {
        tabs
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniOCREnabledChanged)) { _ in onMain { reloadOCREnabled() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniOCRProgressChanged)) { _ in onMain { reloadOCRProgress() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniOCRPowerPolicyChanged)) { _ in onMain { reloadPowerPolicy() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniSemanticEnabledChanged)) { _ in onMain { reloadSemantic() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniSemanticModelChanged)) { _ in onMain { reloadSemantic() } }
            .onReceive(NotificationCenter.default.publisher(for: .sukuriniSemanticStateChanged)) { _ in onMain { reloadSemantic() } }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            Log.settings.debug("preferences notification hopped to main thread")
            DispatchQueue.main.async(execute: work)
        }
    }

    private var tabBinding: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { desired in
                guard desired != selectedTab else { return }
                selectedTab = desired
                stopRecording(reason: "tab_switched")
                Log.settings.info("preferences tab selected value=\(name(of: desired), privacy: .public)")
            }
        )
    }

    private func name(of tab: Tab) -> String {
        switch tab {
        case .general:
            return "general"
        case .folders:
            return "folders"
        case .images:
            return "images"
        case .search:
            return "search"
        }
    }

    private var generalTab: some View {
        Form {
            languageSection
            startupSection
            dockSection
            shortcutSection
            screenshotsSection
            updatesSection
            analyticsSection
        }
        .formStyle(.grouped)
        .frame(minHeight: Layout.tabMinHeight)
    }

    private var analyticsSection: some View {
        Section {
            Toggle(isOn: analyticsBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Analytics.enable)
                    Text(L10n.Analytics.enableDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.Analytics.header)
        } footer: {
            Text(L10n.Analytics.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var analyticsBinding: Binding<Bool> {
        Binding(
            get: { analyticsEnabled },
            set: { desired in
                analyticsEnabled = desired
                if AppSettings.shared.analyticsEnabled != desired {
                    AppSettings.shared.analyticsEnabled = desired
                }
                Log.settings.info("preferences analytics toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private func reloadAnalytics() {
        analyticsEnabled = AppSettings.shared.analyticsEnabled
        Log.settings.debug("preferences analytics synced value=\(self.analyticsEnabled, privacy: .public)")
    }

    private var languageSection: some View {
        Section {
            Picker(L10n.Language.label, selection: languageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { option in
                    Text(languageTitle(option)).tag(option)
                }
            }
        } header: {
            Text(L10n.Language.header)
        } footer: {
            Text(L10n.Language.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func languageTitle(_ option: AppLanguage) -> String {
        guard let explicit = option.explicit else {
            return L10n.Language.systemOption(AppLanguage.systemPreferred)
        }
        return explicit.nativeName
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { language },
            set: { desired in
                guard desired != language else { return }
                language = desired
                AppSettings.shared.language = desired
                Log.settings.info("preferences language selected value=\(desired.rawValue, privacy: .public) resolved=\(desired.resolvedLanguage.rawValue, privacy: .public)")
            }
        )
    }

    private var foldersTab: some View {
        Form {
            foldersSection
            organizeSection
        }
        .formStyle(.grouped)
        .frame(minHeight: Layout.tabMinHeight)
    }

    private var imagesTab: some View {
        Form {
            conversionSection
        }
        .formStyle(.grouped)
        .frame(minHeight: Layout.tabMinHeight)
    }

    private var searchTab: some View {
        Form {
            searchSection
            semanticSection
        }
        .formStyle(.grouped)
        .frame(minHeight: Layout.tabMinHeight)
    }

    private var conversionSection: some View {
        Section {
            Toggle(isOn: webpBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Convert.enable)
                    Text(L10n.Convert.enableDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker(L10n.Convert.originalPNG, selection: disposalBinding) {
                Text(L10n.Convert.disposalTrash).tag(WebPDisposal.trash)
                Text(L10n.Convert.disposalDelete).tag(WebPDisposal.delete)
                Text(L10n.Convert.disposalKeep).tag(WebPDisposal.keep)
            }
            .disabled(!webpEnabled)
            Toggle(isOn: copyAsPNGBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Convert.copyAsPNG)
                    Text(L10n.Convert.copyAsPNGDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!webpEnabled)
            LabeledContent(backfillLabel) {
                Text(backfillSummary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if backfillRunning, let backfillProgress, backfillProgress.total > 0 {
                ProgressView(value: Double(backfillProgress.done), total: Double(backfillProgress.total))
                LabeledContent(L10n.Convert.reclaimed) {
                    Text(reclaimedSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                Button(backfillButtonTitle) { startBackfill() }
                    .disabled(!backfillAvailable)
                if backfillRunning {
                    Button(L10n.Common.stop) { cancelBackfill() }
                }
                Spacer()
            }
            if let convertNotice {
                Text(convertNotice)
                    .font(.caption)
                    .foregroundStyle(convertNoticeIsError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L10n.Convert.header)
        } footer: {
            Text(conversionSinceSummary ?? L10n.Convert.footerDefault)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var backfillLabel: String {
        guard backfillRunning else { return L10n.Convert.existingPNGs }
        return backfillIsCatchUp ? L10n.Convert.catchingUp : L10n.Convert.converting
    }

    private var conversionSinceSummary: String? {
        guard webpEnabled, let conversionSince else { return nil }
        let stamp = LocalizationCenter.shared.dateFormatter(dateStyle: .medium, timeStyle: .short)
        return L10n.Convert.footerSince(stamp.string(from: conversionSince))
    }

    private var backfillSummary: String {
        if backfillRunning, let progress = backfillProgress, progress.total > 0 {
            var parts = [L10n.Convert.progress(progress.done.formatted(), total: progress.total.formatted())]
            if progress.filesPerSecond > 0 {
                parts.append(String(format: "%.1f/s", progress.filesPerSecond))
            }
            if let eta = progress.estimatedTimeRemaining {
                parts.append(L10n.Convert.remaining(L10n.duration(eta)))
            }
            return parts.joined(separator: " · ")
        }
        guard let backfillEstimate else { return L10n.Common.counting }
        guard backfillEstimate.count > 0 else { return L10n.Common.none }
        return L10n.Convert.estimate(
            backfillEstimate.count.formatted(),
            saved: L10n.bytes(backfillEstimate.estimatedSavedBytes)
        )
    }

    private var reclaimedSummary: String {
        guard let progress = backfillProgress else { return L10n.Common.dash }
        let saved = L10n.bytes(progress.savedBytes)
        guard progress.reductionRatio > 0 else { return saved }
        return L10n.Convert.reclaimedSoFar(saved, percent: Int((progress.reductionRatio * 100).rounded()))
    }

    private var backfillButtonTitle: String {
        guard let backfillEstimate, backfillEstimate.count > 0 else { return L10n.Convert.backfillIdle }
        return L10n.Convert.backfill(backfillEstimate.count)
    }

    private var backfillAvailable: Bool {
        guard !backfillRunning, let backfillEstimate else { return false }
        return backfillEstimate.count > 0
    }

    private var webpBinding: Binding<Bool> {
        Binding(
            get: { webpEnabled },
            set: { desired in
                webpEnabled = desired
                if AppSettings.shared.webpConversionEnabled != desired {
                    AppSettings.shared.webpConversionEnabled = desired
                }
                Log.settings.info("preferences webp toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private var disposalBinding: Binding<WebPDisposal> {
        Binding(
            get: { webpDisposal },
            set: { desired in
                webpDisposal = desired
                if AppSettings.shared.webpDisposal != desired {
                    AppSettings.shared.webpDisposal = desired
                }
                Log.settings.info("preferences webp disposal selected value=\(desired.rawValue, privacy: .public)")
            }
        )
    }

    private var copyAsPNGBinding: Binding<Bool> {
        Binding(
            get: { copyAsPNG },
            set: { desired in
                copyAsPNG = desired
                if AppSettings.shared.copyAsPNGEnabled != desired {
                    AppSettings.shared.copyAsPNGEnabled = desired
                }
                Log.settings.info("preferences copy as png toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private func reloadConversion() {
        webpEnabled = AppSettings.shared.webpConversionEnabled
        webpDisposal = AppSettings.shared.webpDisposal
        copyAsPNG = AppSettings.shared.copyAsPNGEnabled
        conversionSince = AppSettings.shared.webpConversionEnabledAt
        refreshBackfillEstimate()
    }

    private func reloadBackfillProgress() {
        guard let controller = backfillProvider() else {
            backfillProgress = nil
            backfillRunning = false
            return
        }
        let progress = controller.backfillProgress
        backfillProgress = progress
        let running = controller.isBackfilling
        let wasCatchUp = controller.isCatchUp
        backfillIsCatchUp = wasCatchUp
        if backfillRunning, !running {
            convertNoticeIsError = false
            convertNotice = progress.converted > 0
                ? L10n.Convert.completed(
                    count: progress.converted.formatted(),
                    duration: L10n.duration(progress.elapsed),
                    saved: L10n.bytes(progress.savedBytes),
                    percent: Int((progress.reductionRatio * 100).rounded()),
                    catchUp: wasCatchUp
                )
                : L10n.Convert.nothingConverted
            refreshBackfillEstimate()
            Log.settings.info("preferences backfill completed converted=\(progress.converted, privacy: .public) saved=\(progress.savedBytes, privacy: .public) ms=\(Int(progress.elapsed * 1000), privacy: .public)")
        }
        backfillRunning = running
    }

    private func refreshBackfillEstimate() {
        guard let controller = backfillProvider() else {
            backfillEstimate = .empty
            return
        }
        controller.estimate { estimate in
            onMain {
                backfillEstimate = estimate
                Log.settings.debug("preferences backfill estimate count=\(estimate.count, privacy: .public) bytes=\(estimate.totalBytes, privacy: .public)")
            }
        }
    }

    private func startBackfill() {
        guard let controller = backfillProvider(),
              let estimate = backfillEstimate, estimate.count > 0 else { return }
        let saved = L10n.bytes(estimate.estimatedSavedBytes)

        let alert = NSAlert()
        alert.messageText = L10n.Convert.confirmTitle(estimate.count.formatted())
        alert.informativeText = L10n.Convert.confirmBody(saved: saved, disposal: webpDisposal)
        alert.alertStyle = webpDisposal == .delete ? .critical : .warning
        alert.addButton(withTitle: L10n.Common.convert)
        alert.addButton(withTitle: L10n.Common.cancel)
        if webpDisposal == .delete {
            alert.buttons.first?.keyEquivalent = ""
            alert.buttons.last?.keyEquivalent = "\r"
        }
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.settings.info("preferences backfill declined count=\(estimate.count, privacy: .public)")
            return
        }

        convertNotice = nil
        convertNoticeIsError = false
        backfillRunning = true
        Log.settings.info("preferences backfill started count=\(estimate.count, privacy: .public) policy=\(self.webpDisposal.rawValue, privacy: .public)")
        controller.startBackfill()
    }

    private func cancelBackfill() {
        backfillProvider()?.cancelBackfill()
        Log.settings.info("preferences backfill stop requested")
    }

    private var organizeSection: some View {
        Section {
            Toggle(isOn: organizeBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Organize.enable)
                    Text(L10n.Organize.enableDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent(L10n.Organize.dateFormat) {
                TextField(L10n.Organize.dateFormat, text: organizeFormatBinding, prompt: Text(DateFolderFormat.defaultPattern))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.leading)
                    .autocorrectionDisabled()
                    .onSubmit { saveFormat() }
            }
            LabeledContent(L10n.Organize.preview) {
                Text(organizePreview)
                    .foregroundStyle(organizeValid ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let organizeHint {
                Text(organizeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button(L10n.Common.save) { saveFormat() }
                    .disabled(!organizeCanSave)
                Button(L10n.Common.revert) { revertFormat() }
                    .disabled(!organizeDirty)
                if organizeDirty {
                    Text(L10n.Organize.unsaved)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Toggle(isOn: includeSubfoldersBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Organize.includeSubfolders)
                    Text(organizeEnabled
                        ? L10n.Organize.includeSubfoldersRequired
                        : L10n.Organize.includeSubfoldersOptional)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(organizeEnabled)
            LabeledContent(organizeRunning ? L10n.Organize.organizing : L10n.Organize.looseScreenshots) {
                Text(organizeSummary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if organizeRunning, let organizeProgress, organizeProgress.total > 0 {
                ProgressView(value: Double(organizeProgress.done), total: Double(organizeProgress.total))
            }
            HStack(spacing: 10) {
                Button(organizeBackfillTitle) { startOrganizeBackfill() }
                    .disabled(!organizeBackfillAvailable)
                if organizeRunning {
                    Button(L10n.Common.stop) { cancelOrganizeBackfill() }
                }
                Spacer()
            }
            if let organizeNotice {
                Text(organizeNotice)
                    .font(.caption)
                    .foregroundStyle(organizeNoticeIsError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L10n.Organize.header)
        }
    }

    private var organizeResolution: Result<DateFolderFormat.Resolved, DateFolderFormat.Invalid> {
        DateFolderFormat.resolve(organizeFormatDraft)
    }

    private var organizeValid: Bool {
        guard case .success = organizeResolution else { return false }
        return true
    }

    private var organizeDirty: Bool { organizeFormatDraft != organizeFormatSaved }

    private var organizeCanSave: Bool { organizeDirty && organizeValid }

    private var organizePreview: String {
        switch organizeResolution {
        case .success(let resolved):
            guard let relative = DateFolderFormat.relativePath(for: organizeSampleDate, pattern: resolved.pattern) else {
                return DateFolderFormat.Invalid.renderFailed.message
            }
            let root = activeFolder?.lastPathComponent ?? L10n.Organize.sampleFolder
            return "\(root)/\(relative)/\(organizeSampleName)"
        case .failure(let issue):
            return issue.message
        }
    }

    private var organizeSampleName: String {
        "\(L10n.Organize.sampleName) \(Self.sampleNameFormatter.string(from: organizeSampleDate)).png"
    }

    private static let sampleNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private var organizeHint: String? {
        guard case .success(let resolved) = organizeResolution else { return nil }
        if resolved.corrected { return L10n.Organize.usingPattern(resolved.pattern) }
        if resolved.isDateless { return L10n.Organize.datelessHint }
        return nil
    }

    private var organizeSummary: String {
        if organizeRunning, let progress = organizeProgress, progress.total > 0 {
            var parts = [L10n.Convert.progress(progress.done.formatted(), total: progress.total.formatted())]
            if progress.filesPerSecond > 0 {
                parts.append(String(format: "%.1f/s", progress.filesPerSecond))
            }
            if let eta = progress.estimatedTimeRemaining {
                parts.append(L10n.Convert.remaining(L10n.duration(eta)))
            }
            return parts.joined(separator: " · ")
        }
        guard let organizeEstimate else { return L10n.Common.counting }
        guard organizeEstimate.count > 0 else { return L10n.Common.none }
        return L10n.Organize.rootCount(organizeEstimate.count.formatted())
    }

    private var organizeBackfillTitle: String {
        guard let organizeEstimate, organizeEstimate.count > 0 else { return L10n.Organize.backfillIdle }
        return L10n.Organize.backfill(organizeEstimate.count.formatted())
    }

    private var organizeBackfillAvailable: Bool {
        guard !organizeRunning, !backfillRunning, organizeValid, !organizeDirty else { return false }
        guard let organizeEstimate else { return false }
        return organizeEstimate.count > 0
    }

    private var organizeBinding: Binding<Bool> {
        Binding(
            get: { organizeEnabled },
            set: { desired in
                organizeEnabled = desired
                if AppSettings.shared.organizeEnabled != desired {
                    AppSettings.shared.organizeEnabled = desired
                }
                if desired, !AppSettings.shared.includeSubfolders {
                    includeSubfolders = true
                    AppSettings.shared.includeSubfolders = true
                    Log.settings.info("preferences include subfolders auto enabled")
                }
                Log.settings.info("preferences organize toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private var includeSubfoldersBinding: Binding<Bool> {
        Binding(
            get: { includeSubfolders },
            set: { desired in
                includeSubfolders = desired
                if AppSettings.shared.includeSubfolders != desired {
                    AppSettings.shared.includeSubfolders = desired
                }
                Log.settings.info("preferences include subfolders toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private var organizeFormatBinding: Binding<String> {
        Binding(
            get: { organizeFormatDraft },
            set: { desired in
                organizeFormatDraft = Self.sanitizeFormat(desired)
            }
        )
    }

    private static func sanitizeFormat(_ value: String) -> String {
        var output = value
        let substitutions = [
            ("\u{2013}", "-"),
            ("\u{2014}", "-"),
            ("\u{2018}", "'"),
            ("\u{2019}", "'"),
            ("\u{201C}", "\""),
            ("\u{201D}", "\"")
        ]
        for (smart, plain) in substitutions {
            output = output.replacingOccurrences(of: smart, with: plain)
        }
        return output
    }

    private func saveFormat() {
        guard organizeCanSave, case .success(let resolved) = organizeResolution else { return }
        AppSettings.shared.organizeFormat = resolved.pattern
        organizeFormatSaved = resolved.pattern
        organizeFormatDraft = resolved.pattern
        organizeNotice = nil
        organizeNoticeIsError = false
        refreshOrganizeEstimate()
        Log.settings.info("preferences organize format saved value=\(resolved.pattern, privacy: .public) corrected=\(resolved.corrected, privacy: .public) depth=\(resolved.depth, privacy: .public)")
    }

    private func revertFormat() {
        organizeFormatDraft = organizeFormatSaved
        Log.settings.info("preferences organize draft reverted value=\(self.organizeFormatSaved, privacy: .public)")
    }

    private func reloadOrganize() {
        let settings = AppSettings.shared
        organizeEnabled = settings.organizeEnabled
        includeSubfolders = settings.includeSubfolders
        organizeFormatSaved = settings.organizeFormat
        organizeFormatDraft = settings.organizeFormat
        organizeSampleDate = Date()
        refreshOrganizeEstimate()
    }

    private func reloadOrganizeProgress() {
        guard let controller = organizeProvider() else {
            organizeProgress = nil
            organizeRunning = false
            return
        }
        let progress = controller.organizeProgress
        organizeProgress = progress
        let running = controller.isOrganizing
        if organizeRunning, !running {
            organizeNoticeIsError = progress.failed > 0
            if progress.moved > 0 {
                organizeNotice = L10n.Organize.moved(
                    progress.moved.formatted(),
                    duration: L10n.duration(progress.elapsed),
                    failed: progress.failed > 0 ? progress.failed.formatted() : nil
                )
            } else {
                organizeNotice = progress.failed > 0 ? L10n.Organize.moveFailed : L10n.Organize.nothingToDo
            }
            refreshOrganizeEstimate()
            Log.settings.info("preferences organize completed moved=\(progress.moved, privacy: .public) failed=\(progress.failed, privacy: .public) ms=\(Int(progress.elapsed * 1000), privacy: .public)")
        }
        organizeRunning = running
    }

    private func refreshOrganizeEstimate() {
        guard let controller = organizeProvider() else {
            organizeEstimate = .empty
            return
        }
        controller.estimate { estimate in
            onMain {
                organizeEstimate = estimate
                Log.settings.debug("preferences organize estimate count=\(estimate.count, privacy: .public)")
            }
        }
    }

    private func startOrganizeBackfill() {
        guard let controller = organizeProvider(),
              let estimate = organizeEstimate, estimate.count > 0 else { return }
        let example = DateFolderFormat.relativePath(for: organizeSampleDate, pattern: organizeFormatSaved) ?? organizeFormatSaved

        let alert = NSAlert()
        alert.messageText = L10n.Organize.confirmTitle(estimate.count.formatted())
        alert.informativeText = L10n.Organize.confirmBody(example)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Common.organize)
        alert.addButton(withTitle: L10n.Common.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.settings.info("preferences organize declined count=\(estimate.count, privacy: .public)")
            return
        }

        organizeNotice = nil
        organizeNoticeIsError = false
        organizeRunning = true
        Log.settings.info("preferences organize started count=\(estimate.count, privacy: .public) pattern=\(self.organizeFormatSaved, privacy: .public)")
        controller.startOrganize()
    }

    private func cancelOrganizeBackfill() {
        organizeProvider()?.cancelOrganize()
        Log.settings.info("preferences organize stop requested")
    }

    private var foldersSection: some View {
        Section {
            if folders.isEmpty {
                Text(L10n.Folders.empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(folders, id: \.path) { folder in
                    folderRow(folder)
                }
            }
            HStack {
                Button(L10n.Folders.add) { addFolder() }
                Spacer()
                Text(folderSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Folders.header)
        } footer: {
            if let captureNotice {
                Text(captureNotice)
                    .font(.caption)
                    .foregroundStyle(captureNoticeIsError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func folderRow(_ folder: URL) -> some View {
        let isActive = activeFolder?.path == folder.path
        let isSystem = AppSettings.shared.isSystemCaptureFolder(folder)
        let removable = AppSettings.shared.canRemoveFolder(folder)
        let exists = folderExists(folder)
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(folder.lastPathComponent)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isSystem {
                        systemBadge
                    }
                    if !exists {
                        Label(L10n.Common.missing, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text(displayPath(folder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !isSystem {
                Button(L10n.Folders.setAsSystem) { setSystemLocation(folder) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!exists)
                    .help(L10n.Folders.setAsSystemHelp)
            }
            Button {
                removeFolder(folder)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!removable)
            .help(removable ? L10n.Folders.removeHelp : L10n.Folders.removeBlockedHelp)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { selectFolder(folder) }
        .contextMenu {
            Button(L10n.Folders.watchThis) { selectFolder(folder) }
                .disabled(isActive)
            Button(L10n.Folders.setSystemLocation) { setSystemLocation(folder) }
                .disabled(isSystem || !exists)
            Divider()
            Button(L10n.Folders.removeFolder) { removeFolder(folder) }
                .disabled(!removable)
        }
    }

    private var systemBadge: some View {
        Text(L10n.Folders.systemBadge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)
            .help(L10n.Folders.systemBadgeHelp)
    }

    private var updatesSection: some View {
        Section {
            Toggle(L10n.Updates.automatic, isOn: automaticUpdatesBinding)
                .disabled(!updateAvailability.isReady)
            Picker(L10n.Updates.channel, selection: updateChannelBinding) {
                ForEach(UpdateChannel.allCases, id: \.self) { channel in
                    Text(channel.displayName).tag(channel)
                }
            }
            .disabled(!updateAvailability.isReady)
            HStack(spacing: 10) {
                Button(L10n.Updates.checkNow) { checkForUpdatesNow() }
                    .disabled(!updateAvailability.isReady)
                Spacer()
                Text(updateVersionDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let explanation = updateAvailability.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L10n.Updates.header)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(updateChannel.summary)
                Text(lastUpdateCheckDisplay)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var updateVersionDisplay: String {
        L10n.Updates.version(UpdateCoordinator.shared.currentVersion)
    }

    private var lastUpdateCheckDisplay: String {
        guard let lastUpdateCheck else { return L10n.Updates.neverChecked }
        let formatter = LocalizationCenter.shared.dateFormatter(dateStyle: .medium, timeStyle: .short)
        return L10n.Updates.lastChecked(formatter.string(from: lastUpdateCheck))
    }

    private var startupSection: some View {
        Section {
            Toggle(L10n.Startup.launchAtLogin, isOn: launchBinding)
                .disabled(!loginAvailable)
            LabeledContent(L10n.Startup.status) {
                Text(loginStatus)
                    .foregroundStyle(.secondary)
            }
            if !loginAvailable {
                Text(L10n.Startup.needsApplications)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if loginNeedsApproval {
                Button(L10n.Startup.openLoginItems) { LoginItem.openSystemSettings() }
            }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L10n.Startup.header)
        }
    }

    private var dockSection: some View {
        Section {
            Toggle(L10n.Dock.alwaysShow, isOn: dockVisibilityBinding)
        } header: {
            Text(L10n.Dock.header)
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent(L10n.Shortcut.toggleGallery) {
                Text(shortcutDisplay)
                    .font(.body.weight(.medium))
                    .foregroundStyle(hotKey == nil ? Color.secondary : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(isRecording ? 0.22 : 0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
            }
            HStack(spacing: 10) {
                Button {
                    toggleRecording()
                } label: {
                    Text(recordButtonTitle)
                        .frame(minWidth: 112)
                }
                Button(L10n.Common.clear) { clearShortcut() }
                    .disabled(hotKey == nil)
                Spacer()
            }
            if let shortcutNotice {
                Text(shortcutNotice)
                    .font(.caption)
                    .foregroundStyle(shortcutNoticeIsError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L10n.Shortcut.header)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Shortcut.optionalNote)
                Text(L10n.Shortcut.escapeNote)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var screenshotsSection: some View {
        Section {
            Toggle(L10n.Capture.showThumbnail, isOn: thumbnailBinding)
            if let thumbnailNotice {
                Text(thumbnailNotice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(L10n.Capture.header)
        } footer: {
            Text(L10n.Capture.thumbnailFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var searchSection: some View {
        Section {
            Toggle(L10n.Search.ocrEnable, isOn: ocrBinding)
            LabeledContent(L10n.Search.indexing) {
                Text(ocrProgressText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let ocrProgress, ocrEnabled, ocrProgress.total > 0, ocrProgress.done < ocrProgress.total {
                ProgressView(value: Double(ocrProgress.done), total: Double(ocrProgress.total))
            }
            Toggle(isOn: lazyIndexBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Search.lazyOnBattery)
                    Text(L10n.Search.lazyOnBatteryDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!ocrEnabled)
            Toggle(isOn: lowPowerBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Search.pauseLowPower)
                    Text(L10n.Search.pauseLowPowerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!ocrEnabled)
        } header: {
            Text(L10n.Search.header)
        }
    }

    private var semanticSection: some View {
        Section {
            Toggle(isOn: semanticBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Semantic.title)
                    Text(L10n.Semantic.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if semanticEnabled {
                if SemanticModelCatalog.all.count > 1 {
                    Picker(L10n.Semantic.model, selection: semanticModelBinding) {
                        ForEach(SemanticModelCatalog.all, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .disabled(semanticIsBusy)
                }

                LabeledContent(L10n.Semantic.status) {
                    Text(semanticStatusText)
                        .foregroundStyle(semanticStatusIsError ? Color.red : Color.secondary)
                        .monospacedDigit()
                }

                switch semanticState {
                case .downloading(let progress):
                    ProgressView(value: progress.fraction)
                    HStack {
                        Spacer()
                        Button(L10n.Common.cancel) { semanticProvider()?.cancelDownload() }
                    }
                case .needsDownload:
                    HStack {
                        Text(semanticDownloadPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if semanticResumable > 0 {
                            Button(L10n.Semantic.startOver) { semanticProvider()?.discardPartialDownload(); reloadSemantic() }
                        }
                        Button(semanticResumable > 0 ? L10n.Semantic.resume : L10n.Semantic.download) { semanticProvider()?.requestDownload() }
                            .keyboardShortcut(.defaultAction)
                    }
                case .missing(let files):
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Semantic.filesMissing)
                                .foregroundStyle(.red)
                            Text(L10n.Semantic.filesMissingDetail(files.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(semanticResumable > 0 ? L10n.Semantic.resumeDownload : L10n.Semantic.downloadAgain) { semanticProvider()?.requestDownload() }
                    }
                case .failed(let detail):
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Semantic.downloadFailed)
                                .foregroundStyle(.red)
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.Common.retry) { semanticProvider()?.requestDownload() }
                    }
                case .ready:
                    LabeledContent(L10n.Semantic.onDisk) {
                        Text(semanticDiskUsage)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text(semanticLicenseNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.Semantic.removeModel, role: .destructive) { showRemoveConfirmation = true }
                    }
                case .disabled:
                    EmptyView()
                }
            }
        } header: {
            Text(L10n.Semantic.title)
        } footer: {
            Text(L10n.Semantic.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(L10n.Semantic.removeTitle(semanticDescriptor.displayName), isPresented: $showRemoveConfirmation) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Common.remove, role: .destructive) {
                semanticProvider()?.removeModelAndVectors()
                reloadSemantic()
            }
        } message: {
            Text(semanticRemovalWarning)
        }
    }

    private var semanticDiskUsage: String {
        guard let coordinator = semanticProvider() else { return L10n.Common.dash }
        let model = coordinator.modelByteCount
        let vectors = coordinator.vectorByteCount
        guard vectors > 0 else { return L10n.megabytes(model) }
        return L10n.Semantic.diskUsage(
            model: L10n.megabytes(model),
            index: L10n.megabytes(vectors),
            total: L10n.megabytes(model + vectors)
        )
    }

    private var semanticRemovalWarning: String {
        guard let coordinator = semanticProvider() else {
            return L10n.Semantic.removeFallback
        }
        return L10n.Semantic.removeWarning(
            total: L10n.megabytes(coordinator.installedByteCount),
            indexed: coordinator.progress.done
        )
    }

    private var semanticIsBusy: Bool {
        if case .downloading = semanticState { return true }
        return false
    }

    private var semanticStatusIsError: Bool {
        switch semanticState {
        case .missing, .failed: return true
        default: return false
        }
    }

    private var semanticDescriptor: SemanticModelDescriptor {
        SemanticModelCatalog.resolved(id: semanticModelID)
    }

    private var semanticDownloadPrompt: String {
        guard semanticResumable > 0 else {
            return L10n.Semantic.downloadPrompt(
                name: semanticDescriptor.displayName,
                size: L10n.megabytes(semanticDescriptor.totalByteCount)
            )
        }
        let remaining = max(0, semanticDescriptor.totalByteCount - semanticResumable)
        return L10n.Semantic.resumePrompt(
            done: L10n.megabytes(semanticResumable),
            remaining: L10n.megabytes(remaining)
        )
    }

    private var semanticLicenseNotice: String {
        "\(semanticDescriptor.displayName) · \(semanticDescriptor.license)"
    }

    private var semanticStatusText: String {
        switch semanticState {
        case .disabled:
            return L10n.Common.off
        case .needsDownload:
            return L10n.Semantic.stateNotDownloaded
        case .downloading(let progress):
            return L10n.Semantic.stateDownloading(
                done: L10n.megabytes(progress.completedBytes),
                total: L10n.megabytes(progress.totalBytes)
            )
        case .missing:
            return L10n.Semantic.stateMissing
        case .failed:
            return L10n.Semantic.stateFailed
        case .ready:
            return L10n.Semantic.stateReady(semanticIndexed)
        }
    }

    private var semanticBinding: Binding<Bool> {
        Binding(
            get: { semanticEnabled },
            set: { desired in
                semanticEnabled = desired
                if AppSettings.shared.semanticSearchEnabled != desired {
                    AppSettings.shared.semanticSearchEnabled = desired
                }
                Log.settings.info("preferences semantic toggled value=\(desired, privacy: .public)")
                reloadSemantic()
            }
        )
    }

    private var semanticModelBinding: Binding<String> {
        Binding(
            get: { semanticModelID },
            set: { desired in
                semanticModelID = desired
                AppSettings.shared.semanticModelIdentifier = desired
                reloadSemantic()
            }
        )
    }

    private func reloadSemantic() {
        semanticEnabled = AppSettings.shared.semanticSearchEnabled
        semanticModelID = AppSettings.shared.semanticModelIdentifier
        guard let coordinator = semanticProvider() else {
            semanticState = semanticEnabled ? .needsDownload : .disabled
            semanticIndexed = 0
            semanticResumable = 0
            return
        }
        semanticState = coordinator.currentState
        semanticIndexed = coordinator.progress.done
        semanticResumable = coordinator.resumableByteCount
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { desired in
                launchAtLogin = desired
                loginError = nil
                do {
                    try LoginItem.setEnabled(desired)
                    Telemetry.log(.settingChanged, ["setting": "launch_at_login", "state": Telemetry.flag(desired)])
                } catch {
                    loginError = error.localizedDescription
                    Log.settings.error("preferences login toggle failed desired=\(desired, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
                reloadLogin()
            }
        )
    }

    private var dockVisibilityBinding: Binding<Bool> {
        Binding(
            get: { alwaysShowInDock },
            set: { desired in
                alwaysShowInDock = desired
                if AppSettings.shared.alwaysShowInDock != desired {
                    AppSettings.shared.alwaysShowInDock = desired
                }
                Log.settings.info("preferences always show in dock toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { updateChannel },
            set: { desired in
                guard desired != updateChannel else { return }
                updateChannel = desired
                AppSettings.shared.updateChannel = desired
                Log.settings.info("preferences update channel selected value=\(desired.rawValue, privacy: .public)")
            }
        )
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { automaticUpdates },
            set: { desired in
                UpdateCoordinator.shared.automaticChecksEnabled = desired
                let applied = UpdateCoordinator.shared.automaticChecksEnabled
                automaticUpdates = applied
                Log.settings.info("preferences automatic updates toggled desired=\(desired, privacy: .public) applied=\(applied, privacy: .public)")
            }
        )
    }

    private var thumbnailBinding: Binding<Bool> {
        Binding(
            get: { showsThumbnail },
            set: { desired in
                showsThumbnail = desired
                let applied = ScreencaptureDefaults.setShowsThumbnail(desired)
                let fresh = ScreencaptureDefaults.showsThumbnail()
                showsThumbnail = fresh
                let matched = fresh == desired
                thumbnailNotice = matched ? nil : L10n.Capture.thumbnailFailed
                Log.settings.info("preferences thumbnail toggled desired=\(desired, privacy: .public) applied=\(applied, privacy: .public) matched=\(matched, privacy: .public)")
            }
        )
    }

    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { ocrEnabled },
            set: { desired in
                ocrEnabled = desired
                if AppSettings.shared.ocrEnabled != desired {
                    AppSettings.shared.ocrEnabled = desired
                }
                Log.settings.info("preferences ocr toggled value=\(desired, privacy: .public)")
                reloadOCRProgress()
            }
        )
    }

    private var lazyIndexBinding: Binding<Bool> {
        Binding(
            get: { lazyIndexOnBattery },
            set: { desired in
                lazyIndexOnBattery = desired
                if AppSettings.shared.lazyIndexOnBattery != desired {
                    AppSettings.shared.lazyIndexOnBattery = desired
                }
                Log.settings.info("preferences lazy index on battery toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private var lowPowerBinding: Binding<Bool> {
        Binding(
            get: { pauseIndexingOnLowPower },
            set: { desired in
                pauseIndexingOnLowPower = desired
                if AppSettings.shared.pauseIndexingOnLowPower != desired {
                    AppSettings.shared.pauseIndexingOnLowPower = desired
                }
                Log.settings.info("preferences pause on low power toggled value=\(desired, privacy: .public)")
            }
        )
    }

    private var folderSummary: String {
        L10n.Folders.summary(folders.count)
    }

    private var ocrProgressText: String {
        guard ocrEnabled else { return L10n.Common.off }
        guard let ocrProgress else { return L10n.Search.notRunning }
        return L10n.Search.indexed(done: ocrProgress.done, total: ocrProgress.total)
    }

    private var shortcutDisplay: String {
        guard let hotKey else { return isRecording ? L10n.Shortcut.pressKeys : L10n.Shortcut.notSet }
        return HotKeyFormatter.display(hotKey)
    }

    private var recordButtonTitle: String {
        if isRecording { return L10n.Shortcut.recording }
        return hotKey == nil ? L10n.Shortcut.record : L10n.Shortcut.change
    }

    private func toggleRecording() {
        guard !recorder.isRecording else {
            stopRecording(reason: "toggle")
            shortcutNoticeIsError = false
            shortcutNotice = nil
            return
        }
        startRecording()
    }

    private func startRecording() {
        shortcutNoticeIsError = false
        shortcutNotice = nil
        isRecording = true
        Log.settings.info("preferences shortcut recording started current=\(self.hotKey.map { HotKeyFormatter.display($0) } ?? "none", privacy: .public)")
        recorder.start { outcome in handleRecording(outcome) }
    }

    private func stopRecording(reason: String) {
        guard recorder.isRecording else { return }
        recorder.stop(reason: reason)
        isRecording = false
    }

    private func handleWindowClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        guard window.identifier?.rawValue == "sukurini.preferences" else { return }
        guard recorder.isRecording else { return }
        stopRecording(reason: "window_closed")
        shortcutNoticeIsError = false
        shortcutNotice = nil
        Log.settings.info("preferences shortcut recording stopped by window close")
    }

    private func handleRecording(_ outcome: HotKeyRecorder.Outcome) {
        switch outcome {
        case .ignored:
            return
        case .cancelled:
            stopRecording(reason: "cancelled")
            shortcutNoticeIsError = false
            shortcutNotice = L10n.Shortcut.cancelled
            Log.settings.info("preferences shortcut recording cancelled")
        case .rejected(let reason):
            shortcutNoticeIsError = true
            shortcutNotice = reason
            Log.settings.info("preferences shortcut rejected reason=missing_modifiers")
        case .captured(let binding):
            stopRecording(reason: "captured")
            shortcutNoticeIsError = false
            shortcutNotice = nil
            hotKey = binding
            AppSettings.shared.galleryHotKey = binding
            Log.settings.info("preferences shortcut captured value=\(HotKeyFormatter.display(binding), privacy: .public) code=\(binding.keyCode, privacy: .public) modifiers=\(binding.carbonModifiers, privacy: .public)")
        }
    }

    private func clearShortcut() {
        stopRecording(reason: "cleared")
        shortcutNoticeIsError = false
        shortcutNotice = nil
        hotKey = nil
        AppSettings.shared.galleryHotKey = nil
        Log.settings.info("preferences shortcut cleared")
    }

    private func applyRegistrationState(_ note: Notification) {
        let failed = note.userInfo?[HotKeyCenter.registrationFailedKey] as? Bool ?? false
        if failed {
            shortcutNoticeIsError = true
            shortcutNotice = L10n.Shortcut.conflict
        } else if shortcutNoticeIsError {
            shortcutNoticeIsError = false
            shortcutNotice = nil
        }
        Log.settings.info("preferences shortcut registration failed=\(failed, privacy: .public)")
    }

    private func reloadHotKey() {
        hotKey = AppSettings.shared.galleryHotKey
        Log.settings.debug("preferences hotkey synced value=\(self.hotKey.map { HotKeyFormatter.display($0) } ?? "none", privacy: .public)")
    }

    private func reloadAll() {
        reloadFolders()
        reloadCaptureLocation()
        reloadThumbnail()
        reloadOCREnabled()
        reloadOCRProgress()
        reloadSemantic()
        reloadPowerPolicy()
        reloadLogin()
        reloadDockVisibility()
        reloadHotKey()
        reloadConversion()
        reloadBackfillProgress()
        reloadOrganize()
        reloadOrganizeProgress()
        reloadUpdates()
        reloadAnalytics()
        language = AppSettings.shared.language
        Log.settings.info("preferences reloaded folders=\(AppSettings.shared.folders.count, privacy: .public) loginAvailable=\(LoginItem.isAvailable, privacy: .public) language=\(self.language.rawValue, privacy: .public)")
    }

    private func relocalize() {
        language = AppSettings.shared.language
        loginStatus = LoginItem.statusDescription
        convertNotice = nil
        organizeNotice = nil
        captureNotice = nil
        shortcutNotice = nil
        thumbnailNotice = nil
        Log.settings.info("preferences relocalized language=\(LocalizationCenter.shared.language.rawValue, privacy: .public)")
    }

    private func reloadFolders() {
        let settings = AppSettings.shared
        folders = settings.folders
        activeFolder = settings.activeFolder
        Log.settings.debug("preferences folders synced count=\(settings.folders.count, privacy: .public) active=\(settings.activeFolder?.path ?? "none", privacy: .public)")
    }

    private func reloadCaptureLocation() {
        let location = ScreencaptureDefaults.currentLocation()
        Log.settings.debug("preferences capture location read path=\(location?.path ?? "none", privacy: .public)")
    }

    private func reloadThumbnail() {
        let value = ScreencaptureDefaults.showsThumbnail()
        showsThumbnail = value
        thumbnailNotice = nil
        Log.settings.debug("preferences thumbnail synced value=\(value, privacy: .public)")
    }

    private func reloadOCREnabled() {
        ocrEnabled = AppSettings.shared.ocrEnabled
    }

    private func reloadOCRProgress() {
        let progress = ocrProgressProvider()
        ocrProgress = progress
        Log.settings.debug("preferences ocr progress done=\(progress?.done ?? -1, privacy: .public) total=\(progress?.total ?? -1, privacy: .public)")
    }

    private func reloadPowerPolicy() {
        let settings = AppSettings.shared
        lazyIndexOnBattery = settings.lazyIndexOnBattery
        pauseIndexingOnLowPower = settings.pauseIndexingOnLowPower
        Log.settings.debug("preferences power policy synced lazy=\(settings.lazyIndexOnBattery, privacy: .public) pauseLowPower=\(settings.pauseIndexingOnLowPower, privacy: .public)")
    }

    private func reloadDockVisibility() {
        alwaysShowInDock = AppSettings.shared.alwaysShowInDock
        Log.settings.debug("preferences dock visibility synced value=\(self.alwaysShowInDock, privacy: .public)")
    }

    private func reloadUpdates() {
        let coordinator = UpdateCoordinator.shared
        let availability = coordinator.availability
        updateChannel = AppSettings.shared.updateChannel
        updateAvailability = availability
        automaticUpdates = coordinator.automaticChecksEnabled
        lastUpdateCheck = coordinator.lastUpdateCheckDate
        Log.settings.debug("preferences updates synced channel=\(self.updateChannel.rawValue, privacy: .public) availability=\(availability.reason, privacy: .public) automatic=\(self.automaticUpdates, privacy: .public)")
    }

    private func checkForUpdatesNow() {
        Log.settings.info("preferences requested update check channel=\(self.updateChannel.rawValue, privacy: .public)")
        UpdateCoordinator.shared.checkForUpdates()
        reloadUpdates()
    }

    private func reloadLogin() {
        loginAvailable = LoginItem.isAvailable
        loginNeedsApproval = LoginItem.requiresApproval
        launchAtLogin = LoginItem.isEnabled
        loginStatus = LoginItem.statusDescription
        Log.settings.debug("preferences login state available=\(loginAvailable, privacy: .public) enabled=\(launchAtLogin, privacy: .public) status=\(loginStatus, privacy: .public)")
    }

    private func selectFolder(_ folder: URL) {
        guard AppSettings.shared.activeFolder?.path != folder.path else { return }
        Log.settings.info("preferences active folder selected path=\(folder.path, privacy: .public)")
        AppSettings.shared.activeFolder = folder
        captureNotice = nil
        reloadFolders()
    }

    private func removeFolder(_ folder: URL) {
        guard AppSettings.shared.canRemoveFolder(folder) else {
            captureNoticeIsError = true
            captureNotice = L10n.Folders.removeBlocked(folder.lastPathComponent)
            Log.settings.info("preferences folder remove blocked reason=system path=\(folder.path, privacy: .public)")
            return
        }
        Log.settings.info("preferences folder removed path=\(folder.path, privacy: .public)")
        AppSettings.shared.removeFolder(folder)
        captureNotice = nil
        reloadFolders()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = L10n.Folders.addPrompt
        panel.message = L10n.Folders.addMessage
        if let activeFolder, folderExists(activeFolder) {
            panel.directoryURL = activeFolder
        }
        let response = panel.runModal()
        guard response == .OK, let picked = panel.url else {
            Log.settings.info("preferences add folder cancelled response=\(response.rawValue, privacy: .public)")
            return
        }
        Log.settings.info("preferences folder added path=\(picked.path, privacy: .public)")
        AppSettings.shared.addFolder(picked)
        reloadFolders()
    }

    private func setSystemLocation(_ folder: URL) {
        guard !AppSettings.shared.isSystemCaptureFolder(folder) else {
            Log.settings.info("preferences system location skipped reason=already_system path=\(folder.path, privacy: .public)")
            return
        }
        guard folderExists(folder) else {
            captureNoticeIsError = true
            captureNotice = L10n.Folders.folderMissingOnDisk
            Log.settings.error("preferences system location refused reason=missing path=\(folder.path, privacy: .public)")
            return
        }
        let applied = ScreencaptureDefaults.setLocation(folder)
        let fresh = ScreencaptureDefaults.currentLocation()
        let matched = fresh?.standardizedFileURL.path == folder.standardizedFileURL.path
        captureNoticeIsError = !(applied && matched)
        captureNotice = matched
            ? L10n.Folders.systemLocationApplied(folder.lastPathComponent)
            : L10n.Folders.systemLocationFailed
        Log.settings.info("preferences system location applied path=\(folder.path, privacy: .public) applied=\(applied, privacy: .public) matched=\(matched, privacy: .public)")
        AppSettings.shared.ensureSystemCaptureFolderListed()
        reloadFolders()
    }

    private func folderExists(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func displayPath(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }
}
