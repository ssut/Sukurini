import AppKit
import Foundation

struct BackfillEstimate {
    let count: Int
    let totalBytes: Int64

    static let empty = BackfillEstimate(count: 0, totalBytes: 0)
    static let measuredReduction = 0.66

    var estimatedSavedBytes: Int64 { Int64(Double(totalBytes) * Self.measuredReduction) }
}

struct BackfillProgress {
    let done: Int
    let total: Int
    let converted: Int
    let savedBytes: Int64
    let processedBytes: Int64
    let totalBytes: Int64
    let elapsed: TimeInterval

    var remaining: Int { max(0, total - done) }

    var filesPerSecond: Double {
        guard elapsed > 0.25, done > 0 else { return 0 }
        return Double(done) / elapsed
    }

    var reductionRatio: Double {
        guard processedBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(processedBytes)
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard remaining > 0, elapsed > 0.25 else { return nil }
        guard processedBytes > 0, totalBytes > processedBytes else {
            let rate = filesPerSecond
            guard rate > 0 else { return nil }
            return Double(remaining) / rate
        }
        let bytesPerSecond = Double(processedBytes) / elapsed
        guard bytesPerSecond > 0 else { return nil }
        return Double(totalBytes - processedBytes) / bytesPerSecond
    }
}

protocol BackfillControlling: AnyObject {
    var isBackfilling: Bool { get }
    var isCatchUp: Bool { get }
    var backfillProgress: BackfillProgress { get }
    func estimate(completion: @escaping (BackfillEstimate) -> Void)
    func startBackfill()
    func cancelBackfill()
}

final class ConversionCoordinator: NSObject, ScreenshotConverting, BackfillControlling {
    private struct StagedConversion {
        let outcome: ConversionOutcome
        let policy: WebPDisposal
        let origin: ConversionOrigin
    }

    private final class ConversionOperation: Operation, @unchecked Sendable {
        private let request: ConversionRequest
        private unowned let coordinator: ConversionCoordinator

        init(request: ConversionRequest, coordinator: ConversionCoordinator) {
            self.request = request
            self.coordinator = coordinator
            super.init()
        }

        override func main() {
            guard !isCancelled else {
                coordinator.abandon(request, reason: "cancelled")
                return
            }
            coordinator.perform(request)
        }
    }

    private static let progressInterval: TimeInterval = 0.5
    private static let deferRetryDelay: TimeInterval = 0.5
    private static let maxParallelConversions = 4
    static let leaseKind = "webp"

    private let store: ScreenshotStore
    private let thumbnails: ThumbnailLoader
    private let settings = AppSettings.shared

    private let queue = OperationQueue()
    private let state = DispatchQueue(label: "sukurini.convert.state")
    private let disposal = DispatchQueue(label: "sukurini.convert.disposal", qos: .utility)

    private var staged: [UUID: StagedConversion] = [:]
    private var remaining: [Screenshot] = []
    private var doneCount = 0
    private var totalCount = 0
    private var convertedCount = 0
    private var savedBytes: Int64 = 0
    private var processedBytes: Int64 = 0
    private var candidateBytes: Int64 = 0
    private var active = false
    private var catchUp = false
    private var inFlight = 0
    private var deferScheduled = false
    private var lastProgressPost: TimeInterval = 0
    private var progressPostScheduled = false
    private var startedAt: TimeInterval = 0
    private var finishedAt: TimeInterval?

    private let parallelism: Int

    static var defaultParallelism: Int {
        max(1, min(maxParallelConversions, ProcessInfo.processInfo.activeProcessorCount))
    }

    init(store: ScreenshotStore, thumbnails: ThumbnailLoader, parallelism: Int = ConversionCoordinator.defaultParallelism) {
        self.store = store
        self.thumbnails = thumbnails
        self.parallelism = max(1, parallelism)
        super.init()
        queue.name = "sukurini.convert"
        queue.maxConcurrentOperationCount = parallelism
        queue.qualityOfService = .utility
        Log.convert.info("coordinator initialized parallelism=\(self.parallelism, privacy: .public) cores=\(ProcessInfo.processInfo.activeProcessorCount, privacy: .public)")
    }

    var isBackfilling: Bool { state.sync { active } }

    var isCatchUp: Bool { state.sync { catchUp } }

    var backfillProgress: BackfillProgress {
        state.sync {
            let reference = finishedAt ?? Date.timeIntervalSinceReferenceDate
            return BackfillProgress(
                done: doneCount,
                total: totalCount,
                converted: convertedCount,
                savedBytes: savedBytes,
                processedBytes: processedBytes,
                totalBytes: candidateBytes,
                elapsed: startedAt > 0 ? max(0, reference - startedAt) : 0
            )
        }
    }

