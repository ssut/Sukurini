import AppKit
import Foundation
import QuartzCore

final class StatusIconAnimator {
    enum Tuning {
        static let canvasSide: CGFloat = 18
        static let ringDiameter: CGFloat = 15
        static let ringLineWidth: CGFloat = 1.7
        static let dotDiameter: CGFloat = 6.5

        static let springScales: [CGFloat] = [0, 1.32, 0.88, 1]
        static let springKeyTimes: [CFTimeInterval] = [0, 0.5, 0.78, 1]
        static let springDuration: CFTimeInterval = 0.46

        static let pulseRingCount = 2
        static let pulseStartDiameter: CGFloat = 10
        static let pulseEndDiameter: CGFloat = 19
        static let pulseLineWidth: CGFloat = 1.2
        static let pulseDuration: CFTimeInterval = 0.55
        static let pulseStagger: CFTimeInterval = 0.13
        static let pulseLeadAlpha: CGFloat = 0.6
        static let pulseTrailAlpha: CGFloat = 0.36
        static let pulseInterval: CFTimeInterval = 1.05
        static let pulseWindow: CFTimeInterval = 5

        static let holdDuration: CFTimeInterval = 30
        static let frameInterval: TimeInterval = 1.0 / 30.0
    }

    private let onFrame: (NSImage) -> Void

    private var pendingSince: CFTimeInterval?
    private var frameTimer: Timer?
    private var holdTimer: Timer?

    private(set) var isPending = false

    init(onFrame: @escaping (NSImage) -> Void) {
        self.onFrame = onFrame
    }

    func renderIdle() {
        onFrame(StatusIconAnimator.image(dotScale: 0, pulses: []))
    }

    func activate() {
        let restarting = isPending
        isPending = true
        pendingSince = CACurrentMediaTime()
        startFrameTimer()
        startHoldTimer()
        Log.statusItem.info("icon pending activated restarting=\(restarting, privacy: .public) holdSec=\(Int(Tuning.holdDuration), privacy: .public)")
    }

    func clear(reason: String) {
        guard isPending else { return }
        isPending = false
        pendingSince = nil
        stopTimers()
        renderIdle()
        Log.statusItem.info("icon pending cleared reason=\(reason, privacy: .public)")
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        let timer = Timer(timeInterval: Tuning.frameInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        tick()
    }

    private func startHoldTimer() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: Tuning.holdDuration, repeats: false) { [weak self] _ in
            self?.clear(reason: "expired")
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func stopTimers() {
        frameTimer?.invalidate()
        frameTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func tick() {
        guard let since = pendingSince else { return }
        let elapsed = CACurrentMediaTime() - since
        let pulses = StatusIconAnimator.activePulses(at: elapsed)
        let scale = StatusIconAnimator.dotScale(at: elapsed)
        onFrame(StatusIconAnimator.image(dotScale: scale, pulses: pulses))

        let animationEnd = Tuning.pulseWindow + Tuning.pulseDuration + Tuning.pulseStagger
        guard elapsed >= animationEnd, elapsed >= Tuning.springDuration else { return }
        frameTimer?.invalidate()
        frameTimer = nil
        onFrame(StatusIconAnimator.image(dotScale: 1, pulses: []))
        Log.statusItem.debug("icon animation settled elapsedMs=\(Int(elapsed * 1000), privacy: .public)")
    }

    private static func dotScale(at elapsed: CFTimeInterval) -> CGFloat {
        guard elapsed < Tuning.springDuration else { return 1 }
        let progress = max(0, elapsed / Tuning.springDuration)
        let times = Tuning.springKeyTimes
        let values = Tuning.springScales
        for index in 1 ..< times.count where progress <= times[index] {
            let span = times[index] - times[index - 1]
            guard span > 0 else { return values[index] }
            let local = (progress - times[index - 1]) / span
            let eased = local * local * (3 - 2 * local)
            return values[index - 1] + (values[index] - values[index - 1]) * CGFloat(eased)
        }
        return 1
    }

    private static func activePulses(at elapsed: CFTimeInterval) -> [(diameter: CGFloat, alpha: CGFloat)] {
        var result: [(diameter: CGFloat, alpha: CGFloat)] = []
        var start: CFTimeInterval = 0
        while start < Tuning.pulseWindow {
            for index in 0 ..< Tuning.pulseRingCount {
                let local = elapsed - start - Tuning.pulseStagger * CFTimeInterval(index)
                guard local >= 0, local <= Tuning.pulseDuration else { continue }
                let progress = local / Tuning.pulseDuration
                let eased = 1 - pow(1 - progress, 2)
                let diameter = Tuning.pulseStartDiameter + (Tuning.pulseEndDiameter - Tuning.pulseStartDiameter) * CGFloat(eased)
                let base = index == 0 ? Tuning.pulseLeadAlpha : Tuning.pulseTrailAlpha
                result.append((diameter, base * CGFloat(1 - progress)))
            }
            start += Tuning.pulseInterval
        }
        return result
    }

    private static func image(dotScale: CGFloat, pulses: [(diameter: CGFloat, alpha: CGFloat)]) -> NSImage {
        let side = Tuning.canvasSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            for pulse in pulses where pulse.alpha > 0.01 {
                let path = NSBezierPath(ovalIn: StatusIconAnimator.centered(pulse.diameter, in: rect))
                path.lineWidth = Tuning.pulseLineWidth
                NSColor.black.withAlphaComponent(min(1, pulse.alpha)).setStroke()
                path.stroke()
            }

            NSColor.black.setStroke()
            let ringSpan = Tuning.ringDiameter - Tuning.ringLineWidth
            let ringPath = NSBezierPath(ovalIn: StatusIconAnimator.centered(ringSpan, in: rect))
            ringPath.lineWidth = Tuning.ringLineWidth
            ringPath.stroke()

            if dotScale > 0.01 {
                let diameter = Tuning.dotDiameter * dotScale
                NSBezierPath(ovalIn: StatusIconAnimator.centered(diameter, in: rect)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sukurini"
        return image
    }

    private static func centered(_ diameter: CGFloat, in rect: NSRect) -> NSRect {
        NSRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }
}
