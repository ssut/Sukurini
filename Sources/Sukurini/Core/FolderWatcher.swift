import Foundation

protocol FolderWatching: AnyObject {
    func start()
    func cancel()
}

final class FolderWatcher: FolderWatching {
    private let url: URL
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private let onFolderLost: () -> Void
    private let queue: DispatchQueue

    private var source: DispatchSourceFileSystemObject?
    private var pendingWork: DispatchWorkItem?
    private var openedPath: String
    private var isStarted = false
    private var isTornDown = false
    private var didReportLost = false

    init(url: URL, debounce: TimeInterval, onChange: @escaping () -> Void, onFolderLost: @escaping () -> Void) {
        let resolved = url.standardizedFileURL
        self.url = resolved
        self.openedPath = resolved.path
        self.debounceInterval = max(0, debounce)
        self.onChange = onChange
        self.onFolderLost = onFolderLost
        self.queue = DispatchQueue(label: "sukurini.watcher.\(UUID().uuidString)", qos: .utility)
    }

    deinit {
        let path = url.path
        if !isTornDown, let live = source {
            live.cancel()
            Log.watcher.info("watcher cancelled by deinit path=\(path, privacy: .public)")
        }
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func cancel() {
        queue.async { self.tearDown(reason: "cancel") }
    }

    private func startOnQueue() {
        let path = url.path
        guard !isTornDown else {
            Log.watcher.debug("start ignored, already torn down path=\(path, privacy: .public)")
            return
        }
        guard !isStarted else {
            Log.watcher.debug("start ignored, already started path=\(path, privacy: .public)")
            return
        }
        isStarted = true

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            let code = errno
            Log.watcher.error("open failed path=\(path, privacy: .public) errno=\(code, privacy: .public)")
            isTornDown = true
            reportLost(reason: "open-failed")
            return
        }

        openedPath = Self.currentPath(of: descriptor) ?? path

        let live = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        live.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        live.setCancelHandler {
            close(descriptor)
            Log.watcher.debug("descriptor closed fd=\(descriptor, privacy: .public) path=\(path, privacy: .public)")
        }
        source = live
        live.resume()
        Log.watcher.info("watching path=\(self.openedPath, privacy: .public) fd=\(descriptor, privacy: .public) debounce=\(self.debounceInterval, privacy: .public)")
    }

    private func handleEvent() {
        guard !isTornDown, let live = source else { return }
        let flags = live.data

        if flags.contains(.delete) || flags.contains(.revoke) {
            Log.watcher.error("folder removed path=\(self.openedPath, privacy: .public) flags=\(flags.rawValue, privacy: .public)")
            reportLost(reason: "delete")
            tearDown(reason: "delete")
            return
        }

        if flags.contains(.rename) {
            let current = Self.currentPath(of: live.handle)
            Log.watcher.info("folder renamed from=\(self.openedPath, privacy: .public) to=\(current ?? "unknown", privacy: .public)")
            if current != openedPath {
                reportLost(reason: "rename")
                tearDown(reason: "rename")
                return
            }
        }

        if flags.contains(.write) {
            scheduleChange()
        }
    }

    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem(qos: .userInitiated) { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.pendingWork = nil
            Log.watcher.debug("change coalesced path=\(self.openedPath, privacy: .public)")
            let handler = self.onChange
            DispatchQueue.main.async { handler() }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func reportLost(reason: String) {
        guard !didReportLost else { return }
        didReportLost = true
        Log.watcher.error("folder lost path=\(self.url.path, privacy: .public) reason=\(reason, privacy: .public)")
        let handler = onFolderLost
        DispatchQueue.main.async { handler() }
    }

    private func tearDown(reason: String) {
        guard !isTornDown else { return }
        isTornDown = true
        pendingWork?.cancel()
        pendingWork = nil
        if let live = source {
            source = nil
            live.cancel()
        }
        Log.watcher.info("watcher stopped path=\(self.url.path, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private static func currentPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &buffer) >= 0 else {
            let code = errno
            Log.watcher.error("fcntl F_GETPATH failed fd=\(descriptor, privacy: .public) errno=\(code, privacy: .public)")
            return nil
        }
        return String(cString: buffer)
    }
}
