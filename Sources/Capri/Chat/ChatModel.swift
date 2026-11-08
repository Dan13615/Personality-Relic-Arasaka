import Foundation

/// L'état de la discussion : les messages, le texte en cours de saisie, et l'envoi au cerveau.
/// `ObservableObject` : SwiftUI redessine la bulle dès qu'une propriété `@Published` change.
///
/// C'est aussi lui qui affiche l'activité des outils (ToolObserver) : une petite ligne par action,
/// et les questions de confirmation avec leurs boutons.
@MainActor
final class ChatModel: ObservableObject, ToolObserver {
    struct Message: Identifiable {
        enum Role {
            case capri      // réponse de Capri
            case user       // message de Daniil
            case error      // erreur (cerveau injoignable…)
            case action     // une action en cours ou faite (« 🚀 Spotify lancée »)
            case notice     // une question ou une notification, avec des boutons
        }
        let id = UUID()
        let role: Role
        var text: String
        var detail: String? = nil      // cause technique, pour les erreurs
        var buttons: [ChatButton] = []
        var isRunning = false          // action en cours (petite roue qui tourne)
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
    /// Le registre des outils : on s'y inscrit comme « observateur » pendant qu'on répond.
    weak var registry: ToolRegistry?

    // Pour animer Capri selon la conversation.
    var onThinking: () -> Void = {}
    var onMood: (Mood) -> Void = { _ in }
    var onReplyEnded: () -> Void = {}

    /// La réponse en cours (on peut l'attendre, par exemple dans le mode --selftest).
    private(set) var task: Task<Void, Never>?

    // État de la réponse en cours
    private var parser = MoodParser()
    private var currentCapriID: UUID?      // le message de Capri qui reçoit le texte
    private var lastMood: Mood?
    private var toolMessages: [UUID: UUID] = [:]   // appel d'outil → ligne affichée
    private var pendingChoices: [UUID: CheckedContinuation<String?, Never>] = [:]   // question → réponse attendue

    init(brain: @escaping () -> ChatBrain) {
        self.brain = brain
    }

    // MARK: - Envoi

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        input = ""
        messages.append(Message(role: .user, text: text))
        isAnswering = true
        isWaitingFirstWords = true
        parser = MoodParser()
        currentCapriID = nil
        lastMood = nil
        registry?.observer = self
        onThinking()

        let stream = brain().reply(to: text, systemPrompt: Persona.systemPrompt())
        task = Task { @MainActor in
            do {
                for try await event in stream {
                    self.handle(event)
                }
                self.show(self.parser.finish())
            } catch let error as BrainError {
                self.fail(message: error.capriMessage, detail: error.technicalDetail)
            } catch {
                self.fail(message: "Aïe, un bobo inconnu.", detail: error.localizedDescription)
            }
            // Bulles vides (réponse arrêtée avant le moindre mot) : on les retire.
            self.messages.removeAll { $0.role == .capri && $0.text.isEmpty }
            self.isAnswering = false
            self.isWaitingFirstWords = false
            self.onReplyEnded()
        }
    }

    private func handle(_ event: BrainEvent) {
        switch event {
        case .newMessage:
            // Un nouveau message (après un outil) : nouvelle bulle, et il peut avoir sa propre humeur.
            show(parser.finish())
            parser = MoodParser()
            currentCapriID = nil
        case .webTool(let name):
            currentCapriID = nil
            let line = name == "WebFetch" ? "🌐 Je lis une page web…" : "🌐 Je cherche sur le web…"
            messages.append(Message(role: .action, text: line))
            isWaitingFirstWords = false
            onThinking()
        case .text(let chunk):
            show(parser.feed(chunk))
        }
    }

    private func show(_ output: MoodParser.Output) {
        if output.moodDecided {
            isWaitingFirstWords = false
            // Nouvelle humeur annoncée, ou on reprend la dernière après un outil (pose hacking entre-temps).
            if output.tagFound || lastMood == nil { lastMood = output.mood }
            if let mood = lastMood { onMood(mood) }
        }
        guard !output.text.isEmpty else { return }
        isWaitingFirstWords = false
        if let id = currentCapriID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += output.text
        } else {
            let message = Message(role: .capri, text: output.text)
            currentCapriID = message.id
            messages.append(message)
        }
    }

    private func fail(message: String, detail: String) {
        messages.append(Message(role: .error, text: message, detail: detail))
        onMood(.confuse)
    }

    /// Bouton stop.
    func stop() {
        task?.cancel()
        // Une question en attente n'aura plus de réponse : on la libère.
        let waiting = pendingChoices
        pendingChoices = [:]
        waiting.values.forEach { $0.resume(returning: nil) }
    }

    /// « Nouvelle conversation » : on vide l'écran et le cerveau oublie tout.
    func newConversation() {
        stop()
        messages = []
        brain().reset()
    }

    /// Ajoute une notification (agenda) directement dans la discussion.
    func appendNotice(_ text: String, buttons: [ChatButton]) {
        let message = Message(role: .notice, text: text)
        let id = message.id
        messages.append(message)
        setButtons(buttons, on: id, suffix: nil)
    }

    // MARK: - Boutons

    /// Pose des boutons sur un message. Un clic exécute l'action puis retire les boutons.
    private func setButtons(_ buttons: [ChatButton], on id: UUID, suffix: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].buttons = buttons.map { button in
            ChatButton(title: button.title, isPrimary: button.isPrimary) { [weak self] in
                button.action()
                guard let self, let i = self.messages.firstIndex(where: { $0.id == id }) else { return }
                self.messages[i].buttons = []
                if let suffix { self.messages[i].text += suffix }
            }
        }
    }

    // MARK: - ToolObserver

    func toolStarted(id: UUID, line: String) {
        currentCapriID = nil       // le texte suivant ira dans une nouvelle bulle, sous l'action
        isWaitingFirstWords = false
        let message = Message(role: .action, text: line, isRunning: true)
        toolMessages[id] = message.id
        messages.append(message)
        onThinking()               // pose hacking pendant que l'outil travaille
    }

    func toolFinished(id: UUID, result: ToolResult) {
        guard let messageID = toolMessages.removeValue(forKey: id),
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].text = result.line
        messages[index].isRunning = false
        if !result.buttons.isEmpty { setButtons(result.buttons, on: messageID, suffix: " — annulé") }
    }

    func askChoice(_ question: String, choices: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let message = Message(role: .notice, text: question)
            pendingChoices[message.id] = continuation
            messages.append(message)
            let buttons = choices.enumerated().map { index, choice in
                ChatButton(title: choice, isPrimary: index == 0) { [weak self] in
                    self?.pendingChoices.removeValue(forKey: message.id)?.resume(returning: choice)
                }
            }
            setButtons(buttons, on: message.id, suffix: nil)
        }
    }
}
