import CoreGraphics
import Foundation
import IOKit.ps
import ImageIO
import Vision
import os

enum OCRPowerSource: String {
    case ac
    case battery

    static func current() -> OCRPowerSource {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            Log.ocr.error("power source snapshot unavailable fallback=ac")
            return .ac
        }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else {
            Log.ocr.error("power source type unavailable fallback=ac")
            return .ac
        }
        let value = type as String
        switch value {
        case kIOPSACPowerValue:
            return .ac
        case kIOPSBatteryPowerValue, kIOPSOffLineValue:
            return .battery
        default:
            Log.ocr.error("power source unrecognized value=\(value, privacy: .public) fallback=ac")
            return .ac
        }
    }
}

struct OCRPowerEnvironment {
    var source: OCRPowerSource
    var lowPowerMode: Bool
    var thermalState: ProcessInfo.ThermalState

    static func system() -> OCRPowerEnvironment {
        let info = ProcessInfo.processInfo
        return OCRPowerEnvironment(
            source: OCRPowerSource.current(),
            lowPowerMode: info.isLowPowerModeEnabled,
            thermalState: info.thermalState
        )
    }
}

struct OCRPowerPolicy: Equatable {
    static let normalConcurrency = 2
    static let lazyConcurrency = 1
    static let lazyIdleRatio = 0.5
    static let minimumIdleInterval: TimeInterval = 0.05
    static let maximumIdleInterval: TimeInterval = 1.0

    let source: OCRPowerSource
    let lowPowerMode: Bool
    let thermalState: ProcessInfo.ThermalState
    let lazyOnBattery: Bool
    let pauseOnLowPower: Bool
    let lazyActive: Bool
    let concurrency: Int
    let qualityOfService: QualityOfService
    let idleRatio: Double
    let paused: Bool

    init(environment: OCRPowerEnvironment, lazyOnBattery: Bool, pauseOnLowPower: Bool) {
        source = environment.source
        lowPowerMode = environment.lowPowerMode
        thermalState = environment.thermalState
        self.lazyOnBattery = lazyOnBattery
        self.pauseOnLowPower = pauseOnLowPower

        let lazy = lazyOnBattery && environment.source == .battery
        lazyActive = lazy
        concurrency = lazy ? OCRPowerPolicy.lazyConcurrency : OCRPowerPolicy.normalConcurrency
        qualityOfService = lazy ? .background : .utility
        idleRatio = lazy ? OCRPowerPolicy.lazyIdleRatio : 0

        let thermalPause = environment.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        paused = thermalPause || (environment.lowPowerMode && pauseOnLowPower)
    }

    func idleInterval(forWork elapsed: TimeInterval) -> TimeInterval {
        guard idleRatio > 0 else { return 0 }
        let scaled = elapsed * idleRatio
        return min(max(scaled, OCRPowerPolicy.minimumIdleInterval), OCRPowerPolicy.maximumIdleInterval)
    }
}

private final class OCRPowerSourceObserver {
    private let handler: () -> Void
    private var source: CFRunLoopSource?

    init?(handler: @escaping () -> Void) {
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { raw in
            guard let raw = raw else { return }
            Unmanaged<OCRPowerSourceObserver>.fromOpaque(raw).takeUnretainedValue().handler()
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            Log.ocr.error("power source subscription failed")
            return nil
        }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        Log.ocr.info("power source subscription installed")
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let source = source else { return }
        self.source = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        Log.ocr.info("power source subscription removed")
    }
}

private final class OCROperation: Operation, @unchecked Sendable {
    private weak var indexer: OCRIndexer?
    private let screenshot: Screenshot
    private let needsText: Bool
    private let needsVector: Bool

    init(indexer: OCRIndexer, screenshot: Screenshot, needsText: Bool, needsVector: Bool) {
        self.indexer = indexer
        self.screenshot = screenshot
        self.needsText = needsText
        self.needsVector = needsVector
        super.init()
    }

    override func main() {
        guard !isCancelled, let indexer = indexer else { return }
        let started = Date()
        indexer.process(
            screenshot,
            needsText: needsText,
            needsVector: needsVector,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
        let elapsed = Date().timeIntervalSince(started)
        indexer.idle(afterWork: elapsed, isCancelled: { [weak self] in self?.isCancelled ?? true })
    }
}

final class OCRIndexer {
    private static let maximumPixel = 2_000
    private static let minimumConfidence: Float = 0.3
    private static let progressInterval: TimeInterval = 1.0
    private static let reconcileDebounce: TimeInterval = 1.5
    private static let maximumReconcileRetries = 40
    private static let idleSliceInterval: TimeInterval = 0.1

