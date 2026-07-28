import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class PNGExporter {
    static let shared = PNGExporter()

    private struct Entry {
        let url: URL
        var lastUsed: Date
    }

    private enum Limits {
        static let maxEntries = 64
        static let maxAge: TimeInterval = 24 * 60 * 60
        static let directoryName = "Sukurini-CopyAsPNG"
    }

    private let root: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let warmQueue = DispatchQueue(label: "sukurini.export.png", qos: .utility)

    init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Limits.directoryName)
    }

    var isActive: Bool {
        AppSettings.shared.exportsCopiesAsPNG
    }

    func handles(_ url: URL) -> Bool {
        isActive && url.pathExtension.lowercased() == ScreenshotFile.convertedExtension
    }

    private func shouldExport(_ url: URL, forced: Bool) -> Bool {
        guard forced else { return handles(url) }
        guard url.pathExtension.lowercased() != ScreenshotFile.pngExtension else {
            Log.convert.debug("png export forced skipped reason=already_png file=\(url.lastPathComponent, privacy: .public)")
            return false
        }
        return true
    }

    func pasteboardWriter(for url: URL, forcingPNG forced: Bool = false) -> NSPasteboardWriting {
        guard shouldExport(url, forced: forced) else { return url as NSURL }
        guard let exported = exportedURL(for: url) else {
            Log.convert.error("png export unavailable, copying original file=\(url.lastPathComponent, privacy: .public)")
            return url as NSURL
        }
        let item = NSPasteboardItem()
        guard item.setString(exported.absoluteString, forType: .fileURL) else {
            Log.convert.error("png export pasteboard url rejected file=\(exported.lastPathComponent, privacy: .public)")
            return url as NSURL
        }
        if let data = try? Data(contentsOf: exported) {
            if !item.setData(data, forType: .png) {
                Log.convert.error("png export pasteboard data rejected file=\(exported.lastPathComponent, privacy: .public)")
            }
        } else {
            Log.convert.error("png export unreadable file=\(exported.lastPathComponent, privacy: .public)")
        }
        Log.convert.info("png export writer ready file=\(exported.lastPathComponent, privacy: .public) forced=\(forced, privacy: .public)")
        return item
    }

    func pasteboardWriters(for urls: [URL]) -> [NSPasteboardWriting] {
        let started = Date()
        let writers = urls.map { pasteboardWriter(for: $0) }
        let converted = writers.filter { $0 is NSPasteboardItem }.count
        guard converted > 0 else { return writers }
        let elapsed = Date().timeIntervalSince(started) * 1000
        Log.convert.info("png export batch count=\(urls.count, privacy: .public) converted=\(converted, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
        return writers
    }

    func warm(_ url: URL, forcingPNG forced: Bool = false) {
        guard shouldExport(url, forced: forced) else { return }
        warmQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldExport(url, forced: forced) else { return }
            guard self.exportedURL(for: url) != nil else { return }
            Log.convert.debug("png export warmed file=\(url.lastPathComponent, privacy: .public) forced=\(forced, privacy: .public)")
        }
    }

    func purgeExpired() {
        warmQueue.async { [weak self] in
            guard let self else { return }
            let manager = FileManager.default
            guard let children = try? manager.contentsOfDirectory(
                at: self.root,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else {
                Log.convert.debug("png export purge skipped reason=no_cache_directory")
                return
            }

            let cutoff = Date().addingTimeInterval(-Limits.maxAge)
            var removed = 0
            for child in children {
                let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard modified < cutoff else { continue }
                guard (try? manager.removeItem(at: child)) != nil else { continue }
                removed += 1
            }
            Log.convert.info("png export purge scanned=\(children.count, privacy: .public) removed=\(removed, privacy: .public)")
        }
    }

    func exportedURL(for source: URL) -> URL? {
        guard let stats = Self.stat(source.path), stats.size > 0 else {
            Log.convert.error("png export stat failed file=\(source.lastPathComponent, privacy: .public)")
            return nil
        }

        let key = Self.fingerprint(source.path, size: stats.size, modified: stats.modified)
        if let cached = cachedEntry(key) { return cached }

        let name = source.deletingPathExtension().lastPathComponent + ".png"
        let destination = root.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name)

        if let existing = Self.stat(destination.path), existing.size > 0 {
            remember(key, url: destination)
            Log.convert.debug("png export reused file=\(name, privacy: .public)")
            return destination
        }

        let started = Date()
        guard let bytes = Self.render(source) else { return nil }
        guard write(bytes, to: destination, stamps: stats) else { return nil }

        remember(key, url: destination)
        let elapsed = Date().timeIntervalSince(started) * 1000
        Log.convert.info("png export wrote file=\(name, privacy: .public) webp=\(stats.size, privacy: .public) png=\(bytes.count, privacy: .public) ms=\(Int(elapsed), privacy: .public)")
        return destination
    }

    private func cachedEntry(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        guard let stats = Self.stat(entry.url.path), stats.size > 0 else {
            entries.removeValue(forKey: key)
            return nil
        }
        entry.lastUsed = Date()
        entries[key] = entry
        return entry.url
    }

    private func remember(_ key: String, url: URL) {
        lock.lock()
        entries[key] = Entry(url: url, lastUsed: Date())
        let stale = entries.count > Limits.maxEntries
            ? entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(entries.count - Limits.maxEntries)
                .map { ($0.key, $0.value.url) }
            : []
        for (evicted, _) in stale { entries.removeValue(forKey: evicted) }
        lock.unlock()

        guard !stale.isEmpty else { return }
        warmQueue.async {
            for (_, url) in stale {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            Log.convert.info("png export evicted count=\(stale.count, privacy: .public)")
        }
    }

    private func write(_ bytes: Data, to destination: URL, stamps: FileStats) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
        } catch {
            Log.convert.error("png export write failed file=\(destination.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }

        var attributes: [FileAttributeKey: Any] = [.modificationDate: stamps.modified]
        if let created = stamps.created { attributes[.creationDate] = created }
        try? manager.setAttributes(attributes, ofItemAtPath: destination.path)
        return true
    }

    private struct FileStats {
        let size: Int
        let created: Date?
        let modified: Date
    }

    private static func stat(_ path: String) -> FileStats? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStats(size: size, created: attributes[.creationDate] as? Date, modified: modified)
    }

    private static func render(_ source: URL) -> Data? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            Log.convert.error("png export decode failed file=\(source.lastPathComponent, privacy: .public)")
            return nil
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            Log.convert.error("png export destination unavailable file=\(source.lastPathComponent, privacy: .public)")
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), buffer.length > 0 else {
            Log.convert.error("png export encode failed file=\(source.lastPathComponent, privacy: .public)")
            return nil
        }
        return buffer as Data
    }

    private static func fingerprint(_ path: String, size: Int, modified: Date) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let seed = "\(path)|\(size)|\(modified.timeIntervalSince1970)"
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
