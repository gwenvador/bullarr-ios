import SwiftUI

// Historique partagé : imports, téléchargements, actions, IA, comptes (ActionsScreens.kt).
// `loadHistoryRows` alimente l'écran Actions et l'historique d'une série.

/// Ligne générique : titre, détail, date, état ; un appui ouvre la série si elle est connue.
struct Row3 {
    let kind: String
    let title: String
    let detail: String?
    let date: String?
    let ok: Bool?
    let seriesId: Int?
    let seriesTitle: String?
    var client: String? = nil
    /// Opération d'import : sa série se lit dans son détail (les fichiers portent la série).
    var operationId: String? = nil
    /// Traitement de l'historique IA : données de l'entrée (tags ajoutés par série).
    var ai: JSONDict? = nil
}

/// Petite icône du type d'événement (import, téléchargement, suppression…).
func kindIcon(_ kind: String) -> String {
    switch kind {
    case "Import": return "tray.and.arrow.down"
    case "Téléchargement": return "arrow.down.circle"
    case "Recherche": return "magnifyingglass"
    case "Renommage": return "pencil"
    case "Série ajoutée": return "books.vertical"
    case "Tome trouvé": return "checkmark.seal"
    case "Acquisition auto": return "bolt"
    case "Tome supprimé": return "trash"
    case "Tome déplacé", "Déplacement de série": return "arrow.right.circle"
    case "Fusion": return "arrow.triangle.merge"
    case "Changement de numéro", "Tags": return "number"
    case "Suppression", "Téléchargement retiré": return "trash"
    case "Contrôle de téléchargement": return "pause.circle"
    case "Validation": return "checkmark.square"
    case "Bibliothèque": return "books.vertical"
    case "Scan": return "antenna.radiowaves.left.and.right"
    case "Modification de série": return "pencil"
    case "Métadonnées": return "internaldrive"
    case "Listes de lecture": return "list.bullet"
    case "Lecture": return "book"
    case "Export": return "shippingbox"
    case "Association": return "link"
    case "Surveillance": return "eye"
    case "Scrap des sources": return "arrow.triangle.2.circlepath"
    case "Réglages": return "gearshape"
    case "Conversion": return "arrow.2.squarepath"
    case "IA": return "sparkles"
    case "Comptes": return "person"
    case "Upscaling": return "wand.and.stars"
    default: return "app"
    }
}

/// Étiquette de type : icône + texte.
struct KindTag: View {
    @Environment(\.bullColors) private var cs
    let kind: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kindIcon(kind)).font(.system(size: 10))
            Text(kind).font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(cs.muted)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(cs.alt))
    }
}

/// Ligne générique : titre, détail, date, état ; un appui ouvre la série si elle est connue.
struct SimpleRow: View {
    @Environment(\.bullColors) private var cs
    let r: Row3
    let onOpenSeries: (Int, String) -> Void
    var onLongClick: (() -> Void)? = nil
    var onClick: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                KindTag(kind: r.kind)
                if let client = r.client, let key = logoKey(client) {
                    Logo(key: key, label: client, size: 16, tip: false)
                }
                switch r.ok {
                case true: IconTag(icon: "checkmark.circle", label: "OK", tint: cs.accentHover)
                case false: IconTag(icon: "exclamationmark.circle", label: "Échec", tint: cs.error)
                case nil: EmptyView()
                }
                if let date = r.date {
                    Text(String(date.prefix(16))).font(.caption2).foregroundColor(cs.muted)
                }
            }
            Text(r.title).font(.subheadline.weight(.medium)).lineLimit(3)
            if let detail = r.detail {
                Text(detail).font(.caption).foregroundColor(cs.muted).lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if let onClick {
                onClick()
            } else if let sid = r.seriesId {
                onOpenSeries(sid, r.seriesTitle ?? r.title)
            }
        }
        .onLongPressGesture { onLongClick?() }
    }
}

// --- Statuts et libellés -----------------------------------------------------

/// Statuts bruts de l'API (anglais) → libellés français ; une valeur inconnue reste telle quelle.
let STATUS_LABELS = [
    "completed": "terminé", "complete": "terminé", "success": "réussi", "succeeded": "réussi",
    "started": "démarré", "running": "en cours", "in_progress": "en cours", "importing": "import en cours",
    "pending": "en attente", "queued": "en file", "failed": "échec", "error": "erreur",
    "partial": "partiel", "cancelled": "annulé", "canceled": "annulé", "skipped": "ignoré",
    "undone": "annulé", "paused": "en pause", "stopped": "arrêté",
]
func statusFr(_ s: String?) -> String? {
    guard let s else { return nil }
    return STATUS_LABELS[s.lowercased().trimmed] ?? s
}

