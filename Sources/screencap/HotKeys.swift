import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Global hotkeys via Carbon. Unlike CGEventTap this needs no Accessibility permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private struct Binding {
        let requireLeftShift: Bool
        let handler: @MainActor () -> Void
        var isPressed = false
    }
    private var handlers: [UInt32: Binding] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(keyCode: Int, modifiers: Int, requireLeftShift: Bool = false,
                  handler: @escaping @MainActor () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = Binding(requireLeftShift: requireLeftShift, handler: handler)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53434150), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status != noErr {
            FileHandle.standardError.write(Data("hotkey registration failed for keyCode \(keyCode): OSStatus \(status)\n".utf8))
            handlers[id] = nil
            return false
        }
        refs.append(ref)
        return true
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // NX_DEVICELSHIFTKEYMASK and NX_DEVICERSHIFTKEYMASK retain the side.
            // Combined keyState can normalize an injected right Shift to left Shift.
            let shiftSides = CGEventSource.flagsState(.combinedSessionState).rawValue & 0x6
            let leftShiftOnly = shiftSides == 0
                ? CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Shift))
                    && !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightShift))
                : shiftSides == 0x2
            DispatchQueue.main.async { HotKeys.shared.receive(id: id, pressed: pressed, leftShift: leftShiftOnly) }
            return noErr
        }, specs.count, &specs, nil, nil)
    }

    private func receive(id: UInt32, pressed: Bool, leftShift: Bool) {
        guard var binding = handlers[id] else { return }
        let wasPressed = binding.isPressed
        binding.isPressed = pressed
        handlers[id] = binding
        guard pressed, !wasPressed, !binding.requireLeftShift || leftShift else { return }
        binding.handler()
    }
}
