import Foundation

/// Le portier des connecteurs claude.ai (Gmail, Drive, Slack, Supabase, Figma…).
///
/// Quand Claude veut utiliser un outil qui n'est pas autorisé d'avance, Claude Code (en mode -p)
/// appelle notre outil `approve` (option --permission-prompt-tool). On décide alors :
/// - lecture seule (get, list, search, read…) → autorisé tout de suite ;
/// - action qui change quelque chose (envoyer, créer, modifier…) → on demande à Daniil dans la bulle ;
/// - action destructrice (supprimer, fusionner, exécuter du SQL, déployer…) → on demande TOUJOURS,
///   sans bouton « Toujours ».
/// Sans réponse au bout de 2 minutes : refusé.
@MainActor
enum ConnectorGate {
    /// Verbes de lecture : premier mot du nom de l'action.
    static let readVerbs: Set<String> = [
        "get", "list", "search", "read", "fetch", "query", "find", "describe", "lookup", "view",
        "show", "check", "count", "inspect", "preview", "whoami", "suggest", "guide",
    ]
    /// Mots qui rendent une action destructrice (jamais de « Toujours »).
    static let destructiveWords: Set<String> = [
        "delete", "remove", "trash", "drop", "merge", "execute", "apply", "deploy", "destroy",
        "purge", "revoke", "reset", "pause", "restore", "rebase", "cancel", "stop",
    ]

    enum Kind { case readOnly, write, destructive }

    /// « mcp__claude_ai_Google_Drive__search_files » → ("Google Drive", "search_files")
    static func parse(_ toolName: String) -> (service: String, action: String) {
        let parts = toolName.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return (toolName, "") }
        let service = parts[1].replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
        return (service, parts[2...].joined(separator: "__"))
    }

    static func kind(of action: String) -> Kind {
        // Le nom peut être en snake_case (search_files) ou en camelCase (searchFiles).
        let spaced = action.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression)
        let words = spaced.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: destructiveWords.contains) { return .destructive }
        // SQL : même un SELECT passe par execute_sql, qui peut tout faire → destructive (ci-dessus).
        if let first = words.first, readVerbs.contains(first) { return .readOnly }
        // Préfixes de service (slack_read_channel, appstore_reviews…) : on regarde le 2e mot.
        if words.count > 1, readVerbs.contains(words[1]) { return .readOnly }
        return .write
    }

    /// Les paramètres importants, en français lisible (destinataire, sujet, début du texte, SQL…).
    static func summary(of input: [String: Any]) -> String {
        let labels: [(keys: [String], label: String)] = [
            (["to", "recipient", "recipients"], "À"), (["cc"], "Cc"), (["subject"], "Sujet"),
            (["channel", "channel_id", "channel_name"], "Salon"), (["repo", "repository"], "Dépôt"),
            (["title", "name"], "Titre"), (["project_id", "project"], "Projet"),
            (["query", "sql"], "Requête"), (["file_id", "document_id", "fileId"], "Fichier"),
            (["body", "text", "content", "message", "description"], "Texte"),
        ]
        var lines: [String] = []
        var used = Set<String>()
        for (keys, label) in labels {
            guard let key = keys.first(where: { input[$0] != nil }), let value = input[key] else { continue }
            used.insert(key)
            lines.append("• \(label) : \(shorten(value, limit: label == "Texte" || label == "Requête" ? 240 : 120))")
        }
        // Les autres paramètres simples, brièvement.
        for (key, value) in input.sorted(by: { $0.key < $1.key }) where !used.contains(key) && lines.count < 8 {
            if value is String || value is NSNumber { lines.append("• \(key) : \(shorten(value, limit: 80))") }
        }
        return lines.joined(separator: "\n")
    }

    private static func shorten(_ value: Any, limit: Int) -> String {
        var text: String
        if let array = value as? [Any] { text = array.map { "\($0)" }.joined(separator: ", ") } else { text = "\(value)" }
        text = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Réponse au format attendu par Claude Code.
    private static func decision(_ allow: Bool, input: [String: Any], message: String = "") -> String {
        let object: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"behavior":"deny","message":"erreur interne"}"#
    }

    static func tool(registry: ToolRegistry, settings: @escaping () -> CapriSettings,
                     remember: @escaping (String) -> Void) -> Tool {
        Tool(name: "approve",
             description: "Usage interne de Capri (demande d'autorisation). Ne jamais appeler directement.",
             schema: parameters(("tool_name", "string", "Outil demandé", true),
                                ("input", "object", "Ses paramètres", true)),
             risk: .read,
             startLine: { args in
                 let (service, action) = parse(args.string("tool_name") ?? "?")
                 return "🔌 \(service) · \(action.replacingOccurrences(of: "_", with: " "))…"
             },
             run: { args in
                 let name = args.string("tool_name") ?? ""
                 let input = args.values["input"] as? [String: Any] ?? [:]
                 let (service, action) = parse(name)
                 let label = "\(service) · \(action.replacingOccurrences(of: "_", with: " "))"

                 // Seuls les connecteurs claude.ai passent par ici ; le reste est refusé.
                 guard name.hasPrefix("mcp__claude_ai_") else {
                     return ToolResult(text: decision(false, input: input, message: "Outil non autorisé pour Capri."),
                                       line: "⛔️ \(name) refusé")
                 }
                 let kind = kind(of: action)
                 if kind == .readOnly {
                     return ToolResult(text: decision(true, input: input), line: "🔌 \(label)")
                 }
                 if kind == .write && settings().connectorAlways.contains(name) {
                     return ToolResult(text: decision(true, input: input), line: "🔌 \(label) (autorisé d'office)")
                 }

                 // On demande à Daniil, avec le détail de l'action.
                 let warning = kind == .destructive ? "⚠️ Action irréversible ou sensible.\n" : ""
                 let question = "\(warning)Capri veut utiliser \(service) : \(action.replacingOccurrences(of: "_", with: " "))\n\(summary(of: input))"
                 var choices = ["Autoriser une fois", "Refuser"]
                 if kind == .write { choices.insert("Toujours pour cet outil", at: 1) }
                 let answer = await registry.ask(question, choices: choices, timeout: 120)
                 switch answer {
                 case "Autoriser une fois":
                     return ToolResult(text: decision(true, input: input), line: "✅ Autorisé : \(label)")
                 case "Toujours pour cet outil":
                     remember(name)
                     return ToolResult(text: decision(true, input: input), line: "✅ Autorisé (toujours) : \(label)")
                 case "Refuser":
                     return ToolResult(text: decision(false, input: input, message: "Daniil a refusé cette action. Ne réessaie pas sans qu'il le demande."),
                                       line: "⛔️ Refusé : \(label)")
                 default:
                     return ToolResult(text: decision(false, input: input, message: "Pas de réponse de Daniil (2 min) : action refusée."),
                                       line: "⏱️ Sans réponse, refusé : \(label)")
                 }
             })
    }

}
