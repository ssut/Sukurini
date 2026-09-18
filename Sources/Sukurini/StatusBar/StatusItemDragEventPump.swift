import AppKit

final class StatusItemDragEventPump {
    enum Metrics {
        static let interval: TimeInterval = 1.0 / 120.0
        static let timeout: TimeInterval = 120
        static let escapeKeyCode: UInt16 = 53
    }

    var pointerSample: () -> StatusItemPointerSample = { .current }
    var isEscapePressed: () -> Bool = {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Metrics.escapeKeyCode))
    }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var post: (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) }

    private(set) var isFinished = false
    private(set) var postedDragCount = 0
    private weak var window: NSWindow?
    private let eventNumber: Int
    private var lastLocation: NSPoint
    private var startedAt: TimeInterval = 0
    private var timer: Timer?

    init(window: NSWindow, eventNumber: Int, origin: NSPoint) {
        self.window = window
        self.eventNumber = eventNumber
        self.lastLocation = origin
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil, !isFinished else { return }
        startedAt = uptime()
        let timer = Timer(timeInterval: Metrics.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        Log.drag.info("drag pump started x=\(Int(self.lastLocation.x), privacy: .public) y=\(Int(self.lastLocation.y), privacy: .public) event=\(self.eventNumber, privacy: .public)")
    }

    func stop(reason: String) {
        guard !isFinished else { return }
        isFinished = true
        timer?.invalidate()
        timer = nil
        Log.drag.info("drag pump stopped reason=\(reason, privacy: .public) posted=\(self.postedDragCount, privacy: .public)")
    }

    func tick() {
        guard !isFinished else { return }
        guard let window else {
            stop(reason: "window_gone")
            return
        }
        let sample = pointerSample()
        if uptime() - startedAt >= Metrics.timeout {
            finish(in: window, sample: sample, cancels: true, reason: "timeout")
            return
        }
        if isEscapePressed() {
            finish(in: window, sample: sample, cancels: true, reason: "escape")
            return
        }
        if sample.location != lastLocation {
            lastLocation = sample.location
            postMouse(.leftMouseDragged, in: window, sample: sample)
            postedDragCount += 1
            if postedDragCount == 1 {
                Log.drag.info("drag pump first movement x=\(Int(sample.location.x), privacy: .public) y=\(Int(sample.location.y), privacy: .public)")
            }
        }
        if !sample.isPressed {
            finish(in: window, sample: sample, cancels: false, reason: "released")
        }
    }

    private func finish(in window: NSWindow, sample: StatusItemPointerSample, cancels: Bool, reason: String) {
        if cancels, let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: window.convertPoint(fromScreen: lastLocation),
            modifierFlags: [],
            timestamp: uptime(),
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: Metrics.escapeKeyCode
        ) {
            post(escape)
        }
        postMouse(.leftMouseUp, in: window, sample: sample)
        Log.drag.info("drag pump release posted x=\(Int(self.lastLocation.x), privacy: .public) y=\(Int(self.lastLocation.y), privacy: .public) cancelled=\(cancels, privacy: .public)")
        stop(reason: reason)
    }

    private func postMouse(_ type: NSEvent.EventType, in window: NSWindow, sample: StatusItemPointerSample) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: window.convertPoint(fromScreen: lastLocation),
            modifierFlags: sample.modifiers,
            timestamp: uptime(),
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            Log.drag.error("drag pump event creation failed type=\(type.rawValue, privacy: .public)")
            return
        }
        post(event)
    }
}
