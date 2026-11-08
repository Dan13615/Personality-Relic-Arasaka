import AppKit

/// Pouvoirs « applications » : lancer une app, lister et lancer des Raccourcis.
@MainActor
enum AppTools {
    static func all(registry: ToolRegistry, settings: @escaping () -> CapriSettings,
                    saveDecision: @escaping (String, String) -> Void) -> [Tool] {
        [
            Tool(name: "open_app",
                 description: "Lance une application du Mac à partir de son nom, même approximatif (ex. « spotify », « vs code », « calculette »). Renvoie l'app ouverte, ou des noms proches si rien ne correspond.",
                 schema: parameters(("name", "string", "Nom de l'application", true)),
                 risk: .action,
                 startLine: { "🚀 Je cherche « \($0.string("name") ?? "?") »…" },
                 run: { openApp($0.string("name") ?? "") }),

            Tool(name: "list_shortcuts",
                 description: "Liste les Raccourcis (app Raccourcis de macOS) de Daniil.",
                 schema: parameters(),
                 risk: .read,
                 startLine: { _ in "⚡️ Je regarde tes Raccourcis…" },
                 run: { _ in await listShortcuts() }),

            Tool(name: "run_shortcut",
                 description: "Lance un Raccourci de Daniil par son nom exact, avec un texte en entrée si besoin. La première fois, Daniil doit confirmer dans la bulle.",
                 schema: parameters(("name", "string", "Nom exact du Raccourci", true),
                                    ("input", "string", "Texte passé en entrée (facultatif)", false)),
                 risk: .sensitive,
                 startLine: { "⚡️ Raccourci « \($0.string("name") ?? "?") »…" },
                 run: { args in
                     await runShortcut(args.string("name") ?? "", input: args.string("input"),
                                       registry: registry, settings: settings(), saveDecision: saveDecision)
                 }),
        ]
    }

    // MARK: - Applications

