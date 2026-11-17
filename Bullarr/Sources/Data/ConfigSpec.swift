import Foundation

// Configuration de Bullarr : chaque réglage est lu avec GET <path> et écrit avec POST <path>.
// Les formats et les règles d'écriture viennent de blueprints/*/routes.py (voir README).

protocol FieldProtocol { var key: String { get }; var label: String { get }; var showWhen: (String, [String])? { get } }

struct FText: FieldProtocol {
    let key: String, label: String
    var hint: String? = nil
    var url: Bool = false
    var showWhen: (String, [String])? = nil
    init(_ key: String, _ label: String, hint: String? = nil, url: Bool = false, showWhen: (String, [String])? = nil) {
        self.key = key; self.label = label; self.hint = hint; self.url = url; self.showWhen = showWhen
    }
}
struct FNumber: FieldProtocol { let key: String, label: String; var showWhen: (String, [String])? { nil }; init(_ key: String, _ label: String) { self.key = key; self.label = label } }
struct FSwitch: FieldProtocol { let key: String, label: String; var help: String? = nil; var showWhen: (String, [String])? { nil }; init(_ key: String, _ label: String, help: String? = nil) { self.key = key; self.label = label; self.help = help } }
/// Secret : jamais relu en clair. Laissé vide = inchangé ; le serveur ne l'écrase que s'il est renseigné.
struct FSecret: FieldProtocol {
    let key: String, label: String
    var keepMasked: Bool = false
    var showWhen: (String, [String])? = nil
    init(_ key: String, _ label: String, keepMasked: Bool = false, showWhen: (String, [String])? = nil) {
        self.key = key; self.label = label; self.keepMasked = keepMasked; self.showWhen = showWhen
    }
}
struct FChoice: FieldProtocol { let key: String, label: String; let options: [(String, String)]; var showWhen: (String, [String])? { nil }; init(_ key: String, _ label: String, _ options: [(String, String)]) { self.key = key; self.label = label; self.options = options } }
/// Liste ordonnée dont seul l'ordre se règle (priorité des sources).
struct FOrder: FieldProtocol { let key: String, label: String; let names: [String: String]; var help: String? = nil; var showWhen: (String, [String])? { nil }; init(_ key: String, _ label: String, _ names: [String: String], help: String? = nil) { self.key = key; self.label = label; self.names = names; self.help = help } }
/// Sous-ensemble choisi parmi des options.
struct FMulti: FieldProtocol { let key: String, label: String; let options: [(String, String)]; var showWhen: (String, [String])? { nil }; init(_ key: String, _ label: String, _ options: [(String, String)]) { self.key = key; self.label = label; self.options = options } }
/// Liste de valeurs saisies séparées par des virgules.
struct FList: FieldProtocol { let key: String, label: String; var hint: String? = nil; var showWhen: (String, [String])? { nil }; init(_ key: String, _ label: String, hint: String? = nil) { self.key = key; self.label = label; self.hint = hint } }

/// [sendConfig] : le test reçoit la configuration enregistrée (ntfy teste les valeurs envoyées).
struct TestCall { let post: Bool; let path: String; var label: String = "Tester"; var note: String? = nil; var sendConfig: Bool = false }

struct Integration {
    let id: String
    let title: String
    let path: String
    let fields: [FieldBox]
    var test: TestCall? = nil
    var help: String? = nil
    /// Phrase d'état tirée de la réponse (ex. nombre d'indexeurs).
    var info: ((JSONDict) -> String?)? = nil
}

/// Boîte type-erased pour les champs (les enums avec données associées rendraient la portation fastidieuse).
enum FieldBox {
    case text(FText), number(FNumber), switchField(FSwitch), secret(FSecret), choice(FChoice), order(FOrder), multi(FMulti), list(FList)

    var field: any FieldProtocol {
        switch self {
        case .text(let f): return f
        case .number(let f): return f
        case .switchField(let f): return f
        case .secret(let f): return f
        case .choice(let f): return f
        case .order(let f): return f
        case .multi(let f): return f
        case .list(let f): return f
        }
    }
}

