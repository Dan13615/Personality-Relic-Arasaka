import Foundation

/// Un « cerveau » : quelque chose qui sait répondre à un message, morceau par morceau.
///
/// Grâce à ce protocole, le reste de l'app ne sait pas (et n'a pas besoin de savoir)
/// si la réponse vient de Claude ou d'Ollama : on peut changer de cerveau sans rien toucher d'autre.
@MainActor
protocol ChatBrain: AnyObject {
    /// Nom affiché dans le menu.
    var displayName: String { get }

    /// Envoie un message et renvoie la réponse sous forme de flux de morceaux de texte.
    /// Le cerveau garde lui-même le fil de la conversation.
    /// Arrêter de lire le flux (bouton stop) interrompt la réponse.
    func reply(to message: String, systemPrompt: String) -> AsyncThrowingStream<String, Error>

    /// Oublie la conversation (« Nouvelle conversation »).
    func reset()
}

/// Les erreurs possibles, avec un message pour Daniil (dans la voix de Capri) et la cause technique.
enum BrainError: LocalizedError {
    case claudeNotFound
    case notLoggedIn(String)
    case timeout(Double)
    case cliFailed(String)
    case ollamaUnavailable(String)

    /// La phrase de Capri.
    var capriMessage: String {
        switch self {
        case .claudeNotFound:
            return "Euh… je ne trouve pas mon cerveau. Le programme « claude » a dit bye-bye ?"
        case .notLoggedIn:
            return "Mon cerveau refuse de me parler : il faut te reconnecter à Claude, mon pote."
        case .timeout:
            return "Bzzt… mon cerveau ne répond plus. Il a fait dodo sans prévenir ?"
        case .cliFailed:
            return "Aïe, un bobo dans mon cerveau. Réessaie dans un instant ?"
        case .ollamaUnavailable:
            return "Mon cerveau local, Ollama, ne répond pas. Il est bien lancé ?"
        }
    }

    /// La cause technique, affichée en petit sous la phrase.
    var technicalDetail: String {
        switch self {
        case .claudeNotFound:
            return "Programme `claude` introuvable. Installe Claude Code, ou indique son chemin dans « claudePath » de settings.json."
        case .notLoggedIn(let detail):
            return "Claude Code n'est pas connecté. Lance `claude` dans le Terminal puis /login. (\(detail))"
        case .timeout(let seconds):
            return "Aucune réponse depuis \(Int(seconds)) s."
        case .cliFailed(let detail):
            return detail
        case .ollamaUnavailable(let detail):
            return detail
        }
    }

    var errorDescription: String? { "\(capriMessage) — \(technicalDetail)" }
}
