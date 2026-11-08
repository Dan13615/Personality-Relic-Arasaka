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
