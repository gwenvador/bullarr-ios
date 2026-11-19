import SwiftUI

// Bibliothèque : liste / grille des séries, recherche, filtres, tri, sélection multiple,
// « Continuer la lecture » et ajout depuis Bédéthèque.

struct LibraryScreen: View {
    @EnvironmentObject private var state: AppState
    var open: (SeriesSummary) -> Void

    var body: some View {
        // OfflineManager observé à part : les pastilles « hors ligne » suivent les téléchargements.
        LibraryScreenInner(offline: state.offline, open: open)
    }
}

private struct LibraryScreenInner: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @ObservedObject var offline: OfflineManager
    var open: (SeriesSummary) -> Void

    @State private var addQuery: String? = nil
    @State private var sheet = false
    /// Sélection multiple (menu contextuel sur une série) : MAJ Bédéthèque, scan, suppression.
    @State private var selected: Set<Int> = []
    @State private var confirmDelete = false
    @State private var confirmDownload = false
    /// En-tête masqué quand on fait défiler vers le bas, réaffiché dès qu'on remonte.
    @State private var headerShown = true

    /// Séries filtrées et triées, recalculées quand les entrées changent.
    private var filtered: [SeriesSummary] {
        let q = state.query
        let inName = state.searchInName
        let inTags = state.searchInTags
        let filters = state.filters
        let terms = normalize(q).split(separator: " ").map(String.init).filter { !$0.isBlank }
        // Chaque mot doit se trouver dans le nom ou dans les tags, selon les cases cochées.
        func hit(_ s: SeriesSummary, _ t: String) -> Bool {
            (inName && s.nameKey.contains(t)) || (inTags && s.tagsKey.contains(t))
        }
        // Séries sans aucun volume disponible : masquées par défaut ; visibles en cherchant leur nom
        // ou avec le filtre « Nombre de volumes → Aucun ».
        let showEmpty = !terms.isEmpty || filters.volumes.contains("0")
        return state.sort.sorted(state.series.filter { s in
            (showEmpty || s.volumeCount > 0) && (terms.isEmpty || terms.allSatisfy { hit(s, $0) }) && filters.matches(s)
        }, desc: state.sortDesc)
    }

    private func offlineOf(_ s: SeriesSummary) -> Int {
        let bySeries = offline.downloadedBySeries()
        return (bySeries.0[s.id] ?? 0) + (bySeries.1[s.title] ?? 0)
    }

    var body: some View {
        listBody
            .background(cs.bg)
            .task { state.loadLibrary() }
            .task(id: state.selectedLibrary?.id) { await reloadKeepReading() }
            .task(id: state.progressVersion) { await reloadKeepReading() }
            .onAppear { state.visibleSeries = filtered }
            .onChange(of: state.series) { _ in state.visibleSeries = filtered }
            .onChange(of: state.query) { _ in state.visibleSeries = filtered }
            .onChange(of: state.filters) { _ in state.visibleSeries = filtered }
            .onChange(of: state.sort) { _ in state.visibleSeries = filtered }
            .onChange(of: state.sortDesc) { _ in state.visibleSeries = filtered }
            .onChange(of: state.searchInName) { _ in state.visibleSeries = filtered }
            .onChange(of: state.searchInTags) { _ in state.visibleSeries = filtered }
            .sheet(isPresented: $sheet) {
                LibraryFilterSheet(all: state.series, filters: state.filters, resultCount: filtered.count,
                                   onChange: { state.filters = $0 })
            }
            .overlay {
                if confirmDownload {
                    ConfirmDialog(
                        title: "Télécharger \(selected.count) série(s) hors ligne ?",
                        text: "Tous les tomes possédés des séries sélectionnées seront téléchargés sur le téléphone. Cela peut être volumineux.",
                        confirm: "Télécharger",
                        onConfirm: { startBatchDownload() },
                        onDismiss: { confirmDownload = false }
                    )
                }
            }
            .overlay {
                if confirmDelete {
                    ConfirmDialog(
                        title: "Supprimer \(selected.count) série(s) ?",
                        text: "Les dossiers et fichiers des séries sélectionnées seront supprimés du disque. Cette action est irréversible.",
                        confirm: "Supprimer",
                        onConfirm: { batch("Séries supprimées", reload: true) { a, id in try await ItemActions.deleteSeries(a, id) } },
                        onDismiss: { confirmDelete = false }
                    )
                }
            }
            .overlay {
                if let aq = addQuery {
                    SeriesAddDialog(initialQuery: aq, onDismiss: { addQuery = nil }, onAdded: { sid, title in
                        addQuery = nil
                        state.openSeriesById(sid, title)
                    })
                }
            }
    }

    /// Série visée par le menu contextuel (favoris, à lire plus tard, sélection).
    // (plus nécessaire : le menu contextuel iOS porte les actions directement)

    // --- Listes ------------------------------------------------------------------

    @ViewBuilder
    private var listBody: some View {
        let filtered = self.filtered
        VStack(spacing: 0) {
            if headerShown || !selected.isEmpty {
                header
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if state.libraryLoading && state.series.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer()
            } else if state.libraryGrid {
                grid(filtered)
            } else {
                list(filtered)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: headerShown)
    }

    private func grid(_ filtered: [SeriesSummary]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: state.libraryCellSize), spacing: 12)], spacing: 14) {
                listHeader
                ForEach(filtered) { s in
                    SeriesCell(
                        s: s, cover: state.coverUrl(s.coverPath),
                        selected: selected.contains(s.id), offline: offlineOf(s),
                        setList: { toRead, fav in setList(s, toReadLater: toRead, isFavorite: fav) },
                        onSelect: { toggle(s.id) },
                        onClick: { click(s) }
                    )
                }
                if !state.query.isBlank { addRow }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .scrollOffset(in: "libScroll")
        }
        .coordinateSpace(name: "libScroll")
        .onPreferenceChange(ScrollOffsetKey.self) { trackScroll($0) }
        .refreshable { await refresh() }
    }

    private func list(_ filtered: [SeriesSummary]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                listHeader
                ForEach(filtered) { s in
                    SeriesRow(
                        s: s, cover: state.coverUrl(s.coverPath),
                        selected: selected.contains(s.id), offline: offlineOf(s),
                        setList: { toRead, fav in setList(s, toReadLater: toRead, isFavorite: fav) },
                        onSelect: { toggle(s.id) },
                        onClick: { click(s) }
                    )
                    Divider().padding(.leading, 84)
                }
                if !state.query.isBlank { addRow }
            }
            .padding(.bottom, 8)
            .scrollOffset(in: "libScroll")
        }
        .onPreferenceChange(ScrollOffsetKey.self) { trackScroll($0) }
        .refreshable { await refresh() }
    }

    /// En-tête masqué vers le bas (seuil 24 pt pour éviter les sauts), réaffiché dès qu'on remonte.
    private func trackScroll(_ offset: CGFloat) {
        if offset > 24 && headerShown { headerShown = false }
        else if offset < 8 && !headerShown { headerShown = true }
    }

    private func refresh() async {
        state.loadLibrary(force: true)
        await reloadKeepReading()
    }

    /// En-tête : barre d'outils, portée de recherche, sélecteur de bibliothèque et infos.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !selected.isEmpty {
                HStack(spacing: 4) {
                    Button { selected = [] } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                        .accessibilityLabel("Annuler la sélection")
                    Text("\(selected.count)").font(.headline).lineLimit(1)
                    Spacer()
                    Button { selected = Set(filtered.map { $0.id }) } label: { Image(systemName: "checklist").frame(width: 36, height: 36) }
                        .accessibilityLabel("Tout sélectionner")
                    Button { confirmDownload = true } label: { Image(systemName: "arrow.down.circle").frame(width: 36, height: 36) }
                        .accessibilityLabel("Télécharger hors ligne")
                    // Métadonnées, scan et suppression : réservés aux administrateurs.
                    if !state.isReader {
                        Button { batch("Mise à jour lancée", reload: false) { a, id in try await ItemActions.updateSeriesMetadata(a, id) } } label: {
                            Image(systemName: "arrow.triangle.2.circlepath").frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Mettre à jour les métadonnées (Bédéthèque)")
                        Button { batch("Scan lancé", reload: true) { a, id in try await ItemActions.scanSeries(a, id) } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Scanner les fichiers")
                        Button { confirmDelete = true } label: {
                            Image(systemName: "trash").frame(width: 36, height: 36).foregroundColor(cs.error)
                        }
                        .accessibilityLabel("Supprimer")
                    }
                }
            } else {
                HStack(spacing: 4) {
                    // Pas de « + » ici : l'ajout de série se fait depuis Recherche.
                    CompactSearchField(
                        value: $state.query,
                        placeholder: state.searchInName && state.searchInTags ? "Série, auteur, tag…" :
                            (state.searchInTags ? "Tag…" : "Série, auteur…")
                    )
                    Menu {
                        ForEach(LibrarySort.allCases) { o in
                            Button {
                                if state.sort == o { state.setSort(o, !state.sortDesc) } else { state.setSort(o, o.defaultDesc) }
                            } label: {
                                Label(o.label, systemImage: sortIcon(o))
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down").frame(width: 36, height: 36)
                            .accessibilityLabel("Trier")
                    }
                    // Bouton de filtres, avec le nombre de groupes actifs.
                    Button { sheet = true } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .frame(width: 36, height: 36)
                            .overlay(alignment: .topTrailing) {
                                if state.filters.activeCount > 0 {
                                    Text("\(state.filters.activeCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .background(Capsule().fill(cs.error))
                                        .foregroundColor(Color.white)
                                        .offset(x: 7, y: -3)
                                }
                            }
                            .accessibilityLabel("Filtres")
                    }
                    // Albums hors ligne (remplace l'ancien onglet « Hors ligne »).
                    Button { state.subTab[Section.library] = 1 } label: {
                        Image(systemName: "pin").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Albums hors ligne")
                    // Liste ↔ grille de couvertures.
                    Button { state.libraryGrid = !state.libraryGrid } label: {
                        Image(systemName: state.libraryGrid ? "list.bullet" : "square.grid.2x2").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(state.libraryGrid ? "Afficher en liste" : "Afficher en grille")
                }
            }
            // Portée de la recherche (affichée dès qu'on tape) : nom de la série et/ou tags ; au moins une reste cochée.
            if selected.isEmpty && (!state.query.isBlank || !state.searchInName || !state.searchInTags) {
                HStack(spacing: 8) {
                    Text("Chercher dans").font(.caption).foregroundColor(cs.muted)
                    FilterChip(selected: state.searchInName, onClick: { if !state.searchInName || state.searchInTags { state.searchInName = !state.searchInName } }, label: { Text("Nom de la série") })
                    FilterChip(selected: state.searchInTags, onClick: { if !state.searchInTags || state.searchInName { state.searchInTags = !state.searchInTags } }, label: { Text("Tags") })
                }
            }
            // Bibliothèque : nom + menu déroulant ; nombre de séries et taille des miniatures sur la même ligne.
            HStack {
                LibraryPicker()
                if state.libraryGrid { SizeSlider(value: $state.libraryCellSize, range: 80...200) }
            }
            .padding(.top, 2)
            if let lib = state.selectedLibrary {
                Text("\(filtered.count) série(s)" + (lib.volumesCount.map { " · \($0) tomes" } ?? ""))
                    .font(.caption2)
                    .foregroundColor(cs.muted)
                    .padding(.leading, 12)
                    .padding(.bottom, 2)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 4)
    }

    private func sortIcon(_ o: LibrarySort) -> String {
        switch o {
        case .title: return "textformat"
        case .popularity: return "hand.thumbsup"
        case .date: return "clock"
        case .size: return "internaldrive"
        }
    }

    @ViewBuilder
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = state.libraryError {
                ErrorCard(message: err)
                    .padding(16)
                Button {
                    state.subTab[Section.library] = 1
                } label: {
                    Text("Sans réseau ? Ouvrir les albums hors ligne").font(.subheadline)
                }
                .padding(.horizontal, 8)
            }
            if !state.libraryLoading && state.libraryError == nil && state.libraries.isEmpty {
                EmptyStateView(title: "Aucune bibliothèque", detail: "Créez-en une dans l'interface web de Bullarr.")
            }
            let recent = currentRecent
            if !recent.isEmpty && state.query.isBlank && state.filters.isEmpty && selected.isEmpty {
                ContinueReading(recent: recent)
            }
            if filtered.isEmpty && !state.series.isEmpty {
                VStack(spacing: 8) {
                    EmptyStateView(
                        title: "Aucun résultat",
                        detail: !state.query.isBlank
                            ? "pour « \(state.query) »" + (state.filters.isEmpty ? "" : " avec ces filtres")
                            : "Aucune série ne correspond aux filtres."
                    )
                    if !state.filters.isEmpty {
                        Button("Réinitialiser les filtres") { state.filters = LibraryFilters() }
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Recherche en cours : proposer d'ajouter la BD (fiche Bédéthèque) après les séries trouvées.
    private var addRow: some View {
        Button {
            addQuery = state.query.trimmed
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 20))
                    .foregroundColor(cs.accent)
                Text((state.isReader ? "Demander « " : "Ajouter « ") + "\(state.query.trimmed) »")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(cs.accent)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // --- Continuer la lecture ---------------------------------------------------

    /// Albums commencés : ceux de Komga (lu par le serveur) sinon, hors réseau, ceux de l'appareil.
    /// Relu à la fermeture du lecteur (progressVersion) pour rafraîchir l'avancement.
    private var currentRecent: [RecentRead] {
        _ = state.progressVersion
        if let kr = state.keepReading { return kr }
        return state.keepReadingLocal ? state.reads.recent() : []
    }

    private func reloadKeepReading() async {
        guard let api = state.api else { state.keepReadingLocal = true; return }
        do {
            if let kr = try await loadKeepReading(api, state.selectedLibrary?.id) {
                state.keepReading = kr
                state.keepReadingLocal = kr.isEmpty
            } else {
                state.keepReading = nil
                state.keepReadingLocal = true
            }
        } catch {
            if state.keepReading == nil { state.keepReadingLocal = true }
        }
    }

    // --- Sélection / actions groupées ------------------------------------------

    private func setList(_ sm: SeriesSummary, toReadLater: Bool? = nil, isFavorite: Bool? = nil) {
        guard let api = state.api else { return }
        let id = sm.id
        launchAction("Liste mise à jour") {
            try await ItemActions.setSeriesReadingLists(api, id, toReadLater: toReadLater, isFavorite: isFavorite)
            state.updateSeriesRow(id) { row in
                row.with(toReadLater: toReadLater ?? row.toReadLater, isFavorite: isFavorite ?? row.isFavorite)
            }
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func batch(_ ok: String, reload: Bool, _ one: @escaping (BullarrApi, Int) async throws -> Void) {
        guard let api = state.api else { return }
        let ids = Array(selected)
        selected = []
        launchAction("\(ok) (\(ids.count))", then: {
            if reload { state.loadLibrary(force: true) }
        }) {
            for id in ids { try await one(api, id) }
        }
    }

    private func click(_ s: SeriesSummary) {
        if !selected.isEmpty { toggle(s.id) } else { open(s) }
    }

    /// Télécharge tous les tomes possédés des séries sélectionnées.
    private func startBatchDownload() {
        guard let api = state.api else { return }
        let filtered = self.filtered
        let picked = filtered.filter { selected.contains($0.id) }
        selected = []
        launchAction("Téléchargements lancés") {
            var n = 0
            for sm in picked {
                let raw = try await api.getObject("api/series/\(sm.id)")
                let d = parseSeriesDetail(raw)
                for v in d.volumes where v.owned && !offline.isDownloaded(v.id) && offline.active[v.id] == nil {
                    offline.start(v.id, "\(d.title) · \(v.label)")
                    n += 1
                }
            }
            if n == 0 { throw ApiException("Rien à télécharger : tout est déjà hors ligne.") }
        }
    }
}

// MARK: - Pièces de l'écran

/// « Continuer la lecture » : les albums commencés, couverture et avancement ; un appui reprend la lecture.
struct ContinueReading: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    @AppStorage("keep_reading_open") private var expanded = false
    let recent: [RecentRead]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text("Continuer la lecture").font(.subheadline.weight(.semibold)).foregroundColor(cs.text)
                    Text(" · \(recent.count)").font(.subheadline).foregroundColor(cs.muted)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(cs.muted)
                        .accessibilityLabel(expanded ? "Replier" : "Déplier")
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(recent, id: \.volumeId) { r in
                            ContinueCell(r: r)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            Divider()
                .padding(.top, expanded ? 8 : 0)
                .padding(.bottom, 4)
        }
    }
}

/// Une vignette de « Continuer la lecture ».
struct ContinueCell: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs
    let r: RecentRead

    var body: some View {
        Button {
            // Ouvrir la fiche sous la liseuse : le retour ramène à la série, pas à la bibliothèque.
            if let sid = r.seriesId, sid > 0 { state.openSeriesById(sid, r.seriesTitle ?? "") }
            state.reading = ReaderTarget(
                volumeId: r.volumeId,
                title: [r.seriesTitle, r.label].compactMap { $0 }.joined(separator: " · "),
                seriesId: r.seriesId,
                seriesTitle: r.seriesTitle
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Cover(url: state.coverUrl(r.coverPath ?? state.series.first { $0.id == r.seriesId }?.coverPath), width: 92)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(cs.outlineVariant)
                        Capsule().fill(cs.accent).frame(width: max(2, geo.size.width * progress))
                    }
                }
                .frame(height: 3)
                Text(r.seriesTitle ?? r.title ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(cs.text)
                    .lineLimit(1)
                Text([r.label, "p. \(r.page + 1)/\(r.total)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundColor(cs.muted)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 92)
    }

    private var progress: CGFloat {
        let total = max(1, r.total)
        return CGFloat(min(1, Double(r.page + 1) / Double(total)))
    }
}

/// Case de la grille : couverture arrondie, pastilles (favori, à lire, hors ligne) et titre.
struct SeriesCell: View {
    @Environment(\.bullColors) private var cs
    let s: SeriesSummary
    let cover: String?
    let selected: Bool
    let offline: Int
    /// Appui long : favoris et « à lire plus tard » (toReadLater, isFavorite).
    let setList: (Bool?, Bool?) -> Void
    let onSelect: () -> Void
    let onClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .topTrailing) {
                    Cover(url: cover, width: geo.size.width)
                        .overlay(alignment: .bottom) { ReadProgressBar(s: s) }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected ? cs.accent : Color.clear, lineWidth: 3)
                        )
                    if s.isFavorite || s.toReadLater || offline > 0 {
                        HStack(spacing: 2) {
                            if s.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)) }
                            if s.toReadLater { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                            if offline > 0 { Image(systemName: "pin").font(.system(size: 10)) }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
                        .padding(5)
                        .accessibilityLabel([s.isFavorite ? "Favori" : nil, s.toReadLater ? "À lire plus tard" : nil, offline > 0 ? "\(offline) album(s) hors ligne" : nil].compactMap { $0 }.joined(separator: ", "))
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(cs.accent)
                            .background(Circle().fill(cs.surface))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(5)
                            .accessibilityLabel("Sélectionnée")
                    }
                }
            }
            .aspectRatio(1 / 1.38, contentMode: .fit)
            .contextMenu {
                Button(s.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { setList(nil, !s.isFavorite) }
                Button(s.toReadLater ? "Retirer de « à lire plus tard »" : "Ajouter à « à lire plus tard »") { setList(!s.toReadLater, nil) }
                Button("Sélectionner") { onSelect() }
            }
            .onTapGesture { onClick() }
            Text(s.title)
                .font(.caption.weight(.medium))
                .foregroundColor(cs.text)
                .lineLimit(2)
                .padding(.horizontal, 2)
            Text(countText)
                .font(.caption2)
                .foregroundColor(cs.muted)
                .lineLimit(1)
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
        }
    }

    private var countText: String {
        if s.isOneshot { return "One-shot" }
        if let t = s.totalKnown { return "\(s.ownedTomes)/\(t) tomes" }
        return "\(s.ownedTomes) tome(s)"
    }
}

/// Nom de la bibliothèque courante ; s'il y en a plusieurs, un appui ouvre la liste pour en changer.
struct LibraryPicker: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.bullColors) private var cs

    var body: some View {
        Menu {
            ForEach(state.libraries, id: \.id) { lib in
                let cur = lib.id == state.selectedLibrary?.id
                Button {
                    if !cur { state.selectLibrary(lib) }
                } label: {
                    if cur {
                        Label(lib.name, systemImage: "checkmark")
                    } else {
                        Text(lib.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.selectedLibrary?.name ?? "")
                    .font(.headline)
                    .foregroundColor(cs.text)
                    .lineLimit(1)
                if state.libraries.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(cs.muted)
                        .accessibilityLabel("Changer de bibliothèque")
                }
            }
        }
        .disabled(state.libraries.count < 2)
    }
}

/// Petit curseur discret pour la taille des miniatures de la grille.
struct SizeSlider: View {
    @Environment(\.bullColors) private var cs
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12))
                .foregroundColor(cs.muted)
            Slider(value: $value, in: range)
                .frame(width: 88)
            Image(systemName: "photo")
                .font(.system(size: 14))
                .foregroundColor(cs.muted)
                .accessibilityLabel("Taille des miniatures")
        }
    }
}

