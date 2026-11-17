import SwiftUI

/// Actions sur séries et tomes (routes Bullarr existantes) : même appel pour une série ou une sélection.
enum ItemActions {
    static func updateSeriesMetadata(_ api: BullarrApi, _ id: Int) async throws {
        try await api.postObject("api/bedetheque/update-metadata/series/\(id)", [:])
    }
    static func scanSeries(_ api: BullarrApi, _ id: Int) async throws {
        try await api.postObject("api/scan/series/\(id)", [:])
    }
    static func deleteSeries(_ api: BullarrApi, _ id: Int) async throws {
        try await api.deleteObject("api/series/\(id)")
    }
    static func updateVolumeMetadata(_ api: BullarrApi, _ id: Int) async throws {
        try await api.postObject("api/bedetheque/update-metadata/volume/\(id)", [:])
    }
    static func refreshVolume(_ api: BullarrApi, _ id: Int) async throws {
        try await api.postObject("api/volumes/\(id)/refresh", [:])
    }
    /// Recherches d'un album dans les magasins (même liste que le site).
    static func shopLinks(_ query: String) -> [(String, String)] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return [
            ("Fnac", "https://www.fnac.com/SearchResult/ResultList.aspx?Search=\(q)"),
            ("Amazon", "https://www.amazon.fr/s?k=\(q)&i=stripbooks"),
            ("BDfugue", "https://www.bdfugue.com/catalogsearch/result/?q=\(q)"),
        ]
    }
    static func editSeries(_ api: BullarrApi, _ id: Int, _ fields: [String: String]) async throws {
        try await api.putObject("api/series/\(id)/manual-metadata", fields)
    }
    /// Déplace une série vers une autre bibliothèque et suit le job serveur jusqu'au bout
    /// (copie possible entre deux disques : ça peut durer).
    static func moveSeries(_ api: BullarrApi, _ id: Int, _ target: Library) async throws -> String {
        let started = try await api.postObject("api/series/move", ["library_id": target.id, "series_ids": [id]])
        if (started.bool("success") ?? true) == false { throw ApiException(started.str("error") ?? "Déplacement impossible") }
        guard let jobId = started.str("job_id"), !jobId.isBlank else { throw ApiException("Déplacement impossible") }
        while true {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let j = try await api.getObject("api/series/move/\(jobId)")
            guard let job = j.dict("job") else { throw ApiException("Suivi du déplacement perdu") }
            let status = job.str("status")
            if status == "running" { continue }
            if status == "failed" { throw ApiException(job.str("error") ?? "Déplacement interrompu") }
            let r = job.objects("results").first
            if let r, (r.bool("success") ?? true) == false {
                throw ApiException("Non déplacée : \(r.str("error") ?? "erreur inconnue")")
            }
            if let r, (r.bool("skipped") ?? false) { return "Série déjà dans \(target.name)" }
            return "Série déplacée vers \(target.name)"
        }
    }
    /// Listes personnelles d'une série ; seul le booléen fourni est modifié côté Bullarr.
    static func setSeriesReadingLists(_ api: BullarrApi, _ id: Int, toReadLater: Bool? = nil, isFavorite: Bool? = nil) async throws {
        var body: JSONDict = [:]
        if let toReadLater { body["to_read_later"] = toReadLater }
        if let isFavorite { body["is_favorite"] = isFavorite }
        try await api.putObject("api/series/\(id)/reading-lists", body)
    }
    /// Remplace la liste complète des tags d'une série.
    static func setSeriesTags(_ api: BullarrApi, _ id: Int, _ tags: [String]) async throws {
        try await api.putObject("api/series/\(id)/tags", ["tags": tags])
    }
    static func deleteVolume(_ api: BullarrApi, _ id: Int) async throws {
        try await api.deleteObject("api/volumes/\(id)")
    }
    static func editVolume(_ api: BullarrApi, _ id: Int, _ fields: [String: String]) async throws {
        try await api.putObject("api/volumes/\(id)/manual-metadata", fields)
    }
}

/// Édition manuelle des métadonnées d'un tome (PUT /api/volumes/<id>/manual-metadata).
struct EditVolumeDialog: View {
    @Environment(\.bullColors) private var cs
    let v: VolumeRow
    let onDismiss: () -> Void
    let onSave: ([String: String]) -> Void

    private let fields: [(String, String)] = [
        ("title", "Titre"), ("summary", "Résumé"), ("writer", "Scénario"), ("penciller", "Dessin"),
        ("colorist", "Couleurs"), ("publisher", "Éditeur"), ("genre", "Genre"), ("year", "Année"),
    ]

    private func initial(_ k: String) -> String {
        if let ci = v.comicInfo, let s = ci.str(k), !s.hasPrefix("<") { return s }
        if k == "title" { return v.title ?? "" }
        if k == "year" { return v.year ?? "" }
        return ""
    }
    @State private var values: [String: String] = [:]

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Éditer \(v.label)").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(fields, id: \.0) { k, label in
                                FormField(value: Binding(
                                    get: { values[k] ?? initial(k) },
                                    set: { values[k] = $0 }
                                ), label: label)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            },
            buttons: {
                Button("Annuler") { onDismiss() }
                    .foregroundColor(cs.accent)
                Button("Enregistrer") {
                    let out = fields.reduce(into: [String: String]()) { acc, f in acc[f.0] = values[f.0] ?? initial(f.0) }
                    onDismiss()
                    onSave(out)
                }
                .foregroundColor(cs.accent)
            }
        )
    }
}

/// Édition des métadonnées de série : seuls les champs modifiés sont envoyés (un champ vide = effacé).
struct SeriesEditDialog: View {
    @Environment(\.bullColors) private var cs
    let d: SeriesDetail
    let onDismiss: () -> Void
    let onSave: ([String: String]) -> Void

    private var years: [String]? { d.years?.components(separatedBy: " – ") }

    private var initial: [String: String] {
        let ys = years ?? []
        return [
            "title": d.title,
            "summary": d.summary ?? "",
            "genre": d.genre ?? "",
            "status": d.status ?? "",
            "author": d.authors ?? "",
            "year_start": ys.count > 0 ? ys[0] : "",
            "year_end": ys.count > 1 ? ys[1] : "",
        ]
    }
    private let labels: [(String, String)] = [
        ("title", "Titre"), ("summary", "Résumé"), ("genre", "Genre"), ("status", "Statut"),
        ("author", "Auteur(s)"), ("year_start", "Année de début"), ("year_end", "Année de fin"),
    ]
    @State private var values: [String: String] = [:]

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Éditer la série").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(labels, id: \.0) { k, label in
                                FormField(value: Binding(
                                    get: { values[k] ?? initial[k] ?? "" },
                                    set: { values[k] = $0 }
                                ), label: label, singleLine: k != "summary")
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            },
            buttons: {
                Button("Annuler") { onDismiss() }
                    .foregroundColor(cs.accent)
                Button("Enregistrer") {
                    let changed = labels.reduce(into: [String: String]()) { acc, f in
                        let val = (values[f.0] ?? initial[f.0] ?? "")
                        if val != (initial[f.0] ?? "") { acc[f.0] = val.trimmingCharacters(in: .whitespaces) }
                    }
                    onDismiss()
                    if !changed.isEmpty { onSave(changed) }
                }
                .foregroundColor(cs.accent)
            }
        )
    }
}

/// Tag comme le site le range : minuscules, espaces remplacés par des tirets.
func normalizeSeriesTag(_ raw: String) -> String {
    raw.trimmed.lowercased().replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
}
