import AppKit
import Carbon.HIToolbox
import OSLog

/// Registers a system-wide hotkey that summons the TerrierGPT panel.
///
/// Uses `RegisterEventHotKey` so Accessibility permission is not required (a `CGEventTap`
/// would). Default is ⌥Space — the same chord many launcher apps use, so the overflow menu
/// can clear or change it later if it collides.
@MainActor
final class GlobalHotKey {

    static let shared = GlobalHotKey()

    private let log = Logger(subsystem: "com.brianmatute.TerrierGPTMenu", category: "hotkey")
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isRegistered = false

    /// Defaults: Option + Space. Stored so a future settings row can change it without a rebuild.
    private(set) var isEnabled: Bool = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true

    private enum Keys {
        static let enabled = "GlobalHotKeyEnabled"
    }

    private init() {}

    func start() {
        guard isEnabled else { return }
        register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    }

    func stop() {
        unregister()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled {
            register(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        } else {
            unregister()
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let box = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    box.handlePress()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            log.error("InstallEventHandler failed: \(status)")
            return
        }

        var hotKeyID = EventHotKeyID(signature: OSType(0x54475054), /* 'TGPT' */ id: 1)
        let hotStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard hotStatus == noErr else {
            log.error("RegisterEventHotKey failed: \(hotStatus)")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            return
        }
        isRegistered = true
        log.info("Global hotkey registered (⌥Space)")
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isRegistered = false
    }

    private func handlePress() {
        let opened = AuthManager.shared.showPanel()
        if !opened {
            CaptureCoordinator.shared.show(Toast(
                kind: .info,
                title: "Click the sparkles icon",
                detail: "The panel couldn't be opened from the hotkey this time."
            ))
        }
    }
}