    private static let recognitionLanguages: [String] = {
        let desired = ["ko-KR", "en-US", "ja-JP"]
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let supported = try? request.supportedRecognitionLanguages() else {
            Log.ocr.error("recognition languages query failed fallback=en-US")
            return ["en-US"]
        }
        let available = desired.filter { supported.contains($0) }
        let resolved = available.isEmpty ? ["en-US"] : available
        Log.ocr.info("recognition languages resolved=\(resolved.joined(separator: ","), privacy: .public) supported=\(supported.count, privacy: .public)")
        return resolved
    }()

    private let store: ScreenshotStore
    private let index: SearchIndex
    private let queue = OperationQueue()
    private let state = DispatchQueue(label: "sukurini.ocr.state")

    private var running = false
    private var doneCount = 0
    private var totalCount = 0
    private var enqueuedPaths = Set<String>()
    private var lastProgressPost: TimeInterval = 0
    private var progressPostScheduled = false

    private var storeObserverInstalled = false
    private var reconcileRetries = 0
    private var reconcileWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private var environmentProvider: () -> OCRPowerEnvironment = OCRPowerEnvironment.system
    private var appliedPolicy: OCRPowerPolicy?
    private var powerObserver: OCRPowerSourceObserver?

    weak var semantic: SemanticCoordinator?

    init(store: ScreenshotStore, index: SearchIndex) {
        self.store = store
        self.index = index
        queue.name = "sukurini.ocr"
        queue.maxConcurrentOperationCount = OCRPowerPolicy.normalConcurrency
        queue.qualityOfService = .utility
        installNotificationObservers()
        installPowerSourceObserver()
        refreshPowerPolicy(reason: "init")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        powerObserver?.invalidate()
        queue.cancelAllOperations()
    }

    var progress: (done: Int, total: Int) {
        state.sync { (doneCount, totalCount) }
    }

    var powerPolicy: OCRPowerPolicy? {
        state.sync { appliedPolicy }
    }

    var appliedConcurrency: Int {
        queue.maxConcurrentOperationCount
    }

    var isPaused: Bool {
        queue.isSuspended
    }

    func requestReconcileNow() {
        guard state.sync(execute: { running }) else {
            Log.ocr.debug("reconcile request ignored reason=not-running")
            return
        }
        requestReconcile(immediate: false)
    }

    func setPowerEnvironmentProvider(_ provider: @escaping () -> OCRPowerEnvironment) {
        state.sync { environmentProvider = provider }
        refreshPowerPolicy(reason: "injected")
    }

    func start() {
        let textWanted = AppSettings.shared.ocrEnabled
        let vectorWanted = semantic?.isReady ?? false
        guard textWanted || vectorWanted else {
            Log.ocr.info("start skipped reason=disabled text=\(textWanted, privacy: .public) vector=\(vectorWanted, privacy: .public)")
            return
        }
        let started: Bool = state.sync {
            guard !running else { return false }
            running = true
            enqueuedPaths.removeAll()
            return true
        }
        guard started else {
            Log.ocr.debug("start ignored reason=already-running")
            return
        }
        installStoreObserver()
        refreshPowerPolicy(reason: "start")
        Log.ocr.info("start indexed=\(self.index.indexedCount(), privacy: .public) concurrency=\(self.queue.maxConcurrentOperationCount, privacy: .public) paused=\(self.queue.isSuspended, privacy: .public)")
        requestReconcile(immediate: true)
    }

    func stop() {
        let wasRunning: Bool = state.sync {
            let previous = running
            running = false
            enqueuedPaths.removeAll()
            appliedPolicy = nil
            return previous
        }
        cancelPendingReconcile()
        queue.cancelAllOperations()
        queue.isSuspended = false
        Log.ocr.info("stop wasRunning=\(wasRunning, privacy: .public)")
        guard wasRunning else { return }
        postProgressNotification()
    }

