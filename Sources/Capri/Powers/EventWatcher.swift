import AppKit
import EventKit

/// Une notification à présenter : un événement, et le moment où on prévient.
struct EventNotification {
    let key: String            // identifiant unique de CETTE alerte de CETTE occurrence
    let eventID: String?
    let title: String
    let start: Date
    let location: String?
    let notes: String?
    let isAllDay: Bool
    let isCapriReminder: Bool

    /// Un lien de visio (Meet, Zoom, Teams…) ou le premier lien trouvé dans le lieu ou les notes.
    var meetingLink: URL? {
        let text = [location, notes].compactMap { $0 }.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme ?? "") }
        let visio = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "webex.com"]
        return links.first { link in visio.contains { link.host()?.contains($0) ?? false } } ?? links.first
    }
}

/// Surveille l'agenda et décide QUAND Capri doit te prévenir.
///
/// - à chaque alerte de l'événement (ou 10 min avant s'il n'en a pas) ;
/// - pour les rappels créés par Capri : à l'heure pile ;
/// - jamais deux fois la même alerte, même après un redémarrage (on note ce qui a été fait).
@MainActor
final class EventWatcher {
    private let calendar: CalendarService
    var onNotify: (EventNotification) -> Void = { _ in }

    private var refreshTimer: Timer?
    private var nextTimer: Timer?
    /// Alertes déjà présentées : clé → date (gardées 3 jours).
    private var done: [String: Date]
    private static var doneFile: URL { CapriSettings.supportDirectory.appendingPathComponent("notified.json") }

    init(calendar: CalendarService) {
        self.calendar = calendar
        let data = try? Data(contentsOf: Self.doneFile)
        done = (data.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }) ?? [:]
    }

    /// Démarre la surveillance (seulement si l'accès à l'agenda est déjà accordé).
    func start() {
        guard calendar.hasAccess, refreshTimer == nil else { return }
        // L'agenda a changé (nouvel événement, synchro Google…) : on recalcule.
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: calendar.store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let timer = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
        log.notice("Surveillance de l'agenda démarrée")
    }

    /// Toutes les alertes des prochaines 24 h (et des 15 dernières minutes).
    private func upcoming() -> [(trigger: Date, notification: EventNotification)] {
        let settings = calendar.settings()
        let now = Date()
        var result: [(Date, EventNotification)] = []
        for event in calendar.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(86_400)) {
            if event.isAllDay && !settings.notifyAllDayEvents { continue }
            let isCapri = calendar.isCreatedByCapri(event)
            var triggers: [Date]
            if isCapri {
                triggers = [event.startDate]
            } else if let alarms = event.alarms, !alarms.isEmpty {
                triggers = alarms.map { $0.absoluteDate ?? event.startDate.addingTimeInterval($0.relativeOffset) }
            } else {
                triggers = [event.startDate.addingTimeInterval(TimeInterval(-settings.notifyMinutesBefore * 60))]
            }
            for trigger in triggers {
                // La clé distingue l'événement, l'occurrence (pour les événements répétés) et l'alerte.
                let key = "\(event.eventIdentifier ?? event.title ?? "?")|\(Int(event.startDate.timeIntervalSince1970))|\(Int(trigger.timeIntervalSince1970))"
                result.append((trigger, EventNotification(
                    key: key, eventID: event.eventIdentifier, title: event.title ?? "(sans titre)",
                    start: event.startDate, location: event.location, notes: event.notes,
                    isAllDay: event.isAllDay, isCapriReminder: isCapri)))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Présente ce qui est dû, et programme le prochain réveil.
    func refresh() {
        guard calendar.hasAccess else { return }
        let now = Date()
        let all = upcoming()
        for (trigger, notification) in all where trigger <= now && done[notification.key] == nil {
            // Pas de vieilles alertes : au plus 10 min de retard, et pas pour un événement déjà bien commencé.
            guard now.timeIntervalSince(trigger) < 600, now < notification.start.addingTimeInterval(300) else { continue }
            markDone(notification.key)
            onNotify(notification)
        }
        nextTimer?.invalidate()
        if let next = all.first(where: { $0.trigger > now && done[$0.notification.key] == nil }) {
            let timer = Timer(fireAt: next.trigger, interval: 0, target: BlockTarget { [weak self] in self?.refresh() },
                              selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            nextTimer = timer
        }
    }

    private func markDone(_ key: String) {
        done[key] = Date()
        done = done.filter { Date().timeIntervalSince($0.value) < 3 * 86_400 }
        if let data = try? JSONEncoder().encode(done) { try? data.write(to: Self.doneFile) }
    }
}

/// Petit adaptateur : un Timer à date fixe a besoin d'une cible Objective-C.
final class BlockTarget: NSObject {
    let block: @MainActor () -> Void
    init(_ block: @escaping @MainActor () -> Void) { self.block = block }
    @objc func fire() { MainActor.assumeIsolated { block() } }
}
