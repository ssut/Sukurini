import Foundation

struct SemanticDownloadProgress: Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
    let fileIndex: Int
    let fileCount: Int

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(completedBytes) / Double(totalBytes))
    }
}

enum SemanticDownloadError: LocalizedError {
    case noBaseURL
    case cancelled
    case transport(String)
    case httpStatus(Int, String)
    case checksumMismatch(String)
    case sizeMismatch(String, Int64, Int64)
    case filesystem(String)

    var errorDescription: String? {
        switch self {
        case .noBaseURL:
            return "No model download location is configured."
        case .cancelled:
            return "Download paused."
        case .transport(let detail):
            return "Network error: \(detail)"
        case .httpStatus(let code, let path):
            return "Server returned \(code) for \(path)."
        case .checksumMismatch(let path):
            return "Downloaded file failed verification: \(path)"
        case .sizeMismatch(let path, let expected, let actual):
            return "Size mismatch for \(path): expected \(expected), got \(actual)."
        case .filesystem(let detail):
            return "Could not write model files: \(detail)"
        }
    }
}

final class SemanticModelDownloader: NSObject {
    private let store = SemanticModelStore.shared
    private let queue = DispatchQueue(label: "sukurini.semantic.download")
    private var session: URLSession?
    private var currentTask: URLSessionDownloadTask?
    private var cancelled = false

    private var descriptor: SemanticModelDescriptor?
    private var pending: [SemanticModelFile] = []
    private var fileIndex = 0
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var stagingRoot: URL?

    private var onProgress: ((SemanticDownloadProgress) -> Void)?
    private var onFinish: ((Result<Void, SemanticDownloadError>) -> Void)?
    private var resumedOffsets: [Int: Int64] = [:]

    var isRunning: Bool {
        queue.sync { currentTask != nil }
    }

    var lastResumeOffsets: [Int: Int64] {
        queue.sync { resumedOffsets }
    }

    func stagingDirectory(for descriptor: SemanticModelDescriptor) -> URL {
        store.modelsRoot.appendingPathComponent(".partial-\(descriptor.id)", isDirectory: true)
    }

    private func resumeDirectory(for descriptor: SemanticModelDescriptor) -> URL {
        stagingDirectory(for: descriptor).appendingPathComponent(".resume", isDirectory: true)
    }

    private func resumeURL(for descriptor: SemanticModelDescriptor, index: Int) -> URL {
        resumeDirectory(for: descriptor).appendingPathComponent("\(index).resume")
    }

    func stagedByteCount(for descriptor: SemanticModelDescriptor) -> Int64 {
        let staging = stagingDirectory(for: descriptor)
        return descriptor.files.reduce(0) { total, file in
            let url = staging.appendingPathComponent(file.relativePath)
            guard let size = store.byteCount(of: url), size == file.byteCount else { return total }
            return total + file.byteCount
        }
    }