    fileprivate func process(_ screenshot: Screenshot, needsText: Bool, needsVector: Bool, isCancelled: () -> Bool) {
        defer { finish(screenshot) }
        guard !isCancelled() else { return }
        guard state.sync(execute: { running }) else { return }
        guard needsText || needsVector else { return }

        let path = screenshot.path
        guard FileManager.default.fileExists(atPath: path) else {
            Log.ocr.info("skip reason=missing path=\(path, privacy: .public)")
            index.removePaths([path])
            return
        }

        let started = Date()
        guard let image = OCRIndexer.downsampledImage(url: screenshot.url) else {
            Log.ocr.error("decode failed path=\(path, privacy: .public)")
            if needsText { index.storeText("", for: screenshot) }
            return
        }
        guard !isCancelled() else { return }

        var characters = -1
        if needsText {
            guard let text = OCRIndexer.recognizeText(in: image, path: path) else { return }
            guard !isCancelled() else { return }
            index.storeText(text, for: screenshot)
            characters = text.count
        }

        var embedded = false
        if needsVector, !isCancelled() {
            embedded = semantic?.embed(screenshot, image: image) ?? false
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.ocr.info("indexed path=\(path, privacy: .public) chars=\(characters, privacy: .public) embedded=\(embedded, privacy: .public) pixels=\(image.width, privacy: .public)x\(image.height, privacy: .public) ms=\(elapsed, privacy: .public)")
    }

    fileprivate func idle(afterWork elapsed: TimeInterval, isCancelled: () -> Bool) {
        let policy = state.sync { appliedPolicy }
        guard let policy = policy, policy.idleRatio > 0 else { return }
        let interval = policy.idleInterval(forWork: elapsed)
        guard interval > 0 else { return }
        guard queue.operationCount > 1 else {
            Log.ocr.debug("idle skipped reason=queue-drained")
            return
        }

        let deadline = Date().addingTimeInterval(interval)
        var slept: TimeInterval = 0
        while true {
            guard !isCancelled(), state.sync(execute: { running }) else {
                Log.ocr.debug("idle aborted ms=\(Int(slept * 1000), privacy: .public)")
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let slice = min(OCRIndexer.idleSliceInterval, remaining)
            Thread.sleep(forTimeInterval: slice)
            slept += slice
        }
        Log.ocr.debug("idle done ms=\(Int(interval * 1000), privacy: .public) work=\(Int(elapsed * 1000), privacy: .public) queued=\(self.queue.operationCount, privacy: .public)")
    }

    private func finish(_ screenshot: Screenshot) {
        state.sync {
            enqueuedPaths.remove(screenshot.path)
            guard running else { return }
            doneCount = min(doneCount + 1, totalCount)
            scheduleProgressNotificationLocked()
        }
    }

    private func installStoreObserver() {
        guard !storeObserverInstalled else { return }
        storeObserverInstalled = true
        store.addObserver { [weak self] change in
            guard let self = self else { return }
            guard self.state.sync(execute: { self.running }) else { return }
            if !change.removedURLs.isEmpty {
                let paths = change.removedURLs.map { $0.path }
                Log.ocr.info("store removed count=\(paths.count, privacy: .public)")
                self.index.removePaths(paths)
            }
            guard !change.inserted.isEmpty || change.isFullReload || !change.removedURLs.isEmpty else { return }
            self.requestReconcile(immediate: false)
        }
        Log.ocr.info("store observer installed")
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .sukuriniOCREnabledChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if AppSettings.shared.ocrEnabled {
                Log.ocr.info("settings changed enabled=true")
                self.start()
            } else {
                Log.ocr.info("settings changed enabled=false")
                self.stop()
            }
        })
        observers.append(center.addObserver(forName: .sukuriniOCRPowerPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPowerPolicy(reason: "settings")
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPowerPolicy(reason: "thermal")
        })
        observers.append(center.addObserver(forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPowerPolicy(reason: "low-power")
        })
    }

    private func installPowerSourceObserver() {
        powerObserver = OCRPowerSourceObserver { [weak self] in
            self?.refreshPowerPolicy(reason: "power-source")
        }
    }

    func refreshPowerPolicy(reason: String) {
        let provider = state.sync { environmentProvider }
        let settings = AppSettings.shared
        let policy = OCRPowerPolicy(
            environment: provider(),
            lazyOnBattery: settings.lazyIndexOnBattery,
            pauseOnLowPower: settings.pauseIndexingOnLowPower
        )
        let previous: OCRPowerPolicy? = state.sync {
            let stored = appliedPolicy
            appliedPolicy = policy
            return stored
        }

        if queue.maxConcurrentOperationCount != policy.concurrency {
            queue.maxConcurrentOperationCount = policy.concurrency
        }
        if queue.qualityOfService != policy.qualityOfService {
            queue.qualityOfService = policy.qualityOfService
        }
        if queue.isSuspended != policy.paused {
            queue.isSuspended = policy.paused
        }

        guard previous != policy else {
            Log.ocr.debug("power policy unchanged reason=\(reason, privacy: .public)")
            return
        }
        Log.ocr.info("power policy reason=\(reason, privacy: .public) source=\(policy.source.rawValue, privacy: .public) lowPower=\(policy.lowPowerMode, privacy: .public) thermal=\(policy.thermalState.rawValue, privacy: .public) lazyOnBattery=\(policy.lazyOnBattery, privacy: .public) pauseOnLowPower=\(policy.pauseOnLowPower, privacy: .public) lazyActive=\(policy.lazyActive, privacy: .public) concurrency=\(policy.concurrency, privacy: .public) qos=\(policy.qualityOfService.rawValue, privacy: .public) idleRatio=\(policy.idleRatio, privacy: .public) paused=\(policy.paused, privacy: .public) queued=\(self.queue.operationCount, privacy: .public)")
    }

