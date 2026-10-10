import Carbon

/// Global hotkey via Carbon — works without Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?

    /// False when another app already owns the combination.
    private(set) var isRegistered = false

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.installEventHandler()
        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x5454_484B) /* 'TTHK' */, id: id)
        isRegistered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                           GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
