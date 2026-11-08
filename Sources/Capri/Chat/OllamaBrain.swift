import Foundation

/// Le cerveau local : Ollama, qui fait tourner un modèle directement sur ton Mac.
/// On lui parle en HTTP sur http://localhost:11434. Ici, c'est nous qui gardons l'historique.
@MainActor
final class OllamaBrain: ChatBrain {
    var displayName: String { "Ollama" }

    static let baseURL = URL(string: "http://localhost:11434")!
    private let settings: CapriSettings
    /// L'historique : [["role": "user"/"assistant", "content": "…"]]
    private var history: [[String: String]] = []

    init(settings: CapriSettings) {
        self.settings = settings
    }

    func reset() {
        history = []
    }

    /// Ollama tourne-t-il ? Renvoie la liste des modèles installés, ou `nil` s'il ne répond pas.
    static func installedModels() async -> [String]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    // Note : Ollama reste « discussion seulement » pour l'instant. Pour lui donner les pouvoirs plus tard,
    // il suffira d'envoyer `ToolRegistry.definitions` dans le champ "tools" de /api/chat.
    func reply(to message: String, systemPrompt: String) -> AsyncThrowingStream<BrainEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.run(message: message, systemPrompt: systemPrompt, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(message: String, systemPrompt: String,
                     continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation) async throws {
        let messages = [["role": "system", "content": systemPrompt]] + history + [["role": "user", "content": message]]
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = settings.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.ollamaModel,
            "messages": messages,
            "stream": true,
        ] as [String: Any])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw BrainError.ollamaUnavailable("Connexion à \(Self.baseURL.absoluteString) impossible : \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BrainError.ollamaUnavailable("Ollama a répondu \(http.statusCode) (modèle « \(settings.ollamaModel) » installé ?)")
        }

        // Réponse en NDJSON : une ligne JSON par morceau, {"message": {"content": "…"}, "done": false}
        var full = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = json["error"] as? String { throw BrainError.ollamaUnavailable(error) }
            if let piece = (json["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                full += piece
                continuation.yield(.text(piece))
            }
        }
        history.append(["role": "user", "content": message])
        history.append(["role": "assistant", "content": full])
    }
}
