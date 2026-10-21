import Carbon.HIToolbox

/// System-wide shortcuts (no permission needed):
/// ⌥⇧⌘R start/stop recording, ⌥⇧⌘P pause/resume.
final class GlobalHotKeys {
    enum Action: UInt32 { case toggleRecording = 1, togglePause = 2 }

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private let handler: (Action) -> Void

    init(handler: @escaping (Action) -> Void) {
        self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
            if let action = Action(rawValue: id.id) {
                MainActor.assumeIsolated { hotKeys.handler(action) }
            }
            return noErr
        }, 1, &spec, context, &handlerRef)

        let modifiers = UInt32(cmdKey | optionKey | shiftKey)
        register(.toggleRecording, keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers)
        register(.togglePause, keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers)
    }

    isolated deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func register(_ action: Action, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x534D4355), id: action.rawValue) // 'SMCU'
        if RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }
}
