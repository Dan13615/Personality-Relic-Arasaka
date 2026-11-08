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

        // Mode test caché : `Capri --open-chat ["message"]` ouvre la bulle (et envoie le message) au lancement.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open-chat") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                controller.toggleChat()
                if index + 1 < arguments.count {
                    controller.chat.model.input = arguments[index + 1]
                    controller.chat.model.send()
                }
            }
        }
        self.menu = menu
    }
}

// Le code de ce fichier s'exécute sur le fil principal : on le dit explicitement à Swift.
MainActor.assumeIsolated {
    // Mode test caché : `Capri --selftest "message" ["message 2" …]`, sans interface.
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--selftest") {
        SelfTest.run(messages: Array(arguments[(index + 1)...]))
        dispatchMain()   // fait tourner la boucle principale ; SelfTest quitte à la fin
    }
    // Mode caché : `Capri --render-ui dossier`, dessine les bulles en PNG pour vérifier leur look.
    if let index = arguments.firstIndex(of: "--render-ui"), index + 1 < arguments.count {
        UIRender.run(directory: arguments[index + 1])
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // « accessory » : pas d'icône dans le Dock ni dans Cmd+Tab. (Dans Capri.app, LSUIElement fait pareil.)
    app.setActivationPolicy(.accessory)
    app.run()   // ne revient qu'à la fermeture de l'app, donc `delegate` reste en vie
}
