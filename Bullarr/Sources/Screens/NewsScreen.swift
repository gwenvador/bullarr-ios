import SwiftUI

// Onglet Nouveautés (NewsScreen.kt) : sorties RSS (Bédéthèque), fichiers Telegram et fils EBDZ,
// regroupés par série ; genre d'après l'origine Bédéthèque ; téléchargement direct ou recherche.

extension NewsType {
    var label: String { rawValue }
}

// Onglet 0 = Tout ; les suivants suivent NewsType.
private let NEWS_TABS = ["Tout"] + NewsType.allCases.map { $0.label }

/// Fenêtre des nouveautés EBDZ et Telegram, en jours (comme le site : nouveautesDaysWindow).
private let NEWS_DAYS = 60
/// Premier lot affiché par source (comme le site : NOUVEAUTES_INITIAL_LIMIT).
private let NEWS_INITIAL_LIMIT = 100

/// Genre connu d'une fiche Bédéthèque : pas encore demandé, aucun, ou BD / Comics / Manga.
private enum GenreInfo {
    case kind(String)
    case noKind
}

struct NewsScreen: View {
    @EnvironmentObject private var state: AppState
    var openSeries: (Int, String) -> Void

    var body: some View {
        // Téléchargements observés à part : les mentions « Envoyé » suivent en direct.
        NewsScreenInner(downloads: state.downloads, openSeries: openSeries)
    }
}

