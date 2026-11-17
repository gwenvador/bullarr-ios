import Foundation
import Security

/// URL du serveur, clé API, identifiants et session, chiffrés par le trousseau iOS
/// (équivalent d'EncryptedSharedPreferences côté Android, clé maître dans le Keystore).
final class SecureStore {
    private let service = "io.github.gwenvador.bullarr"
    private let access = kSecClassGenericPassword

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: access, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func read(_ key: String) -> String {
        var item = base(key)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete(_ key: String) { SecItemDelete(base(key) as CFDictionary) }
}

/// Réglages de connexion de l'app. Les secrets vivent dans le trousseau (SecureStore) ;
/// `lastUrl` seul reste en UserDefaults pour préremplir l'écran de connexion.
final class Settings {
    static let shared = Settings()
    private let store = SecureStore()
    private let defaults = UserDefaults.standard

    var serverUrl: String {
        get { store.read("server_url") }
        set { if newValue.isBlank { store.delete("server_url") } else { store.write("server_url", newValue) } }
    }

    var apiKey: String {
        get { store.read("api_key") }
        set { if newValue.isBlank { store.delete("api_key") } else { store.write("api_key", newValue) } }
    }

    /// "key" (clé API), "password" (identifiant) ou "oidc" (SSO).
    var authMode: String {
        get { defaults.string(forKey: "auth_mode") ?? "key" }
        set { defaults.set(newValue, forKey: "auth_mode") }
    }

    var username: String {
        get { store.read("username") }
        set { if newValue.isBlank { store.delete("username") } else { store.write("username", newValue) } }
    }

    var password: String {
        get { store.read("password") }
        set { if newValue.isBlank { store.delete("password") } else { store.write("password", newValue) } }
    }

    var sessionCookie: String {
        get { store.read("session_cookie") }
        set { if newValue.isBlank { store.delete("session_cookie") } else { store.write("session_cookie", newValue) } }
    }

    /// Dernière URL utilisée, gardée après une déconnexion pour préremplir l'écran de connexion.
    var lastUrl: String {
        get { defaults.string(forKey: "last_url") ?? "" }
        set { defaults.set(newValue, forKey: "last_url") }
    }

    var isConfigured: Bool { !serverUrl.isBlank }
}

/// Client Bullarr d'après les réglages enregistrés ; nil si rien n'est configuré.
func apiFromSettings(_ settings: Settings) -> BullarrApi? {
    guard settings.isConfigured else { return nil }
    if settings.authMode == "key" {
        return try? BullarrApi(settings.serverUrl, apiKey: settings.apiKey)
    }
    let auth = SessionAuth(
        cookie: settings.sessionCookie,
        username: settings.authMode == "password" ? settings.username : "",
        password: settings.authMode == "password" ? settings.password : "",
        onCookie: { settings.sessionCookie = $0 },
    )
    return try? BullarrApi(settings.serverUrl, apiKey: "", session: auth)
}
