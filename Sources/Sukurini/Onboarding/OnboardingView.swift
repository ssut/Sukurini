import AppKit
import SwiftUI

struct OnboardingView: View {
    enum Step: String, CaseIterable {
        case permission
        case recommendations
        case backfill
        case welcome
    }

    enum Layout {
        static let width: CGFloat = 600
        static let height: CGFloat = 640
        static let horizontal: CGFloat = 40
        static let top: CGFloat = 44
    }

    private enum Timing {
        static let estimateRetryDelay: TimeInterval = 0.6
        static let estimateRetryLimit = 3
        static let startGrace: TimeInterval = 1.0
        static let transition = Animation.easeOut(duration: 0.24)
    }

    private static let repositoryURL = "https://github.com/ssut/Sukurini"

    private let presentation: OnboardingWindowController.Presentation
    private let coordinator: OnboardingCoordinator
    private let backfillProvider: () -> BackfillControlling?
    private let onFinish: () -> Void

    @State private var steps: [Step] = [.permission, .recommendations, .welcome]
    @State private var step = Step.permission
    @State private var probes: [FolderAccess.Probe] = []
    @State private var accessChecking = true
    @State private var recommendations: [OnboardingRecommendation] = []
    @State private var selection: Set<OnboardingRecommendationKind> = []
    @State private var hovered: OnboardingRecommendationKind?
    @State private var outcome = OnboardingOutcome()
    @State private var estimate: BackfillEstimate?
    @State private var estimateAttempts = 0
    @State private var pendingAdvance = false
    @State private var progress: BackfillProgress?
    @State private var backfillRunning = false
    @State private var backfillObservedRunning = false
    @State private var backfillFinished = false
    @State private var starOpened = false
    @State private var relocationSurvey: ScreenshotRelocator.Survey?
    @State private var moveExisting = true
    @State private var relocating = false
    @ObservedObject private var localization = LocalizationCenter.shared