let SOURCE_NAMES: [String: String] = [
    "prowlarr": "Prowlarr", "ebdz": "EBDZ", "telegram": "Telegram",
    "fourtoutici": "Fourtoutici", "vk": "VK", "annas_archive": "Anna's Archive",
]

private let ENABLED = FieldBox.switchField(FSwitch("enabled", "Activé"))

let CLIENTS: [Integration] = [
    Integration(
        id: "amule", title: "aMule / eMule", path: "api/emule/config",
        fields: [
            ENABLED,
            FieldBox.choice(FChoice("type", "Type de client", [("amule", "aMule (Linux/Mac)"), ("emule", "eMule (Windows)")])),
            FieldBox.text(FText("host", "Hôte")),
            FieldBox.number(FNumber("ec_port", "Port EC")),
            FieldBox.secret(FSecret("password", "Mot de passe EC")),
        ],
        test: TestCall(post: false, path: "api/emule/test"),
    ),
    Integration(
        id: "qbittorrent", title: "qBittorrent", path: "api/qbittorrent/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("url", "URL", hint: "https://qbittorrent.exemple.fr", url: true)),
            FieldBox.number(FNumber("port", "Port")),
            FieldBox.text(FText("username", "Utilisateur")),
            FieldBox.secret(FSecret("password", "Mot de passe")),
            FieldBox.text(FText("default_category", "Catégorie par défaut", hint: "BD")),
        ],
        test: TestCall(post: true, path: "api/qbittorrent/test"),
    ),
    Integration(
        id: "rtorrent", title: "rTorrent", path: "api/rtorrent/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("url", "URL", url: true)),
            FieldBox.number(FNumber("port", "Port")),
            FieldBox.text(FText("rpc_path", "Chemin RPC", hint: "/RPC2")),
            FieldBox.text(FText("username", "Utilisateur")),
            FieldBox.secret(FSecret("password", "Mot de passe")),
        ],
        test: TestCall(post: true, path: "api/rtorrent/test"),
    ),
    Integration(
        id: "deluge", title: "Deluge", path: "api/deluge/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("url", "URL", url: true)),
            FieldBox.number(FNumber("port", "Port")),
            FieldBox.secret(FSecret("password", "Mot de passe")),
        ],
        test: TestCall(post: true, path: "api/deluge/test"),
    ),
    Integration(
        id: "shelfmark", title: "Shelfmark", path: "api/shelfmark/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("base_url", "URL", hint: "https://shelfmark.exemple.fr", url: true)),
            FieldBox.text(FText("username", "Utilisateur")),
            FieldBox.secret(FSecret("password", "Mot de passe")),
        ],
        test: TestCall(post: true, path: "api/shelfmark/test"),
    ),
    Integration(
        id: "komga", title: "Komga", path: "api/komga/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("url", "URL", hint: "https://komga.exemple.fr", url: true)),
            FieldBox.secret(FSecret("api_key", "Clé API")),
            FieldBox.switchField(FSwitch("sync_read_progress", "Synchroniser la lecture", help: "Avancement de lecture partagé entre Komga et Bullarr.")),
        ],
        test: TestCall(post: true, path: "api/komga/test"),
        help: "Compte Komga du serveur (administrateur). Chaque lecteur peut relier son propre compte dans ses Réglages → Intégrations.",
    ),
]

