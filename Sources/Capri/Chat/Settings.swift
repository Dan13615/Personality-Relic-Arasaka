import Foundation

/// Les réglages de Capri, dans ~/Library/Application Support/Capri/settings.json.
/// Tu peux modifier ce fichier à la main (puis relancer Capri) : par exemple changer de modèle.
struct CapriSettings: Codable {
    /// "claude" ou "ollama"
    var brain: String = "claude"
    /// Alias de modèle pour Claude Code : "sonnet" (par défaut, le plus rapide à répondre) ou "haiku", "opus"…
    var claudeModel: String = "sonnet"
    /// Chemin du programme `claude`, si on ne le trouve pas tout seul.
    var claudePath: String?
    /// Modèle Ollama (voir `ollama list`).
    var ollamaModel: String = "llama3.2"
    /// Délai max sans aucune sortie du cerveau, en secondes.
    var timeoutSeconds: Double = 60

    // MARK: Pouvoirs (étape 3)
    /// Dossiers que Capri peut fouiller et lire (jamais modifier).
    var allowedFolders: [String] = ["~/Desktop", "~/Documents", "~/Downloads"]
    /// Décisions pour les Raccourcis : nom → "always" ou "never".
    var shortcutDecisions: [String: String] = [:]
    /// Moteur de recherche du navigateur de Capri ({q} = la recherche).
    var searchURL: String = "https://duckduckgo.com/?q={q}"
    /// Identifiant de l'agenda où créer les rappels (`nil` = choix automatique : Google, sinon l'agenda par défaut).
    var reminderCalendarID: String?
    /// Prévenir combien de minutes avant un événement qui n'a pas d'alerte.
    var notifyMinutesBefore: Int = 10
    /// Prévenir aussi pour les événements « toute la journée ».
    var notifyAllDayEvents: Bool = false
    /// Son joué avec une notification (nom d'un son système, ex. "Glass", "Tink" ; "" = aucun).
    var notificationSound: String = "Glass"
    /// Identifiant du Google Doc « Carnet de Capri » (créé à la première note).
    var notesDocumentID: String?
    /// Outils de connecteurs autorisés « toujours » (révocables dans le menu « Autorisations… »).
    var connectorAlways: [String] = []

    // Lecture tolérante : un réglage absent du fichier garde sa valeur par défaut.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CapriSettings()
        brain = try c.decodeIfPresent(String.self, forKey: .brain) ?? d.brain
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        allowedFolders = try c.decodeIfPresent([String].self, forKey: .allowedFolders) ?? d.allowedFolders
        shortcutDecisions = try c.decodeIfPresent([String: String].self, forKey: .shortcutDecisions) ?? d.shortcutDecisions
        searchURL = try c.decodeIfPresent(String.self, forKey: .searchURL) ?? d.searchURL
        reminderCalendarID = try c.decodeIfPresent(String.self, forKey: .reminderCalendarID)
        notifyMinutesBefore = try c.decodeIfPresent(Int.self, forKey: .notifyMinutesBefore) ?? d.notifyMinutesBefore
        notifyAllDayEvents = try c.decodeIfPresent(Bool.self, forKey: .notifyAllDayEvents) ?? d.notifyAllDayEvents
        notificationSound = try c.decodeIfPresent(String.self, forKey: .notificationSound) ?? d.notificationSound
        notesDocumentID = try c.decodeIfPresent(String.self, forKey: .notesDocumentID)
        connectorAlways = try c.decodeIfPresent([String].self, forKey: .connectorAlways) ?? d.connectorAlways
    }

    // MARK: Fichiers

    /// ~/Library/Application Support/Capri
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Capri", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { supportDirectory.appendingPathComponent("settings.json") }

    /// Lit les réglages, et crée le fichier avec les valeurs par défaut s'il n'existe pas encore.
    static func load() -> CapriSettings {
        if let data = try? Data(contentsOf: fileURL),
           let settings = try? JSONDecoder().decode(CapriSettings.self, from: data) {
            settings.save()   // ajoute au fichier les nouveaux réglages, avec leur valeur par défaut
            return settings
        }
        let settings = CapriSettings()
        settings.save()
        return settings
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL)
        }
    }
}
