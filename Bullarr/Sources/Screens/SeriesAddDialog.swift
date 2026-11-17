import SwiftUI

/// Ajout d'une série à la bibliothèque par son nom : GET /api/bedetheque/search?q= puis
/// POST /api/bedetheque/add-series (url Bédéthèque + bibliothèque). `onAdded` reçoit l'id de la série créée.
/// Un lecteur ne peut pas ajouter : sa demande passe par POST /api/requests, validée par un administrateur.
struct SeriesAddDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    var initialQuery: String = ""
    var onRequested: () -> Void = {}
    var onDismiss: () -> Void
    var onAdded: (Int, String) -> Void

    @State private var query = ""
    @State private var results: [JSONDict]? = nil
    @State private var busy = false
    @State private var error: String? = nil
    /// État de chaque résultat pour ce compte (POST /api/requests/lookup) : déjà dans la bibliothèque, déjà demandé…
    @State private var states: [String: JSONDict] = [:]

    private var library: Library? { state.selectedLibrary ?? state.libraries.first }
    private var asRequest: Bool { state.isReader }

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(asRequest ? "Demander une BD" : "Ajouter une série").font(.headline)
                    HStack(spacing: 0) {
                        FormField(value: $query, label: "Nom de la série (ou lien Bédéthèque)", onSubmit: { search() })
                            .frame(maxWidth: .infinity)
                        Button(action: search) {
                            Image(systemName: "magnifyingglass").frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Chercher")
                    }
                    if asRequest {
                        Text("Un administrateur valide la demande avant l'ajout.")
                            .font(.caption).foregroundColor(cs.muted)
                    } else if let library {
                        Text("Bibliothèque : \(library.name)")
                            .font(.caption).foregroundColor(cs.muted)
                    }
                    if busy { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    if let error { ErrorCard(message: error) }
                    if let results, results.isEmpty {
                        Text("Aucun résultat sur Bédéthèque.").foregroundColor(cs.muted)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array((results ?? []).enumerated()), id: \.offset) { _, r in
                                resultRow(r)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            },
            buttons: {
                Button("Fermer") { onDismiss() }.foregroundColor(cs.accent)
            }
        )
        .onAppear {
            query = initialQuery
            if !initialQuery.isBlank { search() }
        }
    }

    @ViewBuilder
    private func resultRow(_ r: JSONDict) -> some View {
        let st = r.str("url").flatMap { states[$0] }
        let inLibrary = st?.str("state") == "library"
        Button {
            guard !busy else { return }
            // Déjà dans la bibliothèque : ouvrir la fiche plutôt que l'ajouter / la demander.
            if inLibrary, let sid = st?.int("series_id") {
                onDismiss()
                state.openSeriesById(sid, r.str("title") ?? "")
            } else {
                add(r)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.str("title") ?? "(sans titre)").font(.body).foregroundColor(cs.text)
                if let genre = r.str("genre") {
                    Text(genre).font(.caption).foregroundColor(cs.muted)
                }
                if let badge = badgeText(st) {
                    Text(badge.0).font(.caption2).foregroundColor(badge.1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        Divider()
    }

    private func badgeText(_ st: JSONDict?) -> (String, Color)? {
        switch st?.str("state") {
        case "library":
            var text = "Dans la bibliothèque"
            if let tot = st?.int("total") { text += " · \(st?.int("owned") ?? 0)/\(tot) tomes" }
            return (text, cs.accent)
        case "pending": return ("Déjà demandée", cs.accent)
        case "rejected": return ("Demande refusée", cs.error)
        default: return nil
        }
    }

    private func search() {
        let q = query.trimmed
        if q.isBlank || busy { return }
        guard let api = state.api else { return }
        busy = true
        error = nil
        Task {
            do {
                let o = try await api.getObject("api/bedetheque/search", query: ["q": q])
                let raw: Any = o["results"] ?? [Any]()
                let list: [Any] = raw as? [Any] ?? []
                results = list.compactMap { $0 as? JSONDict }
            } catch {
                self.error = readable(error)
            }
            busy = false
            let urls = (results ?? []).compactMap { $0.str("url") }
            if !urls.isEmpty {
                if let items = (try? await api.postObject("api/requests/lookup", ["urls": urls]))?.dict("items") {
                    var map: [String: JSONDict] = [:]
                    for (k, v) in items { if let d = v as? JSONDict { map[k] = d } }
                    states = map
                }
            }
        }
    }

    private func add(_ r: JSONDict) {
        guard let url = r.str("url") else { return }
        let title = r.str("title") ?? ""
        if asRequest { request(r); return }
        guard let lib = library else { error = "Aucune bibliothèque : créez-en une dans l'interface web."; return }
        guard let api = state.api else { return }
        // Fermeture immédiate : l'ajout continue en arrière-plan, résultat en toast.
        onDismiss()
        ToastCenter.shared.show("Ajout de « \(title) » en cours…")
        Task {
            do {
                let res = try await api.postObject("api/bedetheque/add-series", ["url": url, "library_id": lib.id])
                guard let id = res.int("series_id") else {
                    throw ApiException("Ajout de la série impossible : la réponse ne contient pas d'identifiant.")
                }
                ToastCenter.shared.show("Série ajoutée : \(title)")
                state.loadLibrary(force: true)
                onAdded(id, title)
            } catch {
                ToastCenter.shared.show("Ajout de « \(title) » impossible : \(readable(error))")
            }
        }
    }

    private func request(_ r: JSONDict) {
        guard let url = r.str("url") else { return }
        let title = r.str("title") ?? ""
        guard let api = state.api else { return }
        onDismiss()
        Task {
            do {
                let res = try await api.postObject("api/requests", ["url": url, "title": title])
                let msg: String
                switch res.str("status") {
                case "adding": msg = "Demande validée : ajout de « \(title) » en cours"
                case "already": msg = "« \(title) » est déjà dans la bibliothèque"
                case "added": msg = "« \(title) » ajoutée"
                default:
                    msg = res.bool("duplicate") == true ? "« \(title) » est déjà demandée" : "Demande envoyée : « \(title) »"
                }
                ToastCenter.shared.show(msg)
                onRequested()
            } catch {
                ToastCenter.shared.show("Demande impossible : \(readable(error))")
            }
        }
    }
}

/// Type de tome visé : tome, intégrale, hors-série ou épisode.
enum VolumeKind: CaseIterable {
    case tome
    case integral
    case hs
    case episode

    var label: String {
        switch self {
        case .tome: return "Tome"
        case .integral: return "Intégrale"
        case .hs: return "HS"
        case .episode: return "Épisode"
        }
    }

    /// Champ booléen du type dans l'API (tome : rien à mettre).
    var flag: String? {
        switch self {
        case .tome: return nil
        case .integral: return "is_integral"
        case .hs: return "is_hs"
        case .episode: return "is_episode"
        }
    }

    /// Champ du numéro dans l'API.
    var numberField: String {
        switch self {
        case .tome: return "volume_number"
        case .integral: return "integral_number"
        case .hs: return "hs_number"
        case .episode: return "episode_number"
        }
    }
}

/// Tome visé : type et numéro (facultatif).
struct VolumeTarget {
    let kind: VolumeKind
    let number: Int?

    /// Écrit le type et le numéro dans le corps de requête.
    func putInto(_ o: inout JSONDict) {
        if let flag = kind.flag { o[flag] = true }
        if let number = number { o[kind.numberField] = number }
    }
}

/// Choix d'une série de la bibliothèque (filtre par nom) et, en option, du tome : tome, intégrale,
/// hors-série ou épisode ; « Assigner et importer » lance l'import tout de suite après l'assignation.
struct AssignSeriesDialog: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let count: Int
    var initialQuery: String = ""
    let onDismiss: () -> Void
    let onAddNew: () -> Void
    let onPick: (Int, VolumeTarget?, Bool) -> Void

    @State private var query = ""
    @State private var volume = ""
    @State private var kind: VolumeKind = .tome
    @State private var picked: Int? = nil

    // Toutes les séries qui contiennent tous les mots ; sinon les plus proches
    // (le nom deviné d'un fichier a souvent des mots en trop).
    private var matches: [SeriesSummary] {
        let terms = normalize(query).split(separator: " ").map(String.init).filter { !$0.isBlank }
        let full = state.series.filter { s in terms.isEmpty || terms.allSatisfy { s.searchKey.contains($0) } }
        if !full.isEmpty { return Array(full.prefix(60)) }
        return state.series.map { s -> (SeriesSummary, Int) in
            (s, terms.filter { $0.count > 2 && s.searchKey.contains($0) }.count)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .prefix(30)
        .map { $0.0 }
    }

    // Une intégrale peut ne pas avoir de numéro ; un tome sans numéro efface le tome suivi.
    private var target: VolumeTarget? {
        let n = Int(volume.trimmed)
        if kind == .tome && n == nil { return nil }
        return VolumeTarget(kind: kind, number: n)
    }

    var body: some View {
        BullDialog(
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assigner \(count) téléchargement(s) à une série").font(.headline)
                    FormField(value: $query, label: "Série")
                    FlowRow(spacing: 6) {
                        ForEach(VolumeKind.allCases, id: \.self) { k in
                            FilterChip(selected: kind == k) { kind = k } label: {
                                Text(k.label)
                            }
                        }
                    }
                    FormField(value: $volume, label: "Numéro (\(kind.label.lowercased()))", keyboardType: .numberPad)
                    Text(kind == .tome
                         ? "Le numéro est facultatif ; vide, le tome suivi est effacé."
                         : "Numéro facultatif. Le tome est créé à l'import s'il n'existe pas encore dans la série.")
                        .font(.caption).foregroundColor(cs.muted)
                    if state.series.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    } else if matches.isEmpty {
                        Text("Aucune série ne correspond : raccourcissez le nom, ou créez la série avec « Nouvelle série… ».")
                            .font(.caption).foregroundColor(cs.error)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { s in
                                Button {
                                    picked = s.id
                                } label: {
                                    HStack {
                                        Text(s.title)
                                            .fontWeight(s.id == picked ? .semibold : .regular)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if s.id == picked {
                                            Image(systemName: "checkmark.circle.fill").foregroundColor(cs.accent)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(s.id == picked ? cs.secondaryContainer : Color.clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(cs.text)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            },
            buttons: {
                Button("Assigner") {
                    if let picked { onDismiss(); onPick(picked, target, false) }
                }
                .disabled(picked == nil)
                Button {
                    if let picked { onDismiss(); onPick(picked, target, true) }
                } label: {
                    Text("Assigner et importer").fontWeight(.semibold)
                }
                .disabled(picked == nil)
                Button("Annuler", role: .cancel) { onDismiss() }
            }
        )
        .onAppear { query = initialQuery }
        .task { state.loadLibrary() }
    }
}
