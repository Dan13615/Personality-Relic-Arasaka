import Foundation

/// L'humeur annoncée par Capri au début de chaque réponse, par exemple `[humeur:joyeuse]`.
/// Chaque humeur correspond à une pose.
enum Mood: String, CaseIterable {
    case joyeuse, curieuse, taquine, amoureuse, confuse, agacee, endormie, concentree, fiere, fete, calme

    var pose: Pose {
        switch self {
        case .joyeuse: return .juggle
        case .curieuse: return .sitCurious
        case .taquine: return .sitSwing
        case .amoureuse: return .love
        case .confuse: return .confused
        case .agacee: return .struggle
        case .endormie: return .sleepy
        case .concentree: return .hacking
        case .fiere: return .lounge
        case .fete: return .handstand
        case .calme: return .float
        }
    }

    /// Lecture tolérante : « Humeur : Fière », « fiere », « FÊTE »… marchent tous.
    /// Une humeur inconnue donne `nil` (la pose sera alors `float`).
    init?(tag: String) {
        let cleaned = tag
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .replacingOccurrences(of: "humeur", with: "")
            .filter { $0.isLetter }
        self.init(rawValue: cleaned)
    }
}

/// Repère la balise d'humeur au début d'une réponse qui arrive morceau par morceau,
/// et la retire du texte affiché.
///
/// Pourquoi « au fil de l'eau » ? Le texte arrive en petits morceaux, et la balise peut être
/// coupée en deux (« [hum » puis « eur:joyeuse] »). On garde donc le début en attente
/// jusqu'à être sûr de ce qu'il contient.
struct MoodParser {
    /// Ce que renvoie le parseur pour chaque morceau.
    struct Output {
        var text: String = ""          // texte à afficher
        var moodDecided = false        // vrai une seule fois : quand on sait enfin quelle humeur afficher
        var mood: Mood = .calme        // l'humeur (calme par défaut si la balise manque ou est inconnue)
        var tagFound = false           // une vraie balise reconnue (et pas l'humeur par défaut)
    }

    private var buffer = ""
    private(set) var isResolved = false

    mutating func feed(_ chunk: String) -> Output {
        guard !isResolved else { return Output(text: chunk) }
        buffer += chunk
        let start = buffer.drop { $0.isWhitespace }

        if start.isEmpty { return Output() }
        guard start.first == "[" else {
            // Pas de balise du tout : on affiche tout, humeur par défaut.
            return resolve(mood: nil, text: String(start))
        }
        if let close = start.firstIndex(of: "]") {
            let tag = start[start.index(after: start.startIndex)..<close]
            let rest = start[start.index(after: close)...].drop { $0.isWhitespace }
            return resolve(mood: Mood(tag: String(tag)), text: String(rest))
        }
        if start.count > 40 {
            // Un « [ » sans fin raisonnable : ce n'était pas une balise.
            return resolve(mood: nil, text: String(start))
        }
        return Output()   // on attend la suite
    }

    /// À la fin de la réponse : rend ce qui serait resté en attente.
    mutating func finish() -> Output {
        guard !isResolved else { return Output() }
        return resolve(mood: nil, text: buffer.trimmingCharacters(in: .whitespaces))
    }

    private mutating func resolve(mood: Mood?, text: String) -> Output {
        isResolved = true
        buffer = ""
        return Output(text: text, moodDecided: true, mood: mood ?? .calme, tagFound: mood != nil)
    }
}
