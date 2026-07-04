import AppKit
import Carbon.HIToolbox

/// A single global hotkey backed by Carbon's RegisterEventHotKey.
/// Works system-wide and fires even when Shorthand is not the active app.
final class HotKey {
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Carbon modifier masks, for readability at the call site.
    struct Modifiers {
        static let command = UInt32(cmdKey)
        static let shift = UInt32(shiftKey)
        static let option = UInt32(optionKey)
        static let control = UInt32(controlKey)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let this = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                this.onFire?()
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x53484B59), id: 1)  // 'SHKY'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { unregister() }
}