/// Ligne de la liste : couverture, titre, méta et pastilles d'état.
struct SeriesRow: View {
    @Environment(\.bullColors) private var cs
    let s: SeriesSummary
    let cover: String?
    let selected: Bool
    let offline: Int
    /// Appui long : favoris et « à lire plus tard » (toReadLater, isFavorite).
    let setList: (Bool?, Bool?) -> Void
    let onSelect: () -> Void
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Cover(url: cover, width: 52)
                .overlay(alignment: .bottom) { ReadProgressBar(s: s, height: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(cs.text)
                    .lineLimit(2)
                let meta = [s.author, s.year].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundColor(cs.muted)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let origin = s.origin {
                        Logo(key: origin.lowercased(), label: origin, size: 16, tip: false)
                    }
                    if s.isOneshot {
                        IconTag(icon: "book", label: "One-shot", tint: cs.muted)
                    } else {
                        IconTag(icon: "books.vertical", label: "Tomes possédés", tint: cs.muted, text: owned)
                    }
                    if offline > 0 { IconTag(icon: "pin", label: "\(offline) album(s) hors ligne", tint: cs.accent, text: "\(offline)") }
                    if s.missingCount > 0 { IconTag(icon: "exclamationmark.triangle", label: "\(s.missingCount) manquant(s)", tint: cs.tertiary, text: "\(s.missingCount)") }
                    if s.isFavorite { IconTag(icon: "star.fill", label: "Favori", tint: cs.accentHover) }
                    if s.toReadLater { IconTag(icon: "bookmark.fill", label: "À lire plus tard", tint: cs.accentHover) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(cs.accent)
                    .padding(.trailing, 12)
                    .accessibilityLabel("Sélectionnée")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .background(selected ? cs.accentContainer : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button(s.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") { setList(nil, !s.isFavorite) }
            Button(s.toReadLater ? "Retirer de « à lire plus tard »" : "Ajouter à « à lire plus tard »") { setList(!s.toReadLater, nil) }
            Button("Sélectionner") { onSelect() }
        }
        .onTapGesture { onClick() }
    }

    private var owned: String {
        if let t = s.totalKnown { return "\(s.ownedTomes)/\(t)" }
        return "\(s.ownedTomes)"
    }
}

// MARK: - Offset de défilement (masquage de l'en-tête)

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Publie le décalage vertical du contenu par rapport à l'espace de défilement nommé.
    func scrollOffset(in space: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(
                key: ScrollOffsetKey.self,
                value: -geo.frame(in: .named(space)).minY
            )
        })
    }
}

/// Barre de lecture en bas de la miniature, comme sur le site : affichée dès qu'un tome est lu
/// ou commencé, remplie à la part lue (pages des tomes commencés comprises).
private struct ReadProgressBar: View {
    @Environment(\.bullColors) private var cs
    let s: SeriesSummary
    var height: CGFloat = 4

    var body: some View {
        if s.readTotal > 0 && s.readCount + s.readingCount > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.35))
                    Rectangle().fill(cs.accent)
                        .frame(width: geo.size.width * min(1, CGFloat(s.readUnits) / CGFloat(s.readTotal)))
                }
            }
            .frame(height: height)
            .accessibilityLabel("\(s.readCount)/\(s.readTotal) lus")
        }
    }
}