private struct NewsScreenInner: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @ObservedObject var downloads: DownloadController
    let openSeries: (Int, String) -> Void

    @State private var tab = 0
    @State private var feeds: [NewsType: [NewsItem]] = [:]
    @State private var errors: [NewsType: String] = [:]
    @State private var rssNote: String? = nil
    @State private var loading = false
    @State private var rssRefreshing = false
    @State private var rssPass = 0
    // Entrée dont on choisit ou change la série (menu ⋯).
    @State private var pickFor: NewsItem? = nil
    // Entrée dont on crée la série (dialogue d'ajout), puis rattachée à la nouvelle série.
    @State private var addingFor: NewsItem? = nil
    @State private var daysWindow = NEWS_DAYS
    @State private var fullWindow = false
    @State private var hasMoreEbdz = false
    @State private var loadingMore = false
    @State private var genres: [String: GenreInfo] = [:]
    @State private var genreFilter: String? = nil
    @State private var countriesOpen = false
    @State private var searchOpen = false
    @State private var query = ""
    @State private var expandedGroups: Set<String> = []

    private var shownTypes: [NewsType] {
        tab == 0 ? NewsType.allCases : [NewsType.allCases[tab - 1]]
    }

    private var items: [NewsItem] {
        let q = normalize(query).trimmed
        var list: [NewsItem] = []
        for t in shownTypes { list.append(contentsOf: feeds[t] ?? []) }
        list = list.filter { item in
            if let gf = genreFilter, genreOf(item) != gf { return false }
            if !q.isEmpty {
                let hay = normalize([item.title, item.subtitle, item.seriesTitle].compactMap { $0 }.joined(separator: " "))
                if !hay.contains(q) { return false }
            }
            return true
        }
        // Onglet « Tout » : tout fusionné par date décroissante ; un onglet source garde son ordre.
        if tab == 0 { list.sort { ($0.date ?? "") > ($1.date ?? "") } }
        return list
    }

    private func genreOf(_ item: NewsItem) -> String? {
        guard let u = item.bedethequeUrl else { return nil }
        if case .kind(let k)? = genres[u] { return k.isEmpty ? nil : k }
        return nil
    }

    private func genreCount(_ k: String) -> Int {
        var n = 0
        for list in feeds.values {
            for it in list {
                if let u = it.bedethequeUrl, case .kind(let g)? = genres[u], g == k { n += 1 }
            }
        }
        return n
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            filterRow
            if loading && feeds.isEmpty {
                ProgressView().progressViewStyle(.linear)
            }
            listContent
        }
        .background(cs.bg)
        .task(id: "\(state.api != nil)") {
            if feeds.isEmpty { await loadAll(refresh: false) }
        }
        // Après « Actualiser » seulement, le serveur calcule les séries des nouvelles releases :
        // on relit alors le flux RSS après 4, 8 puis 12 s pour les afficher.
        .task(id: rssPass) {
            guard rssPass > 0 else { return }
            var attempt = 1
            while rssRefreshing && attempt <= 3 {
                try? await Task.sleep(nanoseconds: UInt64(4_000_000_000 * attempt))
                attempt += 1
                await load(.rss, refresh: false)
            }
        }
        // Genre (BD / Comics / Manga) d'après l'origine de la fiche Bédéthèque, comme la page web :
        // POST /api/bedetheque/origins, par lots de 100, en redemandant tant que le serveur lit des pages.
        .task(id: feeds) { await fetchGenres() }
        .sheet(item: $pickFor) { entry in
            NewsSeriesPicker(item: entry, onDismiss: { pickFor = nil }, onAddNew: {
                addingFor = entry
                pickFor = nil
            }, onPick: { series in
                pickFor = nil
                attach(entry, series)
            })
        }
        .overlay {
            if let entry = addingFor {
                SeriesAddDialog(
                    initialQuery: entry.seriesTitle,
                    onDismiss: { addingFor = nil },
                    onAdded: { sid, title in
                        addingFor = nil
                        var linked = entry
                        launchAction("Série « \(title) » créée et rattachée", then: { Task { await loadAll(refresh: false) } }) {
                            try await setNewsSeries(state.api!, entry, sid)
                        }
                        _ = linked
                    }
                )
            }
        }
    }

    // --- Onglets -----------------------------------------------------------------

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(NEWS_TABS.enumerated()), id: \.offset) { i, t in
                    let count: Int? = i == 0
                        ? NewsType.allCases.reduce(0) { $0 + (feeds[$1]?.count ?? 0) }
                        : feeds[NewsType.allCases[i - 1]]?.count
                    Button {
                        tab = i
                    } label: {
                        HStack(spacing: 6) {
                            // Logo de la source (Tout garde son mot), suivi du nombre d'entrées.
                            if i == 0 {
                                Text(t)
                            } else {
                                Logo(key: NewsType.allCases[i - 1].rawValue.lowercased(), label: t, size: 22, tip: false)
                            }
                            if let count, count > 0 {
                                Text("\(count)").font(.footnote).foregroundColor(cs.muted)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == i ? cs.accent : Color.clear).frame(height: 2)
                        }
                        .foregroundColor(tab == i ? cs.accent : cs.text)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // --- Ligne de filtres --------------------------------------------------------

    private var filterRow: some View {
        HStack(spacing: 8) {
            if countriesOpen && !searchOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        genreChip(nil, "Genre")
                        genreChip("bd", "BD")
                        genreChip("comics", "Comics")
                        genreChip("manga", "Manga")
                    }
                }
            } else {
                // Pendant une recherche, un appui sur « Genre » ferme la recherche.
                FilterChip(selected: genreFilter != nil) {
                    if searchOpen {
                        searchOpen = false
                        query = ""
                        countriesOpen = false
                    } else if countriesOpen {
                        countriesOpen = false
                    } else {
                        countriesOpen = true
                    }
                } label: {
                    if let gf = genreFilter {
                        Logo(key: gf, label: gf, size: 20, tip: false)
                    } else {
                        Text("Genre")
                    }
                }
                if searchOpen {
                    CompactSearchField(value: $query, placeholder: "Titre ou série")
                } else {
                    Spacer()
                }
            }
            // Actualiser : relit les flux RSS et relance les scrapes EBDZ / Telegram (comme le site).
            Button {
                guard !loading else { return }
                Task { await loadAll(refresh: true) }
            } label: {
                if loading && !feeds.isEmpty {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.clockwise").foregroundColor(cs.muted).frame(width: 32, height: 32)
                }
            }
            .accessibilityLabel("Actualiser les nouveautés")
            Button {
                searchOpen.toggle()
                if !searchOpen { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(searchOpen ? cs.accent : cs.muted)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Rechercher dans les nouveautés")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func genreChip(_ k: String?, _ l: String) -> some View {
        // Drapeau du genre (BD = France, Comics = USA, Manga = Japon), nombre d'entrées à côté.
        let n = k.map { genreCount($0) }
        return FilterChip(selected: genreFilter == k) {
            genreFilter = k
            if k == nil { countriesOpen = false }
        } label: {
            HStack(spacing: 6) {
                if let k {
                    Logo(key: k, label: l, size: 20, tip: false)
                } else {
                    Text(l)
                }
                if let n, n > 0 {
                    Text("\(n)").font(.footnote).foregroundColor(cs.muted)
                }
            }
        }
    }

    // --- Liste -------------------------------------------------------------------

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shownTypes, id: \.self) { t in
                    if let msg = errors[t] {
                        ErrorCard(message: "\(t.label) : \(msg)", onRetry: { Task { await load(t, refresh: false) } })
                            .padding(16)
                    }
                }
                if shownTypes.contains(.rss), let note = rssNote {
                    ErrorCard(message: note).padding(16)
                }
                if !loading && items.isEmpty && shownTypes.allSatisfy({ errors[$0] == nil }) {
                    EmptyStateView(title: "Rien de neuf", detail: "Aucune entrée récente.")
                        .padding(.top, 24)
                }
                // Albums consécutifs d'une même série : une seule ligne « série », dépliable (comme le site).
                // « si les mêmes albums apparaissent dans les 2 dernières heures, concatène-les » : comme le site.
                let groups = groupConsecutiveSeries(gatherRecentSeries(items))
                ForEach(Array(groups.enumerated()), id: \.offset) { gi, members in
                    let first = members[0]
                    if members.count == 1 {
                        NewsRow(
                            downloads: downloads, item: first, showType: tab == 0,
                            genre: genreOf(first), onOpenSeries: openSeries,
                            onPickSeries: { pickFor = $0 }
                        )
                        Divider()
                    } else {
                        let groupId = "\(newsGroupKey(first) ?? "")|\(first.date ?? "")"
                        let open = expandedGroups.contains(groupId)
                        NewsGroupRow(
                            first: first, count: members.count, showType: tab == 0,
                            genre: genreOf(first), expanded: open,
                            onToggle: {
                                if open { expandedGroups.remove(groupId) } else { expandedGroups.insert(groupId) }
                            }
                        )
                        Divider()
                        if open {
                            ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                                // Date, type et origine laissés vides quand ils répètent ceux de la ligne série.
                                NewsRow(
                                    downloads: downloads, item: m,
                                    showType: tab == 0 && m.type != first.type,
                                    genre: genreOf(m) == genreOf(first) ? nil : genreOf(m),
                                    onOpenSeries: openSeries, onPickSeries: { pickFor = $0 },
                                    hideDate: m.date == first.date, nested: true
                                )
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                }
                let moreAvailable = !fullWindow || (hasMoreEbdz && shownTypes != [.rss])
                if !feeds.isEmpty && !loading && moreAvailable && shownTypes != [.rss] {
                    HStack {
                        Spacer()
                        if loadingMore {
                            ProgressView()
                        } else {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                Text(!fullWindow ? "Charger plus" : "Charger une période plus ancienne")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    .padding(16)
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await loadAll(refresh: true) }
    }

    // --- Chargement --------------------------------------------------------------

    @MainActor
    private func load(_ type: NewsType, refresh: Bool, limit: Int? = NEWS_INITIAL_LIMIT, olderThanDays: Int? = nil) async {
        guard let api = state.api else {
            errors[type] = "Non connecté."
            return
        }
        errors[type] = nil
        // Mêmes réglages que la page web : premier lot des 100 entrées les plus récentes par source,
        // « Charger plus » récupère toute la fenêtre de 60 jours, puis « Charger une période plus
        // ancienne » ajoute 60 jours de plus (EBDZ et Telegram ; le RSS n'a pas d'historique).
        var window: [String: String] = ["days": "\(daysWindow)"]
        if let limit { window["limit"] = "\(limit)" }
        if let olderThanDays { window["older_than_days"] = "\(olderThanDays)" }
        do {
            var loaded: [NewsItem] = []
            switch type {
            case .rss:
                if olderThanDays != nil { return }
                var q: [String: String] = ["limit": "\(limit ?? NEWS_INITIAL_LIMIT)"]
                if refresh { q["refresh"] = "1" }
                let o = try await api.getObject("api/ebdz/rss/latest", query: q)
                let (parsed, errs) = parseRss(o)
                if !errs.isEmpty { rssNote = "Flux RSS en erreur :\n" + errs.joined(separator: "\n") }
                rssRefreshing = o.bool("refreshing") == true
                loaded = parsed
            case .telegram:
                loaded = parseTelegram(try await api.getObject("api/telegram-channels/latest", query: window))
            case .ebdz:
                let o = try await api.getObject("api/ebdz/latest", query: window)
                hasMoreEbdz = o.bool("has_more") == true
                loaded = parseEbdz(o)
            }
            if olderThanDays == nil {
                feeds[type] = loaded
            } else {
                var cur = feeds[type] ?? []
                for it in loaded where !cur.contains(where: { $0.id == it.id }) {
                    cur.append(it)
                }
                feeds[type] = cur
            }
        } catch {
            errors[type] = readable(error)
        }
    }

    @MainActor
    private func loadAll(refresh: Bool) async {
        guard let api = state.api else { return }
        loading = true
        if refresh {
            // Bouton Actualiser du site : relance aussi le scrape EBDZ et Telegram.
            async let s1 = api.postObject("api/ebdz/scrape", JSONDict())
            async let s2 = api.postObject("api/telegram-channels/scrape", JSONDict())
            _ = try? await s1
            _ = try? await s2
            daysWindow = NEWS_DAYS
        }
        fullWindow = false
        async let r: Void = load(.rss, refresh: refresh)
        async let t: Void = load(.telegram, refresh: refresh)
        async let e: Void = load(.ebdz, refresh: refresh)
        _ = await (r, t, e)
        loading = false
        // Seule une actualisation demandée relit les flux ; le serveur calcule ensuite les séries.
        if refresh { rssPass += 1 }
    }

    @MainActor
    private func loadMore() async {
        guard let api = state.api else { return }
        loadingMore = true
        if !fullWindow {
            async let e: Void = load(.ebdz, refresh: false, limit: nil)
            async let t: Void = load(.telegram, refresh: false, limit: nil)
            _ = await (e, t)
            fullWindow = true
        } else {
            let older = daysWindow
            daysWindow += NEWS_DAYS
            async let e: Void = load(.ebdz, refresh: false, limit: nil, olderThanDays: older)
            async let t: Void = load(.telegram, refresh: false, limit: nil, olderThanDays: older)
            _ = await (e, t)
        }
        loadingMore = false
    }

    @MainActor
    private func fetchGenres() async {
        guard let api = state.api else { return }
        let wanted = feeds.values.flatMap { $0 }.compactMap { $0.bedethequeUrl }.filter { !$0.isEmpty }
        var missing = wanted.filter { genres[$0] == nil }
        var rounds = 0
        while !missing.isEmpty && rounds < 40 {
            rounds += 1
            let batch = Array(missing.prefix(100))
            guard let o = try? await api.postObject("api/bedetheque/origins", ["urls": batch]) else { break }
            let answered = o.dict("origins") ?? [:]
            for (url, val) in answered {
                guard let d = val as? JSONDict else { continue }
                let k = d.str("kind")
                genres[url] = (k?.isEmpty == false) ? .kind(k!) : .noKind
            }
            if answered.isEmpty && (o.int("pending") ?? 0) == 0 {
                for url in batch where genres[url] == nil { genres[url] = .noKind }
            }
            missing = wanted.filter { genres[$0] == nil }
            if !missing.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
    }

    // --- Actions -----------------------------------------------------------------

    private func attach(_ entry: NewsItem, _ series: SeriesSummary) {
        launchAction("Série « \(series.title) » rattachée", then: { Task { await loadAll(refresh: false) } }) {
            try await setNewsSeries(state.api!, entry, series.id)
        }
    }
}

// MARK: - Lignes

private struct NewsRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @ObservedObject var downloads: DownloadController
    let item: NewsItem
    let showType: Bool
    let genre: String?
    let onOpenSeries: (Int, String) -> Void
    let onPickSeries: (NewsItem) -> Void
    var hideDate: Bool = false
    var nested: Bool = false

    /// Lien copiable du premier fichier (ed2k / torrent / vk) ; les autres n'en ont pas.
    private var copyable: String? {
        guard let job = item.files.first?.job else { return nil }
        switch job {
        case .ed2k(let link, _, _): return link
        case .torrent(let url, _, _), .vk(let url, _, _): return url
        default: return nil
        }
    }

    var body: some View {
        let sentTo = item.files.compactMap { downloads.sent[$0.job.key] }.first
        HStack(alignment: .center, spacing: 0) {
            // Présentation : 1) série + drapeau d'origine, 2) nom du fichier, 3) une seule ligne
            // « source · heure · taille » suivie des états (possédé, envoyé…). Bédéthèque et les
            // autres liens sont dans le menu ⋯, plus de rangée d'icônes à déchiffrer.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Dans un groupe déplié, la série est déjà sur la ligne au-dessus : le fichier passe en titre.
                    Text(nested ? item.title : (item.subtitle ?? item.title))
                        .font(nested ? .subheadline.weight(.medium) : .subheadline.weight(.semibold))
                        .lineLimit(2)
                    GenreFlag(genre: genre)
                }
                if item.subtitle != nil && !nested {
                    Text(item.title).font(.caption).foregroundColor(cs.muted).lineLimit(2)
                }
                FlowRow(spacing: 6) {
                    SourceLine(item: item, showType: showType, hideDate: hideDate)
                    if item.owned {
                        TagView(text: "Possédé", container: cs.accentContainer, content: cs.accentOnContainer)
                    } else if item.inLibrary {
                        TagView(text: "Série suivie", container: cs.secondaryContainer, content: cs.accentOnContainer)
                    }
                    if let sentTo {
                        TagView(text: "Envoyé · \(sentTo)", container: cs.secondaryContainer, content: cs.accentOnContainer)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !item.files.isEmpty {
                Button {
                    // Choix du fichier parmi ceux de l'entrée ; la note dit s'il remplace un possédé.
                    downloads.choose(item.subtitle ?? item.title, item.files.map { f -> (DownloadJob, String?) in
                        let parts = [f.volumeLabel, f.owned ? "Possédé : sera remplacé" : nil].compactMap { $0 }
                        return (f.job, parts.isEmpty ? nil : parts.joined(separator: " · "))
                    })
                } label: {
                    Image(systemName: "arrow.down.circle").frame(width: 32, height: 32)
                }
                .accessibilityLabel("Télécharger")
            }
            Menu {
                if !item.files.isEmpty && !item.owned {
                    Button {
                        downloads.quick = item
                    } label: {
                        Label(item.seriesId == nil ? "Ajouter la série et télécharger" : "Télécharger dans la série", systemImage: "bolt")
                    }
                }
                Button {
                    onPickSeries(item)
                } label: {
                    Label(item.seriesId == nil ? "Choisir la série" : "Changer la série", systemImage: "pencil")
                }
                if let id = item.seriesId {
                    Button {
                        onOpenSeries(id, item.seriesTitle)
                    } label: {
                        Label("Ouvrir la série", systemImage: "books.vertical")
                    }
                }
                if let bd = item.bedethequeUrl {
                    Button { openInBrowser(bd) } label: {
                        Label("Ouvrir sur Bédéthèque", systemImage: "arrow.up.right")
                    }
                }
                if let link = item.link {
                    Button { openInBrowser(link) } label: {
                        Label("Ouvrir la source", systemImage: "arrow.up.right")
                    }
                }
                if let link = copyable {
                    Button {
                        UIPasteboard.general.string = link
                    } label: {
                        Label("Copier le lien", systemImage: "doc.on.doc")
                    }
                }
                Button {
                    state.search.context = nil
                    state.search.title = item.seriesTitle
                    state.search.volume = ""
                    state.search.search()
                    state.goToSearch()
                } label: {
                    Label("Chercher ailleurs", systemImage: "magnifyingglass")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Actions")
        }
        .padding(.leading, nested ? 28 : 16)
        .padding(.trailing, 4)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if let link = item.link { openInBrowser(link) }
        }
    }
}

/// Ligne « série » d'un groupe replié : nom, nombre d'albums, date / type / origine du plus récent.
private struct NewsGroupRow: View {
    @Environment(\.bullColors) private var cs
    let first: NewsItem
    let count: Int
    let showType: Bool
    let genre: String?
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(first.seriesTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    GenreFlag(genre: genre)
                }
                HStack(spacing: 8) {
                    TagView(text: "\(count) albums", container: cs.secondaryContainer, content: cs.accentOnContainer)
                    SourceLine(item: first, showType: showType, hideDate: false, withSize: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .foregroundColor(cs.muted)
                .padding(.leading, 6)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

/// Drapeau d'origine (BD = France, Comics = USA, Manga = Japon), discret, à côté du titre.
private struct GenreFlag: View {
    let genre: String?

    var body: some View {
        if let g = genre, !g.isEmpty {
            Logo(key: g, label: g, size: 14, tip: false)
        }
    }
}

/// « [logo] C411 · 14:21 · 37 Mo » : un seul logo (celui de la source, sinon le type RSS / Telegram / EBDZ).
private struct SourceLine: View {
    @Environment(\.bullColors) private var cs
    let item: NewsItem
    let showType: Bool
    let hideDate: Bool
    var withSize: Bool = true

    var body: some View {
        let source = item.source?
            .replacingOccurrences(of: "Prowlarr · ", with: "")
            .replacingOccurrences(of: "Prowlarr — ", with: "")
        let srcKey = logoKey(item.source).flatMap { hasLogo($0) ? $0 : nil }
        var parts: [String] = [source ?? item.type.label]
        if !hideDate, let d = item.date { parts.append(shortNewsDate(d)) }
        if withSize, let s = formatBytes(item.sizeBytes) { parts.append(s) }
        return HStack(spacing: 5) {
            if let srcKey {
                Logo(key: srcKey, label: source ?? "", size: 14, tip: false)
            } else if showType || source == nil {
                Logo(key: item.type.rawValue.lowercased(), label: item.type.label, size: 14, tip: false)
            }
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundColor(cs.muted)
                .lineLimit(1)
        }
    }
}

// MARK: - Regroupements et dates

/**
 * Clé de série d'une entrée (comme _nouveautesSeriesGroupKey du site) : série locale
 * (matched_series_id pour EBDZ, series_id sinon), sinon fiche Bédéthèque, sinon titre de
 * série normalisé ; nil si rien ne permet de regrouper.
 */
func newsGroupKey(_ item: NewsItem) -> String? {
    if let id = item.seriesId { return "s:\(id)" }
    if let bd = item.bedethequeUrl, !bd.isBlank { return "b:\(bd)" }
    let r = item.raw
    func str(_ k: String) -> String? {
        let v = r.str(k) ?? ""
        return (!v.isBlank && v != "null") ? v : nil
    }
    let title: String?
    if item.type == .ebdz {
        title = str("matched_series_title") ?? str("bedetheque_title") ?? str("title")
    } else {
        title = str("series_title") ?? str("bedetheque_title") ?? str("parsed_title")
    }
    guard let title else { return nil }
    let n = normalize(title).trimmed
    return n.isEmpty ? nil : "t:\(n)"
}

/// Regroupe les entrées CONSÉCUTIVES d'une même série ; un album d'une autre série coupe le groupe.
func groupConsecutiveSeries(_ items: [NewsItem]) -> [[NewsItem]] {
    var out: [[NewsItem]] = []
    var groupKeys = Set<String>()
    for it in items {
        let keys = newsGroupKeys(it)
        if !out.isEmpty && keys.contains(where: { groupKeys.contains($0) }) {
            out[out.count - 1].append(it)
            groupKeys.formUnion(keys)
        } else {
            out.append([it])
            groupKeys = keys
        }
    }
    return out
}

func compactSeriesName(_ name: String) -> String {
    normalize(name).filter { $0.isLetter || $0.isNumber }
}

/// Clés de série d'une entrée : clé de regroupement + noms devinés, pour rassembler les albums
/// d'une même série même quand une entrée n'a ni série ni fiche Bédéthèque.
func newsGroupKeys(_ item: NewsItem) -> Set<String> {
    let r = item.raw
    func str(_ k: String) -> String? {
        let v = r.str(k) ?? ""
        return (!v.isBlank && v != "null") ? v : nil
    }
    var names = [item.seriesTitle]
    let guessed = newsGuessSeriesTitle(str("title") ?? str("filename") ?? item.title)
    if !guessed.isBlank { names.append(guessed) }
    var keys = Set<String>()
    if let k = newsGroupKey(item) { keys.insert(k) }
    for n in names.map(compactSeriesName) where n.count >= 4 { keys.insert("n:\(n)") }
    return keys
}

/// Date d'une entrée en minutes (« 2026-11-13 07:20 » ou « 2026-11-13T07:20 ») ; nil sans heure.
func newsMinutes(_ date: String?) -> Int? {
    guard let date else { return nil }
    let d = String(date.trimmed.replacingOccurrences(of: "T", with: " ").prefix(16))
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    guard let t = f.date(from: d) else { return nil }
    return Int(t.timeIntervalSince1970 / 60)
}

private let GATHER_WINDOW_MINUTES = 120

/**
 * Liste triée par date : chaque album entraîne juste derrière lui les albums suivants de la même
 * série publiés à moins de 2 h du dernier album rapproché, même entrecoupés d'autres séries ;
 * l'ordre relatif du reste ne change pas. Une date manquante ne rapproche rien.
 */
func gatherRecentSeries(_ items: [NewsItem]) -> [NewsItem] {
    let times = items.map { newsMinutes($0.date) }
    let keys = items.map { newsGroupKeys($0) }
    var used = [Bool](repeating: false, count: items.count)
    var out: [NewsItem] = []
    out.reserveCapacity(items.count)
    for i in items.indices {
        if used[i] { continue }
        used[i] = true
        out.append(items[i])
        guard var t = times[i], !keys[i].isEmpty else { continue }
        var groupKeys = keys[i]
        var j = i + 1
        while j < items.count {
            guard let tj = times[j] else { break }
            // Fenêtre glissante : mesurée depuis le dernier album rapproché, pas seulement depuis le premier.
            if abs(t - tj) > GATHER_WINDOW_MINUTES { break }
            if !used[j] && keys[j].contains(where: { groupKeys.contains($0) }) {
                used[j] = true
                out.append(items[j])
                groupKeys.formUnion(keys[j])
                t = tj
            }
            j += 1
        }
    }
    return out
}

/// « 2026-11-09 14:21 » → « 14:21 » aujourd'hui, « hier 14:21 », sinon « 7 nov. 14:21 ».
func shortNewsDate(_ d: String) -> String {
    let dayFmt = DateFormatter()
    dayFmt.dateFormat = "yyyy-MM-dd"
    dayFmt.locale = Locale(identifier: "en_US_POSIX")
    guard let date = dayFmt.date(from: String(d.prefix(10))) else { return d }
    let time = d.count > 11 ? String(d.dropFirst(11).prefix(5)) : ""
    let cal = Calendar.current
    let today = Date()
    let day: String?
    if cal.isDate(date, inSameDayAs: today) {
        day = nil
    } else if let yesterday = cal.date(byAdding: .day, value: -1, to: today), cal.isDate(date, inSameDayAs: yesterday) {
        day = "hier"
    } else {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: today) ? "d MMM" : "d MMM yyyy"
        day = f.string(from: date)
    }
    return [day, time.isEmpty ? nil : time].compactMap { $0 }.joined(separator: " ")
}

// MARK: - Choix de la série

/** Choix ou changement de la série d'une entrée : toutes les bibliothèques, recherche par titre. */
private struct NewsSeriesPicker: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @Environment(\.dismiss) private var dismiss
    let item: NewsItem
    let onDismiss: () -> Void
    let onAddNew: () -> Void
    let onPick: (SeriesSummary) -> Void

    @State private var all: [SeriesSummary]? = nil
    @State private var failed: String? = nil
    @State private var query = ""

    private var list: [SeriesSummary] {
        let terms = normalize(query).split(separator: " ").map(String.init).filter { !$0.isBlank }
        guard let all else { return [] }
        return all.filter { s in terms.isEmpty || terms.allSatisfy { s.searchKey.contains($0) } }.prefix(200).map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.subtitle ?? item.title)
                    .font(.headline)
                    .lineLimit(2)
                if item.seriesId != nil {
                    Text("Rattachée actuellement à : \(item.seriesTitle)")
                        .font(.caption)
                        .foregroundColor(cs.muted)
                }
                CompactSearchField(value: $query, placeholder: "Chercher une série")
                if let failed {
                    Text(failed).font(.caption).foregroundColor(cs.error)
                }
                if all == nil && failed == nil {
                    ProgressView().progressViewStyle(.linear)
                }
                Button {
                    onDismiss()
                    onAddNew()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Créer une nouvelle série")
                    }
                }
                List {
                    ForEach(list) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.subheadline).lineLimit(2)
                                if let author = s.author {
                                    Text(author).font(.caption).foregroundColor(cs.muted).lineLimit(1)
                                }
                            }
                            Spacer()
                            if s.id == item.seriesId {
                                Image(systemName: "checkmark").foregroundColor(cs.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onDismiss()
                            onPick(s)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .background(cs.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: item.id) {
            guard let api = state.api else { failed = "Non connecté."; return }
            do {
                let libs = parseLibraries(try await api.getArray("api/libraries"))
                var seriesList: [SeriesSummary] = []
                for lib in libs {
                    seriesList.append(contentsOf: parseSeriesList(try await api.getArray("api/library/\(lib.id)/series")))
                }
                all = seriesList.sorted { $0.title.lowercased() < $1.title.lowercased() }
            } catch {
                failed = readable(error)
            }
        }
    }
}