    private func requestReconcile(immediate: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.requestReconcile(immediate: immediate) }
            return
        }
        reconcileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performReconcile() }
        reconcileWorkItem = item
        if immediate {
            reconcileRetries = 0
            item.perform()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + OCRIndexer.reconcileDebounce, execute: item)
    }

    private func cancelPendingReconcile() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.cancelPendingReconcile() }
            return
        }
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
    }

    private func performReconcile() {
        guard state.sync(execute: { running }) else { return }
        let items = store.items
        guard !items.isEmpty else {
            guard reconcileRetries < OCRIndexer.maximumReconcileRetries else {
                Log.ocr.info("reconcile abandoned reason=empty-store folderMissing=\(self.store.isFolderMissing, privacy: .public)")
                return
            }
            reconcileRetries += 1
            Log.ocr.info("reconcile deferred reason=empty-store attempt=\(self.reconcileRetries, privacy: .public) folderMissing=\(self.store.isFolderMissing, privacy: .public)")
            requestReconcile(immediate: false)
            return
        }
        reconcileRetries = 0
        let folder = store.activeFolder
        let textWanted = AppSettings.shared.ocrEnabled
        Log.ocr.info("reconcile start items=\(items.count, privacy: .public) folder=\(folder?.path ?? "none", privacy: .public) text=\(textWanted, privacy: .public)")
        index.reconcile(with: items, folder: folder) { [weak self] textPending in
            guard let self = self else { return }
            let textPaths = textWanted ? Set(textPending.map { $0.path }) : []
            guard let semantic = self.semantic, semantic.isReady else {
                self.enqueue(textWanted ? textPending : [], textPaths: textPaths, vectorPaths: [], corpus: items.count)
                return
            }
            semantic.pending(from: items) { [weak self] vectorPending in
                guard let self = self else { return }
                let vectorPaths = Set(vectorPending.map { $0.path })
                var union: [Screenshot] = []
                var seen = Set<String>()
                for item in (textWanted ? textPending : []) + vectorPending where seen.insert(item.path).inserted {
                    union.append(item)
                }
                Log.ocr.info("reconcile union text=\(textPaths.count, privacy: .public) vector=\(vectorPaths.count, privacy: .public) total=\(union.count, privacy: .public)")
                self.enqueue(union, textPaths: textPaths, vectorPaths: vectorPaths, corpus: items.count)
            }
        }
    }

    private func enqueue(_ items: [Screenshot], textPaths: Set<String>, vectorPaths: Set<String>, corpus: Int) {
        var operations: [Operation] = []
        var done = 0
        state.sync {
            guard running else { return }
            totalCount = corpus
            doneCount = max(0, corpus - items.count)
            done = doneCount
            for item in items where !enqueuedPaths.contains(item.path) {
                enqueuedPaths.insert(item.path)
                operations.append(OCROperation(
                    indexer: self,
                    screenshot: item,
                    needsText: textPaths.contains(item.path),
                    needsVector: vectorPaths.contains(item.path)
                ))
            }
            scheduleProgressNotificationLocked()
        }
        guard !operations.isEmpty else {
            Log.ocr.info("enqueue empty corpus=\(corpus, privacy: .public) done=\(done, privacy: .public)")
            return
        }
        Log.ocr.info("enqueue added=\(operations.count, privacy: .public) corpus=\(corpus, privacy: .public) done=\(done, privacy: .public) concurrency=\(self.queue.maxConcurrentOperationCount, privacy: .public)")
        queue.addOperations(operations, waitUntilFinished: false)
    }

    private func scheduleProgressNotificationLocked() {
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastProgressPost
        guard elapsed < OCRIndexer.progressInterval else {
            lastProgressPost = now
            postProgressNotification()
            return
        }
        guard !progressPostScheduled else { return }
        progressPostScheduled = true
        state.asyncAfter(deadline: .now() + (OCRIndexer.progressInterval - elapsed)) { [weak self] in
            guard let self = self else { return }
            self.progressPostScheduled = false
            self.lastProgressPost = Date.timeIntervalSinceReferenceDate
            self.postProgressNotification()
        }
    }

    private func postProgressNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sukuriniOCRProgressChanged, object: nil)
        }
    }

    private static func downsampledImage(url: URL) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    private static func recognizeText(in image: CGImage, path: String) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.ocr.error("vision failed path=\(path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observations = request.results else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(observations.count)
        var dropped = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard candidate.confidence >= minimumConfidence else {
                dropped += 1
                continue
            }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            lines.append(line)
        }
        if dropped > 0 {
            Log.ocr.debug("low confidence dropped=\(dropped, privacy: .public) path=\(path, privacy: .public)")
        }
        return lines.joined(separator: "\n")
    }
}
