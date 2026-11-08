import AppKit
import EventKit

/// Accès à l'agenda du Mac via EventKit.
///
/// Si ton compte Google est ajouté dans Réglages Système → Comptes Internet (case « Calendriers »),
/// ses agendas apparaissent ici et se synchronisent dans les deux sens : un rappel créé par Capri
/// arrive dans Google Agenda, donc aussi sur ton téléphone. Pas besoin d'API Google ni de connexion.
@MainActor
final class CalendarService {
    let store = EKEventStore()
    var settings: () -> CapriSettings
    var saveCalendarID: (String) -> Void = { _ in }

    /// Les événements créés par Capri (elle seule a le droit de les supprimer).
    private(set) var createdIDs: Set<String>
    private static var createdFile: URL { CapriSettings.supportDirectory.appendingPathComponent("created-events.json") }

    init(settings: @escaping () -> CapriSettings) {
        self.settings = settings
        let data = try? Data(contentsOf: Self.createdFile)
        createdIDs = Set((data.flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [])
    }

    private func saveCreated() {
        if let data = try? JSONEncoder().encode(Array(createdIDs)) { try? data.write(to: Self.createdFile) }
    }

    // MARK: - Autorisation

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Demande l'accès complet à l'agenda (macOS affiche sa fenêtre la première fois seulement).
    func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            log.notice("Accès à l'agenda : \(granted ? "accordé" : "refusé", privacy: .public)")
            return granted
        default:
            return false
        }
    }

    static let noAccessMessage = "accès à l'agenda refusé. Daniil peut l'autoriser dans Réglages Système → Confidentialité et sécurité → Calendriers → Capri."

    // MARK: - Agendas

    /// Les agendas d'un compte Google (le nom du compte contient « google » ou une adresse gmail).
    var googleCalendars: [EKCalendar] {
        store.calendars(for: .event).filter {
            let source = $0.source.title.lowercased()
            return source.contains("google") || source.contains("gmail")
        }
    }

    var writableCalendars: [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
    }

    /// L'agenda des rappels : celui choisi dans le menu, sinon l'agenda principal Google
    /// (celui qui porte le nom du compte), sinon l'agenda par défaut du Mac.
    var reminderCalendar: EKCalendar? {
        if let id = settings().reminderCalendarID, let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        let google = googleCalendars.filter(\.allowsContentModifications)
        if let main = google.first(where: { $0.title == $0.source.title }) ?? google.first { return main }
        return store.defaultCalendarForNewEvents
    }

    func chooseCalendar(_ calendar: EKCalendar) {
        saveCalendarID(calendar.calendarIdentifier)
    }

    // MARK: - Lecture et écriture

    func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func createReminder(title: String, start: Date, minutes: Int, notes: String?) throws -> EKEvent {
        guard let calendar = reminderCalendar else { throw CalendarError("aucun agenda disponible pour créer un rappel.") }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(max(minutes, 1) * 60))
        event.notes = notes
        event.addAlarm(EKAlarm(relativeOffset: 0))   // une alerte à l'heure pile : le téléphone sonne aussi
        try store.save(event, span: .thisEvent, commit: true)
        if let id = event.eventIdentifier {
            createdIDs.insert(id)
            saveCreated()
        }
        return event
    }

    func deleteReminder(id: String) throws -> String {
        guard createdIDs.contains(id) else { throw CalendarError("cet événement n'a pas été créé par Capri : elle n'a pas le droit de le supprimer.") }
        guard let event = store.event(withIdentifier: id) else {
            createdIDs.remove(id); saveCreated()
            throw CalendarError("cet événement n'existe plus.")
        }
        let title = event.title ?? "?"
        try store.remove(event, span: .thisEvent, commit: true)
        createdIDs.remove(id)
        saveCreated()
        return title
    }

    func isCreatedByCapri(_ event: EKEvent) -> Bool {
        event.eventIdentifier.map(createdIDs.contains) ?? false
    }

    struct CalendarError: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: - Format des dates

    nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        // Sans fuseau horaire : on prend l'heure locale.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    /// « dimanche 8 novembre à 14 h 30 »
    nonisolated static func french(_ date: Date, withDay: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = withDay ? "EEEE d MMMM 'à' H 'h' mm" : "H 'h' mm"
        return formatter.string(from: date)
    }

    nonisolated static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// Pouvoirs « agenda ».
