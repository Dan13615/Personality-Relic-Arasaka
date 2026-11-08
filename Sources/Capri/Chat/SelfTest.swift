import Foundation

/// Mode test caché, sans interface :
///
///     build/Capri.app/Contents/MacOS/Capri --selftest "Salut Capri" "Tu te souviens de ce que j'ai dit ?"
///
/// Si Capri.app tourne, la conversation passe PAR l'app (via la socket) : c'est donc l'app qui
/// utilise ses pouvoirs, avec ses autorisations macOS à elle. Sinon, on parle au cerveau
/// directement, sans pouvoirs. Affiche l'humeur, la réponse, les actions et les temps.
@MainActor
enum SelfTest {
    static func run(messages: [String]) {
        print("Persona : \(Persona.fileURL?.path ?? "introuvable")")
        // 1. Par l'app en cours d'exécution (avec les pouvoirs).
        Task.detached {
            let reached = ToolSocket.request(["op": "chat", "messages": messages]) { reply in
                print("\n» \(reply["message"] as? String ?? "")")
                print("[humeur : \(reply["mood"] as? String ?? "?")]")
                for line in reply["lines"] as? [String] ?? [] { print(line) }
                print(String(format: "(premiers mots : %.2f s, réponse complète : %.2f s)",
                             reply["firstWords"] as? Double ?? -1, reply["total"] as? Double ?? -1))
                return true
            }
            if reached { exit(0) }
            await MainActor.run { runWithoutApp(messages: messages) }
        }
    }

