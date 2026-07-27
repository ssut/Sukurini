import Foundation

enum ConversionOrigin {
    case live
    case backfill
}

enum BackfillClaim {
    case started
    case deferred
    case skipped
}

struct OrganizeChunkResult {
    let moved: [URL: URL]
    let failed: Int
    let deferred: Bool
}

struct ConversionRequest {
    let token: UUID
    let source: Screenshot
    let destination: URL
    let origin: ConversionOrigin
}

protocol ScreenshotConverting: AnyObject {
    func enqueue(_ request: ConversionRequest)
    func commit(token: UUID)
    func discard(token: UUID, reason: String)
    func cancelPending(reason: String)
}

final class ScreenshotStore {
    private struct PendingFile {
        var size: Int64
        var attempt: Int
        var batch: Int
    }

    private struct ConversionHold {
        let token: UUID
        let source: URL
        let destination: URL
        var visible: Screenshot?
        let origin: ConversionOrigin
        var timedOut = false
    }

    private static let resourceKeys: [URLResourceKey] = [
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .isHiddenKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isRegularFileKey
    ]
    private static let resourceKeySet = Set(resourceKeys)
    private static let maximumScanDepth = DateFolderFormat.maximumDepth

    private static let localSettleDelays: [TimeInterval] = [0.10, 0.3, 0.6, 1.2]
    private static let remoteSettleDelays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0]

    private let settleGrace: TimeInterval = 2.0
    private let promotionCoalesce: TimeInterval = 0.025
    private let slowRetryDelay: TimeInterval = 5.0
    private let slowRetryLimit = 3
    private let verificationDelay: TimeInterval = 1.5
    private let verificationRoundLimit = 8
    private let watcherDebounce: TimeInterval = 0.12
    private let remotePollInterval: TimeInterval = 5.0
    private let recoveryPollInterval: TimeInterval = 2.0
    private let validationProbeLimit = 8

    private let scanQueue = DispatchQueue(label: "sukurini.store.scan", qos: .utility)
    private let stateLock = NSLock()

    private var lockedItems: [Screenshot] = []
    private var lockedActiveFolder: URL?
    private var lockedFolderMissing = false
    private var lockedIncludeSubfolders = false

    private var observers: [(StoreChange) -> Void] = []
    private var watcher: FolderWatching?

    private var scanFolder: URL?
    private var scanSettleDelays: [TimeInterval] = ScreenshotStore.localSettleDelays
    private var scanLocalityPath: String?
    private var scanItems: [Screenshot] = []
    private var pending: [URL: PendingFile] = [:]
    private var abandoned: [URL: Int] = [:]
    private var promotedBuffer: [Screenshot] = []
    private var promotionFlushScheduled = false
    private var verificationScheduled = false
    private var verificationRounds = 0
    private var scanBatch = 0
    private var generation = 0
    private var scanFolderMissing = false
    private var remoteTimer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?

    private let liveConversionTimeout: TimeInterval = 12.0
    private let backfillConversionTimeout: TimeInterval = 45.0

    private weak var converter: ScreenshotConverting?
    private var converting: [URL: ConversionHold] = [:]
    private var conversionEnabled = false
    private var conversionFloor = Date.distantFuture
    private var dragHold = false
    private var retiredBuffer: Set<URL> = []
    private var replacementBuffer: [URL: URL] = [:]

    private var organizeEnabled = false
    private var organizePattern: String?
    private var organizeFloor = Date.distantFuture
    private var relocationHold = false
    private var rescanDeferred = false
    private var backfillLease: String?
    private var onRelocate: (([URL: URL]) -> Void)?

    init() {
        Log.store.info("store initialized debounce=\(self.watcherDebounce, privacy: .public)")
    }

    var items: [Screenshot] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedItems
    }

    var latest: Screenshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedItems.first
    }

    var activeFolder: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedActiveFolder
    }

    var isFolderMissing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedFolderMissing
    }

    func addObserver(_ handler: @escaping (StoreChange) -> Void) {
        runOnMain {
            self.observers.append(handler)
            Log.store.info("observer added count=\(self.observers.count, privacy: .public)")
        }
    }

    func activate(folder: URL?) {
        runOnMain {
            let resolved = folder?.standardizedFileURL
            Log.store.info("activate path=\(resolved?.path ?? "none", privacy: .public)")
            self.setActiveFolder(resolved)
            self.setFolderMissing(false)
            self.installWatcher(for: resolved)
            self.scanQueue.async {
                self.generation += 1
                self.pending.removeAll()
                self.abandoned.removeAll()
                self.promotedBuffer.removeAll()
                self.retiredBuffer.removeAll()
                self.replacementBuffer.removeAll()
                self.conversionFloor = Date()
                self.organizeFloor = Date()
                self.relocationHold = false
                self.rescanDeferred = false
                self.converter?.cancelPending(reason: "activate")
                self.verificationRounds = 0
                self.scanFolder = resolved
                self.scanFolderMissing = false
                self.stopRecoveryTimer()
                self.configureRemotePolling(for: resolved)
                self.performScan(fullReload: true)
            }
        }
    }

    func rescanNow() {
        Log.store.debug("rescan requested")
        scanQueue.async { self.performScan(fullReload: false) }
    }

    func validatedLatest() -> Screenshot? {
        let snapshot = items
        guard !snapshot.isEmpty else {
            Log.store.debug("validatedLatest empty")
            return nil
        }
        let manager = FileManager.default
        let limit = min(snapshot.count, validationProbeLimit)
        for index in 0..<limit {
            let candidate = snapshot[index]
            if manager.fileExists(atPath: candidate.path) {
                if index > 0 {
                    Log.store.info("validatedLatest skipped missing count=\(index, privacy: .public) path=\(candidate.path, privacy: .public)")
                    rescanNow()
                }
                return candidate
            }
        }
        Log.store.error("validatedLatest found no existing file probes=\(limit, privacy: .public) total=\(snapshot.count, privacy: .public)")
        rescanNow()
        return nil
    }

    private func installWatcher(for folder: URL?) {
        let previous = watcher
        let recursive = includeSubfolders
        if let folder {
            let next: FolderWatching = recursive
                ? RecursiveFolderWatcher(
                    url: folder,
                    debounce: watcherDebounce,
                    onChange: { [weak self] in self?.handleWatcherChange() },
                    onFolderLost: { [weak self] in self?.handleWatcherFolderLost() }
                )
                : FolderWatcher(
                    url: folder,
                    debounce: watcherDebounce,
                    onChange: { [weak self] in self?.handleWatcherChange() },
                    onFolderLost: { [weak self] in self?.handleWatcherFolderLost() }
                )
            watcher = next
            next.start()
        } else {
            watcher = nil
        }
        previous?.cancel()
        Log.store.debug("watcher installed path=\(folder?.path ?? "none", privacy: .public) replaced=\(previous != nil, privacy: .public) recursive=\(recursive, privacy: .public)")
    }

    private func handleWatcherChange() {
        scanQueue.async { self.performScan(fullReload: false) }
    }

    private func handleWatcherFolderLost() {
        Log.store.error("watcher reported folder lost path=\(self.activeFolder?.path ?? "none", privacy: .public)")
        watcher?.cancel()
        watcher = nil
        scanQueue.async { self.applyFolderLost(reason: "watcher") }
    }

    private func performScan(fullReload: Bool) {
        guard !relocationHold || fullReload else {
            rescanDeferred = true
            Log.store.debug("scan deferred reason=relocation_hold")
            return
        }

        guard let folder = scanFolder else {
            publish([], fullReload: true)
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            applyFolderLost(reason: "missing")
            return
        }

        guard let entries = collectEntries(in: folder) else { return }

        if scanFolderMissing {
            scanFolderMissing = false
            stopRecoveryTimer()
            setFolderMissing(false)
            Log.store.info("folder recovered path=\(folder.path, privacy: .public)")
        }

        refreshSettleLadder(for: folder)

        let known = Set(scanItems.map(\.url))
        let currentGeneration = generation
        scanBatch += 1
        let currentBatch = scanBatch
        let now = Date()
        var stable: [Screenshot] = []
        var discovered = Set<URL>()
        var claimed = Set<URL>()
        var deferredCount = 0

        for entry in entries {
            guard ScreenshotFile.isEligible(entry) else { continue }
            guard claimed.insert(entry).inserted else {
                Log.store.debug("scan duplicate skipped path=\(entry.path, privacy: .public)")
                continue
            }

            if let hold = converting[entry] {
                discovered.insert(entry)
                if let frozen = hold.visible {
                    stable.append(frozen)
                }
                continue
            }

            guard let values = try? entry.resourceValues(forKeys: Self.resourceKeySet) else { continue }
            guard values.isHidden != true else { continue }

            let size = Int64(values.fileSize ?? 0)
            let created = values.creationDate ?? values.contentModificationDate ?? Date.distantPast
            let modified = values.contentModificationDate ?? values.creationDate ?? Date.distantPast
            discovered.insert(entry)

            if known.contains(entry) {
                pending.removeValue(forKey: entry)
                abandoned.removeValue(forKey: entry)
                stable.append(Screenshot(url: entry, created: created, size: size))
                continue
            }

            if size > 0, now.timeIntervalSince(modified) >= settleGrace {
                pending.removeValue(forKey: entry)
                abandoned.removeValue(forKey: entry)
                let settled = organizedIfNeeded(Screenshot(url: entry, created: created, size: size))
                claimed.insert(settled.url)
                if isLiveConversionCandidate(url: settled.url, modified: modified),
                   beginConversion(source: settled, visible: nil, origin: .live) {
                    continue
                }
                stable.append(settled)
                continue
            }

            deferredCount += 1
            enqueuePending(url: entry, size: size, generation: currentGeneration, batch: currentBatch)
        }

        for url in Array(pending.keys) where !discovered.contains(url) {
            pending.removeValue(forKey: url)
            Log.store.debug("pending dropped, vanished path=\(url.path, privacy: .public)")
        }
        for url in Array(abandoned.keys) where !discovered.contains(url) {
            abandoned.removeValue(forKey: url)
        }

        stable.sort(by: Self.isOrderedBefore)
        Log.store.debug("scan done path=\(folder.path, privacy: .public) stable=\(stable.count, privacy: .public) deferred=\(deferredCount, privacy: .public) full=\(fullReload, privacy: .public)")
        publish(stable, fullReload: fullReload)
    }

    private func refreshSettleLadder(for folder: URL) {
        guard scanLocalityPath != folder.path else { return }
        scanLocalityPath = folder.path
        let values = try? folder.resourceValues(forKeys: [.volumeIsLocalKey])
        let isLocal = values?.volumeIsLocal ?? true
        scanSettleDelays = isLocal ? Self.localSettleDelays : Self.remoteSettleDelays
        Log.store.info("settle ladder selected path=\(folder.path, privacy: .public) local=\(isLocal, privacy: .public) first=\(self.scanSettleDelays[0], privacy: .public)")
    }

    private func enqueuePending(url: URL, size: Int64, generation currentGeneration: Int, batch: Int) {
        guard pending[url] == nil else { return }
        pending[url] = PendingFile(size: size, attempt: 0, batch: batch)
        Log.store.debug("settle queued path=\(url.path, privacy: .public) size=\(size, privacy: .public) batch=\(batch, privacy: .public)")
        schedulePendingCheck(url: url, generation: currentGeneration)
    }

    private func schedulePendingCheck(url: URL, generation currentGeneration: Int) {
        guard let entry = pending[url], entry.attempt < scanSettleDelays.count else { return }
        let delay = scanSettleDelays[entry.attempt]
        scanQueue.asyncAfter(deadline: .now() + delay, qos: .userInitiated) { [weak self] in
            self?.checkPending(url: url, generation: currentGeneration)
        }
    }

    private func checkPending(url: URL, generation currentGeneration: Int) {
        guard currentGeneration == generation, var entry = pending[url] else { return }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeValue = attributes[.size] as? NSNumber else {
            pending.removeValue(forKey: url)
            Log.store.info("settle aborted, file gone path=\(url.path, privacy: .public)")
            return
        }

        let size = sizeValue.int64Value
        if size > 0, size == entry.size {
            pending.removeValue(forKey: url)
            let created = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date) ?? Date()
            Log.store.info("settle stable path=\(url.path, privacy: .public) size=\(size, privacy: .public) attempt=\(entry.attempt, privacy: .public)")
            promote(Screenshot(url: url, created: created, size: size), batch: entry.batch)
            return
        }

        entry.size = size
        entry.attempt += 1
        guard entry.attempt < scanSettleDelays.count else {
            pending.removeValue(forKey: url)
            let round = (abandoned[url] ?? 0) + 1
            abandoned[url] = round
            Log.store.error("settle gave up path=\(url.path, privacy: .public) size=\(size, privacy: .public) attempts=\(entry.attempt, privacy: .public) round=\(round, privacy: .public)")
            guard round <= slowRetryLimit else {
                Log.store.error("settle abandoned path=\(url.path, privacy: .public) rounds=\(round, privacy: .public)")
                return
            }
            scanQueue.asyncAfter(deadline: .now() + slowRetryDelay) { [weak self] in
                guard let self, currentGeneration == self.generation else { return }
                Log.store.info("settle slow retry path=\(url.path, privacy: .public) round=\(round, privacy: .public)")
                self.performScan(fullReload: false)
            }
            return
        }
        pending[url] = entry
        Log.store.debug("settle retry path=\(url.path, privacy: .public) size=\(size, privacy: .public) attempt=\(entry.attempt, privacy: .public)")
        schedulePendingCheck(url: url, generation: currentGeneration)
    }

    private func promote(_ screenshot: Screenshot, batch: Int) {
        let placed = organizedIfNeeded(screenshot)
        if isLiveConversionCandidate(url: placed.url, modified: placed.created),
           beginConversion(source: placed, visible: nil, origin: .live) {
            scheduleVerification(reset: true)
            return
        }
        promotedBuffer.removeAll { $0.url == placed.url }
        promotedBuffer.append(placed)

        let siblingsPending = pending.values.contains { $0.batch == batch }
        guard siblingsPending else {
            flushPromotions(generation: generation)
            return
        }

        guard !promotionFlushScheduled else { return }
        promotionFlushScheduled = true
        let currentGeneration = generation
        Log.store.debug("promotion held for batch siblings batch=\(batch, privacy: .public)")
        scanQueue.asyncAfter(deadline: .now() + promotionCoalesce, qos: .userInitiated) { [weak self] in
            self?.flushPromotions(generation: currentGeneration)
        }
    }

    private func flushPromotions(generation currentGeneration: Int) {
        promotionFlushScheduled = false
        guard currentGeneration == generation else {
            promotedBuffer.removeAll()
            retiredBuffer.removeAll()
            replacementBuffer.removeAll()
            return
        }
        let batch = promotedBuffer
        promotedBuffer.removeAll()
        let retired = retiredBuffer
        retiredBuffer.removeAll()
        let replacements = replacementBuffer
        replacementBuffer.removeAll()
        guard !batch.isEmpty || !retired.isEmpty else { return }

        let batchURLs = Set(batch.map(\.url))
        var next = scanItems.filter { !batchURLs.contains($0.url) && !retired.contains($0.url) }
        next.append(contentsOf: batch)
        next.sort(by: Self.isOrderedBefore)
        Log.store.info("settle batch flushed count=\(batch.count, privacy: .public) retired=\(retired.count, privacy: .public)")
        publish(next, fullReload: false, replacements: replacements)
        scheduleVerification(reset: true)
    }

    private func scheduleVerification(reset: Bool) {
        if reset { verificationRounds = 0 }
        guard !verificationScheduled else { return }
        guard verificationRounds < verificationRoundLimit else {
            Log.store.debug("verification rounds exhausted rounds=\(self.verificationRounds, privacy: .public)")
            return
        }
        verificationScheduled = true
        let currentGeneration = generation
        scanQueue.asyncAfter(deadline: .now() + verificationDelay) { [weak self] in
            guard let self else { return }
            self.verificationScheduled = false
            guard currentGeneration == self.generation else { return }
            self.verificationRounds += 1
            Log.store.debug("verification scan round=\(self.verificationRounds, privacy: .public)")
            self.performScan(fullReload: false)
        }
    }

    private func applyFolderLost(reason: String) {
        guard !scanFolderMissing else { return }
        scanFolderMissing = true
        pending.removeAll()
        abandoned.removeAll()
        promotedBuffer.removeAll()
        Log.store.error("folder lost path=\(self.scanFolder?.path ?? "none", privacy: .public) reason=\(reason, privacy: .public)")
        setFolderMissing(true)
        publish([], fullReload: true)
        startRecoveryTimer()
    }

    private func startRecoveryTimer() {
        stopRecoveryTimer()
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now() + recoveryPollInterval, repeating: recoveryPollInterval)
        timer.setEventHandler { [weak self] in self?.pollRecovery() }
        recoveryTimer = timer
        timer.resume()
        Log.store.info("recovery poll started interval=\(self.recoveryPollInterval, privacy: .public)")
    }

    private func stopRecoveryTimer() {
        guard let timer = recoveryTimer else { return }
        timer.cancel()
        recoveryTimer = nil
        Log.store.debug("recovery poll stopped")
    }

    private func pollRecovery() {
        guard scanFolderMissing, let folder = scanFolder else {
            stopRecoveryTimer()
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        Log.store.info("folder reappeared path=\(folder.path, privacy: .public)")
        stopRecoveryTimer()
        runOnMain {
            self.installWatcher(for: folder)
            self.scanQueue.async { self.performScan(fullReload: true) }
        }
    }

    private func configureRemotePolling(for folder: URL?) {
        stopRemoteTimer()
        guard let folder else { return }
        let values = try? folder.resourceValues(forKeys: [.volumeIsLocalKey])
        let isLocal = values?.volumeIsLocal ?? true
        guard !isLocal else {
            Log.store.debug("volume is local, polling disabled path=\(folder.path, privacy: .public)")
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: scanQueue)
        timer.schedule(deadline: .now() + remotePollInterval, repeating: remotePollInterval)
        timer.setEventHandler { [weak self] in self?.performScan(fullReload: false) }
        remoteTimer = timer
        timer.resume()
        Log.store.info("remote volume polling started path=\(folder.path, privacy: .public) interval=\(self.remotePollInterval, privacy: .public)")
    }

    private func stopRemoteTimer() {
        guard let timer = remoteTimer else { return }
        timer.cancel()
        remoteTimer = nil
        Log.store.debug("remote volume polling stopped")
    }

    private func publish(_ newItems: [Screenshot], fullReload: Bool, replacements: [URL: URL] = [:]) {
        let previousOrder = scanItems.map(\.url)
        let previousURLs = Set(previousOrder)
        let previousSizes = Dictionary(scanItems.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })
        let newOrder = newItems.map(\.url)
        let newURLs = Set(newOrder)
        scanItems = newItems

        let removed = previousURLs.subtracting(newURLs)
        let insertedURLs = newURLs.subtracting(previousURLs)
        let orderChanged = previousOrder != newOrder
        let drifted = newItems.filter { item in
            guard let previousSize = previousSizes[item.url] else { return false }
            return previousSize != item.size
        }
        if !drifted.isEmpty {
            for item in drifted {
                Log.store.error("size drift corrected path=\(item.path, privacy: .public) size=\(item.size, privacy: .public) previous=\(previousSizes[item.url] ?? -1, privacy: .public)")
            }
            scheduleVerification(reset: false)
        }
        let treatAsFull = fullReload || (insertedURLs.isEmpty && removed.isEmpty && (orderChanged || !drifted.isEmpty))
        let inserted = treatAsFull ? newItems : newItems.filter { insertedURLs.contains($0.url) }
        let verifiedReplacements = treatAsFull ? [:] : replacements.filter { removed.contains($0.key) && insertedURLs.contains($0.value) }
        let change = StoreChange(
            inserted: inserted,
            removedURLs: removed,
            isFullReload: treatAsFull,
            replacements: verifiedReplacements
        )

        runOnMain {
            self.setItems(newItems)
            guard !change.isEmpty else { return }
            Log.store.info("publish inserted=\(change.inserted.count, privacy: .public) removed=\(change.removedURLs.count, privacy: .public) full=\(change.isFullReload, privacy: .public) total=\(newItems.count, privacy: .public) observers=\(self.observers.count, privacy: .public)")
            for observer in self.observers {
                observer(change)
            }
        }
    }

    func setConverter(_ converter: ScreenshotConverting?) {
        scanQueue.async {
            self.converter = converter
            Log.store.info("converter attached present=\(converter != nil, privacy: .public)")
        }
    }

    func setConversionEnabled(_ enabled: Bool) {
        scanQueue.async {
            guard self.conversionEnabled != enabled else { return }
            self.conversionEnabled = enabled
            if enabled {
                self.conversionFloor = Date()
            } else {
                self.converter?.cancelPending(reason: "disabled")
            }
            Log.store.info("conversion enabled value=\(enabled, privacy: .public)")
        }
    }

    func setDragHold(_ active: Bool) {
        scanQueue.async { self.dragHold = active }
    }

    func setIncludeSubfolders(_ enabled: Bool) {
        runOnMain {
            self.stateLock.lock()
            let changed = self.lockedIncludeSubfolders != enabled
            self.lockedIncludeSubfolders = enabled
            self.stateLock.unlock()
            guard changed else { return }
            Log.store.info("includeSubfolders updated value=\(enabled, privacy: .public)")
            let folder = self.activeFolder
            self.installWatcher(for: folder)
            self.scanQueue.async { self.performScan(fullReload: true) }
        }
    }

    func setOrganize(enabled: Bool, pattern: String) {
        scanQueue.async {
            var resolved: String?
            switch DateFolderFormat.resolve(pattern) {
            case .success(let value):
                resolved = value.pattern
            case .failure(let issue):
                Log.store.error("organize pattern rejected value=\(pattern, privacy: .public) reason=\(issue.rawValue, privacy: .public)")
            }
            let active = enabled && resolved != nil
            let changed = self.organizeEnabled != active || self.organizePattern != resolved
            self.organizeEnabled = active
            self.organizePattern = resolved
            if changed, active {
                self.organizeFloor = Date()
            }
            Log.store.info("organize enabled=\(active, privacy: .public) pattern=\(resolved ?? "none", privacy: .public) changed=\(changed, privacy: .public)")
        }
    }

    func setRelocationHandler(_ handler: (([URL: URL]) -> Void)?) {
        scanQueue.async {
            self.onRelocate = handler
            Log.store.info("relocation handler attached present=\(handler != nil, privacy: .public)")
        }
    }

    func setRelocationHold(_ active: Bool) {
        scanQueue.async {
            guard self.relocationHold != active else { return }
            self.relocationHold = active
            Log.store.info("relocation hold value=\(active, privacy: .public)")
            guard !active, self.rescanDeferred else { return }
            self.rescanDeferred = false
            self.performScan(fullReload: false)
        }
    }

    func beginExclusiveBackfill(_ kind: String, completion: @escaping (Bool) -> Void) {
        scanQueue.async {
            guard self.backfillLease == nil || self.backfillLease == kind else {
                Log.store.info("backfill lease refused kind=\(kind, privacy: .public) held=\(self.backfillLease ?? "none", privacy: .public)")
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.backfillLease = kind
            Log.store.info("backfill lease granted kind=\(kind, privacy: .public)")
            DispatchQueue.main.async { completion(true) }
        }
    }

    func endExclusiveBackfill(_ kind: String) {
        scanQueue.async {
            guard self.backfillLease == kind else { return }
            self.backfillLease = nil
            Log.store.info("backfill lease released kind=\(kind, privacy: .public)")
        }
    }

    func organizeCandidates(completion: @escaping ([Screenshot]) -> Void) {
        scanQueue.async {
            guard let folder = self.scanFolder, self.organizePattern != nil else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let items = self.scanItems.filter {
                ScreenshotOrganizer.isInRoot($0.url, root: folder) && self.converting[$0.url] == nil
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    func organizeChunk(_ screenshots: [Screenshot], completion: @escaping (OrganizeChunkResult) -> Void) {
        scanQueue.async {
            guard let folder = self.scanFolder, let pattern = self.organizePattern else {
                DispatchQueue.main.async { completion(OrganizeChunkResult(moved: [:], failed: screenshots.count, deferred: false)) }
                return
            }
            guard !self.dragHold else {
                DispatchQueue.main.async { completion(OrganizeChunkResult(moved: [:], failed: 0, deferred: true)) }
                return
            }

            var moved: [URL: URL] = [:]
            var failed = 0
            for screenshot in screenshots {
                guard let current = self.scanItems.first(where: { $0.url == screenshot.url }),
                      self.converting[current.url] == nil else {
                    failed += 1
                    continue
                }
                switch ScreenshotOrganizer.move(current, root: folder, pattern: pattern) {
                case .moved(let destination):
                    moved[current.url] = destination
                    self.onRelocate?([current.url: destination])
                case .skipped, .failed:
                    failed += 1
                }
            }

            let result = OrganizeChunkResult(moved: moved, failed: failed, deferred: false)
            guard !moved.isEmpty else {
                DispatchQueue.main.async { completion(result) }
                return
            }

            let next = self.scanItems.map { item -> Screenshot in
                guard let destination = moved[item.url] else { return item }
                return Screenshot(url: destination, created: item.created, size: item.size)
            }.sorted(by: Self.isOrderedBefore)

            Log.store.info("organize chunk applied moved=\(moved.count, privacy: .public) failed=\(failed, privacy: .public)")
            self.publish(next, fullReload: false, replacements: moved)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func backfillCandidates(completion: @escaping ([Screenshot]) -> Void) {
        scanQueue.async {
            let converted = Set(
                self.scanItems
                    .filter { $0.url.pathExtension.lowercased() == ScreenshotFile.convertedExtension }
                    .map { $0.url.path }
            )
            let items = self.scanItems.filter {
                guard ScreenshotFile.isConvertible($0.url), self.converting[$0.url] == nil else { return false }
                return !converted.contains(ScreenshotFile.convertedURL(for: $0.url).path)
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    func claimBackfill(_ screenshot: Screenshot, completion: @escaping (BackfillClaim) -> Void) {
        scanQueue.async {
            guard !self.dragHold else {
                DispatchQueue.main.async { completion(.deferred) }
                return
            }
            guard let current = self.scanItems.first(where: { $0.url == screenshot.url }),
                  FileManager.default.fileExists(atPath: current.path) else {
                DispatchQueue.main.async { completion(.skipped) }
                return
            }
            let started = self.beginConversion(source: current, visible: current, origin: .backfill)
            DispatchQueue.main.async { completion(started ? .started : .skipped) }
        }
    }

    func conversionDidStage(token: UUID, converted: Screenshot) {
        scanQueue.async {
            guard let hold = self.converting[converted.url], hold.token == token else {
                self.converter?.discard(token: token, reason: "hold_lost")
                return
            }
            guard !hold.timedOut, self.converting[hold.source]?.timedOut != true else {
                self.converter?.discard(token: token, reason: "timed_out")
                return
            }
            let pending = self.converter
            guard self.canPublish(converted.url) else {
                Log.store.info("conversion publish skipped reason=folder_changed path=\(converted.path, privacy: .public)")
                DispatchQueue.main.async { pending?.commit(token: token) }
                return
            }

            if let visible = self.converting[hold.source]?.visible {
                self.retiredBuffer.insert(visible.url)
                self.replacementBuffer[visible.url] = converted.url
                self.converting[hold.source]?.visible = nil
            }
            self.promotedBuffer.removeAll { $0.url == converted.url }
            self.promotedBuffer.append(converted)
            self.flushPromotions(generation: self.generation)
            DispatchQueue.main.async { pending?.commit(token: token) }
        }
    }

    func conversionDidFinish(token: UUID, sourceRemains: Bool) {
        scanQueue.async {
            self.releaseHold(token: token, publishOriginal: sourceRemains, reason: "finished")
        }
    }

    func conversionDidFail(token: UUID, reason: String) {
        scanQueue.async {
            self.releaseHold(token: token, publishOriginal: true, reason: reason)
        }
    }

    private func isLiveConversionCandidate(url: URL, modified: Date) -> Bool {
        guard conversionEnabled, converter != nil else { return false }
        guard ScreenshotFile.isConvertible(url) else { return false }
        guard modified >= conversionFloor else { return false }
        guard converting[url] == nil else { return false }
        return true
    }

    @discardableResult
    private func beginConversion(source: Screenshot, visible: Screenshot?, origin: ConversionOrigin) -> Bool {
        guard let converter else { return false }
        let destination = ScreenshotFile.convertedURL(for: source.url)
        guard converting[source.url] == nil, converting[destination] == nil else { return false }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            Log.store.info("conversion skipped reason=destination_exists path=\(destination.path, privacy: .public)")
            return false
        }

        let token = UUID()
        converting[source.url] = ConversionHold(
            token: token,
            source: source.url,
            destination: destination,
            visible: visible,
            origin: origin
        )
        converting[destination] = ConversionHold(
            token: token,
            source: source.url,
            destination: destination,
            visible: nil,
            origin: origin
        )

        let timeout = origin == .live ? liveConversionTimeout : backfillConversionTimeout
        scanQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.handleConversionTimeout(token: token, source: source.url)
        }

        Log.store.info("conversion started path=\(source.path, privacy: .public) origin=\(origin == .live ? "live" : "backfill", privacy: .public) held=\(self.converting.count, privacy: .public)")
        converter.enqueue(ConversionRequest(token: token, source: source, destination: destination, origin: origin))
        return true
    }

    private func releaseHold(token: UUID, publishOriginal: Bool, reason: String) {
        guard let entry = converting.values.first(where: { $0.token == token }) else { return }
        converting.removeValue(forKey: entry.source)
        converting.removeValue(forKey: entry.destination)
        Log.store.info("conversion released path=\(entry.source.path, privacy: .public) reason=\(reason, privacy: .public) restore=\(publishOriginal, privacy: .public)")
        guard publishOriginal, canPublish(entry.source) else { return }
        guard let restored = probe(entry.source) else { return }
        promotedBuffer.removeAll { $0.url == entry.source }
        promotedBuffer.append(restored)
        flushPromotions(generation: generation)
    }

    private func handleConversionTimeout(token: UUID, source: URL) {
        guard var hold = converting[source], hold.token == token, !hold.timedOut else { return }
        hold.timedOut = true
        converting[hold.destination]?.timedOut = true
        Log.store.error("conversion timed out path=\(source.path, privacy: .public)")
        guard hold.visible == nil, canPublish(source), let restored = probe(source) else {
            converting[source] = hold
            return
        }
        hold.visible = restored
        converting[source] = hold
        promotedBuffer.removeAll { $0.url == source }
        promotedBuffer.append(restored)
        flushPromotions(generation: generation)
    }

    private func probe(_ url: URL) -> Screenshot? {
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeySet),
              let size = values.fileSize, size > 0 else { return nil }
        let created = values.creationDate ?? values.contentModificationDate ?? Date()
        return Screenshot(url: url, created: created, size: Int64(size))
    }

    private func canPublish(_ url: URL) -> Bool {
        guard let folder = scanFolder else { return false }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let root = folder.standardizedFileURL.path
        if parent == root { return true }
        guard includeSubfolders else { return false }
        return parent.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private var includeSubfolders: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedIncludeSubfolders
    }

    private func collectEntries(in folder: URL) -> [URL]? {
        guard includeSubfolders else {
            do {
                return try FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
            } catch {
                Log.store.error("scan failed path=\(folder.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                Log.store.error("scan entry failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return true
            }
        ) else {
            Log.store.error("scan enumerator unavailable path=\(folder.path, privacy: .public)")
            return nil
        }

        let rootDepth = folder.standardizedFileURL.pathComponents.count
        var entries: [URL] = []
        var skipped = 0

        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: Self.resourceKeySet)
            if values?.isDirectory == true {
                let depth = candidate.standardizedFileURL.pathComponents.count - rootDepth
                if values?.isSymbolicLink == true || values?.isPackage == true || depth > Self.maximumScanDepth {
                    enumerator.skipDescendants()
                    skipped += 1
                }
                continue
            }
            guard values?.isSymbolicLink != true, values?.isRegularFile != false else { continue }
            entries.append(candidate)
        }

        Log.store.debug("recursive scan collected path=\(folder.path, privacy: .public) files=\(entries.count, privacy: .public) skippedDirs=\(skipped, privacy: .public)")
        return entries
    }

    private func organizedIfNeeded(_ screenshot: Screenshot) -> Screenshot {
        guard organizeEnabled, let pattern = organizePattern, let folder = scanFolder else { return screenshot }
        guard screenshot.created >= organizeFloor else { return screenshot }
        guard includeSubfolders else {
            Log.store.error("organize skipped path=\(screenshot.path, privacy: .public) reason=subfolders_hidden")
            return screenshot
        }
        guard converting[screenshot.url] == nil else { return screenshot }
        guard ScreenshotOrganizer.isInRoot(screenshot.url, root: folder) else { return screenshot }

        switch ScreenshotOrganizer.move(screenshot, root: folder, pattern: pattern) {
        case .moved(let destination):
            return Screenshot(url: destination, created: screenshot.created, size: screenshot.size)
        case .skipped, .failed:
            return screenshot
        }
    }

    private func setItems(_ newItems: [Screenshot]) {
        stateLock.lock()
        lockedItems = newItems
        stateLock.unlock()
    }

    private func setActiveFolder(_ folder: URL?) {
        stateLock.lock()
        lockedActiveFolder = folder
        stateLock.unlock()
    }

    private func setFolderMissing(_ missing: Bool) {
        stateLock.lock()
        let changed = lockedFolderMissing != missing
        lockedFolderMissing = missing
        stateLock.unlock()
        if changed {
            Log.store.info("folderMissing changed value=\(missing, privacy: .public)")
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private static func isOrderedBefore(_ lhs: Screenshot, _ rhs: Screenshot) -> Bool {
        if lhs.created != rhs.created { return lhs.created > rhs.created }
        return lhs.name > rhs.name
    }
}
