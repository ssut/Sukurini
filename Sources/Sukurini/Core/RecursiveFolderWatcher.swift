import CoreServices
import Foundation

final class RecursiveFolderWatcher: FolderWatching {
    private let url: URL
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private let onFolderLost: () -> Void
    private let queue: DispatchQueue

    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?
    private var isStarted = false
    private var isTornDown = false
    private var didReportLost = false

    init(url: URL, debounce: TimeInterval, onChange: @escaping () -> Void, onFolderLost: @escaping () -> Void) {
        let resolved = url.standardizedFileURL
        self.url = resolved
        self.debounceInterval = max(0, debounce)
        self.onChange = onChange
        self.onFolderLost = onFolderLost
        self.queue = DispatchQueue(label: "sukurini.watcher.recursive.\(UUID().uuidString)", qos: .utility)
    }

    deinit {
        let path = url.path
        if !isTornDown, let live = stream {
            FSEventStreamStop(live)
            FSEventStreamInvalidate(live)
            FSEventStreamRelease(live)
            Log.watcher.info("recursive watcher cancelled by deinit path=\(path, privacy: .public)")
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
            Log.watcher.debug("recursive start ignored, already torn down path=\(path, privacy: .public)")
            return
        }
        guard !isStarted else {
            Log.watcher.debug("recursive start ignored, already started path=\(path, privacy: .public)")
            return
        }
        isStarted = true

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            RecursiveFolderWatcher.eventCallback,
            &context,
            [path as CFString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            Log.watcher.error("fsevents create failed path=\(path, privacy: .public)")
            isTornDown = true
            reportLost(reason: "create-failed")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            Log.watcher.error("fsevents start failed path=\(path, privacy: .public)")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            isTornDown = true
            reportLost(reason: "start-failed")
            return
        }

        stream = created
        Log.watcher.info("watching recursively path=\(path, privacy: .public) latency=\(self.debounceInterval, privacy: .public)")
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, _, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<RecursiveFolderWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleEvents(count: count, flags: eventFlags)
    }

    private func handleEvents(count: Int, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard !isTornDown else { return }

        var rootChanged = false
        var changed = false
        for index in 0..<count {
            let flag = flags[index]
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 || flag & UInt32(kFSEventStreamEventFlagUnmount) != 0 {
                rootChanged = true
                continue
            }
            changed = true
        }

        if rootChanged {
            var isDirectory: ObjCBool = false
            let alive = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            guard alive else {
                Log.watcher.error("folder removed path=\(self.url.path, privacy: .public) reason=root-changed")
                reportLost(reason: "root-changed")
                tearDown(reason: "root-changed")
                return
            }
            Log.watcher.info("root changed but folder present path=\(self.url.path, privacy: .public)")
            scheduleChange()
            return
        }

        if changed {
            scheduleChange()
        }
    }

    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem(qos: .userInitiated) { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.pendingWork = nil
            Log.watcher.debug("recursive change coalesced path=\(self.url.path, privacy: .public)")
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
        if let live = stream {
            stream = nil
            FSEventStreamStop(live)
            FSEventStreamInvalidate(live)
            FSEventStreamRelease(live)
        }
        Log.watcher.info("recursive watcher stopped path=\(self.url.path, privacy: .public) reason=\(reason, privacy: .public)")
    }
}
