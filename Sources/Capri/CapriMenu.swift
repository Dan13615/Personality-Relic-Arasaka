import AppKit

/// Le menu de Capri, le même au clic droit sur elle et dans la barre des menus.
/// Il est reconstruit à chaque ouverture, pour que les libellés reflètent l'état actuel.
@MainActor
final class CapriMenu: NSObject, NSMenuDelegate {
    private let controller: PetController
    private var statusItem: NSStatusItem?

    init(controller: PetController) {
        self.controller = controller
    }

    func installStatusItem(icon: NSImage?) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = icon ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Capri")
        item.button?.toolTip = "Capri"
        let menu = NSMenu()
        menu.delegate = self      // → menuNeedsUpdate est appelé juste avant chaque ouverture
        item.menu = menu
        statusItem = item
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
        controller.refreshOllama()   // pour la prochaine ouverture
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // Discuter, avec le raccourci global affiché à droite (⌃⌥C).
        let chat = item(controller.chat.isOpen ? "Fermer la discussion" : "Discuter", #selector(toggleChat), key: "c")
        chat.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(chat)
        menu.addItem(item("Nouvelle conversation", #selector(newConversation)))

        let brainItem = NSMenuItem(title: "Cerveau", action: nil, keyEquivalent: "")
        let brainMenu = NSMenu()
        brainMenu.autoenablesItems = false
        let claude = item("Claude (\(controller.settings.claudeModel))", #selector(chooseBrain(_:)))
        claude.representedObject = "claude"
        claude.state = controller.activeBrain is ClaudeBrain ? .on : .off
        brainMenu.addItem(claude)
        let ollamaInstalled = controller.ollamaModels != nil
        let ollama = item(ollamaInstalled ? "Ollama (\(controller.settings.ollamaModel))" : "Ollama (non installé)",
                          #selector(chooseBrain(_:)))
        ollama.representedObject = "ollama"
        ollama.isEnabled = ollamaInstalled
        ollama.state = controller.activeBrain is OllamaBrain ? .on : .off
        brainMenu.addItem(ollama)
        brainItem.submenu = brainMenu
        menu.addItem(brainItem)

        menu.addItem(item("Modifier sa personnalité…", #selector(editPersona)))
        menu.addItem(.separator())

        let calmTitle = controller.machine.isCalm ? "Reprendre" : "Rester tranquille"
        menu.addItem(item(calmTitle, #selector(toggleCalm)))

        let sleepTitle = controller.machine.state == .sleeping ? "Réveiller" : "Dormir"
        menu.addItem(item(sleepTitle, #selector(toggleSleep)))

        let sizeItem = NSMenuItem(title: "Taille", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in PetSize.allCases {
            let entry = item(size.menuTitle, #selector(chooseSize(_:)))
            entry.representedObject = size.rawValue
            entry.state = size == controller.size ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        menu.addItem(item("Quitter Capri", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleChat() { controller.toggleChat() }
    @objc private func newConversation() { controller.newConversation() }
    @objc private func editPersona() { controller.editPersona() }
    @objc private func toggleCalm() { controller.toggleCalm() }

    @objc private func chooseBrain(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.setBrain(name)
    }
    @objc private func toggleSleep() { controller.toggleSleep() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = PetSize(rawValue: raw) else { return }
        controller.setSize(size)
    }
}
