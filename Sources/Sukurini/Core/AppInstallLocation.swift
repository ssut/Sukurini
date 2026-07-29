import AppKit
import Security

enum AppInstallLocation {
    enum Signature: String {
        case distributed
        case adhoc
        case unsigned
    }

    enum Placement: String {
        case installed
        case notABundle
        case elsewhere
    }

    enum Failure: LocalizedError {
        case notInstallable
        case destinationRunning(String)
        case replaceFailed(String)
        case copyFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .notInstallable:
                return L10n.Install.failureNotInstallable
            case .destinationRunning(let path):
                return L10n.Install.failureDestinationRunning(path)
            case .replaceFailed(let reason):
                return L10n.Install.failureReplace(reason)
            case .copyFailed(let reason):
                return L10n.Install.failureCopy(reason)
            case .verificationFailed:
                return L10n.Install.failureVerification
            }
        }
    }

    struct State {
        let runningURL: URL
        let sourceURL: URL
        let destination: URL
        let signature: Signature
        let placement: Placement
        let translocated: Bool
        let sourceRemovable: Bool
        let destinationOccupied: Bool
        let destinationIsUserFolder: Bool

        var isInstalled: Bool { placement == .installed }

        var canInstall: Bool { placement == .elsewhere }

        var recommendsInstall: Bool { canInstall && signature == .distributed }

        var copiesOnly: Bool { !sourceRemovable }
    }

    private static let adhocFlag: UInt32 = 0x0002
    private static let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    private static var cached: State?

    static func current(refresh: Bool = false) -> State {
        if !refresh, let cached { return cached }
        let state = resolve()
        cached = state
        Log.system.info("install location resolved placement=\(state.placement.rawValue, privacy: .public) signature=\(state.signature.rawValue, privacy: .public) translocated=\(state.translocated, privacy: .public) removable=\(state.sourceRemovable, privacy: .public) occupied=\(state.destinationOccupied, privacy: .public) source=\(state.sourceURL.path, privacy: .public) destination=\(state.destination.path, privacy: .public)")
        return state
    }

    static func installRoots() -> [String] {
        let user = userApplications
        let candidates = [
            systemApplications.standardizedFileURL.path,
            systemApplications.resolvingSymlinksInPath().path,
            user.path,
            user.resolvingSymlinksInPath().path
        ]
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func isInstalled(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return installRoots().contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func install(_ state: State, completion: @escaping (Result<URL, Error>) -> Void) {
        guard state.canInstall else {
            Log.system.error("install refused reason=not_installable placement=\(state.placement.rawValue, privacy: .public)")
            completion(.failure(Failure.notInstallable))
            return
        }
        if let conflict = runningInstance(at: state.destination) {
            Log.system.error("install refused reason=destination_running path=\(conflict.path, privacy: .public)")
            completion(.failure(Failure.destinationRunning(displayPath(conflict))))
            return
        }
        Log.system.info("install started source=\(state.sourceURL.path, privacy: .public) destination=\(state.destination.path, privacy: .public) removesSource=\(state.sourceRemovable, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = perform(state)
            DispatchQueue.main.async {
                cached = nil
                completion(result)
            }
        }
    }

    static func relaunch(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.1; done; exec /usr/bin/open \"$1\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sukurini-relaunch", url.path]
        do {
            try task.run()
            Log.system.info("relaunch scheduled pid=\(pid, privacy: .public) path=\(url.path, privacy: .public)")
        } catch {
            Log.system.error("relaunch scheduling failed error=\(error.localizedDescription, privacy: .public) path=\(url.path, privacy: .public)")
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func folderName(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        guard !parent.path.isEmpty, parent.path != "/" else { return url.path }
        return displayPath(parent)
    }

    private static var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
    }

    private static func resolve() -> State {
        let running = Bundle.main.bundleURL.standardizedFileURL
        let origin = untranslocated(running)
        let source = origin.url
        let placement = placement(for: running, source: source)
        let destination = preferredDestination(named: source.lastPathComponent)
        let occupied = FileManager.default.fileExists(atPath: destination.path)

        return State(
            runningURL: running,
            sourceURL: source,
            destination: destination,
            signature: signature(of: running),
            placement: placement,
            translocated: origin.translocated,
            sourceRemovable: placement == .elsewhere && isRemovable(source),
            destinationOccupied: occupied,
            destinationIsUserFolder: !destination.path.hasPrefix(systemApplications.path + "/")
        )
    }

    private static func placement(for running: URL, source: URL) -> Placement {
        guard running.pathExtension.lowercased() == "app",
              (Bundle.main.bundleIdentifier ?? "").isEmpty == false else {
            return .notABundle
        }
        return isInstalled(source) ? .installed : .elsewhere
    }

    private static func preferredDestination(named name: String) -> URL {
        let system = systemApplications.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.isWritableFile(atPath: systemApplications.path) {
            return system.standardizedFileURL
        }
        Log.system.info("install destination falling back to user folder reason=system_not_writable")
        return userApplications.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    }

    private static func isRemovable(_ url: URL) -> Bool {
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        guard !readOnly else { return false }
        let parent = url.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    private static func runningInstance(at destination: URL) -> URL? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let target = destination.standardizedFileURL.path
        let mine = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            guard app.processIdentifier != mine else { continue }
            guard let url = app.bundleURL?.standardizedFileURL, url.path == target else { continue }
            return url
        }
        return nil
    }

    private static func perform(_ state: State) -> Result<URL, Error> {
        let manager = FileManager.default
        let destination = state.destination

        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Log.system.error("install destination folder unavailable error=\(error.localizedDescription, privacy: .public)")
            return .failure(Failure.copyFailed(error.localizedDescription))
        }

        if manager.fileExists(atPath: destination.path) {
            do {
                var trashed: NSURL?
                try manager.trashItem(at: destination, resultingItemURL: &trashed)
                Log.system.info("install replaced existing copy trashed=\((trashed as URL?)?.path ?? "unknown", privacy: .public)")
            } catch {
                Log.system.error("install replace failed error=\(error.localizedDescription, privacy: .public) path=\(destination.path, privacy: .public)")
                return .failure(Failure.replaceFailed(error.localizedDescription))
            }
        }

        let requirement = designatedRequirement(of: state.runningURL)

        do {
            try manager.copyItem(at: state.sourceURL, to: destination)
            Log.system.info("install copy finished path=\(destination.path, privacy: .public)")
        } catch {
            Log.system.error("install copy failed error=\(error.localizedDescription, privacy: .public) source=\(state.sourceURL.path, privacy: .public)")
            try? manager.removeItem(at: destination)
            return .failure(Failure.copyFailed(error.localizedDescription))
        }

        guard verify(destination, against: requirement) else {
            Log.system.error("install verification failed, rolling back path=\(destination.path, privacy: .public)")
            try? manager.removeItem(at: destination)
            return .failure(Failure.verificationFailed)
        }

        clearQuarantine(destination)
        removeSource(state)
        return .success(destination)
    }

    private static func removeSource(_ state: State) {
        guard state.sourceRemovable else {
            Log.system.info("install kept source reason=not_removable path=\(state.sourceURL.path, privacy: .public)")
            return
        }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: state.sourceURL, resultingItemURL: &trashed)
            Log.system.info("install source trashed path=\((trashed as URL?)?.path ?? "unknown", privacy: .public)")
        } catch {
            Log.system.error("install source trash failed error=\(error.localizedDescription, privacy: .public) path=\(state.sourceURL.path, privacy: .public)")
        }
    }

    private static func clearQuarantine(_ url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-d", "-r", "com.apple.quarantine", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            Log.system.info("install quarantine cleared status=\(task.terminationStatus, privacy: .public) path=\(url.path, privacy: .public)")
        } catch {
            Log.system.error("install quarantine clear failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func signature(of url: URL) -> Signature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            Log.system.debug("signature unreadable reason=no_static_code path=\(url.path, privacy: .public)")
            return .unsigned
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any] else {
            Log.system.debug("signature unreadable reason=no_signing_info path=\(url.path, privacy: .public)")
            return .unsigned
        }
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        guard flags & adhocFlag == 0 else { return .adhoc }
        let certificates = (info[kSecCodeInfoCertificates as String] as? [Any])?.count ?? 0
        guard certificates > 0 else { return .unsigned }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
        Log.system.debug("signature distributed team=\(team, privacy: .public) certificates=\(certificates, privacy: .public)")
        return .distributed
    }

    private static func designatedRequirement(of url: URL) -> SecRequirement? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func verify(_ url: URL, against requirement: SecRequirement?) -> Bool {
        guard let requirement else {
            Log.system.info("install verification skipped reason=no_requirement")
            return true
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        Log.system.info("install verification status=\(status, privacy: .public) path=\(url.path, privacy: .public)")
        return status == errSecSuccess
    }

    private typealias IsTranslocatedFn = @convention(c) (
        CFURL,
        UnsafeMutablePointer<DarwinBoolean>?,
        UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool

    private typealias OriginalPathFn = @convention(c) (
        CFURL,
        UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    private static let securityImage: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY)

    private static func untranslocated(_ url: URL) -> (url: URL, translocated: Bool) {
        guard let image = securityImage,
              let probe = dlsym(image, "SecTranslocateIsTranslocatedURL") else {
            return (url, false)
        }
        var flag: DarwinBoolean = false
        let isTranslocated = unsafeBitCast(probe, to: IsTranslocatedFn.self)
        guard isTranslocated(url as CFURL, &flag, nil), flag.boolValue else { return (url, false) }
        guard let resolver = dlsym(image, "SecTranslocateCreateOriginalPathForURL") else {
            Log.system.error("translocation detected but original path resolver missing path=\(url.path, privacy: .public)")
            return (url, true)
        }
        let originalPath = unsafeBitCast(resolver, to: OriginalPathFn.self)
        guard let original = originalPath(url as CFURL, nil)?.takeRetainedValue() as URL? else {
            Log.system.error("translocation original path unresolved path=\(url.path, privacy: .public)")
            return (url, true)
        }
        Log.system.info("translocation resolved running=\(url.path, privacy: .public) original=\(original.path, privacy: .public)")
        return (original.standardizedFileURL, true)
    }
}
