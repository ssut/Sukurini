import CoreServices
import Foundation

enum ScreenshotRelocator {
    struct Survey {
        let source: URL
        let count: Int
        let bytes: Int64

        static func empty(_ source: URL) -> Survey {
            Survey(source: source, count: 0, bytes: 0)
        }
    }

    struct Outcome {
        let moved: Int
        let failed: Int
        let bytes: Int64
    }

    private static let metadataKey = "kMDItemIsScreenCapture" as CFString
    private static let queue = DispatchQueue(label: "sukurini.onboarding.relocate", qos: .userInitiated)
    private static let collisionLimit = 500

    private static let builtInPrefixes = [
        "screenshot",
        "screen shot",
        "스크린샷",
        "スクリーンショット",
        "bildschirmfoto",
        "capture d'écran",
        "capture d\u{2019}écran",
        "captura de pantalla",
        "captura de ecrã",
        "schermafbeelding",
        "снимок экрана",
        "屏幕快照",
        "截屏"
    ]

    static func survey(source: URL, destination: URL, completion: @escaping (Survey) -> Void) {
        let resolvedSource = source.standardizedFileURL
        let resolvedDestination = destination.standardizedFileURL
        guard resolvedSource.path != resolvedDestination.path else {
            Log.settings.info("relocation survey skipped reason=same_folder path=\(resolvedSource.path, privacy: .public)")
            DispatchQueue.main.async { completion(.empty(resolvedSource)) }
            return
        }
        queue.async {
            let started = Date()
            let files = candidates(in: resolvedSource)
            let bytes = files.reduce(Int64(0)) { $0 + size(of: $1) }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.settings.info("relocation survey source=\(resolvedSource.path, privacy: .public) count=\(files.count, privacy: .public) bytes=\(bytes, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
            DispatchQueue.main.async {
                completion(Survey(source: resolvedSource, count: files.count, bytes: bytes))
            }
        }
    }

    static func move(source: URL, destination: URL, completion: @escaping (Outcome) -> Void) {
        let resolvedSource = source.standardizedFileURL
        let resolvedDestination = destination.standardizedFileURL
        guard resolvedSource.path != resolvedDestination.path else {
            Log.settings.error("relocation move refused reason=same_folder path=\(resolvedSource.path, privacy: .public)")
            DispatchQueue.main.async { completion(Outcome(moved: 0, failed: 0, bytes: 0)) }
            return
        }
        queue.async {
            let started = Date()
            do {
                try FileManager.default.createDirectory(at: resolvedDestination, withIntermediateDirectories: true)
            } catch {
                Log.settings.error("relocation destination unavailable path=\(resolvedDestination.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { completion(Outcome(moved: 0, failed: 0, bytes: 0)) }
                return
            }

            let files = candidates(in: resolvedSource)
            var moved = 0
            var failed = 0
            var bytes: Int64 = 0

            for file in files {
                let fileBytes = size(of: file)
                let target = uniqueURL(for: file.lastPathComponent, in: resolvedDestination)
                do {
                    try FileManager.default.moveItem(at: file, to: target)
                    moved += 1
                    bytes += fileBytes
                } catch {
                    failed += 1
                    Log.settings.error("relocation move failed path=\(file.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.settings.info("relocation finished source=\(resolvedSource.path, privacy: .public) destination=\(resolvedDestination.path, privacy: .public) moved=\(moved, privacy: .public) failed=\(failed, privacy: .public) bytes=\(bytes, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
            DispatchQueue.main.async {
                completion(Outcome(moved: moved, failed: failed, bytes: bytes))
            }
        }
    }

    private static func candidates(in folder: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            Log.settings.error("relocation scan failed path=\(folder.path, privacy: .public)")
            return []
        }

        let prefixes = knownPrefixes()
        var skipped = 0
        let files = entries.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return false }
            guard ScreenshotFile.isEligible(url) else { return false }
            guard looksLikeScreenshot(url, prefixes: prefixes) else {
                skipped += 1
                return false
            }
            return true
        }
        Log.settings.debug("relocation candidates path=\(folder.path, privacy: .public) matched=\(files.count, privacy: .public) skippedImages=\(skipped, privacy: .public)")
        return files
    }

    private static func knownPrefixes() -> [String] {
        var prefixes = builtInPrefixes
        guard let custom = ScreencaptureDefaults.nameTemplate()?.lowercased(), !custom.isEmpty else { return prefixes }
        guard !prefixes.contains(custom) else { return prefixes }
        prefixes.append(custom)
        Log.settings.info("relocation using custom screenshot prefix value=\(custom, privacy: .public)")
        return prefixes
    }

    private static func looksLikeScreenshot(_ url: URL, prefixes: [String]) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return isFlaggedScreenCapture(url)
    }

    private static func isFlaggedScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return false }
        guard let raw = MDItemCopyAttribute(item, metadataKey) else { return false }
        return (raw as? NSNumber)?.boolValue ?? false
    }

    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        let direct = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: direct.path) else { return direct }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...collisionLimit {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = folder.appendingPathComponent(candidate)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.settings.info("relocation renamed on collision original=\(name, privacy: .public) resolved=\(candidate, privacy: .public)")
                return url
            }
        }
        let fallback = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        Log.settings.error("relocation collision limit reached name=\(name, privacy: .public)")
        return folder.appendingPathComponent(fallback)
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
