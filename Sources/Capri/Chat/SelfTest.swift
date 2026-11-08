import Foundation

/// Mode test caché, sans interface :
///
///     build/Capri.app/Contents/MacOS/Capri --selftest "Salut Capri" "Tu te souviens de ce que j'ai dit ?"
///
/// Envoie chaque message au cerveau actif, dans la même conversation, et affiche
/// l'humeur, la réponse et les temps (premiers mots, réponse complète).
@MainActor
enum SelfTest {
    static func run(messages: [String]) {
        let settings = CapriSettings.load()
        let brain: ChatBrain = settings.brain == "ollama" ? OllamaBrain(settings: settings) : ClaudeBrain(settings: settings)
        print("Cerveau : \(brain.displayName)\(settings.brain == "claude" ? " (\(settings.claudeModel))" : " (\(settings.ollamaModel))")")
        print("Persona : \(Persona.fileURL?.path ?? "introuvable")")

        Task { @MainActor in
            for message in messages {
                print("\n» \(message)")
                let start = Date()
                var firstWords: TimeInterval?
                var parser = MoodParser()
                var mood = Mood.calme
                var text = ""
                do {
                    for try await chunk in brain.reply(to: message, systemPrompt: Persona.systemPrompt()) {
                        let output = parser.feed(chunk)
                        if output.moodDecided { mood = output.mood }
                        if firstWords == nil && !output.text.isEmpty { firstWords = Date().timeIntervalSince(start) }
                        text += output.text
                    }
                    let rest = parser.finish()
                    if rest.moodDecided { mood = rest.mood }
                    text += rest.text
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
            .init(role: .user, text: "Salut Capri"),
            .init(role: .capri, text: "Daniiil ! Mon processeur rose et spongieux préféré est de retour. Okie-dokie, on fait quoi aujourd'hui ?"),
            .init(role: .user, text: "Tu peux ouvrir Spotify ?"),
            .init(role: .capri, text: "Pas encore, drôle de numéro ! Ce pouvoir-là arrive bientôt, promis."),
            .init(role: .error, text: "Bzzt… mon cerveau ne répond plus. Il a fait dodo sans prévenir ?", detail: "Aucune réponse depuis 60 s."),
        ]
        model.input = "Explique-moi les closures"

        let size = ChatWindowController.contentSize, m = ChatWindowController.margin, t = BubbleTail.length
        let above = BubbleLayout()
        above.tail = BubbleTail(edge: .bottom, position: 120)
        let beside = BubbleLayout()
        beside.tail = BubbleTail(edge: .left, position: 300)

        save(ChatView(model: model, layout: above, brainName: "Claude", onClose: {})
                .frame(width: size.width + 2 * m, height: size.height + t + 2 * m), to: directory, name: "chat-above.png")
        save(ChatView(model: model, layout: beside, brainName: "Claude", onClose: {})
                .frame(width: size.width + t + 2 * m, height: size.height + 2 * m), to: directory, name: "chat-beside.png")
        // ImageRenderer ne sait pas dessiner une ScrollView ni un champ de texte AppKit :
        // on dessine donc aussi l'historique seul, pour juger des messages.
        save(VStack(alignment: .leading, spacing: 10) {
                ForEach(model.messages) { MessageRow(message: $0) }
                TypingIndicator()
            }
            .padding(12).frame(width: size.width).background(Theme.background), to: directory, name: "chat-history.png")
        save(SpeechBubbleView(text: "Arrête, mon processeur va se renverser !"), to: directory, name: "speech.png")
        print("Images écrites dans \(directory)")
        exit(0)
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