    @discardableResult
    func discardPartialDownload(for descriptor: SemanticModelDescriptor) -> Bool {
        let staging = stagingDirectory(for: descriptor)
        guard FileManager.default.fileExists(atPath: staging.path) else { return true }
        do {
            try FileManager.default.removeItem(at: staging)
            Log.semanticModel.info("partial download discarded id=\(descriptor.id, privacy: .public)")
            return true
        } catch {
            Log.semanticModel.error("partial discard failed id=\(descriptor.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func start(
        descriptor: SemanticModelDescriptor,
        progress: @escaping (SemanticDownloadProgress) -> Void,
        completion: @escaping (Result<Void, SemanticDownloadError>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.currentTask == nil else {
                Log.semanticModel.info("download ignored reason=already-running id=\(descriptor.id, privacy: .public)")
                return
            }
            guard SemanticModelCatalog.downloadBase != nil else {
                self.deliver(.failure(.noBaseURL), completion)
                return
            }
            guard self.store.prepareDirectories() else {
                self.deliver(.failure(.filesystem("support directories")), completion)
                return
            }

            let staging = self.stagingDirectory(for: descriptor)
            do {
                try FileManager.default.createDirectory(at: self.resumeDirectory(for: descriptor), withIntermediateDirectories: true)
            } catch {
                self.deliver(.failure(.filesystem(error.localizedDescription)), completion)
                return
            }

            self.descriptor = descriptor
            self.pending = descriptor.files
            self.fileIndex = 0
            self.completedBytes = 0
            self.totalBytes = descriptor.totalByteCount
            self.stagingRoot = staging
            self.cancelled = false
            self.onProgress = progress
            self.onFinish = completion

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 3600
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

            let resumed = self.stagedByteCount(for: descriptor)
            Log.semanticModel.info("download start id=\(descriptor.id, privacy: .public) files=\(descriptor.files.count, privacy: .public) bytes=\(self.totalBytes, privacy: .public) alreadyStaged=\(resumed, privacy: .public)")
            self.startNextLocked()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, let task = self.currentTask else { return }
            self.cancelled = true
            guard let descriptor = self.descriptor else {
                task.cancel()
                return
            }
            let target = self.resumeURL(for: descriptor, index: self.fileIndex)
            task.cancel { data in
                guard let data else {
                    Log.semanticModel.info("cancel produced no resume data index=\(self.fileIndex, privacy: .public)")
                    return
                }
                do {
                    try data.write(to: target, options: .atomic)
                    Log.semanticModel.info("resume data saved index=\(self.fileIndex, privacy: .public) bytes=\(data.count, privacy: .public)")
                } catch {
                    Log.semanticModel.error("resume data write failed error=\(error.localizedDescription, privacy: .public)")
                }
            }
            Log.semanticModel.info("download cancel requested index=\(self.fileIndex, privacy: .public)")
        }
    }

    private func startNextLocked() {
        guard !cancelled else {
            finishLocked(.failure(.cancelled))
            return
        }
        guard let descriptor, let staging = stagingRoot else {
            finishLocked(.failure(.filesystem("staging missing")))
            return
        }
        guard fileIndex < pending.count else {
            commitLocked()
            return
        }

        let file = pending[fileIndex]
        let staged = staging.appendingPathComponent(file.relativePath)
        if let size = store.byteCount(of: staged), size == file.byteCount,
           let digest = store.sha256(of: staged), digest == file.sha256 {
            Log.semanticModel.info("download skip reason=already-staged index=\(self.fileIndex, privacy: .public) path=\(file.relativePath, privacy: .public)")
            completedBytes += file.byteCount
            fileIndex += 1
            report()
            startNextLocked()
            return
        }

        guard let remote = SemanticModelCatalog.remoteURL(for: descriptor, file: file) else {
            finishLocked(.failure(.noBaseURL))
            return
        }

        let resumePath = resumeURL(for: descriptor, index: fileIndex)
        var task: URLSessionDownloadTask?
        if let data = try? Data(contentsOf: resumePath) {
            task = session?.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumePath)
            Log.semanticModel.info("download resume index=\(self.fileIndex, privacy: .public) path=\(file.relativePath, privacy: .public) resumeBytes=\(data.count, privacy: .public)")
        }
        if task == nil {
            task = session?.downloadTask(with: remote)
            Log.semanticModel.info("download file index=\(self.fileIndex, privacy: .public) path=\(file.relativePath, privacy: .public) bytes=\(file.byteCount, privacy: .public)")
        }
        currentTask = task
        task?.resume()
    }

    private func handleDownloaded(_ location: URL, response: URLResponse?) {
        guard let descriptor, let staging = stagingRoot, fileIndex < pending.count else { return }
        let file = pending[fileIndex]

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            finishLocked(.failure(.httpStatus(http.statusCode, file.relativePath)))
            return
        }

        let target = staging.appendingPathComponent(file.relativePath)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            finishLocked(.failure(.filesystem(error.localizedDescription)))
            return
        }

