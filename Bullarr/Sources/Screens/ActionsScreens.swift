import SwiftUI

// MARK: - Actions : Historique, Surveillance, Vérification (ActionsScreens.kt)

private let HISTORY_GROUPS = ["Imports", "Téléchargements", "Recherches", "Renommages", "Conversions", "Suppressions", "IA", "Demandes", "Utilisateurs", "Upscaling"]

/// Filtre du site auquel appartient un type de ligne (nil : seulement dans « Tous »).
private func historyGroup(_ kind: String) -> String? {
    switch kind {
    case "Import": return "Imports"
    case "Téléchargement", "Contrôle de téléchargement", "Téléchargement retiré": return "Téléchargements"
    case "Recherche", "Acquisition auto": return "Recherches"
    case "Renommage": return "Renommages"
    case "Conversion": return "Conversions"
    case "Tome supprimé", "Suppression": return "Suppressions"
    case "IA": return "IA"
    case "Demande": return "Demandes"
    case "Comptes", "Utilisateur": return "Utilisateurs"
    case "Upscaling": return "Upscaling"
    default: return nil
    }
}

private func groupIcon(_ group: String) -> String {
    switch group {
    case "Imports": return kindIcon("Import")
    case "Téléchargements": return kindIcon("Téléchargement")
    case "Recherches": return kindIcon("Recherche")
    case "Renommages": return kindIcon("Renommage")
    case "Conversions": return kindIcon("Conversion")
    case "Suppressions": return kindIcon("Tome supprimé")
    case "Utilisateurs": return kindIcon("Comptes")
    default: return kindIcon(group)
    }
}

func normalizeTitle(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}

extension Row3: Identifiable {
    var id: String { "\(kind)|\(title)|\(date ?? "")|\(detail ?? "")" }
}

/**
 * Onglet Actions → Historique : toutes les opérations du serveur, filtres par type dans l'ordre
 * du site. Appui sur une ligne d'import : sa série se lit dans le détail de l'opération ; appui
 * long : fenêtre avec le détail et les séries à ouvrir.
 */
