import AppKit
import Foundation

enum FolderAccess {
    enum Status: String {
        case granted
        case denied
        case missing
    }

    struct Probe: Identifiable {
        let url: URL
        let status: Status

        var id: String { url.path }
    }

    private static let privacyPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    private static let queue = DispatchQueue(label: "sukurini.onboarding.access", qos: .userInitiated)

    static func watchedTargets() -> [URL] {
        var seen = Set<String>()
        var targets: [URL] = []
        for candidate in [ScreencaptureDefaults.currentLocation(), AppSettings.shared.activeFolder] {
            guard let resolved = candidate?.standardizedFileURL else { continue }
            guard seen.insert(resolved.path).inserted else { continue }
            targets.append(resolved)
        }
        return targets
    }

    static func evaluate(_ targets: [URL], completion: @escaping ([Probe]) -> Void) {
        guard !targets.isEmpty else {
            Log.system.info("folder access probe skipped reason=no_targets")
            DispatchQueue.main.async { completion([]) }
            return
        }
        queue.async {
            let started = Date()
            let probes = targets.map { Probe(url: $0, status: inspect($0)) }
            let summary = probes.map { "\($0.url.lastPathComponent)=\($0.status.rawValue)" }.joined(separator: ",")
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.system.info("folder access probed count=\(probes.count, privacy: .public) result=\(summary, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
            DispatchQueue.main.async { completion(probes) }
        }
    }

    static func isBlocked(_ probes: [Probe]) -> Bool {
        probes.contains { $0.status != .granted }
    }

    static func openPrivacySettings() {
        guard let url = URL(string: privacyPane) else {
            Log.system.error("privacy settings url malformed value=\(privacyPane, privacy: .public)")
            return
        }
        let opened = NSWorkspace.shared.open(url)
        Log.system.info("privacy settings requested opened=\(opened, privacy: .public)")
    }

    private static func inspect(_ url: URL) -> Status {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Log.system.error("folder access target missing path=\(url.path, privacy: .public)")
            return .missing
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            return .granted
        } catch {
            let failure = error as NSError
            Log.system.error("folder access denied path=\(url.path, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
            return .denied
        }
    }
}
