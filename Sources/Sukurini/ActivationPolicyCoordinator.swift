import AppKit
import Foundation

enum ActivationPolicyCoordinator {
    private static var holders: Set<String> = []

    static func acquireRegular(_ holder: String) {
        holders.insert(holder)
        apply(.regular, reason: "acquired:\(holder)")
    }

    static func release(_ holder: String) {
        holders.remove(holder)
        guard holders.isEmpty else {
            Log.app.info("activation policy retained holder=\(holder, privacy: .public) remaining=\(self.holders.count, privacy: .public)")
            return
        }
        apply(.accessory, reason: "released:\(holder)")
    }

    private static func apply(_ policy: NSApplication.ActivationPolicy, reason: String) {
        guard NSApp.activationPolicy() != policy else {
            Log.app.debug("activation policy unchanged policy=\(describe(policy), privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
        let applied = NSApp.setActivationPolicy(policy)
        let now = NSApp.activationPolicy()
        Log.app.info("activation policy target=\(describe(policy), privacy: .public) applied=\(applied, privacy: .public) now=\(describe(now), privacy: .public) reason=\(reason, privacy: .public)")
        guard now != policy else { return }
        DispatchQueue.main.async {
            let retried = NSApp.setActivationPolicy(policy)
            Log.app.info("activation policy retry target=\(describe(policy), privacy: .public) applied=\(retried, privacy: .public) now=\(describe(NSApp.activationPolicy()), privacy: .public)")
        }
    }

    static func describe(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown"
        }
    }
}