let INDEXERS: [Integration] = [
    Integration(
        id: "ebdz", title: "EBDZ — compte", path: "api/ebdz/config",
        fields: [
            FieldBox.text(FText("username", "Identifiant")),
            FieldBox.secret(FSecret("password", "Mot de passe")),
        ],
        help: "Les forums à indexer restent tels quels (ils se règlent dans l'interface web).",
    ),
    Integration(
        id: "ebdz_auto", title: "EBDZ — scraping automatique", path: "api/ebdz/auto-scrape/config",
        fields: [
            FieldBox.switchField(FSwitch("auto_scrape_enabled", "Scraper automatiquement")),
            FieldBox.number(FNumber("auto_scrape_interval", "Intervalle")),
            FieldBox.choice(FChoice("auto_scrape_interval_unit", "Unité", [("minutes", "Minutes"), ("hours", "Heures"), ("days", "Jours")])),
        ],
    ),
    Integration(
        id: "prowlarr", title: "Prowlarr", path: "api/prowlarr/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("url", "URL", hint: "https://prowlarr.exemple.fr", url: true)),
            FieldBox.number(FNumber("port", "Port")),
            FieldBox.secret(FSecret("api_key", "Clé API")),
        ],
        test: TestCall(post: false, path: "api/prowlarr/test"),
        help: "Le choix des indexeurs à interroger se fait dans l'interface web.",
        info: { c in (c.array("selected_indexers")?.count).map { "\($0) indexeur(s) sélectionné(s)" } },
    ),
    Integration(
        id: "fourtoutici", title: "Fourtoutici", path: "api/fourtoutici/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("base_url", "URL du site", url: true)),
        ],
        test: TestCall(post: false, path: "api/fourtoutici/test"),
    ),
    Integration(
        id: "annas", title: "Anna's Archive", path: "api/annas-archive/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("base_url", "URL du site", url: true)),
        ],
        test: TestCall(post: false, path: "api/annas-archive/test"),
    ),
    Integration(
        id: "vk", title: "VK — Au Phil des Bulles", path: "api/vk/config",
        fields: [
            ENABLED,
            FieldBox.text(FText("base_url", "URL du forum", url: true)),
        ],
        test: TestCall(post: false, path: "api/vk/test"),
        info: { c in (c.dict("index")?.int("series")).map { "Index : \($0) séries" } },
    ),
]

/// Canal ntfy du serveur (topic ntfy.sh ou auto-hébergé), comme la carte ntfy de la page de réglages.
let NTFY_CHANNEL = Integration(
    id: "ntfy", title: "ntfy", path: "api/ntfy/config",
    fields: [
        ENABLED,
        FieldBox.text(FText("server_url", "Serveur", hint: "https://ntfy.sh", url: true)),
        FieldBox.text(FText("topic", "Topic", hint: "ex : bullarr-7f3k9q")),
        FieldBox.choice(FChoice("auth", "Authentification", [("none", "Aucune"), ("token", "Jeton d'accès"), ("basic", "Identifiant et mot de passe")])),
        // Comme sur le site : jeton ou identifiant et mot de passe selon l'authentification choisie.
        FieldBox.secret(FSecret("token", "Jeton d'accès", keepMasked: true, showWhen: ("auth", ["token"]))),
        FieldBox.text(FText("username", "Identifiant", showWhen: ("auth", ["basic"]))),
        FieldBox.secret(FSecret("password", "Mot de passe", keepMasked: true, showWhen: ("auth", ["basic"]))),
        FieldBox.choice(FChoice("priority", "Priorité", [("1", "Minimale"), ("2", "Basse"), ("3", "Normale"), ("4", "Haute"), ("5", "Urgente")])),
    ],
    test: TestCall(post: true, path: "api/ntfy/test", label: "Envoyer une notification test", note: "Envoie une vraie notification au topic enregistré.", sendConfig: true),
    help: "Sur ntfy.sh, un topic est public : choisissez un nom difficile à deviner, puis abonnez-vous-y dans l'app ntfy.",
)

let NOTIFICATIONS: [Integration] = [
    Integration(
        id: "telegram", title: "Telegram (bot)", path: "api/telegram/config",
        // Les évènements à envoyer se cochent dans le tableau de l'onglet Notifications.
        fields: [
            ENABLED,
            FieldBox.secret(FSecret("bot_token", "Jeton du bot")),
            FieldBox.text(FText("chat_id", "Identifiant du chat")),
        ],
        test: TestCall(post: true, path: "api/telegram/test", label: "Envoyer un message test", note: "Envoie un vrai message au chat configuré (réglages enregistrés)."),
    ),
]