struct HistoryScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    var openSeries: (Int, String) -> Void

    @State private var rows: [Row3]? = nil
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    @State private var kind: String? = nil
    // Ligne ouverte par appui long : fenêtre avec sa série.
    @State private var detailRow: Row3? = nil
    // Séries des fichiers de l'opération d'import ouverte (vide pour les autres lignes).
    @State private var opSeries: [(Int, String)] = []

    var body: some View {
        if let api = state.api {
            HistoryView(api: api, openSeries: openSeries)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct HistoryView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let openSeries: (Int, String) -> Void

    @State private var rows: [Row3]? = nil
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    @State private var kind: String? = nil
    @State private var detailRow: Row3? = nil
    @State private var opSeries: [(Int, String)] = []

    // Types d'événements présents, dans l'ordre du site ; un type sans filtre n'apparaît que dans « Tous ».
    private var kinds: [(String, Int)] {
        guard let rs = rows else { return [] }
        var counts: [String: Int] = [:]
        for r in rs {
            if let g = historyGroup(r.kind) { counts[g, default: 0] += 1 }
        }
        return HISTORY_GROUPS.compactMap { g in counts[g].map { (g, $0) } }
    }

    private var shown: [Row3] {
        (rows ?? []).filter { kind == nil || historyGroup($0.kind) == kind }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if kinds.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(selected: kind == nil, onClick: { kind = nil }, label: {
                                Text("Tous · \(rows?.count ?? 0)").lineLimit(1)
                            })
                            ForEach(kinds, id: \.0) { k, n in
                                FilterChip(selected: kind == k, onClick: { kind = kind == k ? nil : k }, label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: groupIcon(k)).font(.system(size: 12))
                                        Text("\(k) · \(n)").lineLimit(1)
                                    }
                                })
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                if loading && rows == nil {
                    ProgressView().progressViewStyle(.linear).tint(cs.accent).padding(.vertical, 6)
                }
                ForEach(errors.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    ErrorCard(message: "\(k) : \(v)").padding(16)
                }
                if rows != nil && shown.isEmpty {
                    EmptyStateView(title: "Rien dans l'historique").padding(.vertical, 24)
                }
                ForEach(shown) { r in
                    SimpleRow(r: r, onOpenSeries: openSeries,
                              onLongClick: { detailRow = r },
                              onClick: r.seriesId == nil && r.operationId != nil ? { openImport(r) } : nil)
                    Divider()
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await load() }
        .task { if rows == nil { await load() } }
        .sheet(item: $detailRow) { r in
            detailSheet(r)
        }
    }

    private func load() async {
        loading = true
        let res = await loadHistoryRows(api, nil)
        rows = res.rows
        errors = res.errors
        loading = false
    }

    /// Appui sur un import : sa série se lit dans le détail de l'opération ; une seule série
    /// s'ouvre directement, plusieurs ouvrent la fenêtre de la ligne pour choisir.
    private func openImport(_ r: Row3) {
        guard let op = r.operationId else { return }
        Task {
            do {
                let o = try await api.getObject("api/import/history/\(op)")
                let files = (o.dict("details") ?? [:]).objects("files")
                var seen = Set<Int>()
                let found: [(Int, String)] = files.compactMap { f in
                    guard let sid = f.int("series_id"), seen.insert(sid).inserted else { return nil }
                    return (sid, f.str("series_title") ?? "(série)")
                }
                switch found.count {
                case 1: openSeries(found[0].0, found[0].1)
                case 0: ToastCenter.shared.show("Aucune série liée à cet import")
                default: detailRow = r
                }
            } catch {
                ToastCenter.shared.show(readable(error))
            }
        }
    }

    @ViewBuilder
    private func detailSheet(_ r: Row3) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.seriesTitle ?? r.title).font(.headline).lineLimit(2)
            Text([r.date.map { String($0.prefix(16)) }, r.client].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundColor(cs.muted)
            if let d = r.detail {
                Text(d).font(.subheadline)
            }
            if let e = r.ai {
                ScrollView {
                    AiEntryDetails(e: e, onOpenSeries: { sid, title in
                        detailRow = nil
                        openSeries(sid, title)
                    })
                }
                .frame(maxHeight: 480)
            }
            if r.ai != nil && r.seriesId == nil {
                // Traitement IA non rattaché : pas de série à ouvrir.
            } else {
                let targets: [(Int, String)] = r.seriesId.map { [($0, r.seriesTitle ?? r.title)] } ?? opSeries
                ForEach(Array(targets.prefix(5)), id: \.0) { sid, title in
                    Button {
                        detailRow = nil
                        openSeries(sid, title)
                    } label: {
                        Text(targets.count > 1 ? "Ouvrir « \(title) »" : "Ouvrir la série")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentPillButtonStyle())
                }
                if targets.isEmpty {
                    Text("Aucune série liée à cette ligne.").font(.caption).foregroundColor(cs.muted)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .presentationDetents([.medium, .large])
        .task {
            opSeries = []
            guard r.seriesId == nil, let op = r.operationId else { return }
            do {
                let o = try await api.getObject("api/import/history/\(op)")
                let files = (o.dict("details") ?? [:]).objects("files")
                var seen = Set<Int>()
                opSeries = files.compactMap { f in
                    guard let sid = f.int("series_id"), seen.insert(sid).inserted else { return nil }
                    return (sid, f.str("series_title") ?? "(série)")
                }
            } catch { opSeries = [] }
        }
    }
}

// --- Surveillance ---------------------------------------------------------------

private struct Monitored: Identifiable {
    let id: Int
    let title: String
    let enabled: Bool
    let owned: Int
    let total: Int?
    let missing: Int
    let status: String?
    let key: String
}

/// Onglet Actions → Surveillance : séries surveillées pour tomes manquants, par bibliothèque.
struct MonitorScreen: View {
    @EnvironmentObject private var state: AppState
    var openSeries: (Int, String) -> Void

    var body: some View {
        if let api = state.api {
            MonitorView(api: api, openSeries: openSeries)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct MonitorView: View {
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let openSeries: (Int, String) -> Void

    @State private var list: [Monitored]? = nil
    @State private var error: String? = nil
    @State private var query = ""
    @State private var onlyEnabled = true
    @State private var loading = false

    private var terms: [String] {
        normalizeTitle(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private var shown: [Monitored] {
        (list ?? []).filter { m in
            (!onlyEnabled || m.enabled) && terms.allSatisfy { m.key.contains($0) }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    CompactSearchField(value: $query, placeholder: "Filtrer les séries…")
                    FlowRow(spacing: 8) {
                        FilterChip(selected: onlyEnabled, onClick: { onlyEnabled = true }, label: {
                            Text("Surveillées (\((list ?? []).filter { $0.enabled }.count))")
                        })
                        FilterChip(selected: !onlyEnabled, onClick: { onlyEnabled = false }, label: {
                            Text("Toutes (\(list?.count ?? 0))")
                        })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if loading && list == nil {
                    ProgressView().progressViewStyle(.linear).tint(cs.accent).padding(.vertical, 6)
                }
                if let e = error {
                    ErrorCard(message: e, onRetry: { Task { await load() } }).padding(16)
                }
                ForEach(shown) { m in
                    Button {
                        openSeries(m.id, m.title)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(.subheadline.weight(.medium)).foregroundColor(cs.text)
                                Text([
                                    m.total.map { "\(m.owned)/\($0) tomes" } ?? "\(m.owned) tome(s)",
                                    m.missing > 0 ? "\(m.missing) manquant(s)" : nil,
                                    m.status,
                                ].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundColor(cs.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: binding(for: m))
                                .labelsHidden()
                                .tint(cs.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await load() }
        .task { if list == nil { await load() } }
    }

    private func binding(for m: Monitored) -> Binding<Bool> {
        Binding(
            get: { list?.first { $0.id == m.id }?.enabled ?? false },
            set: { on in toggle(m, on) }
        )
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let libs = (try await api.getObject("api/missing-monitor/libraries")).objects("libraries")
            var all: [Monitored] = []
            for lib in libs {
                guard let libId = lib.int("id") else { continue }
                let series = (try await api.getObject("api/missing-monitor/libraries/\(libId)/series")).objects("series")
                for s in series {
                    let missing = (try? JSONSerialization.jsonObject(with: Data((s.str("missing_volumes") ?? "[]").utf8)) as? [Any])?.count ?? 0
                    let title = s.str("title") ?? "(sans titre)"
                    all.append(Monitored(
                        id: s.int("id") ?? -1,
                        title: title,
                        enabled: s.bool("enabled") == true,
                        owned: s.int("total_local") ?? 0,
                        total: s.int("bedetheque_total_volumes"),
                        missing: missing,
                        status: s.str("bedetheque_status"),
                        key: normalizeTitle(title)
                    ))
                }
            }
            list = all
        } catch {
            self.error = readable(error)
        }
    }

    private func toggle(_ m: Monitored, _ on: Bool) {
        Task {
            do {
                try await api.postObject("api/missing-monitor/series/\(m.id)/monitor", ["enabled": on])
                list = list?.map { $0.id == m.id && $0.enabled != on
                    ? Monitored(id: $0.id, title: $0.title, enabled: on, owned: $0.owned, total: $0.total, missing: $0.missing, status: $0.status, key: $0.key)
                    : $0 }
            } catch {
                ToastCenter.shared.show(readable(error))
            }
        }
    }
}

// --- Vérification ---------------------------------------------------------------

private let VERIFICATIONS: [(String, String)] = [
    ("missing_metadata", "Métadonnées manquantes"),
    ("misnamed", "Noms non conformes"),
    ("misplaced_folders", "Dossiers mal placés"),
    ("missing_files", "Fichiers absents"),
    ("unmatched_owned_volumes", "Tomes non rattachés"),
    ("duplicate_series", "Séries en double"),
    ("invalid_files", "Fichiers invalides (lent)"),
]

private struct VerifItem: Identifiable {
    let type: String
    let raw: JSONDict
    var id: String { "\(type)|\(seriesId ?? 0)|\(volumeId ?? 0)|\(detail ?? "")" }
    var seriesId: Int? { raw.int("series_id") }
    var volumeId: Int? { raw.int("volume_id") }
    var seriesTitle: String { raw.str("series_title") ?? "(sans série)" }
    var detail: String? {
        let s = [raw.str("reason"),
                 raw.str("current_name").map { "Actuel : \($0)" }, raw.str("expected_name").map { "Attendu : \($0)" },
                 raw.str("current_path").map { "Actuel : \($0)" }, raw.str("expected_path").map { "Attendu : \($0)" },
                 raw.str("filename"), raw.str("filepath"),
                ].compactMap { $0 }.joined(separator: "\n")
        return s.isEmpty ? nil : s
    }
}

/// Correction proposée pour une ligne ; [danger] = irréversible, demande une confirmation.
private struct Fix {
    let label: String
    var danger: String? = nil
    let run: (BullarrApi) async throws -> String
}

/// Bouton en pastille pour les actions irréversibles.
private struct DangerPillButtonStyle: ButtonStyle {
    @Environment(\.bullColors) private var cs
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(cs.error))
            .foregroundColor(cs.onError)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private func okOrThrow(_ o: JSONDict, _ fallback: String) throws -> String {
    if let s = o.bool("success"), s == false { throw ApiException(o.str("error") ?? fallback) }
    return o.str("message") ?? fallback
}

/// Mêmes boutons que la page Vérification du site, ligne par ligne.
private func fixesFor(_ v: VerifItem) -> [Fix] {
    guard let sid = v.seriesId else { return [] }
    let vid = v.volumeId
    switch v.type {
    case "missing_metadata":
        if v.raw.str("type") == "series" || vid == nil {
            return [Fix(label: "Matcher sur Bédéthèque (par titre)") { api in
                try okOrThrow(try await api.postObject("api/bedetheque/enrich/\(sid)", [
                    "search_by": "title", "value": v.seriesTitle, "write_volumes": false,
                ]), "Série rattachée à Bédéthèque.")
            }]
        }
        return [
            Fix(label: "Mettre à jour les métadonnées du tome") { api in
                try okOrThrow(try await api.postObject("api/bedetheque/update-metadata/volume/\(vid!)", [:]), "Métadonnées du tome mises à jour.")
            },
            Fix(label: "Mettre à jour toute la série") { api in
                try okOrThrow(try await api.postObject("api/bedetheque/update-metadata/series/\(sid)", ["scope": "all"]), "Mise à jour de la série lancée en arrière-plan.")
            },
        ]
    case "misnamed":
        let label = v.raw.bool("is_folder") == true ? "Renommer le dossier" : "Renommer le fichier"
        return [Fix(label: label) { api in
            let body: JSONDict = (v.raw.bool("is_folder") == true || vid == nil) ? [:] : ["volume_id": vid!]
            return try okOrThrow(try await api.postObject("api/series/\(sid)/rename/execute", body), "Renommé.")
        }]
    case "misplaced_folders":
        if v.raw.bool("can_reconcile") == true {
            return [Fix(label: "Déplacer vers l'emplacement attendu") { api in
                let o = try await api.postObject("api/series/\(sid)/rename/execute", [:])
                if let folder = o.dict("folder"), folder.bool("success") == false {
                    throw ApiException(folder.str("error") ?? "Déplacement impossible")
                }
                return "Dossier déplacé vers son emplacement attendu."
            }]
        }
        return []
    case "missing_files":
        return [
            Fix(label: "Rechercher et télécharger automatiquement") { api in
                let o = try await api.postObject("api/settings/verification/missing-files/\(sid)/auto-acquire", [:])
                try okOrThrow(o, "Recherche automatique lancée.")
                return "Recherche automatique lancée pour \(o.int("count") ?? 0) tome(s)."
            },
            Fix(label: "Supprimer la série de la base",
                danger: "La série et ses tomes seront retirés de Bullarr. Les fichiers sur le disque ne sont pas touchés.") { api in
                try okOrThrow(try await api.deleteObject("api/settings/verification/missing-files/\(sid)/remove-record", ["confirm": true]), "Série retirée de la base.")
            },
        ]
    case "unmatched_owned_volumes":
        if vid != nil {
            return [Fix(label: "Rattacher à Bédéthèque") { api in
                try okOrThrow(try await api.postObject("api/bedetheque/link-volume/\(vid!)", [:]), "Tome rattaché à son album Bédéthèque.")
            }]
        }
        return []
    case "invalid_files":
        if vid != nil {
            return [Fix(label: "Supprimer le fichier",
                        danger: "Le fichier sera supprimé définitivement du disque. Irréversible.") { api in
                try okOrThrow(try await api.deleteObject("api/volumes/\(vid!)"), "Fichier supprimé.")
            }]
        }
        return []
    case "duplicate_series":
        return [Fix(label: "Supprimer cette fiche vide",
                    danger: "La fiche de série vide sera supprimée.") { api in
            try okOrThrow(try await api.postObject("api/settings/verification/duplicate-series/cleanup", ["series_ids": [sid]]), "Fiche supprimée.")
        }]
    default:
        return []
    }
}

/// Onglet Actions → Vérification : anomalies du serveur, catégorie par catégorie, avec
/// corrections (les mêmes que la page Vérification du site).
struct VerificationScreen: View {
    @EnvironmentObject private var state: AppState
    var openSeries: (Int, String) -> Void

    var body: some View {
        if let api = state.api {
            VerificationView(api: api, openSeries: openSeries)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private struct VerificationView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let api: BullarrApi
    let openSeries: (Int, String) -> Void

    @State private var type = VERIFICATIONS.first!.0
    @State private var results: [String: [VerifItem]] = [:]
    @State private var error: String? = nil
    @State private var loading = false
    @State private var selected: VerifItem? = nil
    @State private var confirmFix: (VerifItem, Fix)? = nil
    @State private var running = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FlowRow(spacing: 8) {
                    ForEach(VERIFICATIONS, id: \.0) { k, label in
                        let n = results[k]?.count
                        FilterChip(selected: type == k, onClick: { type = k }, label: {
                            Text(n != nil ? "\(label) (\(n!))" : label)
                        })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if loading {
                    ProgressView().progressViewStyle(.linear).tint(cs.accent).padding(.vertical, 6)
                }
                if let e = error {
                    ErrorCard(message: e, onRetry: { Task { await load(type) } }).padding(16)
                }
                if let list = results[type], list.isEmpty {
                    EmptyStateView(title: "Rien à signaler").padding(.vertical, 24)
                }
                ForEach(results[type] ?? []) { v in
                    Button {
                        selected = v
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.seriesTitle).font(.subheadline.weight(.medium)).foregroundColor(cs.text)
                                if let d = v.detail {
                                    Text(d).font(.caption).foregroundColor(cs.muted).lineLimit(4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundColor(cs.muted)
                        }
                        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await load(type) }
        .task(id: type) { if results[type] == nil { await load(type) } }
        .sheet(item: $selected) { v in
            fixSheet(v)
        }
        .overlay {
            if let (v, fix) = confirmFix {
                ConfirmDialog(
                    title: "\(fix.label) ?",
                    text: "\(v.seriesTitle)\n\n\(fix.danger ?? "")",
                    confirm: "Confirmer",
                    onConfirm: { run(v, fix) },
                    onDismiss: { if !running { confirmFix = nil } }
                )
            }
        }
    }

    private func load(_ t: String) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let o = try await api.getObject("api/settings/verification", query: ["type": t])
            results[t] = o.objects(t).map { VerifItem(type: t, raw: $0) }
        } catch {
            self.error = readable(error)
        }
    }

    private func run(_ item: VerifItem, _ fix: Fix) {
        running = true
        Task {
            defer { running = false; confirmFix = nil }
            do {
                let msg = try await fix.run(api)
                selected = nil
                // La ligne corrigée disparaît tout de suite ; la catégorie est recalculée ensuite.
                results[item.type] = (results[item.type] ?? []).filter { $0.id != item.id }
                ToastCenter.shared.show(msg)
                await load(item.type)
            } catch {
                ToastCenter.shared.show(readable(error))
            }
        }
    }

    @ViewBuilder
    private func fixSheet(_ v: VerifItem) -> some View {
        let fixes = fixesFor(v)
        VStack(alignment: .leading, spacing: 10) {
            Text(v.seriesTitle).font(.title3.weight(.semibold))
            Text(VERIFICATIONS.first { $0.0 == v.type }?.1 ?? "").font(.footnote.weight(.semibold)).foregroundColor(cs.accent)
            if let d = v.detail {
                Text(d).font(.subheadline)
            }
            if running {
                ProgressView().progressViewStyle(.linear).tint(cs.accent)
            }
            ForEach(Array(fixes.enumerated()), id: \.offset) { _, fix in
                if fix.danger != nil {
                    Button {
                        confirmFix = (v, fix)
                    } label: {
                        Text(fix.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DangerPillButtonStyle())
                    .disabled(running)
                } else {
                    Button {
                        run(v, fix)
                    } label: {
                        Text(fix.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentPillButtonStyle())
                    .disabled(running)
                }
            }
            if v.type == "missing_files" {
                Button {
                    selected = nil
                    if let sid = v.seriesId {
                        state.search.prefill(SearchContext(seriesId: sid, seriesTitle: v.seriesTitle, volumeId: nil, volumeLabel: nil, volumeNumber: nil))
                        state.goToSearch()
                    }
                } label: {
                    Text("Recherche manuelle").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlinedPillButtonStyle())
                .disabled(running || v.seriesId == nil)
            }
            if let sid = v.seriesId {
                Button {
                    selected = nil
                    openSeries(sid, v.seriesTitle)
                } label: {
                    Text("Ouvrir la série").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlinedPillButtonStyle())
                .disabled(running)
            }
            if fixes.isEmpty && v.type == "misplaced_folders" {
                Text("Conflit à résoudre : le dossier attendu existe déjà. À corriger depuis l'interface web.")
                    .font(.caption).foregroundColor(cs.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .presentationDetents([.medium, .large])
    }
}
