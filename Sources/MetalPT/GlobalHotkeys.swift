import Carbon.HIToolbox
import MPTApp

/// System-wide hotkeys through Carbon (`RegisterEventHotKey` + an application event handler): they work over
/// fullscreen games and need no Accessibility permission. Handlers run on the main thread.
@MainActor
final class GlobalHotkeys {
    enum Action: UInt32, CaseIterable {
        case record = 1
        case overlay = 2
    }

    /// 'MPTH'.
    private static let signature: OSType = 0x4D50_5448
    private static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    /// Why the event handler could not be installed (then no hotkey can work).
    private(set) var installProblem: String?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let raw = id.id
            // Application-target Carbon events are dispatched on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue().fire(raw)
            }
            return noErr
        }, 1, &spec, me, &handlerRef)
        if status != noErr { installProblem = "Hotkeys unavailable (event handler error \(status))" }
    }

    isolated deinit {
        for a in Action.allCases { unregister(a) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers `combo` for `action`, replacing any previous registration of that action. Returns why it could not
    /// be registered (no modifier on a non-function key, or the combo is taken), or nil on success.
    func register(_ combo: HotkeyCombo, for action: Action, handler: @escaping () -> Void) -> String? {
        unregister(action)
        if let installProblem { return installProblem }
        if let problem = combo.registrationProblem { return problem }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers & Self.modifierMask, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) {
                return "\(combo.display) is already used by another app"
            }
            return "\(combo.display) could not be registered (error \(status))"
        }
        refs[action] = ref
        handlers[action] = handler
        return nil
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        handlers[action] = nil
    }

    private func fire(_ raw: UInt32) {
        guard let action = Action(rawValue: raw) else { return }
        handlers[action]?()
    }
}
