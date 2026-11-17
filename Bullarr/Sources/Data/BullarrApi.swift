import Foundation

/// Erreur destinée à l'utilisateur : [message] est déjà lisible, en français.
struct ApiException: Error, LocalizedError {
    let message: String
    let httpCode: Int?
    init(_ message: String, code: Int? = nil) { self.message = message; self.httpCode = code }
    var errorDescription: String? { message }
}

func readable(_ error: Error) -> String {
    switch error {
    case let e as ApiException: return e.message
    case let e as DecodingError: return "Réponse inattendue du serveur : JSON invalide"
    case let e as NSError:
        if e.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: e.code) {
            case .cannotFindHost, .dnsLookupFailed:
                return "Serveur introuvable : vérifiez l'URL et que le téléphone est sur le bon réseau (Wi-Fi local, VPN…)."
            case .cannotConnectToHost:
                return "Connexion refusée par le serveur. Bullarr est-il démarré et le port correct ?"
            case .timedOut:
                return "Le serveur ne répond pas (délai dépassé)."
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRequired:
                return "Erreur HTTPS (\(e.localizedDescription)). Si le serveur n'a pas de certificat, utilisez http://."
            case .networkConnectionLost, .notConnectedToInternet:
                return "Pas de connexion réseau. Vérifiez le Wi-Fi ou les données."
            case .cannotParseResponse:
                return "Réponse illisible du serveur."
            default:
                return "Erreur réseau : \(e.localizedDescription)"
            }
        }
        return "\(e.domain) : \(e.localizedDescription)"
    default: return error.localizedDescription
    }
}

/// Session ouverte par identifiant/mot de passe ou SSO : cookie Flask, jeton CSRF, identifiants pour se reconnecter.
final class SessionAuth {
    var cookie: String
    let username: String
    let password: String
    let onCookie: (String) -> Void
    var csrf: String?

    init(cookie: String, username: String = "", password: String = "", onCookie: @escaping (String) -> Void = { _ in }) {
        self.cookie = cookie; self.username = username; self.password = password; self.onCookie = onCookie
    }

    /// Reprend les cookies renvoyés par Bullarr. La session Flask est un cookie signé qui change
    /// quand le serveur y écrit (jeton CSRF, rôle…) : garder l'ancien ferait perdre le jeton CSRF.
    func absorb(_ setCookies: [String]) {
        if setCookies.isEmpty { return }
        var jar = [String: String]()
        for piece in cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if piece.contains("=") { jar[String(piece.split(separator: "=", maxSplits: 1)[0])] = piece }
        }
        for c in setCookies.map({ $0.split(separator: ";").first.map(String.init) ?? "" }).filter({ !$0.isEmpty && $0.contains("=") }) {
            let name = String(c.split(separator: "=", maxSplits: 1)[0])
            let value = c.split(separator: "=", maxSplits: 1).count > 1 ? String(c.split(separator: "=", maxSplits: 1)[1]) : ""
            if value.isEmpty { jar.removeValue(forKey: name) } else { jar[name] = c }
        }
        let merged = jar.values.sorted().joined(separator: "; ")
        if !merged.isBlank && merged != cookie { cookie = merged; onCookie(merged) }
    }
}

/**
 * Client des routes /api/ de Bullarr. La clé part dans l'en-tête X-Api-Key ; Accept:
 * application/json fait renvoyer à Bullarr un 401 JSON plutôt qu'une redirection vers
 * la page de connexion quand la clé manque.
 */
final class BullarrApi: @unchecked Sendable {
    let baseUrl: URL
    let apiKey: String
    let session: SessionAuth?

