import Foundation

// --- Activité ---------------------------------------------------------------

struct DownloadItem {
    let clientId: String?
    let name: String
    let progress: Double
    let state: String?
    let sizeBytes: Int64?
    let downloadedBytes: Int64?
    let speed: Int64?
    let eta: Int64?
    let trackingId: Int?
    let seriesTitle: String?
    let volume: String
    let priority: Int
}

struct ClientStatus { let client: String; let label: String; let error: String?; let items: [DownloadItem] }

struct PendingDownloadItem {
    let id: Int
    let title: String
    let client: String
    let status: String
    let seriesTitle: String?
    let volume: String
    let bytesDownloaded: Int64?
    let bytesTotal: Int64?
    let paused: Bool
    let isPack: Bool
    let exhausted: Bool
    let createdAt: String?
    let localCopy: String?
    let clientItemId: String?
}

struct ActivityStatus { let clients: [ClientStatus]; let pending: [PendingDownloadItem] }

func parseActivity(_ o: JSONDict) -> ActivityStatus {
    let clients = o.objects("clients").map { c in
        ClientStatus(
            client: c.str("client") ?? "?",
            label: c.str("label") ?? c.str("client") ?? "?",
            error: c.str("error"),
            items: c.objects("items").map { i in
                DownloadItem(
                    clientId: i.str("id"),
                    name: i.str("name") ?? "(sans nom)",
                    progress: i.dbl("progress") ?? 0,
                    state: i.str("state"),
                    sizeBytes: i.long("size_bytes"),
                    downloadedBytes: i.long("downloaded_bytes"),
                    speed: i.long("speed_bytes_s"),
                    eta: i.long("eta_seconds"),
                    trackingId: i.int("tracking_id"),
                    seriesTitle: i.str("series_title"),
                    volume: volumeLabel(i),
                    priority: i.int("priority") ?? 0,
                )
            },
        )
    }
    let pending = o.objects("pending").map { p -> PendingDownloadItem in
        let localCopy = p.dict("local_copy")?.str("state")
        return PendingDownloadItem(
            id: p.int("id") ?? -1,
            title: p.str("title") ?? "(sans titre)",
            client: p.str("client") ?? "?",
            status: p.str("status") ?? "pending",
            seriesTitle: p.str("series_title"),
            volume: volumeLabel(p),
            bytesDownloaded: p.long("bytes_downloaded"),
            bytesTotal: p.long("bytes_total"),
            paused: p.bool("paused") == true,
            isPack: p.bool("is_pack") == true,
            exhausted: p.bool("exhausted") == true,
            createdAt: p.str("created_at"),
            localCopy: localCopy,
            clientItemId: p.str("client_item_id"),
        )
    }
    return ActivityStatus(clients: clients, pending: pending)
}

// --- Bibliothèque -----------------------------------------------------------

struct Library: Hashable { let id: Int; let name: String; let seriesCount: Int?; let volumesCount: Int? }

func parseLibraries(_ a: [Any]) -> [Library] {
    a.objects().map { Library(id: $0.int("id") ?? -1, name: $0.str("name") ?? "Bibliothèque", seriesCount: $0.int("series_count"), volumesCount: $0.int("volumes_count")) }
}

struct SeriesSummary: Identifiable, Hashable {
    let id: Int
    let title: String
    let author: String?
    let year: String?
    let coverPath: String?
    let ownedTomes: Int
    let totalKnown: Int?
    let missingCount: Int
    let isOneshot: Bool
    let searchKey: String
    /// Champs de filtre de la bibliothèque.
    var isIntegral: Bool = false
    var origin: String? = nil
    var yearInt: Int? = nil
    /// « yyyy-MM-dd HH:mm:ss » du dernier scan, tel que Bullarr le renvoie.
    var lastScanned: String? = nil
    /// Tomes, intégrales, hors-séries… possédés.
    var volumeCount: Int = 0
    /// Taille totale des fichiers, si Bullarr la renvoie (`total_size`).
    var sizeBytes: Int64? = nil
    /// Nombre de votes Bédéthèque (`total_votes`).
    var votes: Int = 0
    /// Genres (humour, fantasy…) : `local_genre`, plusieurs valeurs séparées par des virgules.
    var genres: [String] = []
    /// Tags libres de la série (minuscules, tirets), comme sur le site.
    var tags: [String] = []
    /// Listes personnelles : « à lire plus tard » et « favori ».
    var toReadLater: Bool = false
    var isFavorite: Bool = false
    /// Recherche par nom (titre, auteur, univers) et par tags, séparément.
    var nameKey: String = ""
    var tagsKey: String = ""

