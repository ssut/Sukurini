import AppKit
import AVFoundation
import Foundation
import ImageIO
import os

final class ThumbnailLoader {

    private enum Budget {
        static let bytesPerPixelIncludingCompositorCopy = 8
        static let totalCostLimit = 192 * 1024 * 1024
        static let countLimit = 1500
        static let maxWorkers = 4
        static let statsInterval = 250
    }

    private final class Job: Operation, @unchecked Sendable {
        let url: URL
        let key: String
        let maxPixel: Int
        let scale: CGFloat
        var prefetchOnly: Bool
        var completions: [(URL, NSImage?) -> Void] = []
        private let deliver: (Job, NSImage?) -> Void

        init(
            url: URL,
            key: String,
            maxPixel: Int,
            scale: CGFloat,
            prefetchOnly: Bool,
            deliver: @escaping (Job, NSImage?) -> Void
        ) {
            self.url = url
            self.key = key
            self.maxPixel = maxPixel
            self.scale = scale
            self.prefetchOnly = prefetchOnly
            self.deliver = deliver
            super.init()
        }

        override func main() {
            let name = url.lastPathComponent
            if isCancelled {
                Log.thumbnail.debug("job cancelled before decode file=\(name, privacy: .public)")
                return
            }
            let image = ThumbnailLoader.decodeImage(url: url, maxPixel: maxPixel, scale: scale)
            if isCancelled {
                Log.thumbnail.debug("job cancelled after decode file=\(name, privacy: .public)")
                return
            }
            deliver(self, image)
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var pressureSource: DispatchSourceMemoryPressure?
    private var scaleStorage: CGFloat = 2
    private var decodeCount = 0
    private var hitCount = 0
    private var missCount = 0

    init() {
        cache.name = "sukurini.thumbnails"
        cache.totalCostLimit = Budget.totalCostLimit
        cache.countLimit = Budget.countLimit

        queue.name = "sukurini.thumbnail.decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = min(ProcessInfo.processInfo.activeProcessorCount, Budget.maxWorkers)

        scaleStorage = NSScreen.main?.backingScaleFactor ?? 2

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        installMemoryPressureMonitor()

        let workers = queue.maxConcurrentOperationCount
        let limitMiB = cache.totalCostLimit / (1024 * 1024)
        let scale = Double(scaleStorage)
        Log.thumbnail.info(
            "loader ready workers=\(workers, privacy: .public) cacheLimitMiB=\(limitMiB, privacy: .public) scale=\(scale, privacy: .public)"
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pressureSource?.cancel()
        queue.cancelAllOperations()
    }

    func cachedThumbnail(for url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: Self.cacheKey(url: url, maxPixel: maxPixel) as NSString)
    }

    func loadSync(for url: URL, maxPixel: Int) -> NSImage? {
        let key = Self.cacheKey(url: url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key as NSString) {
            bumpHit()
            return cached
        }
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.thumbnail.error("loadSync aborted file missing file=\(name, privacy: .public)")
            return nil
        }
        guard let image = Self.decodeImage(url: url, maxPixel: maxPixel, scale: currentScale()) else {
            Log.thumbnail.error("loadSync decode failed file=\(name, privacy: .public)")
            return nil
        }
        store(image, key: key)
        Log.thumbnail.debug("loadSync decoded file=\(name, privacy: .public) maxPixel=\(maxPixel, privacy: .public)")
        return image
    }

    func thumbnail(
        for url: URL,
        maxPixel: Int,
        lowPriority: Bool,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let key = Self.cacheKey(url: url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key as NSString) {
            bumpHit()
            completion(url, cached)
            return
        }
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.thumbnail.error("thumbnail skipped file missing file=\(name, privacy: .public)")
            completion(url, nil)
            return
        }

        lock.lock()
        missCount += 1
        if let existing = jobs[key], !existing.isFinished, !existing.isCancelled {
            existing.completions.append(completion)
            if !lowPriority {
                existing.prefetchOnly = false
                existing.queuePriority = .normal
            }
            lock.unlock()
            return
        }
        let job = Job(
            url: url,
            key: key,
            maxPixel: maxPixel,
            scale: scaleStorage,
            prefetchOnly: lowPriority,
            deliver: { [weak self] job, image in
                self?.finish(job: job, image: image)
            }
        )
        job.completions.append(completion)
        job.queuePriority = lowPriority ? .low : .normal
        jobs[key] = job
        lock.unlock()

        queue.addOperation(job)
    }

    func cancel(url: URL, maxPixel: Int) {
        let key = Self.cacheKey(url: url, maxPixel: maxPixel)
        lock.lock()
        let job = jobs.removeValue(forKey: key)
        job?.completions = []
        lock.unlock()
        guard let job else { return }
        job.cancel()
        let name = url.lastPathComponent
        Log.thumbnail.debug("cancelled file=\(name, privacy: .public)")
    }

    func prefetch(urls: [URL], maxPixel: Int) {
        guard !urls.isEmpty else { return }
        for url in urls {
            thumbnail(for: url, maxPixel: maxPixel, lowPriority: true) { _, _ in }
        }
        let count = urls.count
        Log.thumbnail.debug("prefetch requested count=\(count, privacy: .public) maxPixel=\(maxPixel, privacy: .public)")
    }

    func cancelPrefetch(urls: [URL], maxPixel: Int) {
        guard !urls.isEmpty else { return }
        var cancelled: [Job] = []
        lock.lock()
        for url in urls {
            let key = Self.cacheKey(url: url, maxPixel: maxPixel)
            guard let job = jobs[key], job.prefetchOnly else { continue }
            jobs.removeValue(forKey: key)
            job.completions = []
            cancelled.append(job)
        }
        lock.unlock()
        for job in cancelled { job.cancel() }
        let count = cancelled.count
        guard count > 0 else { return }
        Log.thumbnail.debug("prefetch cancelled count=\(count, privacy: .public)")
    }

