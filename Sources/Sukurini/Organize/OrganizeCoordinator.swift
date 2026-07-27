import AppKit
import Foundation

struct OrganizeEstimate {
    let count: Int

    static let empty = OrganizeEstimate(count: 0)
}

struct OrganizeProgress {
    let done: Int
    let total: Int
    let moved: Int
    let failed: Int
    let elapsed: TimeInterval

    var remaining: Int { max(0, total - done) }

    var filesPerSecond: Double {
        guard elapsed > 0.25, done > 0 else { return 0 }
        return Double(done) / elapsed
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard remaining > 0, elapsed > 0.25 else { return nil }
        let rate = filesPerSecond
        guard rate > 0 else { return nil }
        return Double(remaining) / rate
    }
}

protocol OrganizeControlling: AnyObject {
    var isOrganizing: Bool { get }
    var organizeProgress: OrganizeProgress { get }
    func estimate(completion: @escaping (OrganizeEstimate) -> Void)
    func startOrganize()
    func cancelOrganize()
}

final class OrganizeCoordinator: OrganizeControlling {
    private static let progressInterval: TimeInterval = 0.5
    private static let deferRetryDelay: TimeInterval = 0.5
    private static let chunkSize = 200
    static let leaseKind = "organize"

    private let store: ScreenshotStore
    private let state = DispatchQueue(label: "sukurini.organize.state")
    private let indexLock = NSLock()

    private var index: SearchIndex?
    private var remaining: [Screenshot] = []
    private var doneCount = 0
    private var totalCount = 0
    private var movedCount = 0
    private var failedCount = 0
    private var active = false
    private var deferScheduled = false
    private var lastProgressPost: TimeInterval = 0
    private var progressPostScheduled = false
    private var startedAt: TimeInterval = 0
    private var finishedAt: TimeInterval?

    init(store: ScreenshotStore, index: SearchIndex?) {
        self.store = store
        self.index = index
        store.setRelocationHandler { [weak self] pairs in
            guard let self, !pairs.isEmpty else { return }
            guard let index = self.currentIndex() else { return }
            let moves = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key.path, $0.value.path) })
            index.movePaths(moves)
        }
        Log.organize.info("coordinator initialized chunk=\(Self.chunkSize, privacy: .public) index=\(index != nil, privacy: .public)")
    }

    func attachIndex(_ index: SearchIndex?) {
        indexLock.lock()
        self.index = index
        indexLock.unlock()
        Log.organize.info("index attached present=\(index != nil, privacy: .public)")
    }

    private func currentIndex() -> SearchIndex? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return index
    }

    var isOrganizing: Bool { state.sync { active } }

    var organizeProgress: OrganizeProgress {
        state.sync {
            let reference = finishedAt ?? Date.timeIntervalSinceReferenceDate
            return OrganizeProgress(
                done: doneCount,
                total: totalCount,
                moved: movedCount,
                failed: failedCount,
                elapsed: startedAt > 0 ? max(0, reference - startedAt) : 0
            )
        }
    }

    func estimate(completion: @escaping (OrganizeEstimate) -> Void) {
        store.organizeCandidates { candidates in
            completion(OrganizeEstimate(count: candidates.count))
        }
    }

    func startOrganize() {
        store.beginExclusiveBackfill(Self.leaseKind) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Log.organize.info("organize start refused reason=lease_unavailable")
                self.postProgress()
                return
            }
            self.state.async {
                guard !self.active else {
                    Log.organize.info("organize start ignored reason=already_running")
                    return
                }
                self.active = true
                self.doneCount = 0
                self.totalCount = 0
                self.movedCount = 0
                self.failedCount = 0
                self.startedAt = 0
                self.finishedAt = nil
                self.store.organizeCandidates { [weak self] candidates in
                    guard let self else { return }
                    self.state.async {
                        guard self.active else { return }
                        self.remaining = candidates
                        self.totalCount = candidates.count
                        guard !candidates.isEmpty else {
                            self.finishLocked(reason: "no_candidates")
                            return
                        }
                        self.startedAt = Date.timeIntervalSinceReferenceDate
                        self.store.setRelocationHold(true)
                        Log.organize.info("organize started count=\(candidates.count, privacy: .public)")
                        self.postProgress()
                        self.stepLocked()
                    }
                }
            }
        }
    }

    func cancelOrganize() {
        state.async {
            guard self.active else { return }
            self.remaining.removeAll()
            Log.organize.info("organize cancel requested done=\(self.doneCount, privacy: .public) total=\(self.totalCount, privacy: .public)")
            self.finishLocked(reason: "cancelled")
        }
    }

    private func stepLocked() {
        guard active else { return }
        guard !remaining.isEmpty else {
            finishLocked(reason: "complete")
            return
        }

        let size = min(Self.chunkSize, remaining.count)
        let chunk = Array(remaining.prefix(size))
        remaining.removeFirst(size)

        store.organizeChunk(chunk) { [weak self] result in
            guard let self else { return }
            self.state.async {
                guard self.active else { return }
                guard !result.deferred else {
                    self.remaining.insert(contentsOf: chunk, at: 0)
                    guard !self.deferScheduled else { return }
                    self.deferScheduled = true
                    Log.organize.debug("organize chunk deferred size=\(chunk.count, privacy: .public)")
                    self.state.asyncAfter(deadline: .now() + Self.deferRetryDelay) {
                        self.deferScheduled = false
                        self.stepLocked()
                    }
                    return
                }
                self.doneCount += chunk.count
                self.movedCount += result.moved.count
                self.failedCount += result.failed
                self.scheduleProgressLocked()
                self.stepLocked()
            }
        }
    }

    private func finishLocked(reason: String) {
        active = false
        remaining.removeAll()
        if startedAt > 0, finishedAt == nil {
            finishedAt = Date.timeIntervalSinceReferenceDate
        }
        let seconds = finishedAt.map { $0 - startedAt } ?? 0
        store.setRelocationHold(false)
        store.endExclusiveBackfill(Self.leaseKind)
        Log.organize.info("organize finished reason=\(reason, privacy: .public) done=\(self.doneCount, privacy: .public) total=\(self.totalCount, privacy: .public) moved=\(self.movedCount, privacy: .public) failed=\(self.failedCount, privacy: .public) ms=\(Int(seconds * 1000), privacy: .public)")
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
            NotificationCenter.default.post(name: .sukuriniOrganizeBackfillProgressChanged, object: nil)
        }
    }
}
