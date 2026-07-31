import AppKit
import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    static let sukuriniHotKeyRegistrationChanged = Notification.Name("sukurini.hotKeyRegistrationChanged")
}

enum HotKeyPurpose: String {
    case gallery
    case paste
}

final class HotKeyCenter {
    static let registrationFailedKey = "failed"
    static let registrationPurposeKey = "purpose"

    let purpose: HotKeyPurpose

    var onTrigger: (() -> Void)?

    private final class WeakCenter {
        weak var value: HotKeyCenter?

        init(_ value: HotKeyCenter) {
            self.value = value
        }
    }

    private static let signature: OSType = 0x5355_4B52
    private static let lock = NSLock()
    private static var registry: [UInt32: WeakCenter] = [:]
    private static var sharedHandler: EventHandlerRef?
    private static var nextIdentifier: UInt32 = 1

    private static let dispatchHandler: EventHandlerUPP = { _, event, _ in
        guard let event else {
            Log.system.error("hotkey event dropped reason=nil_event")
            return OSStatus(eventNotHandledErr)
        }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else {
            Log.system.error("hotkey event read failed status=\(status, privacy: .public)")
            return OSStatus(eventNotHandledErr)
        }
        guard hotKeyID.signature == HotKeyCenter.signature else {
            Log.system.debug("hotkey event ignored reason=foreign_signature")
            return OSStatus(eventNotHandledErr)
        }
        guard let center = HotKeyCenter.center(for: hotKeyID.id) else {
            Log.system.error("hotkey event dropped reason=center_missing id=\(hotKeyID.id, privacy: .public)")
            return OSStatus(eventNotHandledErr)
        }
        center.dispatchTrigger()
        return noErr
    }

    private let identifier: UInt32
    private let bindingProvider: () -> HotKeyBinding?
    private var hotKeyRef: EventHotKeyRef?
    private var activeBinding: HotKeyBinding?
    private var settingsObserver: NSObjectProtocol?
    private var isStarted = false

