import Foundation

/// La personnalité de Capri vient du fichier Persona/capri.md du projet.
/// Il est relu à CHAQUE message : modifie-le, enregistre, et la réponse suivante en tient compte.
enum Persona {
    /// Où trouver capri.md, dans l'ordre :
    /// 1. le dossier du projet inscrit dans Info.plist par Scripts/run.sh (cas de Capri.app) ;
    /// 2. le dossier du projet déduit de l'emplacement de ce fichier source (cas de `swift run` / Xcode) ;
    /// 3. la copie de secours rangée dans l'app.
    static var fileURL: URL? {
        var candidates: [URL] = []
        if let project = Bundle.main.object(forInfoDictionaryKey: "CapriProjectPath") as? String {
            candidates.append(URL(fileURLWithPath: project).appendingPathComponent("Persona/capri.md"))
        }
        // #filePath = le chemin de ce fichier au moment de la compilation : …/Sources/Capri/Chat/Persona.swift
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(projectRoot.appendingPathComponent("Persona/capri.md"))
        if let bundled = Bundle.main.url(forResource: "capri", withExtension: "md") {
            candidates.append(bundled)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Le texte complet envoyé comme « prompt système » : la personnalité + le contexte du moment.
    static func systemPrompt(now: Date = Date()) -> String {
        let persona = fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Tu es Capri, une IA enjouée et théâtrale. Commence chaque réponse par [humeur:calme]."
        return persona + "\n\n## Contexte\n" + context(now: now)
    }

    /// « Nous sommes le dimanche 8 novembre 2026, il est 9 h 12. »
    /// (L'étape 3, avec les rappels, s'appuiera dessus.)
    static func context(now: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_FR")
        day.dateFormat = "EEEE d MMMM yyyy"
        let hour = DateFormatter()
        hour.locale = Locale(identifier: "fr_FR")
        hour.dateFormat = "H 'h' mm"
        return "Nous sommes le \(day.string(from: now)), il est \(hour.string(from: now))."
    }
}