    /// Toutes les apps installées : nom affiché (traduit, ex. « Calculette ») → emplacement.
    static func installedApps() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", "\(home)/Applications"]
        var apps: [(String, URL)] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(item)
                // displayName donne le nom dans la langue du système ; on garde aussi le nom du fichier.
                let display = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                apps.append((display, url))
                let file = String(item.dropLast(4))
                if file != display { apps.append((file, url)) }
                // Le nom français, même si macOS est en anglais (« Calculatrice » pour Calculator).
                if let french = frenchName(of: url), french != display, french != file { apps.append((french, url)) }
            }
        }
        return apps
    }

    /// Lit le nom français d'une app dans ses traductions : InfoPlist.loctable (récent) ou fr.lproj (ancien).
    static func frenchName(of app: URL) -> String? {
        let resources = app.appendingPathComponent("Contents/Resources")
        let table = resources.appendingPathComponent("InfoPlist.loctable")
        if let data = try? Data(contentsOf: table),
           let all = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let french = (all["fr"] ?? all["fr-FR"]) as? [String: String] {
            return french["CFBundleDisplayName"] ?? french["CFBundleName"]
        }
        let strings = resources.appendingPathComponent("fr.lproj/InfoPlist.strings")
        if let dict = NSDictionary(contentsOf: strings) as? [String: String] {
            return dict["CFBundleDisplayName"] ?? dict["CFBundleName"]
        }
        return nil
    }

    /// Simplifie un nom pour comparer : minuscules, sans accents, sans espaces ni ponctuation.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Note de ressemblance entre ce qui est demandé et un nom d'app (0 = aucune).
    static func score(query: String, name: String) -> Int {
        let q = normalize(query), n = normalize(name)
        guard !q.isEmpty else { return 0 }
        if q == n { return 100 }
        if n.hasPrefix(q) { return 80 }
        if n.contains(q) { return 60 }
        // Initiales : « vsc » pour « Visual Studio Code »
        let initials = name.split(whereSeparator: { !$0.isLetter }).compactMap(\.first).map { String($0).lowercased() }.joined()
        if initials.count > 1 && q.hasPrefix(initials) { return 50 }
        // Lettres dans l'ordre : « vscode » dans « visualstudiocode »
        var index = n.startIndex
        var inOrder = true
        for char in q {
            guard let found = n[index...].firstIndex(of: char) else { inOrder = false; break }
            index = n.index(after: found)
        }
        if inOrder { return 30 }
        // Presque le même mot (faute de frappe, synonyme proche) : « calculette » ≈ « calculatrice »
        let similarity = 1 - Double(editDistance(q, n)) / Double(max(q.count, n.count))
        return similarity >= 0.6 ? 25 : 0
    }

    /// Distance de Levenshtein : nombre de lettres à ajouter, enlever ou changer pour passer d'un mot à l'autre.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func openApp(_ query: String) -> ToolResult {
        // On note chaque app installée, puis on trie : meilleure note d'abord, nom le plus court à égalité.
        struct Candidate { let name: String; let url: URL; let score: Int }
        var ranked: [Candidate] = []
        for app in installedApps() {
            let value = score(query: query, name: app.name)
            if value > 0 { ranked.append(Candidate(name: app.name, url: app.url, score: value)) }
        }
        ranked.sort { a, b in a.score != b.score ? a.score > b.score : a.name.count < b.name.count }
        guard let best = ranked.first, best.score >= 25 else {
            return .failure("aucune application ne ressemble à « \(query) ».", line: "🤷 Aucune app « \(query) »")
        }
        // Score faible et plusieurs candidats : on demande plutôt que de deviner.
        let others = Array(Set(ranked.prefix(5).map { $0.name })).sorted()
        if best.score < 50 && others.count > 1 {
            return ToolResult(text: "Pas de correspondance sûre pour « \(query) ». Noms proches : \(others.joined(separator: ", ")). Rien n'a été ouvert.",
                              line: "🤔 « \(query) » ? Proches : \(others.prefix(3).joined(separator: ", "))", isError: true)
        }
        NSWorkspace.shared.openApplication(at: best.url, configuration: NSWorkspace.OpenConfiguration())
        return ToolResult(text: "Application ouverte : \(best.name) (\(best.url.path)).",
                          line: "🚀 \(best.name) lancée")
    }

    // MARK: - Raccourcis

    /// Lance /usr/bin/shortcuts et renvoie (code de sortie, sortie texte).
    private static func shortcuts(_ arguments: [String]) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (-1, "impossible de lancer /usr/bin/shortcuts") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    static func listShortcuts() async -> ToolResult {
        let (status, output) = await shortcuts(["list"])
        guard status == 0 else { return .failure(output, line: "⚡️ Raccourcis illisibles") }
        let names = output.split(separator: "\n").map(String.init)
        return ToolResult(text: names.isEmpty ? "Aucun Raccourci." : "Raccourcis : " + names.joined(separator: " | "),
                          line: "⚡️ \(names.count) Raccourci\(names.count > 1 ? "s" : "") trouvé\(names.count > 1 ? "s" : "")")
    }

    static func runShortcut(_ name: String, input: String?, registry: ToolRegistry,
                            settings: CapriSettings, saveDecision: (String, String) -> Void) async -> ToolResult {
        // Un Raccourci peut tout faire : la première fois, on demande à Daniil.
        switch settings.shortcutDecisions[name] {
        case "always":
            break
        case "never":
            return .failure("Daniil a interdit ce Raccourci.", line: "⛔️ Raccourci « \(name) » interdit")
        default:
            let choice = await registry.ask("Capri veut lancer le Raccourci « \(name) ». D'accord ?",
                                            choices: ["Autoriser une fois", "Toujours", "Refuser"])
            switch choice {
            case "Toujours": saveDecision(name, "always")
            case "Autoriser une fois": break
            case "Refuser":
                saveDecision(name, "never")
                return .failure("Daniil a refusé.", line: "⛔️ Raccourci « \(name) » refusé")
            default:
                return .failure("pas de confirmation possible (bulle fermée).", line: "⛔️ Raccourci non confirmé")
            }
        }

        var arguments = ["run", name]
        var inputFile: URL?
        if let input {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("capri-input-\(UUID().uuidString).txt")
            try? input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
            inputFile = file
        }
        let outputFile = FileManager.default.temporaryDirectory.appendingPathComponent("capri-output-\(UUID().uuidString).txt")
        arguments += ["--output-path", outputFile.path]
        defer {
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
            try? FileManager.default.removeItem(at: outputFile)
        }

        let (status, log) = await shortcuts(arguments)
        guard status == 0 else {
            return .failure("le Raccourci a échoué : \(log)", line: "⚡️ Raccourci « \(name) » en échec")
        }
        let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        return ToolResult(text: "Raccourci « \(name) » exécuté." + (output.isEmpty ? "" : " Résultat : \(output.prefix(4000))"),
                          line: "⚡️ Raccourci « \(name) » lancé")
    }
}
