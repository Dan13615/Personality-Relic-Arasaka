import AppKit

/// Point d'entrée. On crée l'application à la main (pas de storyboard, pas de SwiftUI pour l'instant).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Un menu principal invisible (Capri n'a pas de barre de menus à elle), juste pour que
    /// ⌘C, ⌘V, ⌘X, ⌘A et ⌘Z marchent dans la bulle et le navigateur : ces raccourcis passent par le menu Édition.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Quitter Capri", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Édition")
        edit.addItem(NSMenuItem(title: "Annuler", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private var controller: PetController?
    private var menu: CapriMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let library = SpriteLibrary()
        let controller = PetController(library: library)
        let menu = CapriMenu(controller: controller)
        controller.menuProvider = { [weak menu] in menu?.makeMenu() ?? NSMenu() }
        menu.installStatusItem(icon: library.menuBarIcon())
        NSApp.mainMenu = Self.editMenu()
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
    // Mode relais MCP : lancé par `claude` pour accéder aux pouvoirs de Capri (voir ToolServer.swift).
    if arguments.contains("--mcp-server") {
        MCPServer.run()
    }
    if arguments.contains("--google-selftest") {
        GoogleSelfTest.run()
        dispatchMain()
    }
    if let index = arguments.firstIndex(of: "--selftest") {
        // `--answers "Refuser,Autoriser une fois"` : réponses aux demandes d'autorisation, dans l'ordre.
        var messages = Array(arguments[(index + 1)...])
        var answers: [String]?
        if let a = messages.firstIndex(of: "--answers"), a + 1 < messages.count {
            answers = messages[a + 1].components(separatedBy: ",")
            messages.removeSubrange(a...(a + 1))
        }
        SelfTest.run(messages: messages, answers: answers)
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
