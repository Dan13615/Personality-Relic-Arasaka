import AppKit
import CryptoKit
import Security

/// Connexion à Google (OAuth 2.0 pour application de bureau), sans mot de passe dans Capri.
///
/// Le principe, en 4 temps :
/// 1. Capri ouvre la page de consentement de Google dans TON navigateur habituel
///    (Google interdit la connexion dans une vue web intégrée comme celle du navigateur de Capri) ;
/// 2. tu acceptes ; Google renvoie le navigateur vers http://127.0.0.1:<port>, où Capri écoute un instant ;
/// 3. Capri échange le « code » reçu contre des jetons (PKCE : une preuve que c'est bien elle qui a demandé) ;
/// 4. le jeton de rafraîchissement, qui dure, est rangé dans ton Trousseau macOS. Les jetons d'accès
///    (1 h) sont redemandés avec lui quand il faut.
@MainActor
final class GoogleAuth {
    nonisolated static let scopes = [
        "https://www.googleapis.com/auth/tasks",       // Google Tasks
        "https://www.googleapis.com/auth/drive.file",  // seulement les fichiers créés par Capri (son Carnet)
    ]

    /// Le fichier téléchargé depuis la console Google (voir docs/google-setup.md).
    static var clientFile: URL { CapriSettings.supportDirectory.appendingPathComponent("google-oauth-client.json") }

    struct Client {
        let id: String
        let secret: String
        let authURI: String
        let tokenURI: String
    }

    enum AuthError: LocalizedError {
        case noClientFile, notConnected, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .noClientFile: return "fichier google-oauth-client.json introuvable dans ~/Library/Application Support/Capri (voir docs/google-setup.md)."
            case .notConnected: return "Google n'est pas connecté : menu de Capri → « Connecter Google… »."
            case .cancelled: return "connexion à Google annulée ou expirée."
            case .failed(let detail): return detail
            }
        }
    }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    var isConnected: Bool { Keychain.read() != nil }
    var hasClientFile: Bool { (try? Self.loadClient()) != nil }

    // MARK: - Le fichier client

    /// Lit le JSON de la console Google : {"installed": {"client_id": …, "client_secret": …, …}}
    static func loadClient() throws -> Client {
        guard let data = try? Data(contentsOf: clientFile) else { throw AuthError.noClientFile }
        return try parseClient(data)
    }

    nonisolated static func parseClient(_ data: Data) throws -> Client {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = (json["installed"] ?? json["web"]) as? [String: Any],
              let id = section["client_id"] as? String else {
            throw AuthError.failed("fichier client Google illisible (il faut un « ID client OAuth » de type « Application de bureau »).")
        }
        return Client(id: id, secret: section["client_secret"] as? String ?? "",
                      authURI: section["auth_uri"] as? String ?? "https://accounts.google.com/o/oauth2/v2/auth",
                      tokenURI: section["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")
    }

    // MARK: - PKCE

    /// Un secret aléatoire, jamais envoyé tel quel à Google au début…
    nonisolated static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// …seulement son empreinte SHA-256. On envoie le secret lui-même à la fin, pour prouver que c'est nous.
    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func authorizationURL(client: Client, redirect: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: client.authURI)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),   // pour obtenir un jeton de rafraîchissement
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    // MARK: - Connexion

    /// Lance tout le parcours de connexion. Renvoie quand c'est fini (ou échoué).
    func connect() async throws {
        let client = try Self.loadClient()
        let verifier = Self.makeVerifier()
        let state = UUID().uuidString
        let server = try LoopbackServer()
        let redirect = "http://127.0.0.1:\(server.port)"
        NSWorkspace.shared.open(Self.authorizationURL(client: client, redirect: redirect,
                                                      challenge: Self.challenge(for: verifier), state: state))
        // On attend le retour du navigateur (5 minutes maximum).
        let query = try await server.waitForRedirect(timeout: 300)
        guard query["state"] == state else { throw AuthError.failed("réponse de Google inattendue (state).") }
        if let error = query["error"] { throw AuthError.failed("Google a refusé : \(error)") }
        guard let code = query["code"] else { throw AuthError.cancelled }

        let tokens = try await tokenRequest(client: client, fields: [
            "code": code, "client_id": client.id, "client_secret": client.secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = tokens["refresh_token"] as? String else {
            throw AuthError.failed("Google n'a pas donné de jeton de rafraîchissement.")
        }
        Keychain.save(refresh)
        remember(tokens)
        log.notice("Google connecté")
    }

    func disconnect() {
        Keychain.delete()
        accessToken = nil
    }

    /// Un jeton d'accès valide (redemandé automatiquement s'il a expiré).
    func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry.addingTimeInterval(-60) { return accessToken }
        guard let refresh = Keychain.read() else { throw AuthError.notConnected }
        let client = try Self.loadClient()
        let tokens = try await tokenRequest(client: client, fields: [
            "refresh_token": refresh, "client_id": client.id, "client_secret": client.secret, "grant_type": "refresh_token",
        ])
        remember(tokens)
        guard let accessToken else { throw AuthError.failed("Google n'a pas donné de jeton d'accès.") }
        return accessToken
    }

    /// Oublie le jeton d'accès (après un refus 401, pour forcer un nouveau).
    func invalidate() { accessToken = nil }

    private func remember(_ tokens: [String: Any]) {
        accessToken = tokens["access_token"] as? String
        accessTokenExpiry = Date().addingTimeInterval(tokens["expires_in"] as? Double ?? 3000)
    }

    private func tokenRequest(client: Client, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: client.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = json["error_description"] as? String ?? json["error"] as? String ?? "code \(http.statusCode)"
            // « invalid_grant » = jeton révoqué ou expiré : il faut se reconnecter.
            if json["error"] as? String == "invalid_grant" { Keychain.delete() }
            throw AuthError.failed("Google : \(detail)")
        }
        return json
    }

    nonisolated static func formBody(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}

/// Le jeton de rafraîchissement Google, rangé dans le Trousseau de macOS (chiffré, lié à Capri).
enum Keychain {
    private static let service = "com.dan13615.capri.google"
    private static let account = "refresh_token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Un mini serveur web sur 127.0.0.1, le temps de recevoir la redirection de Google.
final class LoopbackServer {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0   // 0 = le système choisit un port libre
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw GoogleAuth.AuthError.failed("serveur local impossible à ouvrir.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(fd) }

    /// Attend la requête « GET /?code=…&state=… » du navigateur et renvoie ses paramètres.
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        let fd = self.fd
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&poll, 1, Int32(timeout * 1000)) > 0 else {
                    continuation.resume(throwing: GoogleAuth.AuthError.cancelled)
                    return
                }
                let client = accept(fd, nil, nil)
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = read(client, &buffer, buffer.count)
                let request = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
                let page = """
                <html><head><meta charset="utf-8"><title>Capri</title></head>
                <body style="background:#0a0814;color:#eee;font-family:ui-monospace,monospace;padding:40px">
                <h2 style="color:#f21f85">CAPRI://google</h2><p>Connexion reçue. Tu peux fermer cet onglet et retourner voir Capri.</p>
                </body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                _ = response.withCString { write(client, $0, strlen($0)) }
                close(client)
                continuation.resume(returning: LoopbackServer.queryItems(fromRequest: request))
            }
        }
    }

    /// « GET /?code=abc&state=xyz HTTP/1.1 » → ["code": "abc", "state": "xyz"]
    static func queryItems(fromRequest request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return [:] }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}
