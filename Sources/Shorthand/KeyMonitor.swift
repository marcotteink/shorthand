import AppKit
import ApplicationServices

final class KeyMonitor {
    // Marks events we synthesize so the tap ignores them
    static let syntheticMarker: Int64 = 0x5348_4448  // "SHDH"

    var isEnabled = true {
        didSet { if !isEnabled { buffer = "" } }
    }
    var onTrigger: ((Snippet) -> Void)?

    private let store: SnippetStore
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""

    init(store: SnippetStore) {
        self.store = store
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyMonitorCallback,
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func reenableIfNeeded() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableIfNeeded()
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return }
        if type == .leftMouseDown || type == .rightMouseDown {
            buffer = ""
            return
        }
        guard type == .keyDown, isEnabled else { return }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case 51:  // delete (backspace)
            if !buffer.isEmpty { buffer.removeLast() }
            return
        case 36, 76, 48, 53,          // return, enter, tab, escape
             123, 124, 125, 126,      // arrows
             115, 116, 119, 121, 117: // home, page up, end, page down, forward delete
            buffer = ""
            return
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)
        guard typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }

        buffer += typed
        if buffer.count > 64 { buffer = String(buffer.suffix(64)) }

        if let snippet = store.match(bufferEndingWith: buffer) {
            buffer = ""
            onTrigger?(snippet)
        }
    }
}

private func keyMonitorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