@MainActor
enum CalendarTools {
    static func all(calendar: CalendarService, onChange: @escaping () -> Void) -> [Tool] {
        [
            Tool(name: "create_reminder",
                 description: "Crée un rappel dans l'agenda de Daniil (son Google Agenda si disponible) : un événement avec une alerte à l'heure de début, qui fait aussi sonner son téléphone. L'heure doit être exacte, en ISO 8601 avec fuseau horaire (ex. 2026-11-08T14:30:00+01:00). Renvoie l'identifiant de l'événement.",
                 schema: parameters(("title", "string", "Titre du rappel", true),
                                    ("start", "string", "Date et heure, ISO 8601 avec fuseau", true),
                                    ("notes", "string", "Notes (facultatif)", false),
                                    ("duration_minutes", "integer", "Durée en minutes (15 par défaut)", false)),
                 risk: .action,
                 startLine: { "📅 Je note « \($0.string("title") ?? "?") »…" },
                 run: { args in
                     guard await calendar.ensureAccess() else { return .failure(CalendarService.noAccessMessage, line: "📅 Accès à l'agenda refusé") }
                     guard let title = args.string("title"), let startText = args.string("start"),
                           let start = CalendarService.parseDate(startText) else {
                         return .failure("titre ou date invalide (attendu : ISO 8601, ex. 2026-11-08T14:30:00+01:00).", line: "📅 Date invalide")
                     }
                     do {
                         let event = try calendar.createReminder(title: title, start: start,
                                                                 minutes: args.int("duration_minutes") ?? 15, notes: args.string("notes"))
                         onChange()
                         let id = event.eventIdentifier ?? ""
                         let when = CalendarService.french(start)
                         var result = ToolResult(
                             text: "Rappel créé dans l'agenda « \(event.calendar.title) » (\(event.calendar.source.title)) : « \(title) », \(when) (\(CalendarService.iso(start))). Identifiant : \(id)",
                             line: "📅 Rappel créé : \(title) — \(when)")
                         result.buttons = [ChatButton(title: "Annuler") {
                             _ = try? calendar.deleteReminder(id: id)
                             onChange()
                         }]
                         return result
                     } catch let error as CalendarService.CalendarError {
                         return .failure(error.message, line: "📅 Rappel non créé")
                     } catch {
                         return .failure(error.localizedDescription, line: "📅 Rappel non créé")
                     }
                 }),

            Tool(name: "list_events",
                 description: "Liste les événements de l'agenda de Daniil entre deux dates (ISO 8601), tous agendas confondus.",
                 schema: parameters(("from", "string", "Début, ISO 8601", true),
                                    ("to", "string", "Fin, ISO 8601", true)),
                 risk: .read,
                 startLine: { _ in "📅 Je regarde ton agenda…" },
                 run: { args in
                     guard await calendar.ensureAccess() else { return .failure(CalendarService.noAccessMessage, line: "📅 Accès à l'agenda refusé") }
                     guard let from = args.string("from").flatMap(CalendarService.parseDate),
                           let to = args.string("to").flatMap(CalendarService.parseDate), to > from else {
                         return .failure("dates invalides (ISO 8601 attendu).", line: "📅 Dates invalides")
                     }
                     let events = calendar.events(from: from, to: to)
                     let lines = events.prefix(60).map { event -> String in
                         let when = event.isAllDay ? "toute la journée" : "\(CalendarService.french(event.startDate)) → \(CalendarService.french(event.endDate, withDay: false))"
                         var line = "- \(event.title ?? "(sans titre)") : \(when) [agenda : \(event.calendar.title)]"
                         if let place = event.location, !place.isEmpty { line += " — lieu : \(place)" }
                         if calendar.isCreatedByCapri(event), let id = event.eventIdentifier { line += " — créé par Capri, id : \(id)" }
                         return line
                     }
                     let googleNote = calendar.googleCalendars.isEmpty ? "\n(Note : aucun agenda Google n'est visible sur ce Mac.)" : ""
                     return ToolResult(text: (events.isEmpty ? "Aucun événement." : lines.joined(separator: "\n")) + googleNote,
                                       line: "📅 \(events.count) événement\(events.count > 1 ? "s" : "")")
                 }),

            Tool(name: "delete_reminder",
                 description: "Supprime un rappel créé par Capri (et seulement ceux-là), à partir de son identifiant.",
                 schema: parameters(("id", "string", "Identifiant renvoyé par create_reminder", true)),
                 risk: .action,
                 startLine: { _ in "🗑️ J'efface un rappel…" },
                 run: { args in
                     guard await calendar.ensureAccess() else { return .failure(CalendarService.noAccessMessage, line: "📅 Accès à l'agenda refusé") }
                     do {
                         let title = try calendar.deleteReminder(id: args.string("id") ?? "")
                         onChange()
                         return ToolResult(text: "Rappel supprimé : « \(title) ».", line: "🗑️ Rappel supprimé : \(title)")
                     } catch let error as CalendarService.CalendarError {
                         return .failure(error.message, line: "🗑️ Suppression refusée")
                     } catch {
                         return .failure(error.localizedDescription, line: "🗑️ Suppression impossible")
                     }
                 }),
        ]
    }
}