let ACTION_LABELS = [
    "search": "Recherche", "rename": "Renommage", "add_series": "Série ajoutée",
    "missing_volume_match": "Tome trouvé", "auto_acquire": "Acquisition auto",
    "delete_volume": "Tome supprimé", "move_volume": "Tome déplacé", "move_series": "Déplacement de série",
    "merge": "Fusion", "renumber_volume": "Changement de numéro", "delete": "Suppression",
    "import": "Import", "download": "Téléchargement",
    // Types ajoutés quand toutes les actions sont passées dans l'historique (mêmes libellés que le site).
    "download_control": "Contrôle de téléchargement", "download_remove": "Téléchargement retiré", "review": "Validation",
    "library": "Bibliothèque", "scan": "Scan", "series_edit": "Modification de série", "metadata": "Métadonnées",
    "tags": "Tags", "reading_list": "Listes de lecture", "read": "Lecture", "export": "Export", "match": "Association",
    "monitor": "Surveillance", "scrape": "Scrap des sources", "settings": "Réglages", "convert": "Conversion",
    "quality_upgrade": "Upgrade qualité", "request": "Demande", "user": "Utilisateur", "ai": "IA",
]

/// Étapes de l'upscaling et de la réduction côté serveur, regroupées sous « Upscaling ».
let UPSCALE_LABELS = [
    "upscale": "Upscaling terminé", "upscale_queue": "Upscaling demandé", "upscale_start": "Upscaling commencé",
    "upscale_cancel": "Upscaling annulé", "upscale_settings": "Réglages d'upscaling", "upscale_restore": "Version SD remise",
    "upscale_backup_delete": "Version SD supprimée", "downscale": "Réduction terminée", "downscale_queue": "Réduction demandée",
    "downscale_start": "Réduction commencée", "downscale_cancel": "Réduction annulée", "downscale_restore": "Original remis",
    "downscale_backup_delete": "Original supprimé",
]

/// Libellé d'un traitement IA (AiScreen.kt).
func aiKindLabel(_ e: JSONDict) -> String {
    switch e.str("kind") {
    case "generate": return "Création des tags"
    case "normalize": return "Regroupement"
    case "apply": return "Regroupement appliqué"
    case "auto": return "Nouvelles séries"
    case "series": return "Série" + (e.str("title").map { " : \($0)" } ?? "")
    default: return e.str("kind") ?? ""
    }
}

/// Libellé d'une action du journal des comptes (/api/auth/activity).
func accountActionLabel(_ action: String?) -> String {
    switch action {
    case "login": return "Connexion"
    case "login_failed": return "Connexion refusée"
    case "logout": return "Déconnexion"
    case "signup_request": return "Demande de compte"
    case "account_approved": return "Compte validé"
    case "account_rejected": return "Compte refusé"
    case "account_created": return "Compte créé"
    case "account_deleted": return "Compte supprimé"
    case "account_edited": return "Compte modifié"
    case "role_changed": return "Rôle changé"
    case "access_changed": return "Accès changés"
    case "profile_edited": return "Profil modifié"
    case "password_change_failed": return "Mot de passe refusé"
    case "avatar_changed": return "Avatar changé"
    case "request_created": return "Demande de BD"
    case "request_approved": return "Demande validée"
    case "request_rejected": return "Demande refusée"
    case "request_cancelled": return "Demande annulée"
    case "settings_changed": return "Réglage modifié"
    case nil: return "Action"
    default: return titleize(action ?? "")
    }
}

private func titleize(_ s: String) -> String {
    s.replacingOccurrences(of: "_", with: " ").capitalized
}

// --- Chargement --------------------------------------------------------------

