import AppKit
import Carbon.HIToolbox

final class LatestScreenshotPaster {
    private enum Timing {
        static let restoreDelay: TimeInterval = 0.3
    }

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    private let store: ScreenshotStore
    private var isPasting = false
    private var isAlertVisible = false

    init(store: ScreenshotStore) {
        self.store = store
    }

    func paste() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.paste() }
            return
        }
        guard !isPasting else {
            Log.paste.info("paste skipped reason=already_running")
            return
        }
        guard let latest = store.latest else {
            Log.paste.info("paste skipped reason=no_screenshot")
            NSSound.beep()
            return
        }
        guard AXIsProcessTrusted() else {
            Log.paste.info("paste blocked reason=accessibility_denied file=\(latest.name, privacy: .public)")
            presentPermissionAlert()
            return
        }

        isPasting = true
        let pasteboard = NSPasteboard.general
        let backup = snapshot(pasteboard)
        let writer = PNGExporter.shared.pasteboardWriter(for: latest.url)

        pasteboard.clearContents()
        guard pasteboard.writeObjects([writer]) else {
            Log.paste.error("paste aborted reason=pasteboard_write_failed file=\(latest.name, privacy: .public)")
            restore(pasteboard, items: backup, expectedChangeCount: pasteboard.changeCount)
            isPasting = false
            return
        }
        pasteboard.addTypes([Self.transientType], owner: nil)
        let stagedChangeCount = pasteboard.changeCount
        Log.paste.info("paste staged file=\(latest.name, privacy: .public) backupItems=\(backup.count, privacy: .public) changeCount=\(stagedChangeCount, privacy: .public)")

        sendCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.restoreDelay) { [weak self] in
            guard let self else { return }
            self.restore(pasteboard, items: backup, expectedChangeCount: stagedChangeCount)
            self.isPasting = false
        }
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        let items = pasteboard.pasteboardItems ?? []
        var copies: [NSPasteboardItem] = []
        var skippedTypes = 0
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    skippedTypes += 1
                    continue
                }
                copy.setData(data, forType: type)
            }
            guard !copy.types.isEmpty else { continue }
            copies.append(copy)
        }
        Log.paste.debug("clipboard snapshot items=\(copies.count, privacy: .public) sourceItems=\(items.count, privacy: .public) skippedTypes=\(skippedTypes, privacy: .public)")
        return copies
    }

    private func restore(_ pasteboard: NSPasteboard, items: [NSPasteboardItem], expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else {
            Log.paste.info("restore skipped reason=pasteboard_changed expected=\(expectedChangeCount, privacy: .public) actual=\(pasteboard.changeCount, privacy: .public)")
            return
        }
        pasteboard.clearContents()
        guard !items.isEmpty else {
            Log.paste.info("restore complete state=empty")
            return
        }
        let wrote = pasteboard.writeObjects(items)
        if wrote {
            Log.paste.info("restore complete items=\(items.count, privacy: .public)")
        } else {
            Log.paste.error("restore failed items=\(items.count, privacy: .public)")
        }
    }

    private func sendCommandV() {
        let keyCode = Self.pasteKeyCode()
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Log.paste.error("paste key synthesis failed reason=no_event_source code=\(keyCode, privacy: .public)")
            return
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.paste.error("paste key synthesis failed reason=no_event code=\(keyCode, privacy: .public)")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        Log.paste.info("paste key sent code=\(keyCode, privacy: .public)")
    }

    private static func pasteKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            Log.paste.debug("paste key lookup fallback reason=no_layout")
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        for code in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                return UCKeyTranslate(
                    layout,
                    UInt16(code),
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
            guard status == noErr, length > 0 else { continue }
            let text = String(utf16CodeUnits: characters, count: length).lowercased()
            if text == "v" {
                return CGKeyCode(code)
            }
        }
        Log.paste.debug("paste key lookup fallback reason=not_found")
        return fallback
    }

    private func presentPermissionAlert() {
        guard !isAlertVisible else {
            Log.paste.debug("permission alert skipped reason=already_visible")
            return
        }
        isAlertVisible = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.Paste.permissionTitle
        alert.informativeText = L10n.Paste.permissionBody
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.Paste.openSettings)
        alert.addButton(withTitle: L10n.Common.cancel)
        let response = alert.runModal()
        isAlertVisible = false
        guard response == .alertFirstButtonReturn else {
            Log.paste.info("permission alert dismissed")
            return
        }
        requestAccessibilityListing()
        openAccessibilitySettings()
    }

    private func requestAccessibilityListing() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.paste.info("accessibility prompt requested trusted=\(trusted, privacy: .public)")
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: Self.accessibilityPane) else {
            Log.paste.error("accessibility settings url invalid")
            return
        }
        let opened = NSWorkspace.shared.open(url)
        Log.paste.info("accessibility settings opened=\(opened, privacy: .public)")
    }
}
