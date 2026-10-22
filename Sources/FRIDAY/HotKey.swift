import Carbon
import Foundation

/// Global hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    /// Whether the system accepted the shortcut (false if another app already owns it).
    private(set) var registered = false
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5350_4F54), id: 1)
        registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
        return registered
    }
}
