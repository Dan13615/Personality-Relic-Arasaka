import AppKit

/// Point d'entrée. On crée l'application à la main (pas de storyboard, pas de SwiftUI pour l'instant).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?
    private var menu: CapriMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let library = SpriteLibrary()
        let controller = PetController(library: library)
        let menu = CapriMenu(controller: controller)
        controller.menuProvider = { [weak menu] in menu?.makeMenu() ?? NSMenu() }
        menu.installStatusItem(icon: library.menuBarIcon())
        controller.start()
        self.controller = controller
        self.menu = menu
    }
}

// Le code de ce fichier s'exécute sur le fil principal : on le dit explicitement à Swift.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // « accessory » : pas d'icône dans le Dock ni dans Cmd+Tab. (Dans Capri.app, LSUIElement fait pareil.)
    app.setActivationPolicy(.accessory)
    app.run()   // ne revient qu'à la fermeture de l'app, donc `delegate` reste en vie
}
