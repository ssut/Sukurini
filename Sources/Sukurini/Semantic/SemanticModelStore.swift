import CryptoKit
import Foundation

enum SemanticModelState: Equatable {
    case notInstalled
    case installed
    case incomplete(missing: [String])
}

struct SemanticModelManifest: Codable {
    let modelID: String
    let installedAt: Date
    let embeddingDimension: Int
    let files: [String: String]
}

final class SemanticModelStore {
    static let shared = SemanticModelStore()

    private let fileManager = FileManager.default

    private init() {}

    var supportRoot: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Sukurini", isDirectory: true)
    }

    var modelsRoot: URL {
        supportRoot.appendingPathComponent("Models", isDirectory: true)
    }

    var vectorsRoot: URL {
        supportRoot.appendingPathComponent("Vectors", isDirectory: true)
    }

    func directory(for descriptor: SemanticModelDescriptor) -> URL {
        modelsRoot.appendingPathComponent(descriptor.id, isDirectory: true)
    }

    func fileURL(for descriptor: SemanticModelDescriptor, relativePath: String) -> URL {
        directory(for: descriptor).appendingPathComponent(relativePath)
    }

    func imagePackageURL(for descriptor: SemanticModelDescriptor) -> URL {
        fileURL(for: descriptor, relativePath: descriptor.imagePackageRelativePath)
    }

    func textPackageURL(for descriptor: SemanticModelDescriptor) -> URL {
        fileURL(for: descriptor, relativePath: descriptor.textPackageRelativePath)
    }

    func tokenizerURL(for descriptor: SemanticModelDescriptor) -> URL {
        fileURL(for: descriptor, relativePath: descriptor.tokenizerRelativePath)
    }

    private func manifestURL(for descriptor: SemanticModelDescriptor) -> URL {
        directory(for: descriptor).appendingPathComponent("manifest.json")
    }

    func vectorFileURL(for descriptor: SemanticModelDescriptor) -> URL {
        vectorsRoot.appendingPathComponent("\(descriptor.id).i8")
    }

    func scaleFileURL(for descriptor: SemanticModelDescriptor) -> URL {
        vectorsRoot.appendingPathComponent("\(descriptor.id).scales")
    }

    @discardableResult
    func prepareDirectories() -> Bool {
        for url in [supportRoot, modelsRoot, vectorsRoot] {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                Log.semanticModel.error("directory create failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        excludeFromBackup(modelsRoot)
        return true
    }

    func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            Log.semanticModel.error("backup exclusion failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func state(of descriptor: SemanticModelDescriptor) -> SemanticModelState {
        let root = directory(for: descriptor)
        guard fileManager.fileExists(atPath: root.path) else { return .notInstalled }
        guard fileManager.fileExists(atPath: manifestURL(for: descriptor).path) else {
            return .incomplete(missing: ["manifest.json"])
        }

        var missing: [String] = []
        for file in descriptor.files {
            let url = fileURL(for: descriptor, relativePath: file.relativePath)
            guard let size = byteCount(of: url) else {
                missing.append(file.relativePath)
                continue
            }
            if size != file.byteCount { missing.append(file.relativePath) }
        }
        guard missing.isEmpty else {
            Log.semanticModel.error("model incomplete id=\(descriptor.id, privacy: .public) missing=\(missing.count, privacy: .public)")
            return .incomplete(missing: missing)
        }
        return .installed
    }

    func isInstalled(_ descriptor: SemanticModelDescriptor) -> Bool {
        state(of: descriptor) == .installed
    }

    func installedByteCount(of descriptor: SemanticModelDescriptor) -> Int64 {
        descriptor.files.reduce(0) { total, file in
            total + (byteCount(of: fileURL(for: descriptor, relativePath: file.relativePath)) ?? 0)
        }
    }

    func writeManifest(for descriptor: SemanticModelDescriptor) {
        var hashes: [String: String] = [:]
        for file in descriptor.files { hashes[file.relativePath] = file.sha256 }
        let manifest = SemanticModelManifest(
            modelID: descriptor.id,
            installedAt: Date(),
            embeddingDimension: descriptor.embeddingDimension,
            files: hashes
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL(for: descriptor), options: .atomic)
            Log.semanticModel.info("manifest written id=\(descriptor.id, privacy: .public) files=\(hashes.count, privacy: .public)")
        } catch {
            Log.semanticModel.error("manifest write failed id=\(descriptor.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func removeModel(_ descriptor: SemanticModelDescriptor) -> Bool {
        let root = directory(for: descriptor)
        guard fileManager.fileExists(atPath: root.path) else { return true }
        do {
            try fileManager.removeItem(at: root)
            Log.semanticModel.info("model removed id=\(descriptor.id, privacy: .public)")
            return true
        } catch {
            Log.semanticModel.error("model remove failed id=\(descriptor.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func removeVectors(_ descriptor: SemanticModelDescriptor) -> Bool {
        var ok = true
        for url in [vectorFileURL(for: descriptor), scaleFileURL(for: descriptor)] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                ok = false
                Log.semanticModel.error("vector remove failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        Log.semanticModel.info("vectors removed id=\(descriptor.id, privacy: .public) ok=\(ok, privacy: .public)")
        return ok
    }

    func byteCount(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else { return nil }
        return Int64(size)
    }

    func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            Log.semanticModel.error("hash open failed path=\(url.path, privacy: .public)")
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
