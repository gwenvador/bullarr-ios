import Foundation
import SwiftUI

/**
 * État global de l'app (équivalent d'AppViewModel côté Android) : connexion, bibliothèque en
 * cache, rubriques, badges, lecteur, téléchargements hors ligne, recherche et envois.
 */
@MainActor
final class AppState: ObservableObject {
    let settings = Settings.shared

    // --- Connexion ------------------------------------------------------------

    @Published var api: BullarrApi?

    /// Compte connecté (/api/auth/me) : rôle, nom et avatar. Un lecteur ne voit que la
    /// bibliothèque, ses demandes et quelques réglages (le serveur lui refuse le reste).
    @Published var role: String?
    @Published var profileName: String?
    @Published var avatarUrl: String?
    var isReader: Bool { role == "reader" }

    // --- Navigation ------------------------------------------------------------

    @Published var section: Section = .library
    @Published var subTab: [Section: Int] = [:]
    /// Fiche série ouverte par-dessus la rubrique courante.
    @Published var openSeries: SeriesSummary?
    /// Tome ouvert dans le lecteur plein écran, par-dessus toute l'app.
    @Published var reading: ReaderTarget?

    /// Incrémenté à la fermeture du lecteur : les listes relisent l'état de lecture.
    @Published var progressVersion: Int = 0

    // --- SSO -------------------------------------------------------------------

    @Published var ssoBusy = false
    @Published var ssoError: String?

    // --- Bibliothèque ----------------------------------------------------------

    /// Cache disque de la bibliothèque (liste des bibliothèques et séries de chacune), propre au
    /// serveur et au compte : affichée tout de suite au lancement, puis rafraîchie par le réseau.
    private let libCacheDir: URL
    private var seriesByLibrary: [Int: [SeriesSummary]] = [:]
    /// Dernières fiches de série ouvertes (albums compris), pour les rouvrir sans attendre.
    private var seriesDetailCache: [Int: SeriesDetail] = [:]
    private var seriesDetailOrder: [Int] = []

    @Published var libraries: [Library] = []
    @Published var selectedLibrary: Library?
    @Published var series: [SeriesSummary] = []
    /// Séries ajoutées depuis Bédéthèque pendant la session (url) : restent « ajoutées » même si le serveur ne le sait pas encore.
    @Published var addedBedethequeUrls: Set<String> = []
    @Published var libraryLoading = false
    @Published var libraryError: String?

    /// « Continuer la lecture » lu dans Komga, gardé d'une page à l'autre ; nil tant qu'il n'est pas chargé.
    @Published var keepReading: [RecentRead]?
    /// Komga désactivé ou serveur injoignable : on montre les albums commencés sur l'appareil.
    @Published var keepReadingLocal = false

    lazy var reads = ReadingProgress()

    // --- Recherche de la bibliothèque -----------------------------------------

    @Published var query = ""
    /// Où cherche la recherche de la bibliothèque : nom de la série (titre, auteur, univers) et/ou tags.
    @Published var searchInName = true
    @Published var searchInTags = true
    @Published var filters = LibraryFilters()
    /// Séries dans l'ordre affiché par la bibliothèque : le glissement passe à la voisine.
    var visibleSeries: [SeriesSummary] = []

    @Published var sort: LibrarySort {
        didSet { libPrefs.set(sort.rawValue, forKey: "sort") }
    }
    @Published var sortDesc: Bool {
        didSet { libPrefs.set(sortDesc, forKey: "sortDesc") }
    }
    /// Bibliothèque en grille de couvertures plutôt qu'en liste ; conservé entre les ouvertures.
    @Published var libraryGrid: Bool {
        didSet { libPrefs.set(libraryGrid, forKey: "grid") }
    }
    /// Largeur minimale d'une miniature de la grille (pt), réglée par le curseur ; conservée sur l'appareil.
    @Published var libraryCellSize: CGFloat {
        didSet { libPrefs.set(Double(libraryCellSize), forKey: "cellSize") }
    }

    private let libPrefs = UserDefaults.standard

    // --- Badges ----------------------------------------------------------------

    /// Pastilles des onglets de Suivi (mêmes sources que les badges du web : nav.js).
    @Published var requestCount = 0
    @Published var reviewCount = 0
    @Published var importCount = 0
    @Published var newsCount = 0
    @Published var activityCount = 0
    private let badgePrefs = UserDefaults.standard

    // --- Sous-systèmes ---------------------------------------------------------

