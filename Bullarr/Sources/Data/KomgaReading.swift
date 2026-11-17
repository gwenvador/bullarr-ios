import Foundation

/**
 * Avancement de lecture lu dans Komga par le serveur, comme sur le site : « Continuer la lecture »
 * (GET api/komga/keep-reading), état de chaque tome (GET api/series/<id>/volumes) et
 * synchronisation à la demande (POST api/komga/read-progress/sync).
 * Les pages de Komga sont numérotées à partir de 1.
 */
struct KomgaVolumeProgress: Hashable { let page: Int; let pages: Int?; let completed: Bool }

/// Albums commencés dans Komga (ou le lecteur), du plus récent au plus ancien ; nil si Komga n'est pas activé.
func loadKeepReading(_ api: BullarrApi, _ libraryId: Int?) async throws -> [RecentRead]? {
    var query: [String: String] = [:]
    if let id = libraryId { query["library_id"] = "\(id)" }
    let o = try await api.getObject("api/komga/keep-reading", query: query)
    if o.bool("enabled") != true { return nil }
    return o.objects("items").compactMap { i -> RecentRead? in
        guard let id = i.int("volume_id") else { return nil }
        let page = i.int("page") ?? 0
        return RecentRead(
            volumeId: id, seriesId: i.int("series_id"), seriesTitle: i.str("series_title"), label: i.str("label"), title: nil,
            page: max(page - 1, 0), total: i.int("pages_count") ?? max(page, 1), at: Date(timeIntervalSince1970: 0),
            coverPath: i.str("cover_path"),
        )
    }
}

/// Relit tout de suite l'avancement dans Komga (sinon le serveur le fait toutes les 15 minutes).
func syncKomgaReading(_ api: BullarrApi) async throws {
    _ = try await api.postObject("api/komga/read-progress/sync", [:])
}

/// État Komga des tomes d'une série, par identifiant de tome ; seuls les tomes lus ou commencés y figurent.
func loadSeriesKomgaProgress(_ api: BullarrApi, _ seriesId: Int) async throws -> [Int: KomgaVolumeProgress] {
    let rows = try await api.getArray("api/series/\(seriesId)/volumes")
    var out = [Int: KomgaVolumeProgress]()
    for v in rows.objects() {
        guard let id = v.int("id") else { continue }
        let completed = (v.int("komga_read_completed") ?? 0) != 0
        let page = v.int("komga_read_page") ?? 0
        if !completed && page <= 0 { continue }
        out[id] = KomgaVolumeProgress(page: page, pages: v.int("komga_pages_count") ?? v.int("page_count"), completed: completed)
    }
    return out
}
