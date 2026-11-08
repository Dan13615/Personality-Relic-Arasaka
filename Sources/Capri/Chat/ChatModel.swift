import Foundation

/// L'état de la discussion : les messages, le texte en cours de saisie, et l'envoi au cerveau.
/// `ObservableObject` : SwiftUI redessine la bulle dès qu'une propriété `@Published` change.
@MainActor
final class ChatModel: ObservableObject {
    struct Message: Identifiable {
        enum Role { case capri, user, error }
        let id = UUID()
        let role: Role
        var text: String
        var detail: String? = nil   // cause technique, pour les erreurs
    }

    @Published var messages: [Message] = []
    @Published var input = ""
    @Published private(set) var isAnswering = false
    /// Vrai entre l'envoi et l'arrivée des premiers mots (affiche « capri tape… »).
    @Published private(set) var isWaitingFirstWords = false
    /// Change à chaque ouverture de la bulle, pour redonner le focus au champ de texte.
    @Published var focusRequest = 0

    /// Le cerveau actif (Claude ou Ollama), fourni par le contrôleur.
    var brain: () -> ChatBrain

    // Pour animer Capri selon la conversation.
    var onThinking: () -> Void = {}
    var onMood: (Mood) -> Void = { _ in }
    var onReplyEnded: () -> Void = {}

    private var task: Task<Void, Never>?

    init(brain: @escaping () -> ChatBrain) {
        self.brain = brain
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        input = ""
        messages.append(Message(role: .user, text: text))
        messages.append(Message(role: .capri, text: ""))
        let index = messages.count - 1
        isAnswering = true
        isWaitingFirstWords = true
        onThinking()

        let stream = brain().reply(to: text, systemPrompt: Persona.systemPrompt())
        task = Task { @MainActor in
            var parser = MoodParser()
            do {
                for try await chunk in stream {
                    self.show(parser.feed(chunk), at: index)
                }
                self.show(parser.finish(), at: index)
            } catch let error as BrainError {
                self.fail(at: index, message: error.capriMessage, detail: error.technicalDetail)
            } catch {
                self.fail(at: index, message: "Aïe, un bobo inconnu.", detail: error.localizedDescription)
            }
            // Arrêtée avant le moindre mot : on retire la bulle vide.
            if self.messages.indices.contains(index), self.messages[index].role == .capri, self.messages[index].text.isEmpty {
                self.messages.remove(at: index)
            }
            self.isAnswering = false
            self.isWaitingFirstWords = false
            self.onReplyEnded()
        }
    }

    private func show(_ output: MoodParser.Output, at index: Int) {
        if output.moodDecided {
            isWaitingFirstWords = false
            onMood(output.mood)
        }
        if !output.text.isEmpty, messages.indices.contains(index) {
            isWaitingFirstWords = false
            messages[index].text += output.text
        }
    }

    private func fail(at index: Int, message: String, detail: String) {
        if messages.indices.contains(index), messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        messages.append(Message(role: .error, text: message, detail: detail))
        onMood(.confuse)
    }

    /// Bouton stop.
    func stop() {
        task?.cancel()
    }

    /// « Nouvelle conversation » : on vide l'écran et le cerveau oublie tout.
    func newConversation() {
        stop()
        messages = []
        brain().reset()
    }
}
