import Carbon.HIToolbox

/// Raccourci clavier global (actif même quand une autre app est au premier plan).
///
/// On utilise la vieille API Carbon `RegisterEventHotKey` : elle est toujours là, et surtout
/// elle ne demande AUCUNE permission (contrairement à la surveillance de tout le clavier).
///
/// Raccourci choisi : ⌃⌥C (« C » comme Capri). ⌃⌥Espace aurait été joli, mais macOS l'utilise
/// déjà pour changer de source de saisie (clavier).
@MainActor
final class HotKey {
    static let displayName = "⌃⌥C"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        register()
    }

    private func register() {
        // 1. Un « gestionnaire » qui sera appelé quand une touche globale est pressée.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)

        // 2. Le raccourci lui-même : touche C + Contrôle + Option.
        let id = EventHotKeyID(signature: OSType(0x43505249), id: 1)   // 'CPRI'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            log.error("Raccourci \(Self.displayName, privacy: .public) indisponible (erreur \(status))")
        }
    }
}