    static let sharedClient: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 300
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    /// Délégué qui refuse de suivre les redirections : la réponse 3xx elle-même est renvoyée,
    /// comme OkHttp `followRedirects(false)` côté Android. Indispensable pour POST /login/password,
    /// où c'est la redirection qui porte le cookie de session.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static let noRedirectClient: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    init(_ rawBaseUrl: String, apiKey: String, session: SessionAuth? = nil) throws {
        self.baseUrl = try Self.normalizeBaseUrl(rawBaseUrl)
        self.apiKey = apiKey
        self.session = session
    }

    func absoluteUrl(_ path: String) -> String {
        baseUrl.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // --- Requêtes JSON -------------------------------------------------------

    func getJson(_ path: String, query: [String: String] = [:]) async throws -> Any {
        try await withAuthRetry { try await executeOnce("GET", path, query, body: nil) }
    }

    func getObject(_ path: String, query: [String: String] = [:]) async throws -> JSONDict {
        let v = try await getJson(path, query: query)
        guard let o = v as? JSONDict else { throw ApiException("GET \(path) : réponse inattendue (un objet JSON était attendu).") }
        return o
    }

    func getArray(_ path: String, query: [String: String] = [:]) async throws -> [Any] {
        let v = try await getJson(path, query: query)
        guard let a = v as? [Any] else { throw ApiException("GET \(path) : réponse inattendue (une liste JSON était attendue).") }
        return a
    }

    func postObject(_ path: String, _ body: JSONDict) async throws -> JSONDict {
        try await expectObject("POST", path, try await withAuthRetry { try await executeOnce("POST", path, [:], body: body) })
    }

    func putObject(_ path: String, _ body: JSONDict) async throws -> JSONDict {
        try await expectObject("PUT", path, try await withAuthRetry { try await executeOnce("PUT", path, [:], body: body) })
    }

    func deleteObject(_ path: String, _ body: JSONDict? = nil) async throws -> JSONDict {
        try await expectObject("DELETE", path, try await withAuthRetry { try await executeOnce("DELETE", path, [:], body: body) })
    }

    private func expectObject(_ method: String, _ path: String, _ v: Any) throws -> JSONDict {
        guard let o = v as? JSONDict else { throw ApiException("\(method) \(path) : réponse inattendue (un objet JSON était attendu).") }
        return o
    }

    /// Image binaire (page du lecteur). Une réponse JSON d'erreur devient une ApiException lisible.
    func getBytes(_ path: String) async throws -> Data {
        try await withAuthRetry { try await getBytesOnce(path) }
    }

    private func getBytesOnce(_ path: String) async throws -> Data {
        guard let url = URL(string: absoluteUrl(path)) else { throw ApiException("URL invalide : \(path)") }
        var req = URLRequest(url: url)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        applyAuth(&req, method: "GET")
        let label = "GET /\(path.trimmed)"
        let (data, resp) = try await run(Self.sharedClient, req, url: url, label: label)
        guard let http = resp as? HTTPURLResponse else { throw ApiException("\(label) : réponse illisible.") }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
        if (200..<300).contains(http.statusCode) && type.hasPrefix("image/") { return data }
        let text = String(data: data, encoding: .utf8) ?? ""
        let detail = (try? extractError(JSON.parse(text)) as? String).flatMap { $0 }
            ?? ((200..<300).contains(http.statusCode) ? "réponse inattendue (type \(type) au lieu d'une image)" : "erreur HTTP \(http.statusCode)")
        let hint = hint(for: http.statusCode)
        throw ApiException("\(label) : \(detail)\(hint)", code: http.statusCode)
    }

    /// Envoi d'un fichier (formulaire multipart), par ex. la photo de profil ; [fields] : champs texte en plus.
    func postMultipart(_ path: String, field: String, filename: String, bytes: Data, mime: String, fields: [String: String] = [:]) async throws -> JSONDict {
        let boundary = "Bullarr\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8)
        }
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body += bytes
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        let v = try await withAuthRetry { try await executeOnce("POST", path, [:], body: nil, multipart: (body, boundary)) }
        guard let o = v as? JSONDict else { throw ApiException("POST \(path) : réponse inattendue (un objet JSON était attendu).") }
        return o
    }

    /**
     * Session (identifiant ou SSO) : un 401 relance une connexion par mot de passe si les
     * identifiants sont connus ; un 403 « jeton de sécurité » redemande le jeton CSRF.
     */
    private func withAuthRetry<T>(_ block: () async throws -> T) async throws -> T {
        do { return try await block() }
        catch let e as ApiException {
            guard let s = session, apiKey.isBlank else { throw e }
            if e.httpCode == 401 && !s.username.isBlank && !s.password.isBlank {
                _ = try await loginPassword(s.username, s.password)
                return try await block()
            }
            if e.httpCode == 403 && e.message.contains("sécurité") { s.csrf = nil; return try await block() }
            if e.httpCode == 401 {
                throw ApiException("\(e.message)\nSession expirée : reconnectez-vous (Réglages → Accès).", code: 401)
            }
            throw e
        }
    }

    /// Connexion par formulaire (POST /login/password) ; renvoie le cookie de session et le mémorise.
    @discardableResult
    func loginPassword(_ username: String, _ password: String) async throws -> String {
        let url = URL(string: absoluteUrl("login/password"))!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "username=\(urlEncode(username.trimmed))&password=\(urlEncode(password))".data(using: .utf8)
        let (data, resp) = try await run(Self.noRedirectClient, req, url: url, label: "POST /login/password")
        guard let http = resp as? HTTPURLResponse else { throw ApiException("POST /login/password : réponse illisible.") }
        if http.statusCode == 401 && authDisabled() {
            throw ApiException("L'authentification est désactivée sur ce serveur : aucune connexion n'est nécessaire. Choisissez « Clé API », laissez la clé vide et enregistrez.", code: 401)
        }
        if http.statusCode == 401 {
            throw ApiException("POST /login/password : identifiant ou mot de passe incorrect, ou connexion par mot de passe désactivée sur le serveur (Paramètres → Login).", code: 401)
        }
        if !(300..<400).contains(http.statusCode) {
            throw ApiException("POST /login/password : réponse inattendue (HTTP \(http.statusCode)).", code: http.statusCode)
        }
        let cookies = (http.value(forHTTPHeaderField: "Set-Cookie") ?? "").split(separator: ",").map { $0.split(separator: ";").first.map(String.init) ?? "" }.joined(separator: "; ")
        // Set-Cookie peut contenir une seule entrée ; on garde aussi la valeur directe.
        let cookie = cookies.isBlank ? (http.value(forHTTPHeaderField: "Set-Cookie") ?? "").split(separator: ";").first.map(String.init) ?? "" : cookies
        if cookie.isBlank { throw ApiException("POST /login/password : le serveur n'a renvoyé aucun cookie de session.") }
        session?.cookie = cookie
        session?.csrf = nil
        session?.onCookie(cookie)
        return cookie
    }

    /// Vrai si l'API répond sans aucun identifiant (authentification désactivée côté Bullarr).
    private func authDisabled() -> Bool {
        guard let url = URL(string: absoluteUrl("api/libraries")) else { return false }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Self.sharedClient.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse { ok = (200..<300).contains(http.statusCode) }
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    /**
     * Fin d'une connexion SSO faite dans le navigateur : Bullarr redirige vers bullarr://auth?code=…,
     * et POST /api/auth/app-login échange ce code à usage unique contre une session (cookie).
     */
    func exchangeAppCode(_ code: String) async throws -> String {
        let url = URL(string: absoluteUrl("api/auth/app-login"))!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, resp) = try await run(Self.noRedirectClient, req, url: url, label: "POST /api/auth/app-login")
        guard let http = resp as? HTTPURLResponse else { throw ApiException("POST /api/auth/app-login : réponse illisible.") }
        let text = String(data: data, encoding: .utf8) ?? ""
        let detail = (try? extractError(JSON.parse(text)) as? String).flatMap { $0 }
        if http.statusCode == 404 {
            throw ApiException("POST /api/auth/app-login : route absente. Cette version de Bullarr ne gère pas encore la connexion SSO depuis l'app (utilisez « Dans l'app », la clé API ou un compte).", code: 404)
        }
        if !(200..<300).contains(http.statusCode) {
            throw ApiException("POST /api/auth/app-login : \(detail ?? "erreur HTTP \(http.statusCode)")", code: http.statusCode)
        }
        var cookie = (http.value(forHTTPHeaderField: "Set-Cookie") ?? "").split(separator: ";").first.map(String.init) ?? ""
        // Plusieurs cookies possibles : JSONResponse ne peut pas tous les exposer, on récupère le principal.
        if cookie.isBlank, let fields = http.allHeaderFields as? [String: String] {
            cookie = fields["Set-Cookie"] ?? ""
        }
        if cookie.isBlank { throw ApiException("POST /api/auth/app-login : le serveur n'a renvoyé aucune session.") }
        return cookie
    }

    /// Ajoute l'authentification : clé API, sinon cookie de session (+ jeton CSRF hors lecture).
    private func applyAuth(_ req: inout URLRequest, method: String) {
        if !apiKey.isBlank { req.setValue(apiKey.trimmed, forHTTPHeaderField: "X-Api-Key"); return }
        guard let s = session, !s.cookie.isBlank else { return }
        req.setValue(s.cookie, forHTTPHeaderField: "Cookie")
        if method != "GET" && method != "HEAD" {
            let token: String
            if let t = s.csrf { token = t } else { token = (try? fetchCsrf(s)) ?? ""; s.csrf = token }
            req.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        }
    }

    private func fetchCsrf(_ s: SessionAuth) throws -> String {
        let url = URL(string: absoluteUrl("api/auth/csrf"))!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(s.cookie, forHTTPHeaderField: "Cookie")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, ApiException>?
        Self.sharedClient.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(ApiException("GET /api/auth/csrf : HTTP \(http.statusCode)", code: http.statusCode)); return
            }
            guard let data = data, let body = String(data: data, encoding: .utf8), let o = try? JSON.parse(body) as? JSONDict else {
                result = .failure(ApiException("GET /api/auth/csrf : réponse illisible.")); return
            }
            // Le jeton est rangé dans la session : le cookie qui le contient remplace l'ancien.
            var setCookies: [String] = []
            if let http = resp as? HTTPURLResponse, let sc = http.value(forHTTPHeaderField: "Set-Cookie") { setCookies.append(sc) }
            s.absorb(setCookies)
            guard let token = o.str("token"), !token.isBlank else {
                result = .failure(ApiException("GET /api/auth/csrf : jeton absent.")); return
            }
            result = .success(token)
        }.resume()
        sem.wait()
        switch result {
        case .success(let t): return t
        case .failure(let e): throw e
        case nil: throw ApiException("GET /api/auth/csrf : pas de réponse.")
        }
    }

    private func executeOnce(_ method: String, _ path: String, _ query: [String: String], body: JSONDict?, multipart: (Data, String)? = nil) async throws -> Any {
        var comps = URLComponents(string: absoluteUrl(path))!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw ApiException("URL invalide : \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(&req, method: method)
        if let (data, boundary) = multipart {
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
        } else if let body = body {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let label = "\(method) /\(path.trimmed)"
        let (data, resp) = try await run(Self.sharedClient, req, url: url, label: label)
        guard let http = resp as? HTTPURLResponse else { throw ApiException("\(label) : réponse illisible.") }
        if apiKey.isBlank { session?.absorb([http.value(forHTTPHeaderField: "Set-Cookie") ?? ""]) }
        let text = String(data: data, encoding: .utf8) ?? ""
        let parsed = (try? JSON.parse(text)) ?? nil
        guard let parsed, parsed is JSONDict || parsed is [Any] else {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let looksHtml = contentType.contains("html") || text.trimmed.hasPrefix("<")
            let reason: String
            if looksHtml && (http.statusCode == 302 || text.lowercased().contains("login")) {
                reason = "le serveur a renvoyé la page de connexion au lieu de JSON. Vérifiez la clé API."
            } else if looksHtml {
                reason = "le serveur a renvoyé une page HTML au lieu de JSON (HTTP \(http.statusCode)). L'URL pointe-t-elle bien sur Bullarr (sans chemin après le port) ?"
            } else if text.isBlank {
                reason = "réponse vide (HTTP \(http.statusCode))."
            } else {
                let cut = text.count > 160 ? String(text.prefix(160)) : text
                reason = "réponse illisible (HTTP \(http.statusCode)) : \(cut)"
            }
            throw ApiException("\(label) : \(reason)", code: http.statusCode)
        }
        var error: String?
        var failed = false
        if let o = parsed as? JSONDict {
            error = extractError(o)
            if o["success"] != nil, let b = o.bool("success"), !b { failed = true }
        }
        if !(200..<300).contains(http.statusCode) || failed {
            let detail = error ?? "erreur HTTP \(http.statusCode)"
            throw ApiException("\(label) : \(detail)\(hint(for: http.statusCode))", code: http.statusCode)
        }
        return parsed
    }

    private func hint(for code: Int) -> String {
        switch code {
        case 401: return "\nGénérez une clé dans Bullarr : Paramètres → Login → Accès API."
        case 403: return "\nAccès refusé par le serveur."
        case 404: return "\nRoute introuvable sur ce serveur (version de Bullarr trop ancienne ?)."
        case 500...599: return "\nErreur interne de Bullarr (HTTP \(code))."
        default: return ""
        }
    }

    private func extractError(_ obj: Any) -> String? {
        guard let o = obj as? JSONDict else { return nil }
        let raw = o["error"] ?? o["message"]
        guard let raw, !(raw is NSNull) else { return nil }
        if let s = raw as? String { return s.isBlank ? nil : s }
        if let v = raw as? NSNumber { return v.stringValue.isBlank ? nil : v.stringValue }
        return nil
    }

    private func run(_ client: URLSession, _ req: URLRequest, url: URL, label: String) async throws -> (Data, URLResponse) {
        do {
            return try await client.data(for: req)
        } catch let e as URLError {
            throw ApiException(networkMessage(e, url: url), code: nil)
        } catch {
            throw ApiException("\(label) : \(readable(error))")
        }
    }

    private func networkMessage(_ e: URLError, url: URL) -> String {
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Serveur introuvable : « \(url.host ?? "?") ». Vérifiez l'URL et que le téléphone est sur le bon réseau (Wi-Fi local, VPN…)."
        case .cannotConnectToHost:
            return "Connexion refusée par \(url.host ?? "?"):\(url.port ?? 0). Bullarr est-il démarré et le port correct ?"
        case .timedOut:
            return "Le serveur ne répond pas (délai dépassé) : \(url.host ?? "?"):\(url.port ?? 0)."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Erreur HTTPS (\(e.localizedDescription)). Si le serveur n'a pas de certificat, utilisez http://."
        default:
            return "Erreur réseau vers \(url.host ?? "?") : \(e.localizedDescription)"
        }
    }

    /// « monserveur:4000 » → « http://monserveur:4000/ » ; lève ApiException si invalide.
    static func normalizeBaseUrl(_ raw: String) throws -> URL {
        var s = raw.trimmed
        if s.isEmpty { throw ApiException("Indiquez l'URL du serveur Bullarr.") }
        if !s.contains("://") { s = "http://\(s)" }
        if !s.hasSuffix("/") { s += "/" }
        guard let url = URL(string: s), url.host != nil else {
            throw ApiException("URL invalide : « \(raw.trimmed) ». Exemple : http://192.168.1.10:4000")
        }
        return url
    }
}

func urlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
