import Foundation

/// Mode test caché, sans interface :
///
///     build/Capri.app/Contents/MacOS/Capri --selftest "Salut Capri" "Tu te souviens de ce que j'ai dit ?"
///
/// Si Capri.app tourne, la conversation passe PAR l'app (via la socket) : c'est donc l'app qui
/// utilise ses pouvoirs, avec ses autorisations macOS à elle. Sinon, on parle au cerveau
/// directement, sans pouvoirs. Affiche l'humeur, la réponse, les actions et les temps.
@MainActor
enum SelfTest {
    static func run(messages: [String]) {
        print("Persona : \(Persona.fileURL?.path ?? "introuvable")")
        // 1. Par l'app en cours d'exécution (avec les pouvoirs).
        Task.detached {
            let reached = ToolSocket.request(["op": "chat", "messages": messages]) { reply in
                print("\n» \(reply["message"] as? String ?? "")")
                print("[humeur : \(reply["mood"] as? String ?? "?")]")
                for line in reply["lines"] as? [String] ?? [] { print(line) }
                print(String(format: "(premiers mots : %.2f s, réponse complète : %.2f s)",
                             reply["firstWords"] as? Double ?? -1, reply["total"] as? Double ?? -1))
                return true
            }
            if reached { exit(0) }
            await MainActor.run { runWithoutApp(messages: messages) }
        }
    }

    /// 2. Capri.app n'est pas lancée : discussion seule, directement avec le cerveau.
    private static func runWithoutApp(messages: [String]) {
        print("(Capri.app ne tourne pas : test sans pouvoirs)")
        let settings = CapriSettings.load()
        let brain: ChatBrain
        if settings.brain == "ollama" {
            brain = OllamaBrain(settings: settings)
        } else {
            let claude = ClaudeBrain(settings: settings)
            claude.withPowers = false
            brain = claude
        }
        Task { @MainActor in
            for message in messages {
                print("\n» \(message)")
                let start = Date()
                var firstWords: TimeInterval?
                var parser = MoodParser()
                var mood = Mood.calme
                var text = ""
                do {
                    for try await event in brain.reply(to: message, systemPrompt: Persona.systemPrompt()) {
                        guard case .text(let chunk) = event else { continue }
                        let output = parser.feed(chunk)
                        if output.moodDecided { mood = output.mood }
                        if firstWords == nil && !output.text.isEmpty { firstWords = Date().timeIntervalSince(start) }
                        text += output.text
                    }
                    text += parser.finish().text
                    print("[humeur : \(mood.rawValue) → pose \(mood.pose.rawValue)]")
                    print(text)
                    print(String(format: "(premiers mots : %.2f s, réponse complète : %.2f s)",
                                 firstWords ?? -1, Date().timeIntervalSince(start)))
                } catch let error as BrainError {
                    print("ERREUR : \(error.capriMessage)\n  \(error.technicalDetail)")
                } catch {
                    print("ERREUR : \(error)")
                }
            }
            exit(0)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Mode caché pour vérifier l'apparence des bulles sans capture d'écran :
///
///     Capri --render-ui /un/dossier
///
/// Dessine la bulle de discussion (avec une fausse conversation) et une petite bulle en PNG.
@MainActor
enum UIRender {
    static func run(directory: String) {
        let model = ChatModel { ClaudeBrain(settings: CapriSettings()) }
        model.messages = [
            .init(role: .user, text: "Mets-moi un rappel dans 20 minutes pour sortir le linge"),
            .init(role: .action, text: "📅 Je note « Sortir le linge »…", isRunning: true),
            .init(role: .action, text: "📅 Rappel créé : Sortir le linge — dimanche 8 novembre à 11 h 05",
                  buttons: [ChatButton(title: "Annuler") {}]),
            .init(role: .capri, text: "C'est noté, Daniil ! À **11 h 05** je débarque en haut à gauche pour te le rappeler."),
            .init(role: .notice, text: "Capri veut lancer le Raccourci « Mode concentration ». D'accord ?",
                  buttons: [ChatButton(title: "Autoriser une fois", isPrimary: true) {}, ChatButton(title: "Toujours") {}, ChatButton(title: "Refuser") {}]),
            .init(role: .error, text: "Bzzt… mon cerveau ne répond plus.", detail: "Aucune réponse depuis 60 s."),
        ]
        let size = ChatWindowController.contentSize, m = ChatWindowController.margin, t = BubbleTail.length
        let above = BubbleLayout()
        above.tail = BubbleTail(edge: .bottom, position: 120)
        save(ChatView(model: model, layout: above, brainName: "Claude", onClose: {})
                .frame(width: size.width + 2 * m, height: size.height + t + 2 * m), to: directory, name: "chat-above.png")
        // ImageRenderer ne sait pas dessiner une ScrollView ni un champ de texte AppKit :
        // on dessine donc aussi l'historique seul, pour juger des messages.
        save(VStack(alignment: .leading, spacing: 10) {
                ForEach(model.messages) { MessageRow(message: $0) }
                TypingIndicator()
            }
            .padding(12).frame(width: size.width).background(Theme.background), to: directory, name: "chat-history.png")
        save(SpeechBubbleView(text: "Arrête, mon processeur va se renverser !"), to: directory, name: "speech.png")

        let side = BubbleLayout()
        side.tail = BubbleTail(edge: .left, position: 60)
        let item = EventNotification(key: "x", eventID: nil, title: "Point hebdo équipe", start: Date().addingTimeInterval(600),
                                     location: "https://meet.google.com/abc-defg-hij", notes: nil, isAllDay: false, isCapriReminder: false)
        save(NotificationBubbleView(text: LocalLines.notification(item), time: "à 11 h 15", buttons: [
                ChatButton(title: "OK", isPrimary: true) {}, ChatButton(title: "Dans 5 min") {}, ChatButton(title: "Ouvrir") {},
             ], layout: side), to: directory, name: "notification.png")

        renderBrowser(directory: directory)
    }

    /// Le navigateur : la barre d'outils est dessinée hors écran (fenêtre invisible),
    /// et la page avec l'instantané de WebKit (le web s'affiche dans un autre processus).
    private static func renderBrowser(directory: String) {
        let model = BrowserModel()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: BrowserView(model: model))
        window.contentView = host
        window.orderBack(nil)
        Task { @MainActor in
            if let url = model.url(for: "fr.wikipedia.org/wiki/Night_City") { await model.load(url) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("browser-chrome.png"))
            }
            if let image = try? await model.webView.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("browser-page.png"))
            }
            print("Images écrites dans \(directory) (page : \(model.title))")
            exit(0)
        }
    }

    private static func save(_ view: some View, to directory: String, name: String) {
        // Fond sombre derrière, comme un bureau, pour juger de la lisibilité.
        let renderer = ImageRenderer(content: view.background(Color(white: 0.25)))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