/// Imports, téléchargements et actions réunis ; avec `seriesId`, seulement ceux d'une série.
/// Les cinq sources sont interrogées en même temps ; une source en échec n'empêche pas les autres.
@MainActor
func loadHistoryRows(_ api: BullarrApi, _ seriesId: Int?) async -> (rows: [Row3], errors: [String: String]) {
    async let imports = runPart("Imports") { try await historyImports(api, seriesId) }
    async let downloads = runPart("Téléchargements") { try await historyDownloads(api, seriesId) }
    async let actions = runPart("Actions") { try await historyActions(api, seriesId) }
    async let ai = runPart("IA") { try await historyAi(api, seriesId) }
    async let accounts = runPart("Comptes") { try await historyAccounts(api, seriesId) }
    let (importsR, downloadsR, actionsR, aiR, accountsR) = await (imports, downloads, actions, ai, accounts)
    let parts: [(String, Result<[Row3], Error>)] = [
        ("Imports", importsR), ("Téléchargements", downloadsR), ("Actions", actionsR), ("IA", aiR), ("Comptes", accountsR),
    ]
    var rows: [Row3] = []
    var errors: [String: String] = [:]
    for (name, result) in parts {
        switch result {
        case .success(let rs): rows.append(contentsOf: rs)
        case .failure(let e): errors[name] = readable(e)
        }
    }
    return (rows.sorted { ($0.date ?? "") > ($1.date ?? "") }, errors)
}

private func runPart<T>(_ name: String, _ block: @escaping () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await block()) } catch { return .failure(error) }
}

private func historyImports(_ api: BullarrApi, _ seriesId: Int?) async throws -> [Row3] {
    var q: [String: String] = ["limit": "100"]
    if let seriesId { q["series_id"] = "\(seriesId)" }
    return try await api.getObject("api/import/history", query: q).objects("history").map { h in
        let counts = [
            h.int("files_imported").flatMap { $0 > 0 ? "\($0) importé(s)" : nil },
            h.int("files_replaced").flatMap { $0 > 0 ? "\($0) remplacé(s)" : nil },
            h.int("files_skipped").flatMap { $0 > 0 ? "\($0) ignoré(s)" : nil },
            h.int("files_failed").flatMap { $0 > 0 ? "\($0) en échec" : nil },
        ].compactMap { $0 }.joined(separator: " · ")
        let mode = h.str("operation_type") == "auto_import" ? "automatique" : "manuel"
        return Row3(
            kind: "Import",
            title: h.str("file_names") ?? "(aucun fichier)",
            detail: [mode,
                     counts.isEmpty ? nil : counts,
                     statusFr(h.str("status"))].compactMap { $0 }.joined(separator: " · "),
            date: h.str("created_at"),
            ok: h.str("status") != "failed" && (h.int("files_failed") ?? 0) == 0,
            seriesId: nil, seriesTitle: nil,
            operationId: h.str("operation_id")
        )
    }
}

private func historyDownloads(_ api: BullarrApi, _ seriesId: Int?) async throws -> [Row3] {
    var q: [String: String] = ["limit": "100"]
    if let seriesId { q["series_id"] = "\(seriesId)" }
    return try await api.getObject("api/missing-monitor/history", query: q).objects("history").map { h in
        Row3(
            kind: "Téléchargement",
            title: h.str("title") ?? "(sans titre)",
            detail: [h.str("series_title"), h.str("client"), statusFr(h.str("message"))].compactMap { $0 }.joined(separator: " · "),
            date: h.str("created_at"),
            ok: h.bool("success"),
            seriesId: h.int("series_id"), seriesTitle: h.str("series_title"),
            client: h.str("client")
        )
    }
}

private func historyActions(_ api: BullarrApi, _ seriesId: Int?) async throws -> [Row3] {
    var q: [String: String] = ["limit": "100"]
    if let seriesId { q["series_id"] = "\(seriesId)" }
    return try await api.getObject("api/actions/history", query: q).objects("history").map { h -> Row3 in
        let type = h.str("action_type") ?? "action"
        // Upscaling et réduction (demandé, commencé, annulé, terminé…) : un seul type
        // « Upscaling », l'étape précise en tête du détail.
        let upscale: String?
        if type == "upscale" && h.bool("success") == false {
            upscale = "Upscaling impossible"
        } else if type == "downscale" && h.bool("success") == false {
            upscale = "Réduction impossible"
        } else {
            upscale = UPSCALE_LABELS[type]
        }
        let kind: String
        if let upscale {
            kind = "Upscaling"
        } else if let label = ACTION_LABELS[type] {
            kind = label
        } else {
            kind = titleize(type)
        }
        let detailParts = [
            (upscale != nil && h.str("series_title") != nil) ? upscale : nil,
            statusFr(h.str("detail")).map { $0.hasPrefix("Réglages d'upscaling : ") ? titleize(String($0.dropFirst("Réglages d'upscaling : ".count))) : $0 },
            statusFr(h.str("error")),
        ].compactMap { $0 }.joined(separator: " · ")
        return Row3(
            kind: kind,
            title: h.str("series_title") ?? (upscale ?? "(sans série)"),
            detail: detailParts.isEmpty ? nil : detailParts,
            date: h.str("created_at"),
            ok: type.hasSuffix("_cancel") ? nil : h.bool("success"),
            seriesId: h.int("series_id"), seriesTitle: h.str("series_title")
        )
    }
}

