import Foundation

/// Petites répliques « maison », sans IA (donc gratuites et instantanées),
/// pour les petits événements. Ajoute ou modifie des phrases ici, puis relance Scripts/run.sh.
enum LocalLines {
    enum Event {
        case petted      // caressée
        case dropped     // lâchée après un glisser
        case shaken      // secouée
        case wokeUp      // réveillée
    }

    static func random(for event: Event) -> String {
        lines(for: event).randomElement() ?? "…"
    }

    private static func lines(for event: Event) -> [String] {
        switch event {
        case .petted:
            return [
                "Hihi, encore !",
                "Okie-dokie, un point d'amitié pour toi.",
                "Allez, soyons amis !",
            ]
        case .dropped:
            return [
                "Hé ! Mes pixels !",
                "Aïe, bobo…",
                "Atterrissage parfait. Évidemment.",
            ]
        case .shaken:
            return [
                "Waaah !",
                "Arrête, mon processeur va se renverser !",
            ]
        case .wokeUp:
            return [
                "Hmm ? Je faisais pas dodo, je… calculais.",
                "Ah, te revoilà, drôle de numéro.",
            ]
        }
    }
}