    /// 2. Capri.app n'est pas lancée : discussion seule, directement avec le cerveau.
    private static func runWithoutApp(messages: [String]) {
        print("(Capri.app ne tourne pas : test sans pouvoirs)")
        let settings = CapriSettings.load()
        let brain: ChatBrain
        if settings.brain == "ollama" {
            brain = OllamaBrain(settings: settings)
        } else {
            let claude = ClaudeBrain(settings: settings)
            claude.withPowers = false
            brain = claude
        }
        Task { @MainActor in
            for message in messages {
                print("\n» \(message)")
                let start = Date()
                var firstWords: TimeInterval?
                var parser = MoodParser()
                var mood = Mood.calme
                var text = ""
                do {
                    for try await event in brain.reply(to: message, systemPrompt: Persona.systemPrompt()) {
                        guard case .text(let chunk) = event else { continue }
                        let output = parser.feed(chunk)
                        if output.moodDecided { mood = output.mood }
                        if firstWords == nil && !output.text.isEmpty { firstWords = Date().timeIntervalSince(start) }
                        text += output.text
                    }
                    text += parser.finish().text
                    print("[humeur : \(mood.rawValue) → pose \(mood.pose.rawValue)]")
                    print(text)
                    print(String(format: "(premiers mots : %.2f s, réponse complète : %.2f s)",
                                 firstWords ?? -1, Date().timeIntervalSince(start)))
                } catch let error as BrainError {
                    print("ERREUR : \(error.capriMessage)\n  \(error.technicalDetail)")
                } catch {
                    print("ERREUR : \(error)")
                }
            }
            exit(0)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Mode caché pour vérifier l'apparence des bulles sans capture d'écran :
///
///     Capri --render-ui /un/dossier
///
/// Dessine la bulle de discussion (avec une fausse conversation) et une petite bulle en PNG.
@MainActor
enum UIRender {
    static func run(directory: String) {
        let model = ChatModel { ClaudeBrain(settings: CapriSettings()) }
        model.messages = [
            .init(role: .user, text: "Mets-moi un rappel dans 20 minutes pour sortir le linge"),
            .init(role: .action, text: "📅 Je note « Sortir le linge »…", isRunning: true),
            .init(role: .action, text: "📅 Rappel créé : Sortir le linge — dimanche 8 novembre à 11 h 05",
                  buttons: [ChatButton(title: "Annuler") {}]),
            .init(role: .capri, text: "C'est noté, Daniil ! À **11 h 05** je débarque en haut à gauche pour te le rappeler."),
            .init(role: .notice, text: "Capri veut lancer le Raccourci « Mode concentration ». D'accord ?",
                  buttons: [ChatButton(title: "Autoriser une fois", isPrimary: true) {}, ChatButton(title: "Toujours") {}, ChatButton(title: "Refuser") {}]),
            .init(role: .error, text: "Bzzt… mon cerveau ne répond plus.", detail: "Aucune réponse depuis 60 s."),
        ]
        let size = ChatWindowController.contentSize, m = ChatWindowController.margin, t = BubbleTail.length
        let above = BubbleLayout()
        above.tail = BubbleTail(edge: .bottom, position: 120)
        save(ChatView(model: model, layout: above, brainName: "Claude", onClose: {})
                .frame(width: size.width + 2 * m, height: size.height + t + 2 * m), to: directory, name: "chat-above.png")
        // ImageRenderer ne sait pas dessiner une ScrollView ni un champ de texte AppKit :
        // on dessine donc aussi l'historique seul, pour juger des messages.
        save(VStack(alignment: .leading, spacing: 10) {
                ForEach(model.messages) { MessageRow(message: $0) }
                TypingIndicator()
            }
            .padding(12).frame(width: size.width).background(Theme.background), to: directory, name: "chat-history.png")
        save(SpeechBubbleView(text: "Arrête, mon processeur va se renverser !"), to: directory, name: "speech.png")

        let side = BubbleLayout()
        side.tail = BubbleTail(edge: .left, position: 60)
        let item = EventNotification(key: "x", eventID: nil, title: "Point hebdo équipe", start: Date().addingTimeInterval(600),
                                     location: "https://meet.google.com/abc-defg-hij", notes: nil, isAllDay: false, isCapriReminder: false)
        save(NotificationBubbleView(text: LocalLines.notification(item), time: "à 11 h 15", buttons: [
                ChatButton(title: "OK", isPrimary: true) {}, ChatButton(title: "Dans 5 min") {}, ChatButton(title: "Ouvrir") {},
             ], layout: side), to: directory, name: "notification.png")

        renderBrowser(directory: directory)
    }

    /// Le navigateur : la barre d'outils est dessinée hors écran (fenêtre invisible),
    /// et la page avec l'instantané de WebKit (le web s'affiche dans un autre processus).
    private static func renderBrowser(directory: String) {
        let model = BrowserModel()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: BrowserView(model: model))
        window.contentView = host
        window.orderBack(nil)
        Task { @MainActor in
            if let url = model.url(for: "fr.wikipedia.org/wiki/Night_City") { await model.load(url) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("browser-chrome.png"))
            }
            if let image = try? await model.webView.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("browser-page.png"))
            }
            print("Images écrites dans \(directory) (page : \(model.title))")
            exit(0)
        }
    }

    private static func save(_ view: some View, to directory: String, name: String) {
        // Fond sombre derrière, comme un bureau, pour juger de la lisibilité.
        let renderer = ImageRenderer(content: view.background(Color(white: 0.25)))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Tests de la partie Google qui ne demandent ni réseau ni compte :
///
///     Capri --google-selftest
@MainActor
enum GoogleSelfTest {
    static func run() {
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1; print("✓ \(name)") } else { failed += 1; print("✗ \(name)") }
        }

        // PKCE : base64url(SHA-256(verifier)), valeur attendue calculée indépendamment avec Python (hashlib).
        check("PKCE (S256)", GoogleAuth.challenge(for: "dBjftJeZ4CVP-mJ92K9qPKVqA7PXdz1fCHr9E7d6oTo") == "n8YWm0_zJRMUByclOsKJ3YGSWhYzMSaZEnA-LMJxpBY")
        check("verifier aléatoire (43+ caractères, sans + / =)", { let v = GoogleAuth.makeVerifier(); return v.count >= 43 && !v.contains(where: "+/=".contains) }())

        // Fichier client de la console Google.
        let sample = #"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","project_id":"capri","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","client_secret":"GOCSPX-test","redirect_uris":["http://localhost"]}}"#
        let client = try? GoogleAuth.parseClient(Data(sample.utf8))
        check("lecture du fichier client", client?.id == "123-abc.apps.googleusercontent.com" && client?.secret == "GOCSPX-test")
        check("fichier client invalide refusé", (try? GoogleAuth.parseClient(Data(#"{"foo":1}"#.utf8))) == nil)

        if let client {
            let url = GoogleAuth.authorizationURL(client: client, redirect: "http://127.0.0.1:5555", challenge: "CH", state: "ST")
            let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            check("URL de consentement", items["redirect_uri"] == "http://127.0.0.1:5555" && items["code_challenge_method"] == "S256"
                  && items["access_type"] == "offline" && items["scope"] == GoogleAuth.scopes.joined(separator: " "))
        }
        check("corps de formulaire encodé", GoogleAuth.formBody(["b": "x y&z", "a": "1/2"]) == "a=1%2F2&b=x%20y%26z")
        check("redirection reçue", LoopbackServer.queryItems(fromRequest: "GET /?code=4%2FabC&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") == ["code": "4/abC", "state": "xyz"])

        // Google Docs : texte, entrées, recherche.
        let document: [String: Any] = ["body": ["content": [
            ["sectionBreak": [:]],
            ["paragraph": ["elements": [["textRun": ["content": "Carnet de Capri — les notes que tu lui confies.\n"]]]]],
            ["paragraph": ["elements": [["textRun": ["content": "\n📝 dimanche 8 novembre 2026, 11 h 02 — Courses\n"]]]]],
            ["paragraph": ["elements": [["textRun": ["content": "Acheter du café "]], ["textRun": ["content": "et des pâtes\n"]]]]],
            ["paragraph": ["elements": [["textRun": ["content": "\n📝 lundi 9 novembre 2026, 9 h 00 — Idée\nUn mode nuit pour Capri\n"]]]]],
        ]]]
        let text = GoogleFormat.documentText(document)
        check("texte du document", text.contains("Acheter du café et des pâtes"))
        let entries = GoogleFormat.entries(in: text)
        check("découpage en entrées", entries.count == 2 && entries[0].hasPrefix("📝 dimanche"))
        check("recherche sans accents", GoogleFormat.matching(entries, query: "PATES cafe").count == 1)
        let entry = GoogleFormat.entry(text: " Test ", title: "Titre", date: Date(timeIntervalSince1970: 1_778_230_800))
        check("format d'une entrée", entry.hasPrefix("\n📝 ") && entry.contains("— Titre\nTest\n"))
        let append = GoogleFormat.appendRequest("abc")
        check("requête d'ajout Docs (JSON valide)", JSONSerialization.isValidJSONObject(append)
              && ((append["requests"] as? [[String: Any]])?.first?["insertText"] as? [String: Any])?["endOfSegmentLocation"] != nil)

        // Google Tasks.
        check("échéance (date seule)", GoogleFormat.taskDue("2026-11-12") == "2026-11-12T00:00:00.000Z")
        check("échéance depuis une date ISO", GoogleFormat.taskDue("2026-11-12T14:30:00+01:00") == "2026-11-12T00:00:00.000Z")
        check("échéance invalide refusée", GoogleFormat.taskDue("demain") == nil)
        let line = GoogleFormat.taskLine(["id": "T1", "title": "Appeler Léa", "due": "2026-11-12T00:00:00.000Z", "notes": "pour samedi"])
        check("ligne de tâche", line == "- Appeler Léa — pour le 2026-11-12 — pour samedi [id : T1]")

        // Les outils : présents dans le registre, schémas JSON valides.
        let registry = ToolRegistry()
        let api = GoogleAPI(auth: GoogleAuth())
        registry.register(GoogleTools.all(api: api, notesDocument: { nil }, saveNotesDocument: { _ in }))
        let names = registry.definitions.compactMap { $0["name"] as? String }
        check("5 outils Google", names == ["add_note", "read_notes", "create_task", "list_tasks", "complete_task"])
        check("schémas JSON valides", registry.definitions.allSatisfy { JSONSerialization.isValidJSONObject($0) })

        // Le mini serveur de redirection, pour de vrai : une requête HTTP locale.
        Task { @MainActor in
            do {
                let server = try LoopbackServer()
                let port = server.port
                Task.detached {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=XYZ&state=S1")!)
                }
                let query = try await server.waitForRedirect(timeout: 5)
                check("serveur de redirection (port \(port))", query == ["code": "XYZ", "state": "S1"])
            } catch {
                check("serveur de redirection", false)
            }
            // Sans connexion, un outil répond par un échec clair (pas de plantage).
            let result = await registry.call("list_tasks", arguments: [:])
            check("sans connexion : échec lisible", result.isError && result.text.contains("Connecter Google"))
            print("\n\(passed) réussis, \(failed) échoués")
            exit(failed == 0 ? 0 : 1)
        }
    }
}