    init(
        presentation: OnboardingWindowController.Presentation,
        coordinator: OnboardingCoordinator,
        backfillProvider: @escaping () -> BackfillControlling?,
        onFinish: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.coordinator = coordinator
        self.backfillProvider = backfillProvider
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .id(step)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 18)),
                                removal: .opacity
                            )
                        )
                        .padding(.horizontal, Layout.horizontal)
                        .padding(.top, Layout.top)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .frame(width: Layout.width, height: Layout.height)
        .onAppear { start() }
        .onReceive(NotificationCenter.default.publisher(for: .sukuriniWebPBackfillProgressChanged)) { _ in
            onMain { reloadBackfillProgress() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sukuriniLanguageChanged)) { _ in
            onMain { relocalizeRecommendations() }
        }
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [stepTint.opacity(0.14), stepTint.opacity(0.0)],
            startPoint: .top,
            endPoint: .center
        )
        .animation(.easeOut(duration: 0.4), value: step)
        .ignoresSafeArea()
    }

    private var stepTint: Color {
        switch step {
        case .permission:
            return .blue
        case .recommendations:
            return .purple
        case .backfill:
            return .green
        case .welcome:
            return .orange
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .permission:
            permissionStep
        case .recommendations:
            recommendationsStep
        case .backfill:
            backfillStep
        case .welcome:
            welcomeStep
        }
    }

    private func stepHeader(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingHeroBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                symbol: accessBlocked ? "lock.fill" : "lock.open.fill",
                tint: .blue,
                title: accessBlocked ? L10n.Onboarding.permissionTitleBlocked : L10n.Onboarding.permissionTitleReady,
                subtitle: L10n.Onboarding.permissionSubtitle
            )

            VStack(alignment: .leading, spacing: 10) {
                if accessChecking, probes.isEmpty {
                    OnboardingCard {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(L10n.Onboarding.checkingAccess)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(probes) { probe in
                    probeCard(probe)
                }
            }

            if accessBlocked {
                VStack(alignment: .leading, spacing: 12) {
                    Text(accessMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if !deniedProbes.isEmpty {
                            Button(L10n.Onboarding.openPrivacySettings) { FolderAccess.openPrivacySettings() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(L10n.Onboarding.checkAgain) { runAccessProbe(requested: true) }
                            .disabled(accessChecking)
                        if accessChecking {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func probeCard(_ probe: FolderAccess.Probe) -> some View {
        OnboardingCard {
            HStack(spacing: 12) {
                OnboardingIconChip(symbol: probeSymbol(probe.status), tint: probeColor(probe.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(probe.url.lastPathComponent)
                        .fontWeight(.medium)
                    Text(OnboardingSetup.displayPath(probe.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(probeLabel(probe.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(probeColor(probe.status))
            }
        }
    }

    private func probeSymbol(_ status: FolderAccess.Status) -> String {
        switch status {
        case .granted:
            return "checkmark"
        case .denied:
            return "lock.fill"
        case .missing:
            return "questionmark"
        }
    }

    private func probeColor(_ status: FolderAccess.Status) -> Color {
        switch status {
        case .granted:
            return .green
        case .denied:
            return .red
        case .missing:
            return .orange
        }
    }

    private func probeLabel(_ status: FolderAccess.Status) -> String {
        switch status {
        case .granted:
            return L10n.Onboarding.probeReadable
        case .denied:
            return L10n.Onboarding.probeDenied
        case .missing:
            return L10n.Onboarding.probeMissing
        }
    }

    private var recommendationsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                symbol: "wand.and.stars",
                tint: .purple,
                title: L10n.Onboarding.recommendationsTitle,
                subtitle: L10n.Onboarding.recommendationsSubtitle
            )

            VStack(spacing: 10) {
                ForEach(recommendations) { item in
                    recommendationCard(item)
                }
            }
        }
    }

    private func recommendationCard(_ item: OnboardingRecommendation) -> some View {
        let checked = item.satisfied || selection.contains(item.kind)
        return OnboardingCard(highlighted: checked && !item.satisfied) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    OnboardingIconChip(symbol: symbol(for: item.kind), tint: tint(for: item.kind))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            if item.satisfied {
                                Text(L10n.Onboarding.alreadySet)
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(0.4)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(checked ? (item.satisfied ? Color.secondary : Color.accentColor) : Color.secondary.opacity(0.45))
                        .padding(.top, 2)
                }
                if item.kind == .folder, checked, !item.satisfied {
                    moveRow
                }
            }
        }
        .opacity(item.satisfied ? 0.7 : 1)
        .scaleEffect(hovered == item.kind && !item.satisfied ? 1.01 : 1)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? item.kind : (hovered == item.kind ? nil : hovered) }
        .onTapGesture { toggle(item) }
    }

    @ViewBuilder
    private var moveRow: some View {
        if let survey = relocationSurvey {
            if survey.count > 0 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: moveExisting ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(moveExisting ? Color.accentColor : Color.secondary.opacity(0.55))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.Onboarding.moveExistingTitle(survey.count.formatted()))
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.Onboarding.moveExistingDetail(
                            source: survey.source.lastPathComponent,
                            size: L10n.bytes(survey.bytes)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
                .onTapGesture { toggleMove() }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.Onboarding.moveExistingSurveying)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func toggleMove() {
        moveExisting.toggle()
        Log.settings.info("onboarding move existing toggled value=\(self.moveExisting, privacy: .public) count=\(self.relocationSurvey?.count ?? -1, privacy: .public)")
    }

    private func symbol(for kind: OnboardingRecommendationKind) -> String {
        switch kind {
        case .thumbnail:
            return "bolt.fill"
        case .folder:
            return "folder.badge.plus"
        case .webp:
            return "archivebox.fill"
        case .telemetry:
            return "chart.bar.fill"
        }
    }

    private func tint(for kind: OnboardingRecommendationKind) -> Color {
        switch kind {
        case .thumbnail:
            return .orange
        case .folder:
            return .blue
        case .webp:
            return .green
        case .telemetry:
            return .pink
        }
    }

    private func toggle(_ item: OnboardingRecommendation) {
        guard !item.satisfied else { return }
        if selection.contains(item.kind) {
            selection.remove(item.kind)
        } else {
            selection.insert(item.kind)
        }
        Log.settings.info("onboarding recommendation toggled kind=\(item.kind.rawValue, privacy: .public) value=\(self.selection.contains(item.kind), privacy: .public)")
    }

    private var backfillStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                symbol: "internaldrive.fill",
                tint: .green,
                title: backfillTitle,
                subtitle: backfillSubtitle
            )

            OnboardingSavingsCard(
                amount: heroAmount,
                unit: heroUnit,
                caption: heroCaption,
                progress: heroProgress,
                muted: heroMuted
            ) {
                if backfillRunning || backfillFinished, let progress, progress.total > 0 {
                    HStack(spacing: 12) {
                        OnboardingStatTile(
                            value: "\(progress.converted.formatted()) / \(progress.total.formatted())",
                            caption: L10n.Onboarding.statConverted,
                            onDark: !heroMuted
                        )
                        OnboardingStatTile(
                            value: progress.reductionRatio > 0 ? percentText(progress.reductionRatio) : L10n.Common.dash,
                            caption: L10n.Onboarding.statSmaller,
                            onDark: !heroMuted
                        )
                        OnboardingStatTile(
                            value: backfillRunning ? remainingText : L10n.duration(progress.elapsed),
                            caption: backfillRunning ? L10n.Onboarding.statRemaining : L10n.Onboarding.statElapsed,
                            onDark: !heroMuted
                        )
                    }
                    .padding(.top, 2)
                }
            }

            if !backfillRunning, !backfillFinished, (estimate?.count ?? 0) > 0 {
                Text(disposalNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backfillTitle: String {
        if backfillFinished { return L10n.Onboarding.backfillDone }
        if backfillRunning { return L10n.Onboarding.backfillRunning }
        guard (estimate?.count ?? 0) > 0 else { return L10n.Onboarding.backfillNothing }
        return L10n.Onboarding.backfillReady
    }

    private var backfillSubtitle: String {
        let folder = AppSettings.shared.activeFolder?.lastPathComponent ?? L10n.Onboarding.fallbackFolderName
        if backfillFinished { return L10n.Onboarding.backfillDoneSubtitle }
        if backfillRunning { return L10n.Onboarding.backfillRunningSubtitle }
        guard (estimate?.count ?? 0) > 0 else { return L10n.Onboarding.backfillNothingSubtitle(folder) }
        return L10n.Onboarding.backfillReadySubtitle(folder)
    }

    private var heroMuted: Bool {
        !backfillRunning && !backfillFinished && (estimate?.count ?? 0) == 0
    }

    private var heroBytes: Int64 {
        if backfillRunning || backfillFinished { return progress?.savedBytes ?? 0 }
        return estimate?.estimatedSavedBytes ?? 0
    }

    private var heroAmount: String {
        guard estimate != nil || backfillRunning || backfillFinished else { return "…" }
        return splitBytes(heroBytes).amount
    }

    private var heroUnit: String {
        guard estimate != nil || backfillRunning || backfillFinished else { return "" }
        return splitBytes(heroBytes).unit
    }

    private var heroCaption: String {
        if backfillFinished, let progress {
            guard progress.converted > 0 else { return L10n.Onboarding.heroNothingConverted }
            return L10n.Onboarding.heroReclaimed(progress.converted.formatted())
        }
        if backfillRunning, let progress, progress.total > 0 {
            return L10n.Onboarding.heroRunning(done: progress.done.formatted(), total: progress.total.formatted())
        }
        if backfillRunning { return L10n.Onboarding.heroStarting }
        guard let estimate else { return L10n.Onboarding.heroCounting }
        guard estimate.count > 0 else { return L10n.Onboarding.heroNothingToConvert }
        return L10n.Onboarding.heroEstimate(count: estimate.count.formatted(), total: byteText(estimate.totalBytes))
    }

    private var heroProgress: Double? {
        guard backfillRunning, let progress, progress.total > 0 else { return nil }
        return Double(progress.done) / Double(progress.total)
    }

    private var remainingText: String {
        guard let progress, let eta = progress.estimatedTimeRemaining else { return L10n.Common.dash }
        return L10n.duration(eta)
    }

    private var disposalNotice: String {
        L10n.Onboarding.disposalNotice(AppSettings.shared.webpDisposal)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 62, height: 62)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.Onboarding.welcomeTitle)
                        .font(.system(size: 27, weight: .bold))
                    Text(L10n.Onboarding.welcomeSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            OnboardingCard(padding: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(summaryLines, id: \.self) { line in
                        OnboardingSummaryRow(symbol: "checkmark.circle.fill", tint: .green, text: line)
                    }
                    ForEach(outcome.failures, id: \.self) { failure in
                        OnboardingSummaryRow(symbol: "exclamationmark.triangle.fill", tint: .orange, text: failure)
                    }
                }
            }

            starCard
        }
    }

    private var starCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "star.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Color.orange.opacity(0.3), radius: 8, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Onboarding.starTitle)
                    .fontWeight(.semibold)
                Text(L10n.Onboarding.starDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(starOpened ? L10n.Onboarding.starThanks : L10n.Onboarding.starAction) { openRepository() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(starOpened)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var summaryLines: [String] {
        var lines: [String] = []
        if let folder = coordinator.pendingFolder ?? outcome.stagedFolder {
            lines.append(L10n.Onboarding.summaryFolderStaged(OnboardingSetup.displayPath(folder)))
        } else if let folder = AppSettings.shared.activeFolder {
            lines.append(L10n.Onboarding.summaryFolderWatching(folder.lastPathComponent))
        }
        if outcome.movedCount > 0, let source = outcome.moveSource {
            lines.append(L10n.Onboarding.summaryMoved(
                count: outcome.movedCount.formatted(),
                source: source.lastPathComponent
            ))
        }
        if !ScreencaptureDefaults.showsThumbnail() {
            lines.append(L10n.Onboarding.summaryThumbnailOff)
        }
        if AppSettings.shared.webpConversionEnabled {
            lines.append(L10n.Onboarding.summaryWebP)
        }
        if backfillFinished, let progress, progress.converted > 0 {
            lines.append(L10n.Onboarding.summaryReclaimed(
                saved: byteText(progress.savedBytes),
                count: progress.converted.formatted()
            ))
        }
        if AppSettings.shared.ocrEnabled {
            lines.append(L10n.Onboarding.summaryOCR)
        }
        return lines
    }

    private var footer: some View {
        HStack(spacing: 10) {
            OnboardingStepDots(total: steps.count, index: steps.firstIndex(of: step) ?? 0)
            Spacer()
            if let secondary = secondaryTitle {
                Button(secondary) { secondaryAction() }
                    .controlSize(.large)
                    .disabled(busy)
            }
            Button {
                primaryAction()
            } label: {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(primaryTitle)
                }
                .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
        }
        .padding(.horizontal, Layout.horizontal)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var busy: Bool {
        pendingAdvance || relocating
    }

    private var primaryTitle: String {
        switch step {
        case .permission:
            return L10n.Onboarding.continueAction
        case .recommendations:
            return selectedCount > 0 ? L10n.Onboarding.applyAndContinue : L10n.Onboarding.continueAction
        case .backfill:
            if backfillRunning || backfillFinished { return L10n.Onboarding.continueAction }
            guard let estimate, estimate.count > 0 else { return L10n.Onboarding.continueAction }
            return L10n.Onboarding.convertAction(estimate.count.formatted())
        case .welcome:
            return L10n.Onboarding.done
        }
    }

    private var selectedCount: Int {
        selection.intersection(Set(recommendations.filter { !$0.satisfied }.map(\.kind))).count
    }

    private var secondaryTitle: String? {
        switch step {
        case .permission:
            return accessBlocked ? L10n.Onboarding.skipForNow : nil
        case .recommendations:
            return L10n.Onboarding.skip
        case .backfill:
            if backfillRunning { return L10n.Common.stop }
            if backfillFinished { return nil }
            guard (estimate?.count ?? 0) > 0 else { return nil }
            return L10n.Onboarding.skip
        case .welcome:
            return nil
        }
    }

    private func primaryAction() {
        switch step {
        case .permission:
            move(to: .recommendations)
        case .recommendations:
            applyRecommendations()
        case .backfill:
            if backfillRunning || backfillFinished {
                leaveBackfill(reason: backfillRunning ? "continue_while_running" : "converted")
                return
            }
            guard let estimate, estimate.count > 0 else {
                leaveBackfill(reason: "nothing_to_convert")
                return
            }
            startBackfill()
        case .welcome:
            finish(reason: "done")
        }
    }

    private func secondaryAction() {
        switch step {
        case .permission:
            Log.settings.info("onboarding permission skipped blocked=\(self.accessBlocked, privacy: .public)")
            move(to: .recommendations)
        case .recommendations:
            Log.settings.info("onboarding recommendations skipped pending=\(self.selectedCount, privacy: .public)")
            selection.removeAll()
            outcome = OnboardingOutcome()
            requestBackfillStep()
        case .backfill:
            if backfillRunning {
                backfillProvider()?.cancelBackfill()
                Log.settings.info("onboarding backfill stop requested")
                return
            }
            leaveBackfill(reason: "skipped")
        case .welcome:
            finish(reason: "skip")
        }
    }

    private var showsAllSteps: Bool {
        presentation != .firstLaunch
    }

    private var accessBlocked: Bool {
        !accessChecking && FolderAccess.isBlocked(probes)
    }

    private var deniedProbes: [FolderAccess.Probe] {
        probes.filter { $0.status == .denied }
    }

    private var accessMessage: String {
        let denied = deniedProbes
        guard !denied.isEmpty else {
            return L10n.Onboarding.accessMissingMessage
        }
        let names = denied.map(\.url.lastPathComponent).joined(separator: L10n.Onboarding.nameJoiner)
        return L10n.Onboarding.accessDeniedMessage(names)
    }

    private func start() {
        recommendations = OnboardingSetup.recommendations()
        selection = Set(recommendations.filter { !$0.satisfied }.map(\.kind))
        refreshSteps()
        Log.settings.info("onboarding started presentation=\(self.presentation.rawValue, privacy: .public) allSteps=\(self.showsAllSteps, privacy: .public) steps=\(self.steps.map(\.rawValue).joined(separator: ","), privacy: .public)")
        runAccessProbe(requested: false)
        reloadBackfillProgress()
        prefetchEstimate()
        prefetchRelocationSurvey()
    }

    private func prefetchRelocationSurvey() {
        let target = OnboardingSetup.recommendedFolder
        guard let source = AppSettings.shared.activeFolder ?? ScreencaptureDefaults.currentLocation() else {
            relocationSurvey = .empty(target)
            Log.settings.info("onboarding relocation survey skipped reason=no_source")
            return
        }
        ScreenshotRelocator.survey(source: source, destination: target) { result in
            onMain {
                relocationSurvey = result
                Log.settings.info("onboarding relocation survey ready source=\(result.source.lastPathComponent, privacy: .public) count=\(result.count, privacy: .public) bytes=\(result.bytes, privacy: .public)")
            }
        }
    }

    private func relocalizeRecommendations() {
        recommendations = OnboardingSetup.recommendations()
        outcome.failures = []
        Log.settings.info("onboarding relocalized language=\(LocalizationCenter.shared.language.rawValue, privacy: .public) recommendations=\(self.recommendations.count, privacy: .public)")
    }

    private func runAccessProbe(requested: Bool) {
        accessChecking = true
        let targets = FolderAccess.watchedTargets()
        Log.settings.info("onboarding access probe requested=\(requested, privacy: .public) targets=\(targets.count, privacy: .public)")
        FolderAccess.evaluate(targets) { result in
            onMain {
                probes = result
                accessChecking = false
                refreshSteps()
                guard !showsAllSteps, step == .permission, !FolderAccess.isBlocked(result) else { return }
                Log.settings.info("onboarding permission step cleared, advancing")
                move(to: .recommendations)
            }
        }
    }

    private func refreshSteps() {
        var next: [Step] = []
        if showsAllSteps || accessChecking || FolderAccess.isBlocked(probes) || step == .permission {
            next.append(.permission)
        }
        if showsAllSteps || recommendations.contains(where: { !$0.satisfied }) || step == .recommendations {
            next.append(.recommendations)
        }
        if showsAllSteps || step == .backfill || backfillProvider()?.isBackfilling == true || backfillOffersWork {
            next.append(.backfill)
        }
        next.append(.welcome)
        steps = next
    }

    private var backfillOffersWork: Bool {
        guard AppSettings.shared.webpConversionEnabled else { return false }
        guard let estimate else { return true }
        return estimate.count > 0
    }

    private func move(to target: Step) {
        let order = Step.allCases
        guard let start = order.firstIndex(of: target) else { return }
        for candidate in order[start...] where steps.contains(candidate) {
            guard candidate != step else { return }
            withAnimation(Timing.transition) {
                step = candidate
                refreshSteps()
            }
            Log.settings.info("onboarding step shown value=\(candidate.rawValue, privacy: .public) steps=\(self.steps.map(\.rawValue).joined(separator: ","), privacy: .public)")
            onEnter(candidate)
            return
        }
        finish(reason: "no_more_steps")
    }

    private func onEnter(_ target: Step) {
        switch target {
        case .backfill:
            reloadBackfillProgress()
        case .welcome:
            coordinator.flushStagedFolder(reason: "welcome_step")
        case .permission, .recommendations:
            break
        }
    }

    private func applyRecommendations() {
        let pending = Set(recommendations.filter { !$0.satisfied }.map(\.kind))
        let chosen = selection.intersection(pending)
        var result = OnboardingOutcome()
        var target: URL?

        if chosen.contains(.folder) {
            if let folder = OnboardingSetup.createRecommendedFolder() {
                target = folder
                result.stagedFolder = folder
            } else {
                result.failures.append(L10n.Onboarding.failureFolder(OnboardingSetup.displayPath(OnboardingSetup.recommendedFolder)))
            }
        }
        if chosen.contains(.thumbnail) {
            result.thumbnailDisabled = OnboardingSetup.disableThumbnailPreview()
            if !result.thumbnailDisabled {
                result.failures.append(L10n.Onboarding.failureThumbnail)
            }
        }
        if chosen.contains(.webp) {
            OnboardingSetup.enableWebP()
            result.webpEnabled = true
        }
        if chosen.contains(.telemetry) {
            OnboardingSetup.enableTelemetry()
            result.telemetryEnabled = true
        }

        outcome = result
        Log.settings.info("onboarding recommendations applied chosen=\(chosen.map(\.rawValue).sorted().joined(separator: ","), privacy: .public) thumbnail=\(result.thumbnailDisabled, privacy: .public) webp=\(result.webpEnabled, privacy: .public) telemetry=\(result.telemetryEnabled, privacy: .public) folder=\(result.stagedFolder?.path ?? "none", privacy: .public) failures=\(result.failures.count, privacy: .public)")

        guard let target else {
            finishApply()
            return
        }
        guard let survey = pendingRelocation(to: target), confirmRelocation(survey, target: target) else {
            coordinator.stageFolder(target)
            finishApply()
            return
        }
        performRelocation(survey, target: target)
    }

    private func pendingRelocation(to target: URL) -> ScreenshotRelocator.Survey? {
        guard moveExisting else {
            Log.settings.info("onboarding relocation skipped reason=unchecked")
            return nil
        }
        guard let survey = relocationSurvey, survey.count > 0 else {
            Log.settings.info("onboarding relocation skipped reason=no_candidates surveyed=\(self.relocationSurvey != nil, privacy: .public)")
            return nil
        }
        guard survey.source.path != target.standardizedFileURL.path else {
            Log.settings.info("onboarding relocation skipped reason=same_folder")
            return nil
        }
        return survey
    }

    private func confirmRelocation(_ survey: ScreenshotRelocator.Survey, target: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.Onboarding.confirmMoveTitle(
            count: survey.count.formatted(),
            source: survey.source.lastPathComponent
        )
        alert.informativeText = L10n.Onboarding.confirmMoveBody(destination: OnboardingSetup.displayPath(target))
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.Onboarding.moveAction)
        alert.addButton(withTitle: L10n.Onboarding.keepInPlaceAction)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        Log.settings.info("onboarding relocation confirmation count=\(survey.count, privacy: .public) confirmed=\(confirmed, privacy: .public)")
        return confirmed
    }

    private func performRelocation(_ survey: ScreenshotRelocator.Survey, target: URL) {
        relocating = true
        ScreenshotRelocator.move(source: survey.source, destination: target) { result in
            onMain {
                relocating = false
                outcome.movedCount = result.moved
                outcome.moveSource = survey.source
                if result.failed > 0 {
                    outcome.failures.append(L10n.Onboarding.failureMove(result.failed.formatted()))
                }
                let adopted = OnboardingSetup.adoptFolder(target)
                if !adopted {
                    outcome.failures.append(L10n.Onboarding.failureAdopt(OnboardingSetup.displayPath(target)))
                }
                Log.settings.info("onboarding relocation applied moved=\(result.moved, privacy: .public) failed=\(result.failed, privacy: .public) adopted=\(adopted, privacy: .public)")
                estimate = nil
                estimateAttempts = 0
                prefetchEstimate()
                finishApply()
            }
        }
    }

    private func finishApply() {
        recommendations = OnboardingSetup.recommendations()
        requestBackfillStep()
    }

    private func requestBackfillStep() {
        guard !showsAllSteps else {
            move(to: .backfill)
            return
        }
        guard AppSettings.shared.webpConversionEnabled else {
            Log.settings.info("onboarding backfill step skipped reason=webp_off")
            move(to: .welcome)
            return
        }
        if backfillProvider()?.isBackfilling == true {
            move(to: .backfill)
            return
        }
        guard let estimate else {
            pendingAdvance = true
            Log.settings.info("onboarding advance waiting reason=estimate_pending")
            return
        }
        guard estimate.count > 0 else {
            Log.settings.info("onboarding backfill step skipped reason=no_candidates")
            move(to: .welcome)
            return
        }
        move(to: .backfill)
    }

    private func prefetchEstimate() {
        guard let controller = backfillProvider() else {
            estimate = .empty
            Log.settings.error("onboarding backfill estimate unavailable reason=no_controller")
            resolvePendingAdvance()
            return
        }
        controller.estimate { value in
            onMain {
                guard value.count == 0, estimateAttempts < Timing.estimateRetryLimit else {
                    estimate = value
                    Log.settings.info("onboarding backfill estimate settled count=\(value.count, privacy: .public) bytes=\(value.totalBytes, privacy: .public) attempts=\(self.estimateAttempts, privacy: .public)")
                    refreshSteps()
                    resolvePendingAdvance()
                    return
                }
                estimateAttempts += 1
                Log.settings.debug("onboarding backfill estimate retry attempt=\(self.estimateAttempts, privacy: .public)")
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.estimateRetryDelay) {
                    prefetchEstimate()
                }
            }
        }
    }

    private func resolvePendingAdvance() {
        guard pendingAdvance else { return }
        pendingAdvance = false
        requestBackfillStep()
    }

    private func startBackfill() {
        guard let controller = backfillProvider(), let estimate, estimate.count > 0 else { return }
        guard confirmDestructiveBackfill(count: estimate.count) else { return }

        backfillRunning = true
        backfillObservedRunning = false
        backfillFinished = false
        controller.startBackfill()
        Log.settings.info("onboarding backfill started count=\(estimate.count, privacy: .public) policy=\(AppSettings.shared.webpDisposal.rawValue, privacy: .public)")

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.startGrace) {
            guard step == .backfill, backfillRunning, !backfillObservedRunning else { return }
            guard backfillProvider()?.isBackfilling != true else { return }
            backfillRunning = false
            backfillFinished = false
            Log.settings.error("onboarding backfill never reported running, returning to ready state")
        }
    }

    private func confirmDestructiveBackfill(count: Int) -> Bool {
        guard AppSettings.shared.webpDisposal == .delete else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.Onboarding.confirmDeleteTitle(count.formatted())
        alert.informativeText = L10n.Onboarding.confirmDeleteBody
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.Common.convert)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        Log.settings.info("onboarding backfill confirmation policy=delete confirmed=\(confirmed, privacy: .public)")
        return confirmed
    }

    private func reloadBackfillProgress() {
        guard let controller = backfillProvider() else { return }
        let value = controller.backfillProgress
        progress = value
        let running = controller.isBackfilling
        if running { backfillObservedRunning = true }
        if backfillRunning, !running, backfillObservedRunning {
            backfillFinished = true
            Log.settings.info("onboarding backfill completed converted=\(value.converted, privacy: .public) saved=\(value.savedBytes, privacy: .public) ms=\(Int(value.elapsed * 1000), privacy: .public)")
        }
        backfillRunning = running
    }

    private func leaveBackfill(reason: String) {
        Log.settings.info("onboarding backfill step left reason=\(reason, privacy: .public)")
        move(to: .welcome)
    }

    private func openRepository() {
        guard let url = URL(string: Self.repositoryURL) else { return }
        let opened = NSWorkspace.shared.open(url)
        starOpened = opened
        Log.settings.info("onboarding repository opened=\(opened, privacy: .public)")
    }

    private func finish(reason: String) {
        Log.settings.info("onboarding finish requested reason=\(reason, privacy: .public) step=\(self.step.rawValue, privacy: .public)")
        onFinish()
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func splitBytes(_ bytes: Int64) -> (amount: String, unit: String) {
        let text = byteText(bytes)
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return (text, "") }
        return (String(parts[0]), String(parts[1]))
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func percentText(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
