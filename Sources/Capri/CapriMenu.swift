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

        menu.addItem(item("Navigateur de Capri", #selector(openBrowser)))
        let calendarItem = NSMenuItem(title: "Agenda des rappels", action: nil, keyEquivalent: "")
        calendarItem.submenu = calendarMenu()
        menu.addItem(calendarItem)
        addGoogleItems(to: menu)
        let permissions = NSMenuItem(title: "Autorisations…", action: nil, keyEquivalent: "")
        permissions.submenu = permissionsMenu()
        menu.addItem(permissions)
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

    /// Les outils de connecteurs autorisés « toujours ». Cliquer sur l'un d'eux le retire.
    private func permissionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let always = controller.settings.connectorAlways
        if always.isEmpty {
            let empty = NSMenuItem(title: "Aucune autorisation permanente", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Clique pour retirer :", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            for name in always {
                let (service, action) = ConnectorGate.parse(name)
                let entry = item("✓ \(service) · \(action.replacingOccurrences(of: "_", with: " "))", #selector(revokeConnector(_:)))
                entry.representedObject = name
                menu.addItem(entry)
            }
        }
        return menu
    }

    @objc private func revokeConnector(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { controller.revokeConnector(name) }
    }

    /// Google (Carnet + Tasks) : l'état de la connexion, en clair.
    private func addGoogleItems(to menu: NSMenu) {
        let auth = controller.googleAuth
        let status: NSMenuItem
        if controller.isConnectingGoogle {
            status = NSMenuItem(title: "Google : connexion en cours (regarde ton navigateur)…", action: nil, keyEquivalent: "")
            status.isEnabled = false
        } else if auth.isConnected {
            status = NSMenuItem(title: "Google : connecté ✓", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(item("Déconnecter Google", #selector(disconnectGoogle)))
            status.submenu = sub
        } else {
            do {
                _ = try GoogleAuth.loadClient()
                status = item("Connecter Google…", #selector(connectGoogle))
            } catch let error as GoogleAuth.AuthError {
                // Fichier client absent ou illisible : on le dit clairement, sans bouton qui ne mènerait à rien.
                if case .noClientFile = error {
                    status = NSMenuItem(title: "Google : fichier google-oauth-client.json manquant", action: nil, keyEquivalent: "")
                } else {
                    status = NSMenuItem(title: "Google : fichier google-oauth-client.json illisible", action: nil, keyEquivalent: "")
                }
                status.isEnabled = false
                menu.addItem(status)
                menu.addItem(item("   Ouvrir le dossier de Capri…", #selector(openSupportFolder)))
                return
            } catch {
                return
            }
        }
        menu.addItem(status)
    }

    /// Les agendas où Capri peut écrire ; celui des rappels est coché.
    private func calendarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let service = controller.calendar
        guard service.hasAccess else {
            menu.addItem(item("Autoriser l'accès à l'agenda…", #selector(requestCalendarAccess)))
            return menu
        }
        let current = service.reminderCalendar?.calendarIdentifier
        // Regroupés par compte (Google, iCloud, Sur mon Mac…).
        let bySource = Dictionary(grouping: service.writableCalendars) { $0.source.title }
        for source in bySource.keys.sorted() {
            let header = NSMenuItem(title: source, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for calendar in bySource[source]!.sorted(by: { $0.title < $1.title }) {
                let entry = item("   " + calendar.title, #selector(chooseCalendar(_:)))
                entry.representedObject = calendar.calendarIdentifier
                entry.state = calendar.calendarIdentifier == current ? .on : .off
                menu.addItem(entry)
            }
        }
        if service.googleCalendars.isEmpty {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Aucun agenda Google : Réglages Système → Comptes Internet", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleChat() { controller.toggleChat() }
    @objc private func openBrowser() { controller.browser.show() }
    @objc private func connectGoogle() { controller.connectGoogle() }
    @objc private func disconnectGoogle() { controller.disconnectGoogle() }
    @objc private func openSupportFolder() { NSWorkspace.shared.open(CapriSettings.supportDirectory) }
    @objc private func requestCalendarAccess() { controller.requestCalendarAccess() }

    @objc private func chooseCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let calendar = controller.calendar.store.calendar(withIdentifier: id) else { return }
        controller.calendar.chooseCalendar(calendar)
    }
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
