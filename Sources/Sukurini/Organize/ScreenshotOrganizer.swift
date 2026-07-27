import Darwin
import Foundation

enum ScreenshotOrganizer {
    static let maximumCollisionAttempts = 99

    enum Outcome {
        case moved(URL)
        case skipped(String)
        case failed(String)
    }

    static func isInRoot(_ url: URL, root: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
    }

    static func directory(for date: Date, root: URL, pattern: String) -> URL? {
        guard let relative = DateFolderFormat.relativePath(for: date, pattern: pattern) else { return nil }
        var directory = root
        for component in relative.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
        }
        return directory
    }

    static func move(_ screenshot: Screenshot, root: URL, pattern: String) -> Outcome {
        let url = screenshot.url
        guard isInRoot(url, root: root) else { return .skipped("not_in_root") }
        guard screenshot.created > Date.distantPast else { return .skipped("no_date") }
        guard let destinationDirectory = directory(for: screenshot.created, root: root, pattern: pattern) else {
            Log.organize.error("organize failed path=\(url.path, privacy: .public) reason=render_failed")
            return .failed("render_failed")
        }

        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            Log.organize.error("organize failed path=\(url.path, privacy: .public) reason=create_directory detail=\(error.localizedDescription, privacy: .public)")
            return .failed("create_directory")
        }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var attempt = 1

        while attempt <= maximumCollisionAttempts {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            var destination = destinationDirectory.appendingPathComponent(name, isDirectory: false)
            if !ext.isEmpty {
                destination.appendPathExtension(ext)
            }

            let status = exclusiveRename(from: url, to: destination)
            if status == 0 {
                Log.organize.info("organized from=\(url.path, privacy: .public) to=\(destination.path, privacy: .public) attempt=\(attempt, privacy: .public)")
                return .moved(destination)
            }

            switch status {
            case EEXIST:
                attempt += 1
            case ENOENT:
                Log.organize.info("organize skipped path=\(url.path, privacy: .public) reason=vanished")
                return .skipped("vanished")
            case ENOTSUP, EINVAL:
                return fallbackMove(from: url, to: destinationDirectory, base: base, ext: ext)
            default:
                Log.organize.error("organize failed path=\(url.path, privacy: .public) reason=move errno=\(status, privacy: .public)")
                return .failed("move")
            }
        }

        Log.organize.error("organize failed path=\(url.path, privacy: .public) reason=collision_exhausted attempts=\(maximumCollisionAttempts, privacy: .public)")
        return .failed("collision_exhausted")
    }

    private static func exclusiveRename(from source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else { return EINVAL }
            return destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else { return EINVAL }
                guard renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) != 0 else { return 0 }
                return errno
            }
        }
    }

    private static func fallbackMove(from source: URL, to directory: URL, base: String, ext: String) -> Outcome {
        Log.organize.info("organize fallback path=\(source.path, privacy: .public) reason=renamex_unsupported")
        var attempt = 1
        while attempt <= maximumCollisionAttempts {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            var destination = directory.appendingPathComponent(name, isDirectory: false)
            if !ext.isEmpty {
                destination.appendPathExtension(ext)
            }
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                Log.organize.info("organized from=\(source.path, privacy: .public) to=\(destination.path, privacy: .public) attempt=\(attempt, privacy: .public) fallback=true")
                return .moved(destination)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                attempt += 1
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                return .skipped("vanished")
            } catch {
                Log.organize.error("organize failed path=\(source.path, privacy: .public) reason=move_fallback detail=\(error.localizedDescription, privacy: .public)")
                return .failed("move")
            }
        }
        Log.organize.error("organize failed path=\(source.path, privacy: .public) reason=collision_exhausted attempts=\(maximumCollisionAttempts, privacy: .public)")
        return .failed("collision_exhausted")
    }
}
