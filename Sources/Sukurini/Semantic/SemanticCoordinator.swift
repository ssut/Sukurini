import CoreGraphics
import Foundation

enum SemanticState: Equatable {
    case disabled
    case needsDownload
    case downloading(SemanticDownloadProgress)
    case missing([String])
    case failed(String)
    case ready
}

final class SemanticCoordinator {
    private let store: ScreenshotStore
    private let index: SearchIndex
    private let modelStore = SemanticModelStore.shared
    private let downloader = SemanticModelDownloader()
    private let state = DispatchQueue(label: "sukurini.semantic.state")

    private var descriptor: SemanticModelDescriptor
    private var encoder: SemanticEncoder?
    private var vectors: VectorStore?
    private var current: SemanticState = .disabled
    private var pendingCount = 0
    private var embeddedCount = 0

    init(store: ScreenshotStore, index: SearchIndex) {
        self.store = store
        self.index = index
        self.descriptor = SemanticModelCatalog.resolved(id: AppSettings.shared.semanticModelIdentifier)
        index.semanticSlotsReleased = { [weak self] slots in
            self?.releaseSlots(slots)
        }
    }

    var activeDescriptor: SemanticModelDescriptor {
        state.sync { descriptor }
    }

    var currentState: SemanticState {
        state.sync { current }
    }

    var isReady: Bool {
        if case .ready = currentState { return true }
        return false
    }

    var progress: (done: Int, total: Int) {
        state.sync { (embeddedCount, pendingCount + embeddedCount) }
    }

    func refresh(reason: String) {
        let settings = AppSettings.shared
        let selected = SemanticModelCatalog.resolved(id: settings.semanticModelIdentifier)
        let enabled = settings.semanticSearchEnabled

        state.sync {
            if descriptor.id != selected.id {
                Log.semantic.info("model switched from=\(self.descriptor.id, privacy: .public) to=\(selected.id, privacy: .public)")
                descriptor = selected
                encoder = nil
                vectors = nil
                embeddedCount = 0
                pendingCount = 0
            }
        }

        guard enabled else {
            teardown()
            publish(.disabled, reason: reason)
            return
        }

        switch modelStore.state(of: selected) {
        case .notInstalled:
            teardown()
            publish(.needsDownload, reason: reason)
        case .incomplete(let missing):
            teardown()
            publish(.missing(missing), reason: reason)
        case .installed:
            activate(descriptor: selected, reason: reason)
        }
    }

    private func activate(descriptor selected: SemanticModelDescriptor, reason: String) {
        let built: Bool = state.sync {
            if encoder == nil { encoder = SemanticEncoder(descriptor: selected) }
            if vectors == nil {
                vectors = VectorStore(
                    dimension: selected.embeddingDimension,
                    vectorURL: modelStore.vectorFileURL(for: selected),
                    scaleURL: modelStore.scaleFileURL(for: selected)
                )
            }
            return vectors != nil && encoder != nil
        }
        guard built else {
            publish(.failed("Could not open the vector store."), reason: reason)
            return
        }
        let indexed = index.semanticIndexedCount(model: selected.id)
        state.sync { embeddedCount = indexed }
        publish(.ready, reason: reason)
        Log.semantic.info("activated model=\(selected.id, privacy: .public) indexed=\(indexed, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func teardown() {
        state.sync {
            encoder?.unloadImageTower()
            encoder?.unloadTextTower()
            encoder = nil
            vectors = nil
        }
    }

    private func publish(_ next: SemanticState, reason: String) {
        let changed: Bool = state.sync {
            guard current != next else { return false }
            current = next
            return true
        }
        guard changed else { return }
        Log.semantic.info("state=\(SemanticCoordinator.describe(next), privacy: .public) reason=\(reason, privacy: .public)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sukuriniSemanticStateChanged, object: nil)
        }
    }

    static func describe(_ state: SemanticState) -> String {
        switch state {
        case .disabled: return "disabled"
        case .needsDownload: return "needsDownload"
        case .downloading(let progress): return "downloading(\(Int(progress.fraction * 100))%)"
        case .missing(let files): return "missing(\(files.count))"
        case .failed(let detail): return "failed(\(detail))"
        case .ready: return "ready"
        }
    }

    func requestDownload() {
        let target = activeDescriptor
        guard !downloader.isRunning else {
            Log.semantic.info("download request ignored reason=already-running")
            return
        }
        publish(.downloading(SemanticDownloadProgress(completedBytes: 0, totalBytes: target.totalByteCount, fileIndex: 0, fileCount: target.files.count)), reason: "user")
        downloader.start(
            descriptor: target,
            progress: { [weak self] snapshot in
                self?.publish(.downloading(snapshot), reason: "progress")
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    Log.semantic.info("download succeeded model=\(target.id, privacy: .public)")
                    self.refresh(reason: "download-complete")
                case .failure(let error):
                    if case .cancelled = error {
                        self.refresh(reason: "download-cancelled")
                    } else {
                        self.publish(.failed(error.localizedDescription), reason: "download-failed")
                    }
                }
            }
        )
    }