private let IMPORT = "api/import/config"

let IMPORTS: [Integration] = [
    Integration(
        id: "rename", title: "Format de renommage", path: "api/settings/rename",
        fields: [
            FieldBox.text(FText("volume_template", "Modèle d'un tome")),
            FieldBox.text(FText("oneshot_template", "Modèle d'un one-shot")),
            FieldBox.text(FText("series_template", "Modèle du dossier de série")),
        ],
        help: "Laissez vide pour revenir au format par défaut. Les variables disponibles sont décrites dans l'interface web.",
    ),
    Integration(
        id: "import", title: "Import automatique", path: IMPORT,
        fields: [
            FieldBox.switchField(FSwitch("auto_import_enabled", "Importer automatiquement", help: "Importe un fichier dès qu'il est prêt et assigné à une série.")),
            FieldBox.switchField(FSwitch("auto_assign_enabled", "Assigner automatiquement")),
            FieldBox.switchField(FSwitch("auto_convert_to_cbz", "Convertir en CBZ", help: "PDF et ZIP nus convertis à l'import.")),
            FieldBox.list(FList("monitored_extensions", "Extensions surveillées", hint: ".cbz, .cbr, .zip, .rar, .pdf")),
        ],
    ),
]

let SEARCH_SETTINGS: [Integration] = [
    Integration(
        id: "order", title: "Ordre des sources", path: IMPORT,
        fields: [
            FieldBox.order(FOrder("auto_acquire_sources", "Priorité de la recherche automatique", SOURCE_NAMES,
                help: "La source du haut est essayée en premier.")),
        ],
    ),
    Integration(
        id: "blocked", title: "Extensions désactivées", path: IMPORT,
        fields: [
            FieldBox.list(FList("blocked_search_extensions", "Extensions ignorées dans les résultats", hint: "epub, mobi, mkv")),
        ],
    ),
    Integration(
        id: "series", title: "Création de séries", path: IMPORT,
        fields: [
            FieldBox.switchField(FSwitch("create_series_folder_on_add", "Créer le dossier à l'ajout d'une série")),
        ],
    ),
    Integration(
        id: "auto", title: "Recherche automatique", path: IMPORT,
        fields: [
            FieldBox.switchField(FSwitch("auto_acquire_on_add_enabled", "Chercher à l'ajout d'une série")),
            FieldBox.switchField(FSwitch("auto_acquire_pack_search_enabled", "Chercher aussi les packs")),
            FieldBox.switchField(FSwitch("prioritize_black_and_white", "Préférer le noir et blanc")),
        ],
    ),
]

let MONITOR: [Integration] = [
    Integration(
        id: "monitor", title: "Surveillance des volumes", path: "api/missing-monitor/config",
        fields: [
            FieldBox.switchField(FSwitch("monitor_missing_volumes.enabled", "Volumes manquants", help: "Valable pour les séries activées dans Actions → Surveillance.")),
            FieldBox.switchField(FSwitch("quality_upgrade.enabled", "Upgrade de qualité", help: "Remplace un fichier par un meilleur.")),
            FieldBox.number(FNumber("quality_upgrade.min_size_increase_percent", "Augmentation de taille minimale (%)")),
        ],
    ),
]

// --- Lecture / écriture JSON -------------------------------------------------

