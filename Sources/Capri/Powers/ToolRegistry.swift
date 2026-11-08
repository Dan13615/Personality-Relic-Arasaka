import Foundation

/// Un bouton dans la bulle (« Annuler », « Autoriser une fois »…).
struct ChatButton: Identifiable {
    let id = UUID()
    let title: String
    var isPrimary = false
    let action: @MainActor () -> Void
}

/// Le niveau de risque d'un outil.
enum ToolRisk: String {
    case read        // lit seulement (fichiers, agenda, page web)
    case action      // agit, mais sans danger (ouvrir une app, créer un rappel)
    case sensitive   // peut tout faire (Raccourcis) : demande une confirmation
}

/// Ce que renvoie un outil.
struct ToolResult {
    /// Le texte renvoyé au cerveau (il s'en sert pour répondre).
    var text: String
    /// La ligne affichée dans la bulle, par exemple « 🚀 Spotify lancé ».
    var line: String
    var isError = false
    /// Boutons à ajouter sous la ligne (par exemple « Annuler » pour un rappel créé).
    var buttons: [ChatButton] = []

    static func failure(_ text: String, line: String) -> ToolResult {
        ToolResult(text: "ÉCHEC : " + text, line: line, isError: true)
    }
}

/// Un outil (un « pouvoir ») : nom, description pour le cerveau, schéma des arguments, et code.
struct Tool {
    let name: String
    let description: String
    /// Les arguments, au format JSON Schema (c'est ce que comprennent Claude et Ollama).
    let schema: [String: Any]
    let risk: ToolRisk
    /// La ligne affichée pendant que l'outil travaille, par exemple « 🔍 Je fouille tes Documents… ».
    let startLine: @MainActor (ToolArguments) -> String
    let run: @MainActor (ToolArguments) async -> ToolResult
}

/// Petit raccourci pour décrire les arguments d'un outil en JSON Schema.
/// `parameters(("title", "string", "Titre du rappel", true), …)` : (nom, type, description, obligatoire)
func parameters(_ list: (String, String, String, Bool)...) -> [String: Any] {
    var properties: [String: Any] = [:]
    var required: [String] = []
    for (name, type, description, isRequired) in list {
        properties[name] = ["type": type, "description": description]
        if isRequired { required.append(name) }
    }
    return ["type": "object", "properties": properties, "required": required]
}

/// Les arguments reçus, avec des lectures pratiques.
struct ToolArguments {
    let values: [String: Any]
    func string(_ key: String) -> String? {
        (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    func int(_ key: String) -> Int? {
        if let n = values[key] as? Int { return n }
        if let d = values[key] as? Double { return Int(d) }
        if let s = values[key] as? String { return Int(s) }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Qui affiche l'activité des outils et pose les questions de confirmation (la bulle de discussion).
@MainActor
protocol ToolObserver: AnyObject {
    func toolStarted(id: UUID, line: String)
    func toolFinished(id: UUID, result: ToolResult)
    /// Pose une question avec des choix dans la bulle. Renvoie le choix, ou `nil` si impossible.
    func askChoice(_ question: String, choices: [String]) async -> String?
}

/// Le registre des outils : la liste de tous les pouvoirs de Capri.
///
/// Il ne dépend d'aucun cerveau : Claude y accède via le serveur MCP (ToolServer.swift),
/// et Ollama pourra plus tard utiliser `definitions` avec son API d'outils.
@MainActor
final class ToolRegistry {
    private(set) var tools: [String: Tool] = [:]
    private var order: [String] = []
    /// La bulle qui affiche les actions en cours (celle de la conversation qui répond).
    weak var observer: ToolObserver?
    /// Nombre d'outils en train de travailler (le chien de garde du cerveau patiente pendant ce temps).
    private(set) var activeCalls = 0

    func register(_ newTools: [Tool]) {
        for tool in newTools {
            if tools[tool.name] == nil { order.append(tool.name) }
            tools[tool.name] = tool
        }
    }

    /// Les définitions des outils, au format attendu par MCP (`tools/list`).
    var definitions: [[String: Any]] {
        order.compactMap { tools[$0] }.map {
            ["name": $0.name, "description": $0.description, "inputSchema": $0.schema]
        }
    }

    /// Exécute un outil et affiche son activité dans la bulle.
    func call(_ name: String, arguments: [String: Any]) async -> ToolResult {
        guard let tool = tools[name] else {
            return .failure("outil inconnu : \(name)", line: "❓ Pouvoir inconnu : \(name)")
        }
        let args = ToolArguments(values: arguments)
        let id = UUID()
        let observer = self.observer
        observer?.toolStarted(id: id, line: tool.startLine(args))
        activeCalls += 1
        let result = await tool.run(args)
        activeCalls -= 1
        observer?.toolFinished(id: id, result: result)
        log.info("Outil \(name, privacy: .public) → \(result.isError ? "échec" : "ok", privacy: .public)")
        return result
    }

    /// Demande une confirmation dans la bulle (pour les outils sensibles).
    func ask(_ question: String, choices: [String]) async -> String? {
        await observer?.askChoice(question, choices: choices)
    }
}
