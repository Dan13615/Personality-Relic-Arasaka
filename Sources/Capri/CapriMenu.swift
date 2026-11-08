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
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // Étape 2 : ouvrira la discussion avec Capri.
        let chat = NSMenuItem(title: "Discuter (bientôt)", action: nil, keyEquivalent: "")
        chat.isEnabled = false
        menu.addItem(chat)
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

    @objc private func toggleCalm() { controller.toggleCalm() }
    @objc private func toggleSleep() { controller.toggleSleep() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = PetSize(rawValue: raw) else { return }
        controller.setSize(size)
    }
}