    /// Copie avec les listes personnelles modifiées (seuls les booléens fournis changent).
    func with(toReadLater: Bool? = nil, isFavorite: Bool? = nil) -> SeriesSummary {
        var copy = self
        if let toReadLater { copy.toReadLater = toReadLater }
        if let isFavorite { copy.isFavorite = isFavorite }
        return copy
    }
}

/// Anciens (Europe, USA, Asie) et nouveaux (Franco-Belge, Comics, Manga) libellés d'origine de Bédéthèque → un seul jeu.
func canonicalOrigin(_ raw: String?) -> String? {
    switch raw?.trimmed.lowercased() {
    case nil, "": return nil
    case "franco-belge", "europe": return "Europe"
    case "comics", "usa": return "USA"
    case "manga", "asie": return "Asie"
    default: return raw?.trimmed
    }
}

func coverOf(_ o: JSONDict) -> String? {
    o.str("local_cover_path") ?? o.str("bedetheque_cover_path") ?? o.str("komga_cover_path")
}

func parseSeriesList(_ a: [Any]) -> [SeriesSummary] {
    a.objects().map { it in
        let title = it.str("title") ?? "(sans titre)"
        let author = it.str("local_author")
        let tags = it.strings("tags")
        return SeriesSummary(
            id: it.int("id") ?? -1,
            title: title,
            author: author,
            year: it.str("year"),
            coverPath: coverOf(it),
            ownedTomes: it.int("owned_tomes") ?? 0,
            totalKnown: it.int("bedetheque_total_volumes"),
            missingCount: it.array("missing_volumes")?.count ?? 0,
            isOneshot: it.bool("is_oneshot") == true,
            // Un tag se cherche avec ou sans tiret : « chat-surdoue » trouve aussi « chat surdoué ».
            searchKey: normalize("\(title) \(author ?? "") \(it.str("universe_name") ?? "") \(tags.map { "\($0) \($0.replacingOccurrences(of: "-", with: " "))" }.joined(separator: " "))"),
            isIntegral: it.bool("oneshot_is_integral") == true,
            origin: canonicalOrigin(it.str("bedetheque_origin")),
            yearInt: it.str("year").flatMap { Int($0) },
            lastScanned: it.str("last_scanned"),
            volumeCount: ["owned_tomes", "owned_integrals", "owned_hs", "owned_episodes", "owned_specials"].reduce(0) { acc, k in acc + (it.int(k) ?? 0) },
            sizeBytes: it.long("total_size"),
            votes: it.int("total_votes") ?? 0,
            // « genre » : genre effectif renvoyé par le serveur ; local_genre pour les anciens serveurs.
            genres: ((it.str("genre") ?? it.str("local_genre")) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            tags: tags,
            toReadLater: it.bool("to_read_later") == true,
            isFavorite: it.bool("is_favorite") == true,
            nameKey: normalize("\(title) \(author ?? "") \(it.str("universe_name") ?? "")"),
            tagsKey: normalize(tags.map { "\($0) \($0.replacingOccurrences(of: "-", with: " "))" }.joined(separator: " ")),
        )
    }
}

struct VolumeRow: Identifiable {
    let id: Int
    let label: String
    let title: String?
    let owned: Bool
    let coverPath: String?
    let fileSize: Int64?
    let pageCount: Int?
    let format: String?
    let year: String?
    let filename: String?
    let number: Int?
    let isIntegral: Bool
    let isHs: Bool
    let isEpisode: Bool
    let isSpecial: Bool
    /// ComicInfo du tome (titre, résumé, auteurs, éditeur, note…), tel que Bullarr le renvoie.
    let comicInfo: JSONDict?
    let isbn: String?
    let author: String?
    let komgaUrl: String?
    /// Demande de tome (comptes lecteurs) : « pending », « searching », « rejected » (nil : aucune).
    let requested: String?
    /// État d'upscaling serveur (affichage seul : le traitement est fait par Bullarr).
    let upscaleBusy: Bool
    let upscaled: Bool
    let upscaledModel: String?
    let upscaledAt: String?
    /// Version SD gardée d'une réduction (original remis en HD).
    let reducedBackup: Bool
}

struct SeriesDetail: Identifiable {
    let id: Int
    let title: String
    let libraryName: String?
    /// Bibliothèque de la série (édition du tome, déplacement de la série).
    let libraryId: Int?
    let coverPath: String?
    let summary: String?
    let status: String?
    let authors: String?
    let publishers: String?
    let genre: String?
    let years: String?
    let totalKnown: Int?
    let monitored: Bool
    let completeReason: String?
    let isOneshot: Bool
    let bedethequeUrl: String?
    let komgaUrl: String?
    let ebdzUrl: String?
    /// Fiche Bédéthèque de chaque auteur (nom → URL) : ouvre ses autres séries.
    let authorLinks: [String: String]
    let tags: [String]
    let toReadLater: Bool
    let isFavorite: Bool
    let volumes: [VolumeRow]
}

func parseSeriesDetail(_ o: JSONDict) -> SeriesDetail {
    let bd = o.dict("bedetheque") ?? [:]
    let authorParts = [o.str("manual_author"), bd.str("scenaristes"), bd.str("dessinateurs")]
        .compactMap { $0 }.flatMap { $0.split(separator: ",").map(String.init) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("<") }
    var seen = Set<String>()
    let ordered = authorParts.filter { seen.insert($0).inserted }
    let authors = ordered.prefix(8).joined(separator: ", ")
    let start = o.str("manual_year_start") ?? bd.str("year_start") ?? o.str("local_year")
    let end = o.str("manual_year_end") ?? bd.str("year_end")
    let volumes = o.objects("volumes").map { v -> VolumeRow in
        let ci = v.dict("comicinfo")
        let number: Int? = {
            if v.bool("is_integral") == true { return v.int("integral_number") }
            if v.bool("is_hs") == true { return v.int("hs_number") }
            if v.bool("is_episode") == true { return v.int("episode_number") }
            return v.int("volume_number")
        }()
        return VolumeRow(
            id: v.int("id") ?? -1,
            label: volumeLabel(v).ifBlank("Tome"),
            title: ci?.str("title") ?? v.str("bedetheque_title"),
            owned: v.str("filepath") != nil && v.bool("filesystem_present") != false,
            coverPath: v.str("cover_path"),
            fileSize: v.long("file_size"),
            pageCount: v.int("page_count"),
            format: v.str("format"),
            year: v.str("year"),
            filename: v.str("filename"),
            number: number,
            isIntegral: v.bool("is_integral") == true,
            isHs: v.bool("is_hs") == true,
            isEpisode: v.bool("is_episode") == true,
            isSpecial: v.bool("is_special") == true,
            comicInfo: ci,
            isbn: v.str("isbn"),
            author: v.str("author"),
            komgaUrl: v.str("komga_book_url"),
            requested: v.str("requested"),
            upscaleBusy: { let s = v.str("upscale_status"); return s == "queued" || s == "running" }(),
            upscaled: v.dict("upscaled") != nil,
            upscaledModel: v.dict("upscaled")?.str("model"),
            upscaledAt: v.dict("upscaled")?.str("at"),
            reducedBackup: v.bool("sd_backup") == true && v.str("backup_kind") == "downscale",
        )
    }
    var authorLinks = [String: String]()
    if let links = bd.dict("author_links") {
        for (name, url) in links {
            if let s = url as? String, !s.isBlank { authorLinks[name] = s }
            else if let n = url as? NSNumber, !n.stringValue.isBlank { authorLinks[name] = n.stringValue }
        }
    }
    return SeriesDetail(
        id: o.int("id") ?? -1,
        title: o.str("title") ?? "(sans titre)",
        libraryName: o.dict("library")?.str("name"),
        libraryId: o.dict("library")?.int("id"),
        coverPath: coverOf(o) ?? bd.str("cover_path") ?? o.dict("komga")?.str("cover_path"),
        summary: o.str("manual_summary") ?? bd.str("description") ?? o.str("local_summary"),
        status: o.str("manual_status") ?? bd.str("status"),
        authors: authors.isBlank ? o.str("local_author") : authors,
        publishers: bd.str("editeurs"),
        genre: o.str("manual_genre") ?? bd.str("genre") ?? o.str("local_genre"),
        years: (start != nil && end != nil && start != end) ? "\(start!) – \(end!)" : start,
        totalKnown: bd.int("total_volumes"),
        monitored: o.bool("monitored") == true,
        completeReason: o.str("bedetheque_complete_reason"),
        isOneshot: o.bool("is_oneshot") == true,
        bedethequeUrl: bd.str("url") ?? o.str("bedetheque_url"),
        komgaUrl: o.dict("komga")?.str("url"),
        ebdzUrl: o.dict("ebdz")?.str("thread_url"),
        authorLinks: authorLinks,
        tags: o.strings("tags"),
        toReadLater: o.bool("to_read_later") == true,
        isFavorite: o.bool("is_favorite") == true,
        volumes: volumes,
    )
}

// --- Import -----------------------------------------------------------------

struct ImportProgress {
    let processingFile: String?
    let elapsedSeconds: Int64?
    let startedAt: String?
    let claimedFiles: [String]
    let paused: Bool
}

func parseImportProgress(_ o: JSONDict) -> ImportProgress {
    let cur = o.dict("currently_processing")
    let claimed = o.array("importing_filepaths")?.strings() ?? []
    return ImportProgress(
        processingFile: cur?.str("filename"),
        elapsedSeconds: cur?.long("elapsed_seconds"),
        startedAt: cur?.str("started_at"),
        claimedFiles: claimed,
        paused: o.bool("import_paused") == true,
    )
}

/// Fichier en attente d'import : [trackingId] = téléchargement suivi, sans lui rien ne peut être fait depuis l'app.
struct WaitingFile: Hashable { let key: String; let filename: String; let trackingId: Int? }

struct ImportPendingCount { let waitingFiles: Int; let awaitingDiscovery: Int; let waiting: [WaitingFile] }

func parsePendingCount(_ o: JSONDict) -> ImportPendingCount {
    ImportPendingCount(
        waitingFiles: o.int("waiting_file_count") ?? 0,
        awaitingDiscovery: o.int("awaiting_discovery_count") ?? 0,
        // Fichiers en attente d'import (état « waiting » de Bullarr), agissables depuis l'Activité.
        waiting: o.objects("items").map { WaitingFile(key: $0.str("item_key") ?? $0.str("source_path") ?? "", filename: $0.str("filename") ?? "(sans nom)", trackingId: $0.int("tracking_id")) },
    )
}

// --- Formatage --------------------------------------------------------------

func formatBytes(_ b: Int64?) -> String? {
    guard let b = b, b > 0 else { return nil }
    let units = ["o", "Ko", "Mo", "Go", "To"]
    var v = Double(b); var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    if i == 0 { return "\(b) o" }
    return String(format: "%.1f %@", v, units[i]).replacingOccurrences(of: ".", with: ",")
}

func formatDuration(_ sec: Int64?) -> String? {
    guard let sec = sec, sec >= 0 else { return nil }
    let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min \(s) s" }
    return "\(s) s"
}

// --- Recherche --------------------------------------------------------------
// POST /api/missing-monitor/search, une requête par source (comme la page web, chaque
// source s'affiche dès qu'elle répond au lieu d'attendre la plus lente).

let SEARCH_SOURCES: [(String, String)] = [
    ("prowlarr", "Prowlarr"), ("ebdz", "EBDZ"), ("telegram", "Telegram"),
    ("fourtoutici", "Fourtoutici"), ("vk", "VK"), ("annas_archive", "Anna's Archive"),
]

func searchSourceName(_ key: String) -> String { SEARCH_SOURCES.first { $0.0 == key }?.1 ?? key }

struct SearchResult: Identifiable {
    let source: String
    let name: String
    let sizeBytes: Int64?
    let volumeLabel: String?
    let volumeNumber: Int?
    let unconfirmed: String?
    let detail: String?
    let sourceLink: String?
    let raw: JSONDict

    var id: String { "\(source)|\(name)|\(volumeLabel ?? "")|\(sizeBytes.map(String.init) ?? "")" }
    /// Seeders (Prowlarr) : tri et départage.
    var seeders: Int? { raw.int("seeders") }
    /// Date de publication (Prowlarr, VK), au format AAAA-MM-JJ.
    var date: String? { ((raw.str("publish_date") ?? raw.str("date")) as String?).map { String($0.prefix(10)) }.flatMap { $0.isBlank ? nil : $0 } }
    /// Format lu dans le nom (CBZ, CBR, PDF, EPUB) : filtre.
    var format: String? {
        guard let m = name.range(of: "\\b(cbz|cbr|pdf|epub)\\b", options: [.regularExpression, .caseInsensitive]) else { return nil }
        return name[m].uppercased()
    }
    /// Lien sur lequel le serveur reconnaît un ajout (torrent, ed2k, VK…).
    var downloadLink: String? { raw.str("download_url") ?? raw.str("link") }
}

func decodeName(_ s: String) -> String {
    s.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? s
}

func parseSearchResults(_ o: JSONDict) -> [SearchResult] {
    o.objects("results").map { r -> SearchResult in
        let source = r.str("source") ?? "?"
        let name = { () -> String in
            switch source {
            case "ebdz": return decodeName(r.str("filename") ?? r.str("title") ?? "")
            case "telegram", "fourtoutici", "vk": return r.str("filename") ?? r.str("title") ?? ""
            default: return r.str("title") ?? r.str("filename") ?? ""
            }
        }().ifBlank("(sans nom)")
        let detail: String? = { () -> String? in
            switch source {
            case "prowlarr":
                let parts = [r.str("indexer"), (r.int("seeders").map { "\($0) seeders" }), (r.str("publish_date").map { String($0.prefix(10)) })].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            case "ebdz": return r.str("title")
            case "telegram": return r.str("channel_title") ?? r.str("channel")
            case "vk":
                let parts = [r.str("topic_title"), (r.str("date").map { String($0.prefix(10)) })].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            default: return nil
            }
        }()
        let sourceLink: String? = { () -> String? in
            switch source {
            case "prowlarr", "annas_archive": return r.str("info_url")
            case "telegram":
                if r.str("channel") != nil && r.str("message_id") != nil { return "https://t.me/\(r.str("channel")!)/\(r.str("message_id")!)" }
                return nil
            case "fourtoutici": return nil
            default: return r.str("thread_url")
            }
        }()
        return SearchResult(
            source: source, name: name, sizeBytes: r.long("size"),
            volumeLabel: r.str("parsed_volume"), volumeNumber: r.int("volume"),
            unconfirmed: r.bool("unconfirmed_volume") == true ? (r.str("unconfirmed_reason") ?? "Tome non confirmé") : nil,
            detail: detail, sourceLink: sourceLink, raw: r,
        )
    }
}
