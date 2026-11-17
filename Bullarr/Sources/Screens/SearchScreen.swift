import SwiftUI
import UIKit

// MARK: - Onglet Recherche

/**
 * Cherche un album sur Prowlarr, EBDZ, Telegram, Fourtoutici, VK et Anna's Archive.
 * Résultats groupés par source (repliables) ou en liste unique, tri, filtres format/confirmé,
 * envoi aux clients de téléchargement (DownloadController) et ajout de série (Bédéthèque).
 */
struct SearchScreen: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var dl: DownloadController

    var body: some View {
        if state.api != nil {
            SearchView(search: state.search, dl: dl)
        } else {
            EmptyStateView(title: "Non connecté.", detail: "Connectez-vous dans Réglages → Accès.")
        }
    }
}

private let SEARCH_SORTS = ["Source", "Taille", "Date", "Seeders", "Tome", "Titre"]

/// Résultat de recherche → fichier à envoyer ; nil pour Anna's Archive (lien seulement).
extension SearchResult {
    func toJob(_ ctx: SearchContext?) -> DownloadJob? {
        // Tome transmis pour le suivi : celui du résultat, sinon celui de la fiche (sauf intégrale/HS).
        let ctxTome = (ctx?.isIntegral == true || ctx?.isHs == true || ctx?.isEpisode == true) ? nil : ctx?.volumeNumber
        let volume = volumeNumber ?? ctxTome
        let t = Tracking(seriesId: ctx?.seriesId, volumeId: ctx?.volumeId, volumeNumber: volume, sourceLink: sourceLink)
        switch source {
        case "prowlarr": return downloadLink.map { DownloadJob.torrent(url: $0, name: name, tracking: t) }
        case "ebdz": return raw.str("link").map { DownloadJob.ed2k(link: $0, name: name, tracking: t) }
        case "telegram":
            let id = (raw.str("message_id") ?? "").isEmpty ? nil : Int64(raw.str("message_id")!)
            if let ch = raw.str("channel"), let id {
                return DownloadJob.telegram(channel: ch, messageId: id, channelTitle: raw.str("channel_title"), name: name, tracking: t)
            }
            return nil
        case "fourtoutici": return raw.str("file_id").map { DownloadJob.fourtoutici(fileId: $0, name: name, tracking: t) }
        case "vk": return downloadLink.map { DownloadJob.vk(url: $0, name: name, tracking: t) }
        default: return nil
        }
    }
}

private struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @ObservedObject var search: SearchState
    @ObservedObject var dl: DownloadController

    // Tous les résultats en une liste, ou groupés par source (repliables).
    @State private var table = true
    // Sources masquées (appui sur leur puce) : leurs résultats disparaissent, sans rien relancer.
    @State private var hidden: [String: Bool] = [:]
    @State private var sortKey: String? = nil
    @State private var sortDesc = true
    @State private var formatFilter: String? = nil
    @State private var onlyConfirmed = false
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if loading {
                ProgressView().progressViewStyle(.linear).tint(cs.accent).padding(.top, 8)
            }
            list
        }
        .sheet(isPresented: $adding) {
            SeriesAddDialog(initialQuery: search.title.trimmed, onDismiss: { adding = false }, onAdded: { sid, title in
                adding = false
                state.section = .library
                state.openSeriesById(sid, title)
            })
        }
        .task {
            // Débogage / préremplissage : une recherche déjà tapée mais pas lancée part à l'ouverture.
            if search.lastQuery == nil && !search.title.trimmed.isBlank { search.search() }
        }
    }

    // --- En-tête ------------------------------------------------------------------

    private var header: some View {
        let ctxTitle = search.context.map { " · \($0.seriesTitle)" } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let ctx = search.context {
                    // Retour à l'album recherché (recherche lancée depuis une fiche).
                    Button {
                        state.section = .library
                        state.openSeriesById(ctx.seriesId, ctx.seriesTitle)
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(cs.text)
                            .frame(width: 30, height: 36)
                    }
                    .accessibilityLabel("Retour à l'album")
                }
                TextField("Série ou album…", text: $search.title)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { runSearch() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(cs.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cs.outlineVariant, lineWidth: 1))
                TextField("Tome", text: $search.volume)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .onSubmit { runSearch() }
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(cs.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(cs.outlineVariant, lineWidth: 1))
                    .frame(width: 66)
                    .onChange(of: search.volume) { v in
                        let f = String(v.filter { $0.isNumber }.prefix(4))
                        if f != search.volume { search.volume = f }
                    }
                Menu {
                    ForEach(SEARCH_SORTS, id: \.self) { k in
                        Button {
                            if sortKey == k { sortDesc.toggle() } else { sortKey = k; sortDesc = true }
                        } label: {
                            HStack {
                                Text(k)
                                Spacer()
                                if sortKey == k {
                                    Image(systemName: sortDesc ? "arrow.down" : "arrow.up")
                                }
                            }
                        }
                    }
                    if sortKey != nil {
                        Button("Ordre par défaut") { sortKey = nil }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 16))
                        .foregroundColor(cs.text)
                        .frame(width: 30, height: 36)
                }
                .accessibilityLabel("Trier")
                // Ajout d'une série (Découvrir du site) : recherche Bédéthèque puis ajout à la bibliothèque.
                Button { adding = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18))
                        .foregroundColor(cs.text)
                        .frame(width: 30, height: 36)
                }
                .accessibilityLabel(state.isReader ? "Demander une série" : "Ajouter une série")
            }
            sourcesRow
            if search.lastQuery != nil { filtersRow }
            if let q = search.lastQuery {
                Text("« \(q) » · \(rows.count) résultat(s)\(ctxTitle)")
                    .font(.caption).foregroundColor(cs.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func runSearch() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if !search.title.trimmed.isBlank { search.search() }
    }

    // --- Puces de sources ---------------------------------------------------------

    private var sourcesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SEARCH_SOURCES, id: \.0) { key, label in
                    sourceChip(key, label)
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// Puce d'une source : logo et nombre de résultats ; atténuée si la source est désactivée ou masquée.
    /// Appui : afficher/masquer ses résultats ; appui long : activer/désactiver la source.
    private func sourceChip(_ key: String, _ label: String) -> some View {
        let st = search.sources[key]
        let count: Int? = {
            if case .done(let rs) = st { return rs.filter { keep($0) }.count }
            return nil
        }()
        let isLoading = { if case .loading = st { return true }; return false }()
        let isFailed = { if case .failed = st { return true }; return false }()
        let enabled = search.enabledSources[key] == true
        let shown = hidden[key] != true
        let active = enabled && shown
        return HStack(spacing: 6) {
            if active {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundColor(cs.text)
            }
            Logo(key: key, label: label, size: 18, tip: false)
            if isLoading {
                ProgressView().controlSize(.mini).tint(cs.text)
            } else if isFailed {
                Text("!").font(.footnote.weight(.semibold)).foregroundColor(cs.error)
            } else if let c = count {
                Text("\(c)").font(.footnote.weight(.semibold)).foregroundColor(active ? cs.text : cs.muted)
            } else {
                Text(label).font(.footnote).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? cs.alt : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? cs.border : cs.outlineVariant, lineWidth: active ? 1.5 : 1))
        .opacity(active ? 1 : 0.4)
        .contentShape(Rectangle())
        .onTapGesture { toggleShown(key) }
        .onLongPressGesture(minimumDuration: 0.4) {
            search.enabledSources[key] = !(search.enabledSources[key] ?? true)
        }
    }

    private func toggleShown(_ key: String) {
        let allVisible = SEARCH_SOURCES.allSatisfy { hidden[$0.0] != true }
        let onlyThis = SEARCH_SOURCES.allSatisfy { $0.0 == key || hidden[$0.0] == true }
        if allVisible {
            for (k, _) in SEARCH_SOURCES { hidden[k] = k != key }
        } else if onlyThis {
            for (k, _) in SEARCH_SOURCES { hidden[k] = false }
        } else {
            hidden[key] = !(hidden[key] ?? false)
        }
    }

    // --- Filtres ------------------------------------------------------------------

    private var filtersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(selected: !table, onClick: { table.toggle() }, label: { Text("Par source") })
                FilterChip(selected: onlyConfirmed, onClick: { onlyConfirmed.toggle() }, label: { Text("Tome confirmé") })
                ForEach(formats, id: \.self) { f in
                    FilterChip(selected: formatFilter == f, onClick: { formatFilter = formatFilter == f ? nil : f }, label: { Text(f) })
                }
            }
            .padding(.vertical, 1)
        }
    }

    // --- Liste des résultats ------------------------------------------------------

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if search.lastQuery == nil {
                    EmptyStateView(
                        title: "Cherchez un album",
                        detail: "Sur Prowlarr, EBDZ, Telegram, Fourtoutici, VK et Anna's Archive. Depuis une fiche série, touchez un tome pour le chercher."
                    )
                    .padding(.vertical, 40)
                }
                ForEach(SEARCH_SOURCES, id: \.0) { key, label in
                    if case .failed(let m) = search.sources[key], hidden[key] != true {
                        ErrorCard(message: "\(label) : \(m)")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                }
                if table {
                    ForEach(rows, id: \.id) { r in
                        resultRow(r)
                        Divider()
                    }
                    if rows.isEmpty && search.lastQuery != nil && !loading {
                        EmptyStateView(
                            title: "Aucun résultat",
                            detail: formatFilter != nil || onlyConfirmed ? "avec ces filtres" : nil
                        )
                        .padding(.vertical, 24)
                    }
                } else {
                    ForEach(SEARCH_SOURCES, id: \.0) { key, label in
                        if hidden[key] != true, case .done(let rs) = search.sources[key] {
                            let group = sortResults(rs.filter { keep($0) })
                            groupHeader(key, label, group.count)
                            // Fermé par défaut, comme sur Android.
                            if search.collapsed[key] != false {
                                ForEach(group, id: \.id) { r in
                                    resultRow(r)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func groupHeader(_ key: String, _ label: String, _ count: Int) -> some View {
        let closed = search.collapsed[key] != false
        return Button {
            search.collapsed[key] = !closed
        } label: {
            HStack(spacing: 0) {
                Logo(key: key, label: label, size: 22, tip: false).padding(.trailing, 12)
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count)").font(.caption).foregroundColor(cs.muted)
                Image(systemName: closed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 13))
                    .foregroundColor(cs.muted)
                    .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Ligne de résultat, dans le style des listes de l'app : logo de la source, titre, détails, téléchargement.
    private func resultRow(_ r: SearchResult) -> some View {
        let job = r.toJob(search.context)
        let sentTo = job.flatMap { dl.sent[$0.key] }
        let link = r.sourceLink
        let meta = [r.volumeLabel, formatBytes(r.sizeBytes), r.format, r.seeders.map { "\($0) seeds" }, r.date, r.detail]
            .compactMap { $0 }
            .joined(separator: " · ")
        return Button {
            if let link { openInBrowser(link) }
        } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 8).fill(cs.alt)
                    .frame(width: 36, height: 36)
                    .overlay(Logo(key: r.source, label: searchSourceName(r.source), size: 22, tip: false))
                Spacer().frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !meta.isEmpty {
                        Text(meta).font(.caption).foregroundColor(cs.muted).lineLimit(2)
                    }
                    if let u = r.unconfirmed {
                        Text(u).font(.caption).foregroundColor(cs.tertiary).lineLimit(2)
                    }
                    if let st = sentTo {
                        TagView(text: "Envoyé · \(st)", container: cs.secondaryContainer, content: cs.accentOnContainer)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let j = job {
                    Button { send(r, j) } label: {
                        Image(systemName: sentTo != nil ? "checkmark.circle" : "arrow.down.circle")
                            .font(.system(size: 20))
                            .foregroundColor(sentTo != nil ? cs.tertiary : cs.accent)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sentTo != nil ? "Envoyé, renvoyer" : "Télécharger")
                } else {
                    Color.clear.frame(width: 8)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(link == nil)
    }

    private func send(_ r: SearchResult, _ job: DownloadJob) {
        let ctx = search.context
        let vol = r.volumeNumber != nil ? r.volumeLabel : ctx?.volumeLabel
        let context = ctx.map { "Rattaché à \($0.seriesTitle)" + (vol.map { " · \($0)" } ?? "") }
        dl.request(job, context: context, warning: r.unconfirmed)
    }

    // --- Données ------------------------------------------------------------------

    private var loading: Bool {
        search.sources.values.contains { state in
            if case .loading = state { return true }
            return false
        }
    }

    private var all: [SearchResult] {
        SEARCH_SOURCES.filter { hidden[$0.0] != true }.flatMap { key, _ -> [SearchResult] in
            if case .done(let rs) = search.sources[key] { return rs }
            return []
        }
    }

    private var formats: [String] {
        Array(Set(all.compactMap { $0.format })).sorted()
    }

    /// Résultats affichés : sources visibles, filtres appliqués, triés.
    private var rows: [SearchResult] {
        sortResults(all.filter { keep($0) })
    }

    private func keep(_ r: SearchResult) -> Bool {
        (formatFilter == nil || r.format == formatFilter) && (!onlyConfirmed || r.unconfirmed == nil)
    }

    /// Tri des résultats ; sans clé, l'ordre du serveur avec les tomes confirmés d'abord.
    private func sortResults(_ list: [SearchResult]) -> [SearchResult] {
        let sorted: [SearchResult]
        switch sortKey {
        case "Source": sorted = list.sorted { $0.source < $1.source }
        case "Taille": sorted = list.sorted { ($0.sizeBytes ?? -1) < ($1.sizeBytes ?? -1) }
        case "Date": sorted = list.sorted { ($0.date ?? "") < ($1.date ?? "") }
        case "Seeders": sorted = list.sorted { ($0.seeders ?? -1) < ($1.seeders ?? -1) }
        case "Tome": sorted = list.sorted { ($0.volumeNumber ?? -1) < ($1.volumeNumber ?? -1) }
        case "Titre": sorted = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        default:
            // Ordre du serveur : tomes confirmés d'abord, ordre gardé dans chaque groupe.
            return list.filter { $0.unconfirmed == nil } + list.filter { $0.unconfirmed != nil }
        }
        return sortDesc ? sorted.reversed() : sorted
    }
}