    func enqueue(_ request: ConversionRequest) {
        let operation = ConversionOperation(request: request, coordinator: self)
        operation.qualityOfService = request.origin == .live ? .userInitiated : .utility
        operation.queuePriority = request.origin == .live ? .veryHigh : .normal
        queue.addOperation(operation)
    }

    func commit(token: UUID) {
        state.async {
            guard let entry = self.staged.removeValue(forKey: token) else { return }
            self.disposal.async {
                let removed = ScreenshotConverter.dispose(entry.outcome.source.url, policy: entry.policy)
                let remains = entry.policy == .keep || !removed
                Log.convert.info("committed path=\(entry.outcome.source.path, privacy: .public) saved=\(entry.outcome.savedBytes, privacy: .public) policy=\(entry.policy.rawValue, privacy: .public) remains=\(remains, privacy: .public)")
                if entry.origin == .backfill {
                    self.recordConverted(entry.outcome)
                }
                self.store.conversionDidFinish(token: token, sourceRemains: remains)
                if entry.origin == .backfill { self.completeItem() }
            }
        }
    }

    func discard(token: UUID, reason: String) {
        state.async {
            guard let entry = self.staged.removeValue(forKey: token) else { return }
            self.disposal.async {
                ScreenshotConverter.discard(entry.outcome.destination)
                Log.convert.error("discarded path=\(entry.outcome.destination.path, privacy: .public) reason=\(reason, privacy: .public)")
                self.store.conversionDidFinish(token: token, sourceRemains: true)
                if entry.origin == .backfill { self.completeItem() }
            }
        }
    }

    func cancelPending(reason: String) {
        for operation in queue.operations where !operation.isExecuting {
            operation.cancel()
        }
        state.async {
            guard self.active else { return }
            self.remaining.removeAll()
            self.finishLocked(reason: reason)
        }
    }

    fileprivate func perform(_ request: ConversionRequest) {
        let policy = settings.webpDisposal
        let effort = request.origin == .live ? WebPEncoder.liveEffort : WebPEncoder.backfillEffort
        do {
            let outcome = try ScreenshotConverter.stage(request.source, effort: effort)
            state.sync {
                staged[request.token] = StagedConversion(outcome: outcome, policy: policy, origin: request.origin)
            }
            thumbnails.seed(
                outcome.image,
                for: outcome.destination,
                maxPixel: ThumbnailLoader.dragThumbnailPixel
            )
            let converted = Screenshot(
                url: outcome.destination,
                created: request.source.created,
                size: outcome.outputBytes
            )
            store.conversionDidStage(token: request.token, converted: converted)
        } catch {
            abandon(request, reason: Self.describe(error))
        }
    }

    fileprivate func abandon(_ request: ConversionRequest, reason: String) {
        Log.convert.error("conversion failed path=\(request.source.path, privacy: .public) reason=\(reason, privacy: .public)")
        store.conversionDidFail(token: request.token, reason: reason)
        if request.origin == .backfill { completeItem() }
    }

    private static func describe(_ error: Error) -> String {
        if let converterError = error as? ScreenshotConverterError { return converterError.reason }
        if let encoderError = error as? WebPEncoderError { return encoderError.reason }
        return "unknown"
    }

    func estimate(completion: @escaping (BackfillEstimate) -> Void) {
        store.backfillCandidates { candidates in
            let bytes = candidates.reduce(Int64(0)) { $0 + $1.size }
            completion(BackfillEstimate(count: candidates.count, totalBytes: bytes))
        }
    }

    func startBackfill() {
        beginRun(floor: nil, label: "backfill")
    }

    func startCatchUp(since: Date) {
        store.backfillCandidates { [weak self] candidates in
            guard let self else { return }
            let due = candidates.filter { $0.created >= since }
            guard !due.isEmpty else {
                Log.convert.info("catchup skipped reason=nothing_new pngs=\(candidates.count, privacy: .public) since=\(Int(since.timeIntervalSince1970), privacy: .public)")
                return
            }
            let bytes = due.reduce(Int64(0)) { $0 + $1.size }
            Log.convert.info("catchup due count=\(due.count, privacy: .public) of=\(candidates.count, privacy: .public) bytes=\(bytes, privacy: .public) since=\(Int(since.timeIntervalSince1970), privacy: .public)")
            self.beginRun(floor: since, label: "catchup")
        }
    }