    private func finish(job: Job, image: NSImage?) {
        if let image {
            store(image, key: job.key)
        }
        lock.lock()
        if jobs[job.key] === job {
            jobs.removeValue(forKey: job.key)
        }
        let completions = job.completions
        job.completions = []
        decodeCount += 1
        let total = decodeCount
        let hits = hitCount
        let misses = missCount
        lock.unlock()

        if total % Budget.statsInterval == 0 {
            let cacheCost = cache.totalCostLimit / (1024 * 1024)
            Log.thumbnail.info(
                "decode progress decoded=\(total, privacy: .public) hits=\(hits, privacy: .public) misses=\(misses, privacy: .public) cacheLimitMiB=\(cacheCost, privacy: .public)"
            )
        }

        guard !completions.isEmpty else { return }
        let url = job.url
        DispatchQueue.main.async {
            for completion in completions {
                completion(url, image)
            }
        }
    }

    static let dragThumbnailPixel = 256

    func seed(_ cgImage: CGImage, for url: URL, maxPixel: Int) {
        guard let scaled = Self.downsample(cgImage, maxPixel: maxPixel) else { return }
        let image = Self.pointScaledImage(scaled, scale: currentScale())
        store(image, key: Self.cacheKey(url: url, maxPixel: maxPixel))
        Log.thumbnail.debug("seeded file=\(url.lastPathComponent, privacy: .public) maxPixel=\(maxPixel, privacy: .public)")
    }

    private static func downsample(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let ratio = CGFloat(maxPixel) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        let space: CGColorSpace
        if let existing = image.colorSpace, existing.model == .rgb {
            space = existing
        } else {
            space = CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func store(_ image: NSImage, key: String) {
        var pixels = Int(image.size.width * image.size.height)
        if let rep = image.representations.first as? NSBitmapImageRep {
            pixels = rep.pixelsWide * rep.pixelsHigh
        }
        let cost = pixels * Budget.bytesPerPixelIncludingCompositorCopy
        cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
    }

    private func bumpHit() {
        lock.lock()
        hitCount += 1
        lock.unlock()
    }

    private func currentScale() -> CGFloat {
        lock.lock()
        let value = scaleStorage
        lock.unlock()
        return value
    }

    @objc private func screenParametersChanged() {
        let updated = NSScreen.main?.backingScaleFactor ?? 2
        lock.lock()
        let changed = updated != scaleStorage
        scaleStorage = updated
        lock.unlock()
        guard changed else { return }
        cache.removeAllObjects()
        let scale = Double(updated)
        Log.thumbnail.info("display scale changed scale=\(scale, privacy: .public) cache flushed")
    }

    private func installMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let raw = self.pressureSource?.data.rawValue ?? 0
            self.cache.removeAllObjects()
            Log.thumbnail.error("memory pressure event raw=\(raw, privacy: .public) thumbnail cache flushed")
        }
        source.resume()
        pressureSource = source
    }

    private static func cacheKey(url: URL, maxPixel: Int) -> String {
        "\(url.path)|\(maxPixel)"
    }

    private static func decodeImage(url: URL, maxPixel: Int, scale: CGFloat) -> NSImage? {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.thumbnail.error("decode aborted file missing file=\(name, privacy: .public)")
            return nil
        }
        if ScreenshotFile.isVideo(url) {
            return decodeVideoFrame(url: url, maxPixel: maxPixel, scale: scale)
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            Log.thumbnail.info("image source unavailable falling back to icon file=\(name, privacy: .public)")
            return fallbackIcon(url: url, maxPixel: maxPixel, scale: scale)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            Log.thumbnail.info("thumbnail decode failed falling back to icon file=\(name, privacy: .public)")
            return fallbackIcon(url: url, maxPixel: maxPixel, scale: scale)
        }
        return pointScaledImage(cgImage, scale: scale)
    }

    private static func decodeVideoFrame(url: URL, maxPixel: Int, scale: CGFloat) -> NSImage? {
        let name = url.lastPathComponent
        let started = Date()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        do {
            let frame = try generator.copyCGImage(at: .zero, actualTime: nil)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.thumbnail.debug("video frame decoded file=\(name, privacy: .public) pixels=\(frame.width, privacy: .public)x\(frame.height, privacy: .public) ms=\(elapsed, privacy: .public)")
            return pointScaledImage(frame, scale: scale)
        } catch {
            Log.thumbnail.info("video frame decode failed falling back to icon file=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return fallbackIcon(url: url, maxPixel: maxPixel, scale: scale)
        }
    }

    private static func pointScaledImage(_ cgImage: CGImage, scale: CGFloat) -> NSImage {
        let effectiveScale = scale > 0 ? scale : 2
        let pointSize = NSSize(
            width: max(1, CGFloat(cgImage.width) / effectiveScale),
            height: max(1, CGFloat(cgImage.height) / effectiveScale)
        )
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    private static func fallbackIcon(url: URL, maxPixel: Int, scale: CGFloat) -> NSImage? {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.thumbnail.error("icon fallback aborted file missing file=\(name, privacy: .public)")
            return nil
        }
        let effectiveScale = scale > 0 ? scale : 2
        let side = min(CGFloat(maxPixel) / effectiveScale, 96)
        let resolve: () -> NSImage = {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return (icon.copy() as? NSImage) ?? icon
        }
        let icon = Thread.isMainThread ? resolve() : DispatchQueue.main.sync(execute: resolve)
        icon.size = NSSize(width: side, height: side)
        Log.thumbnail.info("icon fallback produced file=\(name, privacy: .public)")
        return icon
    }
}