/// Valeur de départ d'un champ, telle qu'affichée : String, Bool ou [String].
func initialValue(_ box: FieldBox, _ o: JSONDict) -> Any {
    let f = box.field
    switch box {
    case .switchField:
        if let v = o.getPath(f.key) as? Bool { return v }
        if let n = o.getPath(f.key) as? NSNumber { return n.intValue != 0 }
        return false
    case .secret: return ""
    case .list:
        return ((o.getPath(f.key) as? [Any])?.strings() ?? []).joined(separator: ", ")
    case .order, .multi:
        return ((o.getPath(f.key) as? [Any])?.strings() ?? [])
    default:
        if let v = o.getPath(f.key) as? String { return v }
        if let n = o.getPath(f.key) as? NSNumber { return n.stringValue }
        if let b = o.getPath(f.key) as? Bool { return b ? "true" : "false" }
        return ""
    }
}

func secretIsSet(_ f: FSecret, _ o: JSONDict) -> Bool {
    guard let v = o.getPath(f.key) else { return false }
    if let b = v as? Bool { return b }
    if let s = v as? String { return !s.isEmpty }
    return false
}

/**
 * Corps du POST : l'état actuel du serveur, avec seulement les champs modifiés appliqués.
 * Les secrets non modifiés sont envoyés vides : le serveur les laisse alors tels quels.
 */
func buildPayload(_ spec: Integration, _ fresh: JSONDict, _ initial: [String: Any], _ edited: [String: Any]) throws -> JSONDict {
    var body = fresh
    for box in spec.fields {
        let f = box.field
        guard let now = edited[f.key] else { continue }
        let changed = !anyEqual(now, initial[f.key])
        switch box {
        case .secret(let fs):
            if changed { body.putPath(f.key, now as? String ?? "") }
            else if fs.keepMasked { body.putPath(f.key, (fresh.getPath(f.key) as? String) ?? "") }
            else { body.putPath(f.key, "") }
        default:
            if !changed { continue }
            switch box {
            case .switchField: body.putPath(f.key, now as? Bool ?? false)
            case .number:
                let t = (now as? String ?? "").trimmed
                if t.isEmpty { body.putPath(f.key, nil) }
                else if let n = Int(t) { body.putPath(f.key, n) }
                else { throw ApiException("« \(f.label) » doit être un nombre entier.") }
            case .list:
                let values = (now as? String ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                body.putPath(f.key, values)
            case .order:
                body.putPath(f.key, now as? [String] ?? [])
            case .multi:
                let sel = now as? [String] ?? []
                let kept = ((fresh.getPath(f.key) as? [Any])?.strings() ?? []).filter { sel.contains($0) }
                body.putPath(f.key, kept + sel.filter { !kept.contains($0) })
            case .text: body.putPath(f.key, (now as? String ?? "").trimmed)
            case .choice: body.putPath(f.key, now as? String ?? "")
            default: break
            }
        }
    }
    return body
}

func anyEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let x as String, let y as String): return x == y
    case (let x as Bool, let y as Bool): return x == y
    case (let x as [String], let y as [String]): return x == y
    default: return false
    }
}

/// Accès à Bullarr (mot de passe, SSO). La clé API reste valable quel que soit le mode.
let ACCESS: [Integration] = [
    Integration(
        id: "login", title: "Authentification du serveur", path: "api/auth/config",
        fields: [
            FieldBox.choice(FChoice("mode", "Authentification", [("none", "Aucune"), ("password", "Mot de passe"), ("oidc", "SSO (OIDC)"), ("both", "Mot de passe + SSO")])),
            FieldBox.text(FText("username", "Identifiant")),
            FieldBox.secret(FSecret("password", "Nouveau mot de passe")),
            FieldBox.text(FText("issuer", "URL de l'issuer SSO", hint: "https://sso.exemple.fr", url: true)),
            FieldBox.text(FText("client_id", "Client ID")),
            FieldBox.secret(FSecret("client_secret", "Client secret")),
            FieldBox.text(FText("scopes", "Scopes", hint: "openid profile email")),
            FieldBox.switchField(FSwitch("auto_redirect", "Aller directement au SSO", help: "Saute le formulaire de connexion de la page web.")),
        ],
        help: "Attention : avec « Aucune », tout le monde accède à Bullarr. L'app continue de fonctionner avec la clé API quel que soit le mode.",
    ),
]
