import Foundation

/// Le cerveau Claude : il lance le vrai programme `claude` (Claude Code), avec ton abonnement.
///
/// Un processus par message, en mode « print » (`-p`) : il répond puis se termine.
/// La conversation continue grâce à l'identifiant de session (`--resume`).
/// La sortie est en « stream-json » : une ligne JSON par événement, dont les morceaux de texte.
@MainActor
final class ClaudeBrain: ChatBrain {
    var displayName: String { "Claude" }

    private let settings: CapriSettings
    /// L'identifiant de la conversation en cours, renvoyé par Claude. `nil` = nouvelle conversation.
    private var sessionID: String?
    /// Donner ses pouvoirs à Capri (outils MCP + recherche web). Faux pour une discussion seule.
    var withPowers = true
    /// Vrai quand un outil de Capri travaille : le chien de garde patiente (ex. confirmation d'un Raccourci).
    var isToolRunning: () -> Bool = { false }

    init(settings: CapriSettings) {
        self.settings = settings
    }

    /// La configuration MCP : `claude` lancera « Capri --mcp-server », qui relaie vers l'app.
    private var mcpConfig: String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let config: [String: Any] = ["mcpServers": ["capri": [
            "type": "stdio", "command": executable, "args": ["--mcp-server"],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func reset() {
        sessionID = nil
    }

    /// Dossier de travail vide et dédié : Claude n'y trouve ni CLAUDE.md, ni réglages de projet.
    static var workingDirectory: URL {
        let dir = CapriSettings.supportDirectory.appendingPathComponent("brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Arguments

    private func arguments(message: String, systemPrompt: String) -> [String] {
        var args = [
            "-p", message,
            "--output-format", "stream-json",
            "--verbose",                         // obligatoire avec stream-json en mode -p
            "--include-partial-messages",        // les morceaux de texte au fur et à mesure
            "--system-prompt", systemPrompt,     // SA personnalité remplace le prompt par défaut
            "--system-prompt-snapshot", "off",   // relit le prompt à chaque message (date, heure, persona modifiée)
            "--strict-mcp-config",               // aucun autre serveur MCP que le sien
            "--setting-sources", "",             // ni tes réglages ni ceux d'un projet
            "--disable-slash-commands",
            "--model", settings.claudeModel,
        ]
        if withPowers {
            args += [
                // Outils intégrés de Claude Code : SEULEMENT la recherche et la lecture web.
                // Pas de Bash, Read, Write… : ils contourneraient les règles de dossiers de Capri.
                "--tools", "WebSearch,WebFetch",
                // Ses pouvoirs à elle, via notre serveur MCP « capri ».
                "--mcp-config", mcpConfig,
                // Autorisés sans question ; tout le reste est refusé d'office (dontAsk).
                "--allowedTools", "mcp__capri,WebSearch,WebFetch",
                "--permission-mode", "dontAsk",
            ]
        } else {
            args += ["--tools", ""]   // discussion seule
        }
        if let sessionID {
            args += ["--resume", sessionID]
        }
        return args
    }

    // MARK: - Réponse

    func reply(to message: String, systemPrompt: String) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.run(message: message, systemPrompt: systemPrompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Si on arrête de lire (bouton stop), on annule la tâche, ce qui tue le processus.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(message: String, systemPrompt: String,
                     continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation) async throws {
        guard let executable = ClaudeLocator.find(settings: settings) else { throw BrainError.claudeNotFound }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(message: message, systemPrompt: systemPrompt)
        process.currentDirectoryURL = Self.workingDirectory
        var environment = ClaudeLocator.environment(for: executable)
        environment["MCP_TOOL_TIMEOUT"] = "600000"   // 10 min : le temps de confirmer un Raccourci
        process.environment = environment
        process.standardInput = FileHandle.nullDevice   // sinon claude attend 3 s une entrée
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Chien de garde : si rien ne sort pendant trop longtemps, on arrête tout.
        var lastOutput = Date()
        var timedOut = false
        let timeout = settings.timeoutSeconds
        let isToolRunning = self.isToolRunning
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if isToolRunning() { lastOutput = Date(); continue }   // un outil travaille : on patiente
                if Date().timeIntervalSince(lastOutput) > timeout {
                    timedOut = true
                    process.terminate()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        var newSessionID: String?
        var streamedText = false
        var finalResult: String?
        var resultIsError = false

        try await withTaskCancellationHandler {
            // On lit la sortie ligne par ligne : chaque ligne est un objet JSON.
            for try await line in output.fileHandleForReading.bytes.lines {
                lastOutput = Date()
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let id = json["session_id"] as? String { newSessionID = id }

                switch json["type"] as? String {
                case "stream_event":
                    guard let event = json["event"] as? [String: Any] else { break }
                    switch event["type"] as? String {
                    case "message_start":
                        continuation.yield(.newMessage)
                    case "content_block_start":
                        // Début d'un appel d'outil. Les nôtres (mcp__capri__…) sont affichés par l'app elle-même.
                        if let block = event["content_block"] as? [String: Any],
                           let name = block["name"] as? String, !name.hasPrefix("mcp__") {
                            continuation.yield(.webTool(name))
                        }
                    case "content_block_delta":
                        // Un morceau de texte : {"delta": {"type": "text_delta", "text": "…"}}
                        if let delta = event["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            streamedText = true
                            continuation.yield(.text(text))
                        }
                    default:
                        break
                    }
                case "result":
                    finalResult = json["result"] as? String
                    resultIsError = json["is_error"] as? Bool ?? false
                default:
                    break
                }
            }
        } onCancel: {
            process.terminate()
        }

        while process.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
        if Task.isCancelled { return }
        if timedOut { throw BrainError.timeout(timeout) }

        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if resultIsError || process.terminationStatus != 0 {
            let detail = [finalResult, stderr].compactMap { $0 }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Si la reprise de conversation échoue, la prochaine fois on repart de zéro.
            sessionID = nil
            let lower = detail.lowercased()
            if lower.contains("login") || lower.contains("log in") || lower.contains("not logged") || lower.contains("authenticat") {
                throw BrainError.notLoggedIn(String(detail.prefix(200)))
            }
            throw BrainError.cliFailed(detail.isEmpty ? "claude s'est arrêté (code \(process.terminationStatus))." : String(detail.prefix(300)))
        }

        // Sans morceaux en direct (vieille version de claude ?), on envoie le résultat d'un coup.
        if !streamedText, let finalResult { continuation.yield(.text(finalResult)) }
        sessionID = newSessionID ?? sessionID
    }
}

/// Trouve le programme `claude`.
/// Une app lancée depuis le Finder n'hérite pas du PATH de ton Terminal : il faut chercher nous-mêmes.
@MainActor
enum ClaudeLocator {
    private static var cached: URL?

    static func find(settings: CapriSettings) -> URL? {
        if let cached { return cached }
        var candidates: [String] = []
        if let path = settings.claudePath { candidates.append(path) }
        if let fromShell = askLoginShell() { candidates.append(fromShell) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cached = found.map { URL(fileURLWithPath: $0) }
        return cached
    }

    /// Demande à un shell « de connexion » (qui lit ton .zprofile/.zshrc) où se trouve claude.
    private static func askLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Pas plus de 3 s : un shell mal configuré ne doit pas bloquer Capri.
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // On garde la dernière ligne qui ressemble à un chemin (le profil peut afficher d'autres choses).
        return text.split(separator: "\n").map(String.init).last { $0.hasPrefix("/") }
    }

    /// Variables d'environnement pour claude, avec un PATH raisonnable.
    static func environment(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [executable.deletingLastPathComponent().path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }
}