        guard let size = store.byteCount(of: target) else {
            finishLocked(.failure(.filesystem("size unavailable for \(file.relativePath)")))
            return
        }
        guard size == file.byteCount else {
            try? FileManager.default.removeItem(at: target)
            Log.semanticModel.error("size mismatch path=\(file.relativePath, privacy: .public) expected=\(file.byteCount, privacy: .public) actual=\(size, privacy: .public)")
            finishLocked(.failure(.sizeMismatch(file.relativePath, file.byteCount, size)))
            return
        }
        guard let digest = store.sha256(of: target), digest == file.sha256 else {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: resumeURL(for: descriptor, index: fileIndex))
            Log.semanticModel.error("checksum mismatch path=\(file.relativePath, privacy: .public)")
            finishLocked(.failure(.checksumMismatch(file.relativePath)))
            return
        }

        try? FileManager.default.removeItem(at: resumeURL(for: descriptor, index: fileIndex))
        completedBytes += file.byteCount
        fileIndex += 1
        report()
        currentTask = nil
        startNextLocked()
    }

    private func commitLocked() {
        guard let descriptor, let staging = stagingRoot else {
            finishLocked(.failure(.filesystem("staging missing")))
            return
        }
        try? FileManager.default.removeItem(at: resumeDirectory(for: descriptor))
        let destination = store.directory(for: descriptor)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            finishLocked(.failure(.filesystem(error.localizedDescription)))
            return
        }
        store.excludeFromBackup(destination)
        store.writeManifest(for: descriptor)
        Log.semanticModel.info("download complete id=\(descriptor.id, privacy: .public) bytes=\(self.completedBytes, privacy: .public)")
        stagingRoot = nil
        finishLocked(.success(()))
    }

    private func report() {
        guard let handler = onProgress else { return }
        let snapshot = SemanticDownloadProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            fileIndex: min(fileIndex, pending.count),
            fileCount: pending.count
        )
        DispatchQueue.main.async { handler(snapshot) }
    }

    private func finishLocked(_ result: Result<Void, SemanticDownloadError>) {
        if case .failure(let error) = result {
            Log.semanticModel.error("download stopped error=\(error.localizedDescription, privacy: .public) staged=\(self.completedBytes, privacy: .public)")
        }
        let completion = onFinish
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        descriptor = nil
        pending = []
        stagingRoot = nil
        onProgress = nil
        onFinish = nil
        guard let completion else { return }
        DispatchQueue.main.async { completion(result) }
    }

    private func deliver(_ result: Result<Void, SemanticDownloadError>, _ completion: @escaping (Result<Void, SemanticDownloadError>) -> Void) {
        if case .failure(let error) = result {
            Log.semanticModel.error("download rejected error=\(error.localizedDescription, privacy: .public)")
        }
        DispatchQueue.main.async { completion(result) }
    }
}

extension SemanticModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)
        let response = downloadTask.response
        queue.async { [weak self] in
            self?.handleDownloaded(staged, response: response)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resumedOffsets[self.fileIndex] = fileOffset
            Log.semanticModel.info("download resumed index=\(self.fileIndex, privacy: .public) offset=\(fileOffset, privacy: .public) expected=\(expectedTotalBytes, privacy: .public)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        queue.async { [weak self] in
            guard let self, let handler = self.onProgress else { return }
            let snapshot = SemanticDownloadProgress(
                completedBytes: self.completedBytes + totalBytesWritten,
                totalBytes: self.totalBytes,
                fileIndex: self.fileIndex,
                fileCount: self.pending.count
            )
            DispatchQueue.main.async { handler(snapshot) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        queue.async { [weak self] in
            guard let self, self.currentTask != nil else { return }
            if self.cancelled {
                self.finishLocked(.failure(.cancelled))
                return
            }
            let nsError = error as NSError
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               let descriptor = self.descriptor {
                let target = self.resumeURL(for: descriptor, index: self.fileIndex)
                try? data.write(to: target, options: .atomic)
                Log.semanticModel.info("resume data saved after failure index=\(self.fileIndex, privacy: .public) bytes=\(data.count, privacy: .public)")
            }
            self.finishLocked(.failure(.transport(error.localizedDescription)))
        }
    }
}
