import Carbon
import AppKit

/// Global keyboard shortcuts for answering a request without touching the mouse:
/// Option-Command-Y allow, N deny, A always allow. They exist only while a request is waiting,
/// so they never block those keys in other apps the rest of the time. No permission needed.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    static let labels = (allow: "⌥⌘Y", deny: "⌥⌘N", always: "⌥⌘A")

    var onAllow: (() -> Void)?
    var onDeny: (() -> Void)?
    var onAlways: (() -> Void)?
    private(set) var isEnabled = false
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Returns true when all three shortcuts were registered.
    @discardableResult
    func enable() -> Bool {
        if isEnabled { return true }
        hotKeyTarget = { [weak self] id in
            switch id {
            case 1: self?.onAllow?()
            case 2: self?.onDeny?()
            case 3: self?.onAlways?()
            default: break
            }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &handler)
        let mods = UInt32(cmdKey | optionKey)
        var ok = true
        for (id, key) in [(UInt32(1), kVK_ANSI_Y), (2, kVK_ANSI_N), (3, kVK_ANSI_A)] {
            var ref: EventHotKeyRef?
            let hk = EventHotKeyID(signature: OSType(0x4E544348), id: id)      // "NTCH"
            let status = RegisterEventHotKey(UInt32(key), mods, hk, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { ok = false }
        }
        isEnabled = true
        return ok && refs.count == 3
    }

    func disable() {
        guard isEnabled else { return }
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        isEnabled = false
        hotKeyTarget = nil
    }
}

private var hotKeyTarget: ((UInt32) -> Void)?

private let hotKeyCallback: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    let pressed = id.id
    DispatchQueue.main.async { hotKeyTarget?(pressed) }
    return noErr
}