/// Dates de l'historique IA en secondes epoch ; les autres sources sont en UTC « aaaa-MM-jj HH:mm:ss ».
private let aiDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private func historyAi(_ api: BullarrApi, _ seriesId: Int?) async throws -> [Row3] {
    var q: [String: String] = [:]
    if let seriesId { q["series_id"] = "\(seriesId)" }
    return try await api.getObject("api/ai/history", query: q).objects("entries").compactMap { e -> Row3? in
        let details = e.objects("details")
        // Historique d'une série : seulement les traitements qui l'ont touchée, avec ses seuls tags.
        let mine = seriesId.map { id in details.filter { $0.int("series_id") == id } } ?? nil
        if let mine, mine.isEmpty { return nil }
        let shown = mine ?? details
        let single = shown.count == 1 && shown[0].int("series_id") != nil ? shown[0] : nil
        let tags = single?.strings("added").joined(separator: ", ")
        let detail = [e.str("message").flatMap { $0.isEmpty ? nil : $0 },
                      tags.flatMap { $0.isEmpty ? nil : $0 },
                      e.str("model")].compactMap { $0 }.joined(separator: " · ")
        let date = e.dbl("finished_at").map { aiDateFormatter.string(from: Date(timeIntervalSince1970: $0)) }
        let ok: Bool?
        switch e.str("status") {
        case "error": ok = false
        case "done": ok = true
        default: ok = nil
        }
        return Row3(
            kind: "IA",
            title: aiKindLabel(e),
            detail: detail.isEmpty ? nil : detail,
            date: date,
            ok: ok,
            seriesId: single?.int("series_id"), seriesTitle: single?.str("title"),
            ai: e
        )
    }
}

private func historyAccounts(_ api: BullarrApi, _ seriesId: Int?) async throws -> [Row3] {
    // Journal des comptes (connexions, comptes, demandes de BD, avatars) : administrateurs seulement.
    try await api.getObject("api/auth/activity", query: ["limit": "300"]).objects("entries").compactMap { e -> Row3? in
        let sid = e.int("series_id")
        if let seriesId, sid != seriesId { return nil }
        let who = e.str("actor_name")
        let target = e.str("target_name")
        let title = accountActionLabel(e.str("action")) + (target.map { " · \($0)" } ?? "")
        let detail = [who, e.str("detail")].compactMap { $0 }.joined(separator: " · ")
        return Row3(
            kind: "Comptes",
            title: title,
            detail: detail.isEmpty ? nil : detail,
            date: e.str("created_at"),
            ok: e.bool("success") == true ? nil : false,
            seriesId: sid, seriesTitle: e.str("series_title")
        )
    }
}

/// Historique d'une série (imports, téléchargements, actions…), ouvert depuis son menu.
struct SeriesHistorySheet: View {
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let api: BullarrApi
    let seriesId: Int
    let title: String

    @State private var rows: [Row3]? = nil
    @State private var errors: [String: String] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Historique").font(.headline)
                        Text(title).font(.caption).foregroundColor(cs.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    ForEach(errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        ErrorCard(message: "\(key) : \(value)").padding(.horizontal, 20).padding(.top, 8)
                    }
                    if rows == nil && errors.isEmpty {
                        ProgressView().padding(.top, 12)
                    }
                    if let rows, rows.isEmpty {
                        EmptyStateView(title: "Rien dans l'historique de cette série")
                            .padding(.top, 12)
                    }
                    if let rows {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                            SimpleRow(r: r, onOpenSeries: { _, _ in })
                            Divider()
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .background(cs.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: seriesId) {
            let (rs, es) = await loadHistoryRows(api, seriesId)
            rows = rs
            errors = es
        }
    }
}