    func cancelDownload() {
        downloader.cancel()
    }

    var resumableByteCount: Int64 {
        downloader.stagedByteCount(for: activeDescriptor)
    }

    var installedByteCount: Int64 {
        let target = activeDescriptor
        return modelStore.installedByteCount(of: target) + vectorByteCount(for: target)
    }

    var modelByteCount: Int64 {
        modelStore.installedByteCount(of: activeDescriptor)
    }

    var vectorByteCount: Int64 {
        vectorByteCount(for: activeDescriptor)
    }

    private func vectorByteCount(for target: SemanticModelDescriptor) -> Int64 {
        let vectors = modelStore.byteCount(of: modelStore.vectorFileURL(for: target)) ?? 0
        let scales = modelStore.byteCount(of: modelStore.scaleFileURL(for: target)) ?? 0
        return vectors + scales
    }

    func discardPartialDownload() {
        downloader.discardPartialDownload(for: activeDescriptor)
        refresh(reason: "partial-discarded")
    }

    func removeModelAndVectors() {
        let target = activeDescriptor
        teardown()
        downloader.discardPartialDownload(for: target)
        modelStore.removeModel(target)
        modelStore.removeVectors(target)
        index.forgetSemanticModel(target.id)
        state.sync { embeddedCount = 0; pendingCount = 0 }
        refresh(reason: "removed")
    }

    @discardableResult
    func embed(_ screenshot: Screenshot, image: CGImage) -> Bool {
        guard isReady else { return false }
        let model = activeDescriptor.id
        let (encoderRef, storeRef) = state.sync { (encoder, vectors) }
        guard let encoderRef, let storeRef else { return false }

        let started = Date()
        guard let vector = encoderRef.encodeImage(image) else {
            Log.semantic.error("embed failed path=\(screenshot.path, privacy: .public)")
            return false
        }
        guard let slot = index.claimSemanticSlot(path: screenshot.path, model: model) else {
            Log.semantic.error("slot claim failed path=\(screenshot.path, privacy: .public)")
            return false
        }
        guard storeRef.write(vector, at: slot) else {
            index.releaseSemanticSlot(path: screenshot.path, model: model)
            Log.semantic.error("vector write failed path=\(screenshot.path, privacy: .public) slot=\(slot, privacy: .public)")
            return false
        }
        state.sync {
            embeddedCount += 1
            if pendingCount > 0 { pendingCount -= 1 }
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.semantic.info("embedded path=\(screenshot.path, privacy: .public) slot=\(slot, privacy: .public) ms=\(elapsed, privacy: .public)")
        return true
    }

    func pending(from items: [Screenshot], completion: @escaping ([Screenshot]) -> Void) {
        guard isReady else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let model = activeDescriptor.id
        index.semanticPending(model: model, from: items) { [weak self] pending in
            self?.state.sync { self?.pendingCount = pending.count }
            completion(pending)
        }
    }

    func search(query: String, limit: Int, completion: @escaping ([(path: String, score: Float)]) -> Void) {
        guard isReady else {
            completion([])
            return
        }
        let model = activeDescriptor.id
        let (encoderRef, storeRef) = state.sync { (encoder, vectors) }
        guard let encoderRef, let storeRef else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let started = Date()
            guard let vector = encoderRef.encodeText(query) else {
                Log.semantic.error("query encode failed")
                DispatchQueue.main.async { completion([]) }
                return
            }
            let hits = storeRef.search(query: vector, limit: limit)
            let mapping = self.index.semanticPaths(slots: hits.map { $0.slot }, model: model)
            let resolved = hits.compactMap { hit -> (path: String, score: Float)? in
                guard let path = mapping[hit.slot] else { return nil }
                return (path, hit.score)
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.semantic.info("semantic search hits=\(resolved.count, privacy: .public) ms=\(elapsed, privacy: .public)")
            DispatchQueue.main.async { completion(resolved) }
        }
    }

    func prewarmTextTower() {
        guard isReady else { return }
        let encoderRef = state.sync { encoder }
        guard let encoderRef, !encoderRef.isTextTowerLoaded else { return }
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let ok = encoderRef.prepareTextTower()
            Log.semantic.info("text tower prewarm ok=\(ok, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
        }
    }

    func releaseImageTower() {
        let encoderRef = state.sync { encoder }
        encoderRef?.unloadImageTower()
    }

    private func releaseSlots(_ slots: [Int]) {
        let storeRef = state.sync { vectors }
        guard let storeRef, !slots.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            storeRef.clear(slots: slots)
        }
    }
}