    init(purpose: HotKeyPurpose, binding: @escaping () -> HotKeyBinding?) {
        self.purpose = purpose
        self.bindingProvider = binding
        identifier = HotKeyCenter.reserveIdentifier()
        Log.system.info("hotkey center created id=\(self.identifier, privacy: .public) purpose=\(purpose.rawValue, privacy: .public)")
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        settingsObserver = nil
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            Log.system.info("hotkey unregistered id=\(self.identifier, privacy: .public) reason=deinit status=\(status, privacy: .public)")
        }
        hotKeyRef = nil
        activeBinding = nil
        HotKeyCenter.detach(identifier: identifier)
        Log.system.info("hotkey center released id=\(self.identifier, privacy: .public)")
    }

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    func start() {
        onMain {
            guard !self.isStarted else {
                Log.system.info("hotkey center start repeated id=\(self.identifier, privacy: .public)")
                self.applyCurrentBinding(reason: "restart")
                return
            }
            self.isStarted = true
            self.observeSettings()
            Log.system.info("hotkey center started id=\(self.identifier, privacy: .public)")
            self.applyCurrentBinding(reason: "start")
        }
    }

    func stop() {
        onMain {
            let wasStarted = self.isStarted
            let wasRegistered = self.isRegistered
            self.isStarted = false
            self.removeSettingsObserver()
            self.unregisterHotKey(reason: "stop")
            Log.system.info("hotkey center stopped id=\(self.identifier, privacy: .public) wasStarted=\(wasStarted, privacy: .public) wasRegistered=\(wasRegistered, privacy: .public)")
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            Log.system.debug("hotkey work hopped to main thread id=\(self.identifier, privacy: .public)")
            DispatchQueue.main.async(execute: work)
        }
    }

    private func observeSettings() {
        removeSettingsObserver()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .sukuriniHotKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.system.info("hotkey settings change received id=\(self.identifier, privacy: .public)")
            self.applyCurrentBinding(reason: "settings_changed")
        }
    }

    private func removeSettingsObserver() {
        guard let settingsObserver else { return }
        NotificationCenter.default.removeObserver(settingsObserver)
        self.settingsObserver = nil
        Log.system.debug("hotkey settings observer removed id=\(self.identifier, privacy: .public)")
    }

    private func applyCurrentBinding(reason: String) {
        guard isStarted else {
            Log.system.debug("hotkey apply skipped id=\(self.identifier, privacy: .public) reason=not_started")
            return
        }
        guard let binding = bindingProvider() else {
            unregisterHotKey(reason: "not_configured")
            Log.system.info("hotkey idle id=\(self.identifier, privacy: .public) reason=\(reason, privacy: .public) state=not_configured")
            postRegistrationState(failed: false)
            return
        }
        guard binding.carbonModifiers != 0 else {
            unregisterHotKey(reason: "invalid_binding")
            Log.system.error("hotkey refused id=\(self.identifier, privacy: .public) reason=missing_modifiers code=\(binding.keyCode, privacy: .public)")
            postRegistrationState(failed: true)
            return
        }
        if isRegistered, activeBinding == binding {
            Log.system.debug("hotkey unchanged id=\(self.identifier, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
        unregisterHotKey(reason: "rebind")
        register(binding, reason: reason)
    }

    private func register(_ binding: HotKeyBinding, reason: String) {
        guard HotKeyCenter.installSharedHandler() else {
            Log.system.error("hotkey registration aborted id=\(self.identifier, privacy: .public) reason=handler_unavailable")
            postRegistrationState(failed: true)
            return
        }
        HotKeyCenter.attach(self, identifier: identifier)
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: identifier)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            HotKeyCenter.detach(identifier: identifier)
            Log.system.error("hotkey registration failed id=\(self.identifier, privacy: .public) code=\(binding.keyCode, privacy: .public) modifiers=\(binding.carbonModifiers, privacy: .public) status=\(status, privacy: .public)")
            postRegistrationState(failed: true)
            return
        }
        hotKeyRef = reference
        activeBinding = binding
        Log.system.info("hotkey registered id=\(self.identifier, privacy: .public) code=\(binding.keyCode, privacy: .public) modifiers=\(binding.carbonModifiers, privacy: .public) reason=\(reason, privacy: .public)")
        postRegistrationState(failed: false)
    }

    private func unregisterHotKey(reason: String) {
        guard let hotKeyRef else {
            Log.system.debug("hotkey unregister skipped id=\(self.identifier, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
        let status = UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        activeBinding = nil
        HotKeyCenter.detach(identifier: identifier)
        Log.system.info("hotkey unregistered id=\(self.identifier, privacy: .public) reason=\(reason, privacy: .public) status=\(status, privacy: .public)")
    }

    private func postRegistrationState(failed: Bool) {
        NotificationCenter.default.post(
            name: .sukuriniHotKeyRegistrationChanged,
            object: self,
            userInfo: [
                HotKeyCenter.registrationFailedKey: failed,
                HotKeyCenter.registrationPurposeKey: purpose.rawValue
            ]
        )
    }

    private func dispatchTrigger() {
        Log.system.info("hotkey triggered id=\(self.identifier, privacy: .public)")
        guard let onTrigger else {
            Log.system.error("hotkey trigger ignored id=\(self.identifier, privacy: .public) reason=no_handler")
            return
        }
        DispatchQueue.main.async(execute: onTrigger)
    }

    private static func reserveIdentifier() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextIdentifier
        nextIdentifier = nextIdentifier &+ 1
        return value
    }

    private static func attach(_ center: HotKeyCenter, identifier: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        registry[identifier] = WeakCenter(center)
        Log.system.debug("hotkey center attached id=\(identifier, privacy: .public) count=\(registry.count, privacy: .public)")
    }

    private static func detach(identifier: UInt32) {
        lock.lock()
        registry.removeValue(forKey: identifier)
        registry = registry.filter { $0.value.value != nil }
        var orphanedHandler: EventHandlerRef?
        if registry.isEmpty, let handler = sharedHandler {
            orphanedHandler = handler
            sharedHandler = nil
        }
        let remaining = registry.count
        lock.unlock()
        Log.system.debug("hotkey center detached id=\(identifier, privacy: .public) count=\(remaining, privacy: .public)")
        guard let orphanedHandler else { return }
        let status = RemoveEventHandler(orphanedHandler)
        Log.system.info("hotkey handler removed status=\(status, privacy: .public)")
    }

    private static func center(for identifier: UInt32) -> HotKeyCenter? {
        lock.lock()
        defer { lock.unlock() }
        return registry[identifier]?.value
    }

    private static func installSharedHandler() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sharedHandler != nil { return true }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            dispatchHandler,
            1,
            &specification,
            nil,
            &handler
        )
        guard status == noErr, let handler else {
            Log.system.error("hotkey handler install failed status=\(status, privacy: .public)")
            return false
        }
        sharedHandler = handler
        Log.system.info("hotkey handler installed")
        return true
    }
}