    /// Albums copiés pour la lecture hors ligne.
    lazy var offline = OfflineManager(apiProvider: { [weak self] in self?.api })
    lazy var search = SearchState(apiProvider: { [weak self] in self?.api })
    lazy var downloads = DownloadController(apiProvider: { [weak self] in self?.api })

    // --- Version ---------------------------------------------------------------

    /// Version installée (CFBundleShortVersionString) et build.
    lazy var installedVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }()
    private lazy var installedName: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }()

    @Published var update: UpdateState = .idle

    init() {
        libCacheDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: libCacheDir, withIntermediateDirectories: true)
        let sortRaw = libPrefs.string(forKey: "sort")
        sort = sortRaw.flatMap { LibrarySort(rawValue: $0) } ?? .date
        sortDesc = libPrefs.object(forKey: "sortDesc") as? Bool ?? LibrarySort.date.defaultDesc
        libraryGrid = libPrefs.bool(forKey: "grid")
        libraryCellSize = CGFloat(libPrefs.double(forKey: "cellSize").isZero ? 108 : libPrefs.double(forKey: "cellSize"))
        api = apiFromSettings(settings)
        // Débogage : `--bullarr-demo:<url>` branche l'app sur un faux serveur (simulateur seulement).
        for a in ProcessInfo.processInfo.arguments where a.hasPrefix("--bullarr-demo:") {
            let url = String(a.dropFirst("--bullarr-demo:".count))
            guard !url.isBlank else { break }
            // Direct, sans le trousseau (SecureStore peut échouer en silence dans le simulateur).
            api = try? BullarrApi(url, apiKey: "demo")
            let line = "[DEMO] url=\(url) api=\(api != nil)\n"
            if let d = line.data(using: .utf8) {
                var out = Data()
                if let old = FileManager.default.contents(atPath: "/tmp/bullarr_demo.log") { out = old }
                out.append(d)
                try? out.write(to: URL(fileURLWithPath: "/tmp/bullarr_demo.log"))
            }
            // `--bullarr-reader:<id>` : ouvre le lecteur directement sur ce tome.
            for b in ProcessInfo.processInfo.arguments where b.hasPrefix("--bullarr-reader:") {
                if let id = Int(String(b.dropFirst("--bullarr-reader:".count))) {
                    reading = ReaderTarget(volumeId: id, title: "Démo")
                }
            }
            // `--bullarr-config:<i>` : ouvre directement le i-ème sous-écran des Réglages.
            for b in ProcessInfo.processInfo.arguments where b.hasPrefix("--bullarr-config:") {
                if let i = Int(String(b.dropFirst("--bullarr-config:".count))) {
                    section = .config
                    subTab[.config] = i
                }
            }
            // `--bullarr-search:<titre>` : ouvre la recherche avec ce titre (simulateur).
            for b in ProcessInfo.processInfo.arguments where b.hasPrefix("--bullarr-search:") {
                let q = String(b.dropFirst("--bullarr-search:".count))
                if !q.isBlank { section = .search; search.title = q }
            }
            // `--bullarr-tab:<section>:<i>` : ouvre le i-ème sous-écran d'une rubrique (simulateur).
            for b in ProcessInfo.processInfo.arguments where b.hasPrefix("--bullarr-tab:") {
                let parts = String(b.dropFirst("--bullarr-tab:".count)).split(separator: ":")
                if let s = Section(rawValue: String(parts.first ?? "")), let i = parts.last.flatMap({ Int($0) }) {
                    section = s
                    subTab[s] = i
                }
            }
        }
    }

    // --- Enregistrement / déconnexion -----------------------------------------

    /// Enregistre le serveur et le mode d'accès ; [cookie] = session déjà ouverte (identifiant ou SSO).
    func save(url: String, key: String, mode: String = "key", user: String = "", pass: String = "", cookie: String = "") {
        settings.serverUrl = url.trimmed
        settings.apiKey = mode == "key" ? key.trimmed : ""
        settings.authMode = mode
        settings.username = user.trimmed
        settings.password = pass
        settings.sessionCookie = cookie
        api = apiFromSettings(settings)
        seriesByLibrary.removeAll()
        seriesDetailCache.removeAll()
        libraries = []
        series = []
        libraryError = nil
        selectedLibrary = nil
        role = nil
        profileName = nil
        avatarUrl = nil
    }

    /// Oublie la clé, la session et les identifiants (et prévient Bullarr si une session était ouverte).
    func logout() {
        let old = api
        let hadSession = settings.authMode != "key" && !settings.sessionCookie.isBlank
        settings.lastUrl = settings.serverUrl
        if hadSession, let old {
            let cookie = settings.sessionCookie
            Task.detached {
                var req = URLRequest(url: URL(string: old.absoluteUrl("logout"))!)
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
                _ = try? await BullarrApi.sharedClient.data(for: req)
            }
        }
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        clearLibCache()
        seriesByLibrary.removeAll()
        seriesDetailCache.removeAll()
        settings.serverUrl = ""
        settings.apiKey = ""
        settings.authMode = "key"
        settings.username = ""
        settings.password = ""
        settings.sessionCookie = ""
        api = nil
        libraries = []
        series = []
        libraryError = nil
        selectedLibrary = nil
        role = nil
        profileName = nil
        avatarUrl = nil
        section = .library
        CoverLoader.shared.clearDisk()
    }

    /// Appelé quand le navigateur renvoie bullarr://auth?code=… : échange le code et ouvre la session.
    func completeSso(code: String) {
        let url = settings.serverUrl.isBlank ? settings.lastUrl : settings.serverUrl
        if url.isBlank { ssoError = "URL du serveur inconnue : saisissez-la puis relancez le SSO."; return }
        ssoBusy = true
        ssoError = nil
        Task {
            do {
                let probe = try BullarrApi(url, apiKey: "", session: SessionAuth(cookie: ""))
                let cookie = try await probe.exchangeAppCode(code)
                let check = try BullarrApi(url, apiKey: "", session: SessionAuth(cookie: cookie))
                let me = try await check.getObject("api/auth/me")
                if me.dict("user") == nil { throw ApiException("Le serveur n'a pas reconnu la session SSO.") }
                save(url: url, key: "", mode: "oidc", cookie: cookie)
            } catch {
                ssoError = readable(error)
            }
            ssoBusy = false
        }
    }

    // --- Cache disque bibliothèque --------------------------------------------

    private func libCacheFile(_ name: String) -> URL {
        let who = "\(settings.serverUrl)|\(settings.authMode)|\(settings.username)|\(settings.apiKey.hashValue)"
        let h = HexSha1.of(who).prefix(16)
        return libCacheDir.appendingPathComponent("\(h)_\(name).json")
    }

    private func readLibCache(_ name: String) -> [Any]? {
        guard let data = try? Data(contentsOf: libCacheFile(name)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return arr
    }

    private func writeLibCache(_ name: String, _ a: [Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: a) {
            try? data.write(to: libCacheFile(name))
        }
    }

    private func clearLibCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: libCacheDir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    // --- Compte ----------------------------------------------------------------

    func loadMe() async {
        guard let client = api else { return }
        if let me = try? await client.getObject("api/auth/me") {
            role = me.str("role").ifBlank("admin")
            let p = me.dict("profile")
            let u = me.dict("user")
            profileName = p?.str("name").ifBlank(nil) ?? u?.str("name").ifBlank(nil) ?? u?.str("email").ifBlank(nil)
            avatarUrl = p?.str("avatar_url").ifBlank(nil)
            if isReader && !sections.contains(section) {
                section = .library
                openSeries = nil
            }
        }
    }

    /// Rubriques de la barre du bas selon le rôle.
    var sections: [Section] {
        isReader ? [.library, .requests, .config] : [.library, .search, .tracking, .actions, .config]
    }

    /// Sous-onglets d'une rubrique selon le rôle (les réglages du serveur sont réservés aux administrateurs).
    func subsOf(_ s: Section) -> [String] {
        // (Pas d'« Upscaling » pour les lecteurs : le serveur seul gère l'upscaling, iOS ne l'expose pas.)
        if s == .config && isReader { return ["Profil", "Intégrations", "Apparence", "À propos"] }
        return s.subs
    }

    func openSeriesById(_ id: Int, _ title: String) {
        openSeries = series.first { $0.id == id }
            ?? SeriesSummary(id: id, title: title, author: nil, year: nil, coverPath: nil, ownedTomes: 0, totalKnown: nil, missingCount: 0, isOneshot: false, searchKey: "")
    }

    func goToSearch() {
        openSeries = nil
        section = .search
    }

    /**
     * Lien vers une page du site (bullarr://series/12, ou https://serveur/series/12 partagé) :
     * ouvre l'écran équivalent. Renvoie un message d'erreur, ou nil si le lien est pris en charge.
     * Portage de AppViewModel.openWebLink (Android 1.10).
     */
    @discardableResult
    func openWebLink(_ url: URL) -> String? {
        guard api != nil else { return "Connectez-vous d'abord à votre serveur Bullarr" }
        let path: String
        switch url.scheme?.lowercased() {
        case "bullarr":
            let segs = [url.host ?? "", url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isBlank }
            path = "/" + segs.joined(separator: "/")
        case "http", "https":
            let raw = settings.serverUrl.trimmed
            guard let server = URL(string: raw.contains("://") ? raw : "http://\(raw)"),
                  let host = server.host,
                  host.caseInsensitiveCompare(url.host ?? "") == .orderedSame else {
                return "Ce lien n'est pas une page de votre serveur Bullarr"
            }
            // Bullarr servi sous un sous-chemin (https://hôte/bullarr/…) : on retire ce préfixe.
            let base = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var p = url.path
            if !base.isBlank, p.hasPrefix("/\(base)") { p = String(p.dropFirst(base.count + 1)) }
            path = p.isBlank ? "/" : p
        default:
            return "Lien non pris en charge"
        }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isBlank }
        func go(_ sec: Section, _ sub: String? = nil) {
            guard sections.contains(sec) else { return }
            openSeries = nil
            section = sec
            if let sub, let i = subsOf(sec).firstIndex(of: sub) { subTab[sec] = i }
        }
        if parts.isEmpty { go(.library); return nil }
        switch parts[0] {
        case "series":
            guard parts.count > 1, let id = Int(parts[1]) else { return "Série introuvable dans le lien" }
            section = .library
            openSeriesById(id, series.first { $0.id == id }?.title ?? "Série")
        case "library":
            go(.library)
            if parts.count > 1, let id = Int(parts[1]), let lib = libraries.first(where: { $0.id == id }) { selectLibrary(lib) }
        case "activity", "import": go(.tracking, "Activité")
        case "nouveautes", "ebdz-nouveautes": go(.tracking, "Nouveautés")
        case "validation": go(.tracking, "Validation")
        case "history": go(.tracking, "Historique")
        case "demandes": isReader ? go(.requests) : go(.tracking, "Validation")
        case "discover": go(.search)
        case "bedetheque-enrich": go(.actions, "Enrichir")
        case "missing-monitor": go(.actions, "Surveillance")
        case "verification": go(.actions, "Vérification")
        case "upscaling": go(.actions) // iOS n'a pas de sous-onglet Upscaling
        case "profil": go(.config, "Profil")
        case "settings": go(.config)
        default: go(.library)
        }
        return nil
    }

    func coverUrl(_ path: String?) -> String? {
        guard let path else { return nil }
        return api?.absoluteUrl(path)
    }

    // --- Mises à jour -----------------------------------------------------------

    func checkUpdate() {
        update = .checking
        Task {
            do {
                if let latest = try await UpdateChecker.latest() {
                    update = compareVersions(latest.version, installedName) > 0 ? .available(latest) : .upToDate(latest)
                } else {
                    update = .upToDate(nil)
                }
            } catch {
                update = .failed(readable(error))
            }
        }
    }

    // --- Badges ----------------------------------------------------------------

    /// Nouveautés : comme sur le web, « nouveau » = arrivé depuis la dernière ouverture de l'onglet.
    func markNewsSeen() {
        badgePrefs.set(ISO8601DateFormatter().string(from: Date()), forKey: "newsSeen")
        newsCount = 0
    }

    func refreshBadges() async {
        guard let client = api, !isReader else { return }
        if let o = try? await client.getObject("api/requests/pending-count") { requestCount = o.int("total") ?? 0 }
        if let o = try? await client.getObject("api/auto-acquire/reviews/count") { reviewCount = o.int("count") ?? 0 }
        if let o = try? await client.getObject("api/import/pending-count") { importCount = o.int("waiting_file_count") ?? 0 }
        do {
            let since = badgePrefs.string(forKey: "newsSeen") ?? {
                let now = ISO8601DateFormatter().string(from: Date())
                badgePrefs.set(now, forKey: "newsSeen")
                return now
            }()
            if let o = try? await client.getObject("api/ebdz/nouveautes/new-count", query: ["since": since]) {
                newsCount = o.int("count") ?? 0
            }
        }
        if let o = try? await client.getObject("api/activity/status") {
            let st = parseActivity(o)
            activityCount = st.clients.reduce(0) { $0 + $1.items.count } + st.pending.count
        }
    }

    // --- Bibliothèque ------------------------------------------------------------

    /// Met à jour une ligne de la bibliothèque après une modification faite sur sa fiche, sans recharger.
    func updateSeriesRow(_ id: Int, change: (SeriesSummary) -> SeriesSummary) {
        series = series.map { $0.id == id ? change($0) : $0 }
        if let lib = selectedLibrary { seriesByLibrary[lib.id] = series }
    }

    func markAdded(_ url: String) {
        addedBedethequeUrls.insert(url)
    }

    func loadLibrary(force: Bool = false, library: Library? = nil) {
        guard let client = api else { return }
        let target = library ?? selectedLibrary
        if libraryLoading || (!force && !series.isEmpty && target?.id == selectedLibrary?.id) { return }
        // Affichage immédiat depuis le cache (mémoire, sinon disque), puis rafraîchissement réseau.
        if libraries.isEmpty, let raw = readLibCache("libraries"), let libs = try? parseLibraries(raw) {
            libraries = libs
        }
        let first: Library? = target.flatMap { t in libraries.first { $0.id == t.id } } ?? libraries.first
        if let f = first, series.isEmpty {
            selectedLibrary = f
            if let cached = seriesByLibrary[f.id] ?? (readLibCache("series_\(f.id)").flatMap { try? parseSeriesList($0) }) {
                series = cached
                seriesByLibrary[f.id] = cached
            }
        }
        libraryLoading = true
        libraryError = nil
        Task {
            do {
                let raw = try await client.getArray("api/libraries")
                writeLibCache("libraries", raw)
                let libs = parseLibraries(raw)
                libraries = libs
                let lib = target.flatMap { t in libs.first { $0.id == t.id } } ?? libs.first
                if lib?.id != selectedLibrary?.id { series = [] }
                selectedLibrary = lib
                if let lib {
                    let rawSeries = try await client.getArray("api/library/\(lib.id)/series")
                    writeLibCache("series_\(lib.id)", rawSeries)
                    let fresh = parseSeriesList(rawSeries)
                    seriesByLibrary[lib.id] = fresh
                    // L'utilisateur a pu changer de bibliothèque pendant le chargement.
                    if selectedLibrary?.id == lib.id { series = fresh }
                } else {
                    series = []
                }
            } catch {
                // Hors réseau avec un cache : on garde la liste en cache sans bandeau d'erreur bloquant.
                if series.isEmpty { libraryError = readable(error) }
            }
            libraryLoading = false
        }
    }

    func selectLibrary(_ lib: Library) {
        if lib.id == selectedLibrary?.id { return }
        series = []
        // Affiche aussitôt la version en cache puis la rafraîchit.
        loadLibrary(force: true, library: lib)
    }

    /// Change le critère de tri et son sens (mémorisés sur l'appareil).
    func setSort(_ s: LibrarySort, _ desc: Bool) {
        sort = s
        sortDesc = desc
    }

    // --- Fiches de série (cache mémoire) ----------------------------------------

    func cachedSeriesDetail(_ id: Int) -> SeriesDetail? {
        seriesDetailCache[id]
    }

    func rememberSeriesDetail(_ detail: SeriesDetail) {
        seriesDetailCache[detail.id] = detail
        seriesDetailOrder.removeAll { $0 == detail.id }
        seriesDetailOrder.append(detail.id)
        if seriesDetailOrder.count > 60 {
            let evict = seriesDetailOrder.removeFirst()
            seriesDetailCache.removeValue(forKey: evict)
        }
    }
}

/// Tome visé par la recherche, rattaché à une fiche de série.
struct SearchContext: Hashable {
    let seriesId: Int
    let seriesTitle: String
    let volumeId: Int?
    let volumeLabel: String?
    let volumeNumber: Int?
    var isIntegral: Bool = false
    var isHs: Bool = false
    var isEpisode: Bool = false
}

/// Cible du lecteur plein écran.
struct ReaderTarget: Hashable, Identifiable {
    let volumeId: Int
    let title: String
    let seriesId: Int?
    let seriesTitle: String?
    let offline: Bool

    init(volumeId: Int, title: String, seriesId: Int? = nil, seriesTitle: String? = nil, offline: Bool = false) {
        self.volumeId = volumeId
        self.title = title
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.offline = offline
    }

    var id: Int { volumeId }
}
