import Foundation

// Comment Claude utilise les pouvoirs de Capri :
//
//   claude ──(MCP, stdin/stdout)──▶ « Capri --mcp-server »  ──(socket Unix)──▶  Capri.app
//                                   petit relais sans interface                 exécute l'outil
//
// Pourquoi ce détour ? Les autorisations macOS (agenda, dossiers…) appartiennent à Capri.app.
// Si `claude` ou le relais lisaient eux-mêmes ton agenda, macOS demanderait la permission pour
// eux (ou la refuserait). Ici, c'est toujours l'app qui agit : un seul endroit, une seule permission.
//
// Le protocole sur la socket est minuscule : une ligne JSON envoyée, une ou plusieurs lignes JSON
// en réponse, puis la connexion se ferme.

enum ToolSocket {
    /// ~/Library/Application Support/Capri/capri.sock (lisible par ton seul compte).
    static var path: String {
        CapriSettings.supportDirectory.appendingPathComponent("capri.sock").path
    }

    /// Prépare l'adresse d'une socket Unix à partir d'un chemin de fichier.
    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.prefix(buffer.count - 1).enumerated() { buffer[i] = UInt8(bitPattern: byte) }
        }
        return address
    }

    static func writeLine(_ fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)   // "\n"
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Lit des lignes jusqu'à la fin de la connexion, et appelle `onLine` pour chacune.
    static func readLines(_ fd: Int32, onLine: ([String: Any]) -> Bool) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { return }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if !onLine(object) { return }
                }
            }
        }
    }

    /// Côté client : envoie une requête à Capri.app et lit les réponses.
    /// Renvoie faux si l'app ne répond pas (pas lancée).
    @discardableResult
    static func request(_ object: [String: Any], onLine: ([String: Any]) -> Bool) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        writeLine(fd, object)
        readLines(fd, onLine: onLine)
        return true
    }
}

/// Côté app : écoute la socket et exécute les demandes (outils, et le mode --selftest).
final class ToolSocketServer {
    /// Traite une requête. `send` renvoie une ligne au client ; la connexion se ferme au retour.
    typealias Handler = @MainActor (_ request: [String: Any], _ send: @escaping ([String: Any]) -> Void) async -> Void
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        // Écrire dans une connexion fermée ne doit pas tuer Capri (signal SIGPIPE).
        signal(SIGPIPE, SIG_IGN)
        let path = ToolSocket.path
        unlink(path)   // une vieille socket d'un lancement précédent
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = ToolSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else {
            log.error("Socket des outils impossible à ouvrir : \(path, privacy: .public)")
            return
        }
        chmod(path, 0o600)   // seulement ton compte

        // Un fil dédié attend les connexions (accept bloque) ; le travail se fait sur le fil principal.
        let handler = self.handler
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                Thread.detachNewThread {
                    var request: [String: Any]?
                    ToolSocket.readLines(client) { request = $0; return false }
                    guard let request else { close(client); return }
                    Task { @MainActor in
                        await handler(request) { ToolSocket.writeLine(client, $0) }
                        close(client)
                    }
                }
            }
        }
    }
}

/// Le relais MCP : `Capri --mcp-server`. Lancé par `claude`, il parle JSON-RPC sur stdin/stdout
/// (une ligne JSON par message) et transmet tout à Capri.app via la socket.
///
/// MCP en bref : `initialize` (présentation), `tools/list` (la liste des outils),
/// `tools/call` (exécuter un outil). C'est tout ce dont on a besoin.
enum MCPServer {
    static func run() -> Never {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            let id = message["id"]   // absent = simple notification, pas de réponse attendue
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "capri", "version": "0.3"],
                ])
            case "tools/list":
                var tools: [Any] = []
                let reached = ToolSocket.request(["op": "list"]) { response in
                    tools = response["tools"] as? [Any] ?? []
                    return false
                }
                if reached {
                    reply(id, result: ["tools": tools])
                } else {
                    replyError(id, code: -32000, message: "Capri.app ne répond pas (elle est lancée ?)")
                }
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                var text = "Capri.app ne répond pas : l'outil n'a pas pu être exécuté."
                var isError = true
                ToolSocket.request(["op": "call", "name": name, "arguments": arguments]) { response in
                    text = response["text"] as? String ?? text
                    isError = response["isError"] as? Bool ?? true
                    return false
                }
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": isError])
            case "ping":
                reply(id, result: [:])
            default:
                if id != nil { replyError(id, code: -32601, message: "Méthode inconnue : \(method)") }
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func replyError(_ id: Any?, code: Int, message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}