final class HotKeyRecorder {
    enum Outcome: Equatable {
        case captured(HotKeyBinding)
        case cancelled
        case rejected(String)
        case ignored
    }

    private var monitor: Any?

    var isRecording: Bool {
        monitor != nil
    }

    deinit {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        Log.settings.info("shortcut recorder stopped reason=deinit")
    }

    func start(_ handler: @escaping (Outcome) -> Void) {
        stop(reason: "restart")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let outcome = HotKeyRecorder.evaluate(event)
            Log.settings.info("shortcut recorder captured code=\(event.keyCode, privacy: .public) outcome=\(HotKeyRecorder.describe(outcome), privacy: .public)")
            handler(outcome)
            return nil
        }
        Log.settings.info("shortcut recorder started")
    }

    func stop(reason: String) {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        Log.settings.info("shortcut recorder stopped reason=\(reason, privacy: .public)")
    }

    static func evaluate(_ event: NSEvent) -> Outcome {
        let keyCode = UInt32(event.keyCode)
        guard !event.isARepeat else { return .ignored }
        guard keyCode != UInt32(kVK_Escape) else { return .cancelled }
        guard !modifierKeyCodes.contains(keyCode) else { return .ignored }
        let modifiers = carbonModifiers(from: event.modifierFlags)
        let anchors = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard modifiers & anchors != 0 else {
            return .rejected(L10n.Shortcut.needsModifier)
        }
        return .captured(HotKeyBinding(keyCode: keyCode, carbonModifiers: modifiers))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let cleaned = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if cleaned.contains(.command) { modifiers |= UInt32(cmdKey) }
        if cleaned.contains(.option) { modifiers |= UInt32(optionKey) }
        if cleaned.contains(.control) { modifiers |= UInt32(controlKey) }
        if cleaned.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .captured(let binding):
            return "captured:\(binding.carbonModifiers)+\(binding.keyCode)"
        case .cancelled:
            return "cancelled"
        case .rejected:
            return "rejected"
        case .ignored:
            return "ignored"
        }
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_CapsLock),
        UInt32(kVK_Function)
    ]
}

enum HotKeyFormatter {
    static func display(_ binding: HotKeyBinding) -> String {
        modifierSymbols(binding.carbonModifiers) + keyName(for: binding.keyCode)
    }

    static func modifierSymbols(_ carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let named = namedKeys[keyCode] {
            return named
        }
        if let translated = layoutCharacter(for: keyCode) {
            return translated
        }
        Log.settings.debug("hotkey key name fallback code=\(keyCode, privacy: .public)")
        return "Key \(keyCode)"
    }

    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            Log.settings.debug("keyboard layout source unavailable code=\(keyCode, privacy: .public)")
            return nil
        }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            Log.settings.debug("keyboard layout data unavailable code=\(keyCode, privacy: .public)")
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else {
            Log.settings.debug("key translate failed code=\(keyCode, privacy: .public) status=\(status, privacy: .public)")
            return nil
        }
        let text = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.uppercased()
    }

    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_ANSI_KeypadEnter): "Enter",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12"
    ]
}