    private func beginRun(floor: Date?, label: String) {
        store.beginExclusiveBackfill(Self.leaseKind) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Log.convert.info("run start refused kind=\(label, privacy: .public) reason=lease_unavailable")
                self.postProgress()
                return
            }
            self.startBackfillLocked(floor: floor, label: label)
        }
    }

    private func startBackfillLocked(floor: Date?, label: String) {
        state.async {
            guard !self.active else {
                Log.convert.info("run start ignored kind=\(label, privacy: .public) reason=already_running")
                return
            }
            self.active = true
            self.catchUp = floor != nil
            self.inFlight = 0
            self.doneCount = 0
            self.totalCount = 0
            self.convertedCount = 0
            self.savedBytes = 0
            self.processedBytes = 0
            self.candidateBytes = 0
            self.startedAt = 0
            self.finishedAt = nil
            self.store.backfillCandidates { [weak self] candidates in
                guard let self else { return }
                self.state.async {
                    guard self.active else { return }
                    let selected = floor.map { mark in candidates.filter { $0.created >= mark } } ?? candidates
                    self.remaining = selected
                    self.totalCount = selected.count
                    self.candidateBytes = selected.reduce(Int64(0)) { $0 + $1.size }
                    guard !selected.isEmpty else {
                        self.finishLocked(reason: "no_candidates")
                        return
                    }
                    self.startedAt = Date.timeIntervalSinceReferenceDate
                    Log.convert.info("run started kind=\(label, privacy: .public) count=\(selected.count, privacy: .public) skipped=\(candidates.count - selected.count, privacy: .public) lanes=\(self.parallelism, privacy: .public)")
                    self.postProgress()
                    self.stepLocked()
                }
            }
        }
    }

    func cancelBackfill() {
        state.async {
            guard self.active else { return }
            self.remaining.removeAll()
            Log.convert.info("backfill cancel requested done=\(self.doneCount, privacy: .public) total=\(self.totalCount, privacy: .public)")
            self.finishLocked(reason: "cancelled")
        }
    }

    private func stepLocked() {
        guard active else { return }
        while inFlight < parallelism, !remaining.isEmpty {
            let next = remaining.removeFirst()
            inFlight += 1
            store.claimBackfill(next) { [weak self] claim in
                guard let self else { return }
                self.state.async {
                    guard self.active else { return }
                    switch claim {
                    case .started:
                        return
                    case .deferred:
                        self.inFlight -= 1
                        self.remaining.insert(next, at: 0)
                        guard !self.deferScheduled else { return }
                        self.deferScheduled = true
                        self.state.asyncAfter(deadline: .now() + Self.deferRetryDelay) {
                            self.deferScheduled = false
                            self.stepLocked()
                        }
                    case .skipped:
                        self.inFlight -= 1
                        self.doneCount += 1
                        self.scheduleProgressLocked()
                        self.stepLocked()
                    }
                }
            }
        }
        if inFlight == 0, remaining.isEmpty {
            finishLocked(reason: "complete")
        }
    }

    private func completeItem() {
        state.async {
            guard self.active else { return }
            self.inFlight = max(0, self.inFlight - 1)
            self.doneCount += 1
            self.scheduleProgressLocked()
            self.stepLocked()
        }
    }

    private func recordConverted(_ outcome: ConversionOutcome) {
        state.async {
            self.convertedCount += 1
            self.savedBytes += outcome.savedBytes
            self.processedBytes += outcome.source.size
        }
    }

    private func finishLocked(reason: String) {
        active = false
        inFlight = 0
        remaining.removeAll()
        if startedAt > 0, finishedAt == nil {
            finishedAt = Date.timeIntervalSinceReferenceDate
        }
        let seconds = finishedAt.map { $0 - startedAt } ?? 0
        let rate = seconds > 0 ? Double(doneCount) / seconds : 0
        store.endExclusiveBackfill(Self.leaseKind)
        Log.convert.info("run finished kind=\(self.catchUp ? "catchup" : "backfill", privacy: .public) reason=\(reason, privacy: .public) done=\(self.doneCount, privacy: .public) total=\(self.totalCount, privacy: .public) converted=\(self.convertedCount, privacy: .public) saved=\(self.savedBytes, privacy: .public) ms=\(Int(seconds * 1000), privacy: .public) rate=\(String(format: "%.1f", rate), privacy: .public)")
        postProgress()
    }

    private func scheduleProgressLocked() {
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastProgressPost
        guard elapsed < Self.progressInterval else {
            lastProgressPost = now
            postProgress()
            return
        }
        guard !progressPostScheduled else { return }
        progressPostScheduled = true
        state.asyncAfter(deadline: .now() + (Self.progressInterval - elapsed)) { [weak self] in
            guard let self else { return }
            self.progressPostScheduled = false
            self.lastProgressPost = Date.timeIntervalSinceReferenceDate
            self.postProgress()
        }
    }

    private func postProgress() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sukuriniWebPBackfillProgressChanged, object: nil)
        }
    }
}
