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

    // MARK: - Notifications d'agenda
    //
    // {titre} = titre de l'événement, {n} = minutes avant le début, {heure} = heure de début.

    /// L'événement commence dans quelques minutes.
    static let startsSoon = [
        "Psst, Daniil ! « {titre} » commence dans {n} minutes ({heure}).",
        "Alerte magnifique : « {titre} » dans {n} min, à {heure}. Tu ne diras pas que je ne t'ai pas prévenu.",
        "Dans {n} minutes : « {titre} » ({heure}). Je dis ça, je dis rien… si, je le dis.",
    ]
    /// L'événement commence maintenant.
    static let startsNow = [
        "C'est l'heure : « {titre} » !",
        "Top départ pour « {titre} » ! Allez, allez, allez !",
        "« {titre} », c'est maintenant, drôle de numéro.",
    ]
    /// Un rappel que Daniil a demandé à Capri.
    static let capriReminder = [
        "Tu m'as demandé de te le rappeler : {titre}. Voilà, magnifique assistante, comme toujours.",
        "Ding ding ! Ton rappel : {titre}. Okie-dokie, mission accomplie.",
        "Rappel livré en main propre : {titre}. De rien.",
    ]

    /// Le texte de la notification, rempli avec l'événement.
    static func notification(_ item: EventNotification, now: Date = Date()) -> String {
        let minutes = Int((item.start.timeIntervalSince(now) / 60).rounded())
        let templates: [String]
        if item.isCapriReminder { templates = capriReminder }
        else if minutes >= 1 { templates = startsSoon }
        else { templates = startsNow }
        let hour = item.isAllDay ? "toute la journée" : CalendarService.french(item.start, withDay: false)
        var text = (templates.randomElement() ?? "{titre}")
            .replacingOccurrences(of: "{titre}", with: item.title)
            .replacingOccurrences(of: "{n}", with: String(max(minutes, 1)))
            .replacingOccurrences(of: "{heure}", with: hour)
        if let place = item.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            text += "\n📍 \(place)"
        }
        if !item.isCapriReminder, let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            text += "\n📝 \(notes.prefix(160))\(notes.count > 160 ? "…" : "")"
        }
        return text
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
