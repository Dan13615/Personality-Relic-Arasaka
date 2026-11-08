import AppKit
import SpriteKit

/// La fenêtre de Capri : un petit panneau sans bord, transparent, qui flotte au-dessus des autres.
///
/// - « non-activating » : cliquer dessus ne vole pas le focus à l'app que tu utilises ;
/// - niveau « floating » : au-dessus des fenêtres normales (mais sous le Dock et les menus) ;
/// - présente sur tous les Spaces, y compris à côté d'une app en plein écran.
final class PetPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false        // un NSPanel se cache par défaut quand l'app n'est pas active
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // Jamais de focus clavier : Capri ne doit pas interrompre ce que tu tapes.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// La vue SpriteKit transparente. Elle transmet juste les événements souris au contrôleur.
final class PetView: SKView {
    weak var controller: PetController?

    // Accepte le tout premier clic, même si l'app n'est pas active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Ctrl + clic = clic droit, comme partout sur Mac.
        if event.modifierFlags.contains(.control) {
            controller?.showContextMenu(with: event, in: self)
        } else {
            controller?.mouseDown()
        }
    }

    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp() }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(with: event, in: self)
    }
}
